{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
-- | The dispatcher. Runs the pure authorization gate, then — for Untrusted
-- opcodes — durably records the invocation (itwRecordAndAck) BEFORE executing,
-- so no untrusted action runs until its audit entry is on disk. Trusted
-- opcodes record concurrently with execution.
--
-- Invariant: for an Untrusted opcode, itwRecordAndAck completes before opRun
-- is called. This ordering is the whole point of the module.
--
-- There is no longer an Audited branch: the four evolutionary stores
-- (memory, skills, agent-defs) are file-backed under @config\/@ and versioned
-- by git; their opcodes are Trusted file writes that auto-commit. The session
-- transcript (indexed transcript format) remains the per-session record of every opcode
-- invocation, recorded here as an 'EKHarness' entry.
--
-- Opcode invocations are recorded as 'EKHarness' entries in @entries.jsonl@:
-- the opcode name goes into 'erMeta' under @"op"@, and the secret-free input
-- goes into 'erMeta' under @"input"@. No conversation lines are added.
module Seal.ISA.Dispatch
  ( DispatchError (..)
  , dispatch
  , dispatchOn
  , recordSkillLoadResult
  , recordSetupRepoResult
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.Handles.Transcript (IndexedTranscriptHandle (..), IndexedTranscriptWrite (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Providers.Class (ContentBlock (..), pattern Message, Role (..), ToolResultPart (..))
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Types.App
import Seal.Tools.Exec.Abort (AbortFlag)
import Seal.Tools.Exec.Timeout (runWithTimeoutAbortRetry)
import Seal.Tools.Exec.UIO.Internal (UIOEnv (..))
import Seal.Tools.Exec.Machine
  ( MachineError (..), rtResolve, rtSelectable, rtSession )
import Seal.ISA.Ops.Machine
  ( machineField, renderMachineError )
import Seal.Config.Machines
  ( MachineName, Selectable (..), localMachineName, machineNameText, mkMachineName )
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Timeout (Microseconds (..), ToolError, ToolTimeoutConfig, errorClass, extractPerCallTimeout, renderToolError)

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

-- | Dispatch an opcode invocation. The dispatcher threads a 'UIOEnv'
-- for Untrusted opcodes (the restricted execution environment carrying
-- the 'UntrustedIO' capability handle + the Git 'CloneDeps' surface);
-- Trusted/Audited opcodes ignore it (they have no 'UIOEnv' in scope —
-- type-level capability scoping, spec §4/§8).
-- | The error class recorded when machine resolution fails, so the transcript
-- shows why a call never ran without duplicating the rendered message.
resolvedErrClass :: Text
resolvedErrClass = "machine"

-- | Dispatch an opcode. See 'dispatchOn' for the machine-reporting variant.
dispatch
  :: Registry -> IndexedTranscriptHandle -> BackendExec -> UIOEnv
  -> ToolTimeoutConfig -> AbortFlag
  -> OpName -> Value
  -> App (Either DispatchError OpResult)
dispatch reg h backend uioEnv tt abort name input =
  fmap fst (dispatchOn reg h backend uioEnv tt abort name input)

-- | 'dispatch', also reporting WHICH machine the call ran on.
--
-- The machine is resolved inside 'dispatch' anyway (to pick the handle and,
-- for an untrusted call, to stamp the ACK). Callers that act on the result —
-- notably the post-@SETUP_REPO@ hooks in 'Seal.Core.TurnEngine', which must not
-- re-scan the SESSION machine's workdir after a clone landed on ANOTHER one —
-- need that name, and re-deriving it outside would be a second resolution that
-- could disagree.
--
-- 'Nothing' for a Trusted opcode (there is no machine) and for a call that
-- never reached resolution (not found, denied). 'Just' the RESOLVED machine for
-- an untrusted call that got as far as picking a target, including one whose
-- bootstrap then failed: the caller still needs to know where it was aimed.
dispatchOn
  :: Registry -> IndexedTranscriptHandle -> BackendExec -> UIOEnv
  -> ToolTimeoutConfig -> AbortFlag
  -> OpName -> Value
  -> App (Either DispatchError OpResult, Maybe MachineName)
dispatchOn reg h backend uioEnv toolTimeout abortFlag name input =
  case lookupOp reg name of
    Nothing -> pure (Left (OpNotFound name), Nothing)
    Just op ->
      case opAuthorize op input of
        Left why -> pure (Left (Denied why), Nothing)
        Right () -> do
          let -- Extract the per-call timeout (in seconds → microseconds)
              -- from the input JSON, clamped to the max.
              Microseconds perCallMicros = extractPerCallTimeout input toolTimeout
          case op of
            UntrustedOpcode {} -> do
              -- Resolve the target machine BEFORE the ACK, so the durable
              -- record names the machine that will actually run (design §6.5).
              -- The pure part needs no handle and no connection; a failed
              -- resolution records the REQUESTED name plus an error class, so a
              -- model naming a forbidden machine still leaves a trace.
              case resolveMachineForCall uioEnv input of
                Left merr -> do
                  let requested = machineField input
                  entry' <- liftIO (mkInvocationEntry name input (requested, Just resolvedErrClass))
                  liftIO (itwRecordAndAck h (IndexedTranscriptWrite [] entry'))
                  pure (Left (ExecFailed (renderMachineError name merr)), Nothing)
                Right resolved -> do
                  -- Fetch-or-bootstrap the machine's capabilities, then build
                  -- the per-call environment. Swapping BOTH fields is required:
                  -- CloneDeps is transport-bound, so a call routed to another
                  -- machine must not inherit the session machine's transport.
                  resolvedCaps <- liftIO (rtResolve (uieMachines uioEnv) resolved)
                  case resolvedCaps of
                    Left merr -> do
                      entry' <- liftIO (mkInvocationEntry name input (Just (machineNameText resolved), Just resolvedErrClass))
                      liftIO (itwRecordAndAck h (IndexedTranscriptWrite [] entry'))
                      pure (Left (ExecFailed (renderMachineError name merr))
                             , Just resolved)
                    Right (handle', deps') -> do
                      let callEnv = uioEnv { uieUntrustedIO = handle'
                                           , uieCloneDeps   = deps' }
                      entry' <- liftIO (mkInvocationEntry name input (Just (machineNameText resolved), Nothing))
                      liftIO (itwRecordAndAck h (IndexedTranscriptWrite [] entry'))   -- ACK-before-execute
                      let ioAction :: IO (Either ToolError OpResult)
                          ioAction = do
                            r <- runUIOWithEnv callEnv (uoRun op input)
                            pure (Right r)
                      raced <- liftIO (runWithTimeoutAbortRetry toolTimeout abortFlag (Microseconds perCallMicros) ioAction)
                      case raced of
                        Right opResult -> pure (Right opResult, Just resolved)
                        Left toolErr -> do
                          liftIO (recordToolError h name input toolErr perCallMicros)
                          pure (Left (ExecFailed (renderToolError name toolErr)), Just resolved)
            TrustedOpcode {} ->
              case opTrust op of
                Trusted -> do
                  entry <- liftIO (mkInvocationEntry name input (Nothing, Nothing))
                  liftIO (itwRecordAsync h (IndexedTranscriptWrite [] entry))
                  addNoMachine <$> runTrustedOpcode h backend toolTimeout abortFlag op name input perCallMicros
                Audited -> do
                  entry <- liftIO (mkInvocationEntry name input (Nothing, Nothing))
                  -- No Audited log remains; treat as Trusted (record to the
                  -- session transcript, then run). The evolutionary-store
                  -- opcodes that used to be Audited are now Trusted file writes.
                  liftIO (itwRecordAsync h (IndexedTranscriptWrite [] entry))
                  addNoMachine <$> runTrustedOpcode h backend toolTimeout abortFlag op name input perCallMicros
                Untrusted ->
                  -- Unreachable: an UntrustedOpcode would have matched above.
                  -- Kept for exhaustiveness (the GADT already separates the
                  -- arms; opTrust on a TrustedOpcode returns its stored tl,
                  -- which the Opcode invariants guarantee is Trusted or Audited).
                  error "dispatch: invariant violation — Untrusted trust on a TrustedOpcode"
  where
    -- A Trusted opcode runs in-process on the control plane: there is no
    -- execution machine to report.
    addNoMachine r = (r, Nothing)

    -- | Run a Trusted opcode, conditionally wrapping it in the
    -- timeout/abort/retry race. Blocking opcodes (ASK_HUMAN) skip the
    -- race — they block on human input which can take arbitrarily long,
    -- and the 'AskReplyStore' has its own cancel mechanism. Non-blocking
    -- opcodes get the full timeout/abort/retry treatment.
    runTrustedOpcode
      :: IndexedTranscriptHandle -> BackendExec -> ToolTimeoutConfig -> AbortFlag
      -> Opcode -> OpName -> Value -> Int
      -> App (Either DispatchError OpResult)
    runTrustedOpcode h' backend' tt abort op' nm inp micros
      | opBlocking op' = do
          -- Blocking: run directly, no timeout race.
          r <- toRun op' backend' inp
          pure (Right r)
      | otherwise = do
          env <- ask
          let ioAction :: IO (Either ToolError OpResult)
              ioAction = do
                r <- runApp env (toRun op' backend' inp)
                pure (Right r)
          raced <- liftIO (runWithTimeoutAbortRetry tt abort (Microseconds micros) ioAction)
          case raced of
            Right opResult -> pure (Right opResult)
            Left toolErr -> do
              liftIO (recordToolError h' nm inp toolErr micros)
              pure (Left (ExecFailed (renderToolError nm toolErr)))

-- | Build the 'EntryRecord' for an opcode invocation. The opcode name and the
-- secret-free input are recorded in 'erMeta'; the entry kind is 'EKHarness'.
-- 'erConvLen' is 0 because no conversation lines are added by an opcode
-- invocation.
--
-- For an untrusted opcode the resolved execution machine is recorded too, so
-- the durable record names the machine the call actually ran on. That is
-- strictly stronger than recording only what the model typed: a call that omits
-- @machine@ still records the session machine it used. A resolution failure
-- records the /requested/ name plus an error class, so a model naming a
-- forbidden machine leaves a trace.
--
-- The record carries the machine NAME and nothing else about it — no host, user
-- or path.
mkInvocationEntry :: OpName -> Value -> (Maybe Text, Maybe Text) -> IO EntryRecord
mkInvocationEntry name input (mMachine, mErrClass) = do
  now <- getCurrentTime
  let machineField' = case mMachine of
        Nothing -> []
        Just nm -> [("machine", String nm)]
      errField = case mErrClass of
        Nothing -> []
        Just cls -> [("error", String cls)]
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
    , erMeta = Map.fromList $
        [ ("op", object ["name" .= name])
        , ("input", input) ] <> machineField' <> errField
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
-- 'Seal.Agent.Loop' reads @itwReadConversation@); without this write,
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
recordSkillLoadResult :: IndexedTranscriptHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()
recordSkillLoadResult h (OpName nm) input result mChannel
  | isSkillLoadOp nm input && not (orIsError result) = do
      now <- getCurrentTime
      let channelMeta = case mChannel of
            Just ch  -> [("channel", A.String ch)]
            Nothing  -> []
          entry = EntryRecord
            { erId = ""
            , erTimestamp = now
            , erKind = EKHarness
            , erConvLen = length convMsgs
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
          convMsgs =
            [ Message Assistant [CbText bodyText] | not (T.null bodyText) ]
      itwRecordAndAck h (IndexedTranscriptWrite convMsgs entry)
  | otherwise = pure ()

-- | Predicate: is this opcode invocation a skill-load? Matches the
-- consolidated @SKILL_MANAGE@ with @action="load"@, and also the legacy
-- @SKILL_LOAD@ name (for backward compatibility with old transcripts and
-- any caller still dispatching the legacy shim).
isSkillLoadOp :: Text -> Value -> Bool
isSkillLoadOp nm input =
  nm == "SKILL_LOAD"
  || (nm == "SKILL_MANAGE" && parseAction input == Just ("load" :: Text))
  where
    parseAction = parseMaybe (withObject "input" (.: "action"))

-- | Record the result of a 'SETUP_REPO' opcode invocation as an
-- 'EKHarness' transcript entry + a conversation message. Unlike
-- 'recordSkillLoadResult', this records BOTH success and failure (a
-- failed clone is the case the operator most needs to see in the
-- transcript — the error text tells them why the repo didn't appear).
-- The conversation message carries the opcode's text result so the
-- user sees the clone/no-op/conflict/failure message in the chat.
recordSetupRepoResult :: IndexedTranscriptHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()
recordSetupRepoResult h (OpName nm) input result mChannel = do
  now <- getCurrentTime
  let channelMeta = case mChannel of
        Just ch  -> [("channel", A.String ch)]
        Nothing  -> []
      entry = EntryRecord
        { erId = ""
        , erTimestamp = now
        , erKind = EKHarness
        , erConvLen = length convMsgs
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
  itwRecordAndAck h (IndexedTranscriptWrite convMsgs entry)

-- | Record a 'ToolError' as an 'EKHarness' transcript entry carrying the
-- error CLASS (secret-free — design Blocker Resolution #13: never the full
-- 'ToolIOError' Text payload, which could contain paths/host info). The
-- metadata includes the timeout value (seconds) and the error class string.
-- Called by 'dispatch' when the timeout/abort/retry wrapper returns 'Left'.
recordToolError :: IndexedTranscriptHandle -> OpName -> Value -> ToolError -> Int -> IO ()
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
  itwRecordAndAck h (IndexedTranscriptWrite [] entry)

-- | Resolve which machine this call should run on, without touching a handle or
-- opening a connection.
--
-- 'Nothing' from the input means "the session's machine", which is the
-- documented default and is deliberately not sticky: every call re-resolves, so
-- a call that omits @machine@ after one that named another machine goes back to
-- the session machine.
--
-- A name that does not parse, or that is not selectable, is 'MachineUnknown'
-- carrying the name the model asked for and the valid choices — so the error
-- can list them.
resolveMachineForCall
  :: UIOEnv
  -> Value
  -> Either MachineError MachineName
resolveMachineForCall uioEnv input =
  case machineField input of
    Nothing  -> Right (rtSession (uieMachines uioEnv))
    Just raw ->
      case mkMachineName raw of
        Right name | name `elem` selectableNames uioEnv -> Right name
        _ -> Left (MachineUnknown raw (selectableNames uioEnv))

-- | The names that may be chosen, @local@ included when permitted. 'local' is
-- reserved (mkMachineName refuses to construct it), so it comes from the
-- registry's own constant rather than a parse.
selectableNames :: UIOEnv -> [MachineName]
selectableNames uioEnv =
  [ nm | SelMachine nm <- rtSelectable (uieMachines uioEnv) ]
    <> [ localMachineName | SelLocal <- rtSelectable (uieMachines uioEnv) ]
