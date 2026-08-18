{-# LANGUAGE OverloadedStrings #-}
-- | The dispatcher. Runs the pure authorization gate, then — for Untrusted
-- opcodes — durably records the invocation (tfwRecordAndAck) BEFORE executing,
-- so no untrusted action runs until its audit entry is on disk. Trusted
-- opcodes record concurrently with execution.
--
-- Invariant: for an Untrusted opcode, tfwRecordAndAck completes before opRun
-- is called. This ordering is the whole point of the module.
--
-- There is no longer an Audited branch: the four evolutionary stores
-- (memory, skills, agent-defs) are file-backed under @config\/@ and versioned
-- by git; their opcodes are Trusted file writes that auto-commit. The session
-- transcript (two-file format) remains the per-session record of every opcode
-- invocation, recorded here as an 'EKHarness' entry.
--
-- Opcode invocations are recorded as 'EKHarness' entries in @entries.jsonl@:
-- the opcode name goes into 'erMeta' under @"op"@, and the secret-free input
-- goes into 'erMeta' under @"input"@. No conversation lines are added.
module Seal.ISA.Dispatch
  ( DispatchError (..)
  , dispatch
  , recordSkillLoadResult
  , recordSetupRepoResult
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..), ToolResultPart (..))
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Types.App
import Seal.Tools.Exec.Abort (AbortFlag)
import Seal.Tools.Exec.Timeout (runWithTimeoutAbortRetry)
import Seal.Tools.Exec.UIO.Internal (UIOEnv)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Timeout (Microseconds (..), ToolError, ToolTimeoutConfig, errorClass, extractPerCallTimeout, renderToolError)

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

-- | Dispatch an opcode invocation. The dispatcher threads a 'UIOEnv'
-- for Untrusted opcodes (the restricted execution environment carrying
-- the 'UntrustedIO' capability handle + the Git 'CloneDeps' surface);
-- Trusted/Audited opcodes ignore it (they have no 'UIOEnv' in scope —
-- type-level capability scoping, spec §4/§8).
dispatch
  :: Registry -> TwoFileHandle -> BackendExec -> UIOEnv
  -> ToolTimeoutConfig -> AbortFlag
  -> OpName -> Value
  -> App (Either DispatchError OpResult)
