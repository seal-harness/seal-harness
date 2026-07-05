{-# LANGUAGE OverloadedStrings #-}
-- | The dispatcher. Runs the pure authorization gate, then — for Untrusted
-- opcodes — durably records the invocation (tfwRecordAndAck) BEFORE executing,
-- so no untrusted action runs until its audit entry is on disk. Trusted/Audited
-- opcodes record concurrently with execution.
--
-- Invariant: for an Untrusted opcode, tfwRecordAndAck completes before opRun
-- is called. This ordering is the whole point of the module.
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
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)

import Seal.Core.Types
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Types.App

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

dispatch
  :: Registry -> TwoFileHandle -> BackendExec -> OpName -> Value
  -> App (Either DispatchError OpResult)
dispatch reg h backend name input =
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
              Right <$> opRun op backend input

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