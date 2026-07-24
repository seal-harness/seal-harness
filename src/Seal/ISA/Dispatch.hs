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
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Types.App
import Seal.Tools.Exec.UntrustedIO (UntrustedIO)

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

-- | Dispatch an opcode invocation. The dispatcher threads an 'UntrustedIO'
-- for Untrusted opcodes (the unified capability handle for all their
-- side-effecting IO — files, commands, process management, search);
-- Trusted/Audited opcodes ignore it (they have no 'UntrustedIO' in scope —
-- type-level capability scoping, spec §4/§8).
dispatch
  :: Registry -> TwoFileHandle -> BackendExec -> UntrustedIO -> OpName -> Value
  -> App (Either DispatchError OpResult)
dispatch reg h backend untrustedIO name input =
  case lookupOp reg name of
    Nothing -> pure (Left (OpNotFound name))
    Just op ->
      case opAuthorize op input of
        Left why -> pure (Left (Denied why))
        Right () -> do
          entry <- liftIO (mkInvocationEntry name input)
          case op of
            UntrustedOpcode {} -> do
              liftIO (tfwRecordAndAck h (TwoFileWrite [] entry))   -- ACK-before-execute
              Right <$> uoRun op untrustedIO input
            TrustedOpcode {} ->
              case opTrust op of
                Trusted -> do
                  liftIO (tfwRecordAsync h (TwoFileWrite [] entry))
                  Right <$> toRun op backend input
                Audited -> do
                  -- No Audited log remains; treat as Trusted (record to the
                  -- session transcript, then run). The evolutionary-store
                  -- opcodes that used to be Audited are now Trusted file writes.
                  liftIO (tfwRecordAsync h (TwoFileWrite [] entry))
                  Right <$> toRun op backend input
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
recordSkillLoadResult :: TwoFileHandle -> OpName -> Value -> OpResult -> IO ()
recordSkillLoadResult h (OpName nm) input result
  | nm == "SKILL_LOAD" && not (orIsError result) = do
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
                [ ("op", object ["name" .= OpName nm])
                , ("input", input)
                , ("result", orRecorded result)
                ]
            }
      tfwRecordAndAck h (TwoFileWrite [] entry)
  | otherwise = pure ()