dispatch reg h backend uioEnv toolTimeout abortFlag name input =
  case lookupOp reg name of
    Nothing -> pure (Left (OpNotFound name))
    Just op ->
      case opAuthorize op input of
        Left why -> pure (Left (Denied why))
        Right () -> do
          entry <- liftIO (mkInvocationEntry name input)
          let -- Extract the per-call timeout (in seconds → microseconds)
              -- from the input JSON, clamped to the max.
              Microseconds perCallMicros = extractPerCallTimeout input toolTimeout
          case op of
            UntrustedOpcode {} -> do
              liftIO (tfwRecordAndAck h (TwoFileWrite [] entry))   -- ACK-before-execute
              -- Wrap uoRun in the timeout/abort/retry race. The untrusted
              -- action runs via 'runUIOWithEnv' (the UIO→IO bridge carrying
              -- the 'UntrustedIO' capability handle + Git 'CloneDeps'
              -- surface from the 'UIOEnv'); the race wrapper treats it as a
              -- plain 'IO' action. OpResult semantic errors are NOT
              -- ToolErrors (wrapped Right).
              let ioAction :: IO (Either ToolError OpResult)
                  ioAction = do
                    r <- runUIOWithEnv uioEnv (uoRun op input)
                    pure (Right r)
              raced <- liftIO (runWithTimeoutAbortRetry toolTimeout abortFlag (Microseconds perCallMicros) ioAction)
              case raced of
                Right opResult -> pure (Right opResult)
                Left toolErr -> do
                  -- Record the error class in the transcript (design Task 8:
                  -- orRecorded carries the error class only — never the full
                  -- ToolIOError Text payload, which could contain paths/host
                  -- info, design Blocker Resolution #13).
                  liftIO (recordToolError h name input toolErr perCallMicros)
                  pure (Left (ExecFailed (renderToolError name toolErr)))
            TrustedOpcode {} ->
              case opTrust op of
                Trusted -> do
                  liftIO (tfwRecordAsync h (TwoFileWrite [] entry))
                  -- Wrap toRun in the same timeout/abort/retry race.
                  env <- ask
                  let ioAction :: IO (Either ToolError OpResult)
                      ioAction = do
                        r <- runApp env (toRun op backend input)
                        pure (Right r)
                  raced <- liftIO (runWithTimeoutAbortRetry toolTimeout abortFlag (Microseconds perCallMicros) ioAction)
                  case raced of
                    Right opResult -> pure (Right opResult)
                    Left toolErr -> do
                      liftIO (recordToolError h name input toolErr perCallMicros)
                      pure (Left (ExecFailed (renderToolError name toolErr)))
                Audited -> do
                  -- No Audited log remains; treat as Trusted (record to the
                  -- session transcript, then run). The evolutionary-store
                  -- opcodes that used to be Audited are now Trusted file writes.
                  liftIO (tfwRecordAsync h (TwoFileWrite [] entry))
                  env <- ask
                  let ioAction :: IO (Either ToolError OpResult)
                      ioAction = do
                        r <- runApp env (toRun op backend input)
                        pure (Right r)
                  raced <- liftIO (runWithTimeoutAbortRetry toolTimeout abortFlag (Microseconds perCallMicros) ioAction)
                  case raced of
                    Right opResult -> pure (Right opResult)
                    Left toolErr -> do
                      liftIO (recordToolError h name input toolErr perCallMicros)
                      pure (Left (ExecFailed (renderToolError name toolErr)))
                Untrusted ->
                  -- Unreachable: an UntrustedOpcode would have matched above.
                  -- Kept for exhaustiveness (the GADT already separates the
                  -- arms; opTrust on a TrustedOpcode returns its stored tl,
                  -- which the Opcode invariants guarantee is Trusted or Audited).
                  error "dispatch: invariant violation — Untrusted trust on a TrustedOpcode"

-- | Build the 'EntryRecord' for an opcode invocation. The opcode name and the
-- secret-free input are recorded in 'erMeta'; the entry kind is 'EKHarness'.
-- 'erConvLen' is 0 because no conversation lines are added by an opcode
-- invocation.
mkInvocationEntry :: OpName -> Value -> IO EntryRecord
mkInvocationEntry name input = do
  now <- getCurrentTime
  pure EntryRecord
    { erId = ""
    , erTimestamp = now
    , erKind = EKHarness
    , erConvLen = 0
    , erEnvelope = Nothing
    , erUsage = Nothing
    , erStop = Nothing
    , erDurationMs = Nothing
    , erHarness = Nothing
    , erCorrelation = Nothing
    , erMeta = Map.fromList [("op", object ["name" .= name]), ("input", input)]
    }

-- | Record a second 'EKHarness' entry carrying the opcode's 'orRecorded'
-- value as @result@ in @erMeta@. Called by the 'CallDispatcher' sites
-- (webCallDispatcher, channelCallDispatcher, CLI callDispatcher) after
-- 'dispatch' returns a successful 'Right' for the 'SKILL_LOAD' opcode.
-- The invocation entry (recorded by 'dispatch' before the opcode runs)
-- carries only @op.name@ + @input@; this result entry adds the
-- @orRecorded@ payload (which for 'SKILL_LOAD' includes the skill id,
-- description, body, updated_at, and session) so the frontend can render
-- the skill body in a collapsible tool-call box without duplicating it
-- in the transient slash bubble.
--
-- Only fires for 'SKILL_LOAD' (the v1 user-surfacing opcode). Other
-- opcodes' 'orRecorded' is not surfaced to the frontend via this path.
-- Error results ('orIsError' = True) are NOT recorded here — the error
-- text is rendered via 'ccSend' to the slash bubble instead.
--
-- The skill body is ALSO appended to @conversation.jsonl@ as an 'Assistant'
-- message carrying the rendered body text (harness output, not user input).
-- The agent loop builds its
-- next-turn context from @conversation.jsonl@ ('runTurn' at
-- 'Seal.Agent.Loop' reads @tfwReadConversation@); without this write,
-- a user-invoked @/skill load@ would record the body only to
-- @entries.jsonl@ (the audit sidecar) and the model would never see
-- the skill on the next turn — the @/skill load@ "Command output" box
-- would display but the skill would not actually load. The agent's own
-- tool-call path needs no such write because 'runTurn' already folds
-- the 'CbToolResult' into @conversation.jsonl@; this closes the gap
-- for the user-invoked path, which bypasses the agent loop.
--
-- The @channel@ argument is the communications-channel label of the
-- session the skill was loaded into (e.g. @"telegram"@, @"web"@,
-- @"cli"@), or 'Nothing' when the caller didn't supply one. It is
-- recorded under @"channel"@ in @erMeta@ so the frontend can surface
-- the channel provenance in the skill-load row's source label (e.g.
-- @"Skill · telegram"@), making it clear how/why the skill was loaded.
--
-- The @input@'s optional @message@ field (a string) is appended to
-- @conversation.jsonl@ as a SECOND 'User' message AFTER the skill body,
-- so the model sees the skill followed by the user's trailing message on
-- the next turn (e.g. @/skill load start #123@ loads the @start@ skill
-- then sends @#123@ as the user's message). When @message@ is absent or
-- blank, no second message is written (the load behaves as before — skill
-- body only).
recordSkillLoadResult :: TwoFileHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()
recordSkillLoadResult h (OpName nm) input result mChannel
  | nm == "SKILL_LOAD" && not (orIsError result) = do
      now <- getCurrentTime
      let channelMeta = case mChannel of
            Just ch  -> [("channel", A.String ch)]
            Nothing  -> []
          entry = EntryRecord
            { erId = ""
            , erTimestamp = now
            , erKind = EKHarness
            , erConvLen = 0
            , erEnvelope = Nothing
            , erUsage = Nothing
            , erStop = Nothing
            , erDurationMs = Nothing
            , erHarness = Nothing
            , erCorrelation = Nothing
            , erMeta = Map.fromList
                ([ ("op", object ["name" .= OpName nm])
                 , ("input", input)
                 , ("result", orRecorded result)
                 ] <> channelMeta)
            }
          bodyText = T.intercalate "\n" [ t | TrpText t <- orParts result ]
          -- The optional trailing message from the /skill load <id> <message>
          -- invocation. Extracted from the input's @message@ field; blank or
          -- absent yields no second conversation message.
          messageText = fromMaybe "" (parseMaybe (A.withObject "input" (A..: "message")) input)
          trimmedMessage = T.strip messageText
          convMsgs =
            [ Message Assistant [CbText bodyText] | not (T.null bodyText) ]
            <> [ Message User [CbText trimmedMessage] | not (T.null trimmedMessage) ]
      tfwRecordAndAck h (TwoFileWrite convMsgs entry)
  | otherwise = pure ()

-- | Record the result of a 'SETUP_REPO' opcode invocation as an
-- 'EKHarness' transcript entry + a conversation message. Unlike
-- 'recordSkillLoadResult', this records BOTH success and failure (a
-- failed clone is the case the operator most needs to see in the
-- transcript — the error text tells them why the repo didn't appear).
-- The conversation message carries the opcode's text result so the
-- user sees the clone/no-op/conflict/failure message in the chat.
recordSetupRepoResult :: TwoFileHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()
recordSetupRepoResult h (OpName nm) input result mChannel = do
  now <- getCurrentTime
  let channelMeta = case mChannel of
        Just ch  -> [("channel", A.String ch)]
        Nothing  -> []
      entry = EntryRecord
        { erId = ""
        , erTimestamp = now
        , erKind = EKHarness
        , erConvLen = 0
        , erEnvelope = Nothing
        , erUsage = Nothing
        , erStop = Nothing
        , erDurationMs = Nothing
        , erHarness = Nothing
        , erCorrelation = Nothing
        , erMeta = Map.fromList
            ([ ("op", object ["name" .= OpName nm])
             , ("input", input)
             , ("result", orRecorded result)
            ] <> channelMeta)
        }
      bodyText = T.intercalate "\n" [ t | TrpText t <- orParts result ]
      convMsgs = [ Message Assistant [CbText bodyText] | not (T.null bodyText) ]
  tfwRecordAndAck h (TwoFileWrite convMsgs entry)

-- | Record a 'ToolError' as an 'EKHarness' transcript entry carrying the
-- error CLASS (secret-free — design Blocker Resolution #13: never the full
-- 'ToolIOError' Text payload, which could contain paths/host info). The
-- metadata includes the timeout value (seconds) and the error class string.
-- Called by 'dispatch' when the timeout/abort/retry wrapper returns 'Left'.
recordToolError :: TwoFileHandle -> OpName -> Value -> ToolError -> Int -> IO ()
recordToolError h name input toolErr timeoutMicros = do
  now <- getCurrentTime
  let entry = EntryRecord
        { erId = ""
        , erTimestamp = now
        , erKind = EKHarness
        , erConvLen = 0
        , erEnvelope = Nothing
        , erUsage = Nothing
        , erStop = Nothing
        , erDurationMs = Nothing
        , erHarness = Nothing
        , erCorrelation = Nothing
        , erMeta = Map.fromList
            [ ("op", object ["name" .= name])
            , ("input", input)
            , ("error", A.String (errorClass toolErr))
            , ("timeout_s", A.toJSON (timeoutMicros `div` 1_000_000))
            ]
        }
  tfwRecordAndAck h (TwoFileWrite [] entry)
