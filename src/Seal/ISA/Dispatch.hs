{-# LANGUAGE OverloadedStrings #-}
-- | The dispatcher. Runs the pure authorization gate, then — for Untrusted
-- opcodes — durably records the invocation (recordAndAck) BEFORE executing, so
-- no untrusted action runs until its audit entry is on disk. Trusted/Audited
-- opcodes record concurrently with execution.
--
-- Invariant: for an Untrusted opcode, recordAndAck completes before opRun
-- is called. This ordering is the whole point of the module.
--
-- Note: teId is left as "" for now; uuid minting is a deferred follow-up.
module Seal.ISA.Dispatch
  ( DispatchError (..)
  , dispatch
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, toJSON)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)

import Seal.Core.Types
import Seal.Handles.Transcript
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Transcript.Types
import Seal.Types.App

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

dispatch
  :: Registry -> TranscriptHandle -> BackendExec -> OpName -> Value
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
              liftIO (recordAndAck h entry)   -- ACK-before-execute: durable before run
              Right <$> opRun op backend input
            _ -> do
              liftIO (recordAsync h entry)
              Right <$> opRun op backend input

mkInvocationEntry :: OpName -> Value -> IO TranscriptEntry
mkInvocationEntry name input = do
  now <- getCurrentTime
  pure TranscriptEntry
    { teId = ""
    , teTimestamp = now
    , teModel = Nothing
    , teDirection = Request
    , tePayload = input
    , teDurationMs = Nothing
    , teCorrelation = Nothing
    , teMeta = Map.fromList [("op", toJSON name)]
    }
