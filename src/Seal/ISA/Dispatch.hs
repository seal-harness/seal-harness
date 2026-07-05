{-# LANGUAGE OverloadedStrings #-}
-- | The dispatcher. Runs the pure authorization gate, then — for Untrusted
-- opcodes — durably records the invocation (tfwRecordAndAck) BEFORE executing,
-- so no untrusted action runs until its audit entry is on disk. Trusted/Audited
-- opcodes record concurrently with execution.
--
-- Invariant: for an Untrusted opcode, tfwRecordAndAck completes before opRun
-- is called. This ordering is the whole point of the module.
--
-- For Audited opcodes, the dispatcher writes to BOTH the session transcript
-- (per-session audit) AND the unified cross-session Audited log (canonical for
-- the four evolutionary stores). The Audited log entry carries the opcode name,
-- the kind (derived from the opcode), the originating session, and the
-- secret-free input. Secret values never reach either log.
--
-- Opcode invocations are recorded as 'EKHarness' entries in @entries.jsonl@
-- (they are harness-internal events, not provider calls): the opcode name goes
-- into 'erMeta' under @"op"@, and the secret-free input goes into 'erMeta'
-- under @"input"@. No conversation lines are added (the opcode's tool-result
-- blocks, which may carry secret values, are never written to
-- @conversation.jsonl@ — the loop's redaction handles the case where the model
-- feeds them back as a continuation).
module Seal.ISA.Dispatch
  ( DispatchError (..)
  , dispatch
  , auditedKindFor
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Audited.Types (AuditedEntry (..), AuditedKind (..))
import Seal.Core.Types (OpName (..), SessionId (..), TrustLevel (..))
import Seal.Handles.Audited (AuditedHandle (..))
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Types.App

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

dispatch
  :: Registry -> TwoFileHandle -> AuditedHandle -> BackendExec -> OpName -> Value
  -> App (Either DispatchError OpResult)
dispatch reg h audited backend name input =
  case lookupOp reg name of
    Nothing -> pure (Left (OpNotFound name))
    Just op ->
      case opAuthorize op input of
        Left why -> pure (Left (Denied why))
        Right () -> do
          entry <- liftIO (mkInvocationEntry name input)
          case opTrust op of
            Untrusted -> do
              liftIO (tfwRecordAndAck h (TwoFileWrite [] entry))   -- ACK-before-execute
              Right <$> opRun op backend input
            Trusted -> do
              liftIO (tfwRecordAsync h (TwoFileWrite [] entry))
              Right <$> opRun op backend input
            Audited -> do
              liftIO (tfwRecordAsync h (TwoFileWrite [] entry))
              liftIO (recordAudited audited name input)
              Right <$> opRun op backend input

-- | Map an opcode name to its Audited store kind. Used by the Audited branch to
-- tag the cross-session log entry. Opcodes outside the four evolutionary
-- stores (e.g. a hypothetical opcode that is misclassified as Audited) default
-- to 'AKConfig'; the wiring layer is responsible for only registering the
-- Memory/Skills/AgentDef/Config opcodes as Audited.
auditedKindFor :: OpName -> AuditedKind
auditedKindFor (OpName n)
  | "MEMORY"  `T.isPrefixOf` n = AKMemory
  | "SKILL"   `T.isPrefixOf` n = AKSkill
  | "AGENT_"  `T.isPrefixOf` n = AKAgentDef
  | otherwise                   = AKConfig

-- | Write one entry to the Audited log. The payload is the secret-free opcode
-- input; the kind is derived from the opcode name. The session id is not known
-- to the dispatcher (it is per-turn context held in 'AgentEnv'); the wiring
-- layer threads the active session id through 'AuditedHandle' via the
-- 'aeSession' field, which the writer fills from an IORef at write time. For
-- now the session is a sentinel @\"unknown\"@ — the wiring layer can override
-- this when it constructs the entry. (M1 ships the foundation; M2 fills the
-- session field from the live session runtime.)
recordAudited :: AuditedHandle -> OpName -> Value -> IO ()
recordAudited h name input = do
  now <- getCurrentTime
  auditedAck h AuditedEntry
    { aeId = ""
    , aeTimestamp = now
    , aeSession = unknownSessionId
    , aeOpcode = name
    , aeKind = auditedKindFor name
    , aePayload = input
    }

-- | The sentinel session id used by the dispatcher when it does not yet know
-- the originating session (M1; M2 threads the live session id through the
-- 'AuditedHandle'). @"unknown"@ satisfies 'isValidSessionId'.
unknownSessionId :: SessionId
unknownSessionId = SessionId "unknown"

-- | Build the 'EntryRecord' for an opcode invocation. The opcode name and the
-- secret-free input are recorded in 'erMeta'; the entry kind is 'EKHarness'
-- (harness-internal event). 'erConvLen' is 0 because no conversation lines are
-- added by an opcode invocation.
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