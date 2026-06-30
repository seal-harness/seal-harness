{-# LANGUAGE RankNTypes #-}
-- | The ISA as data: an 'Opcode' carries its trust level, JSON schemas, a pure
-- authorization gate, and an effectful run action. Untrusted opcodes run their
-- effects through 'BackendExec' (the seam Phase 4 swaps a remote executor into).
module Seal.ISA.Opcode
  ( OpResult (..)
  , Opcode (..)
  , BackendExec (..)
  , localBackend
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Text (Text)

import Seal.Core.Types
import Seal.Providers.Class (ToolResultPart)
import Seal.Types.App

data OpResult = OpResult
  { orParts :: [ToolResultPart]  -- ^ what the model sees (may include secret values)
  , orIsError :: Bool
  , orRecorded :: Value          -- ^ what the transcript records (secret-free)
  }

-- | The execution seam. Untrusted opcodes funnel their IO through 'runLocal';
-- Phase 4 introduces a remote-SSH 'BackendExec' with the same shape.
newtype BackendExec = BackendExec { runLocal :: forall a. IO a -> App a }

localBackend :: BackendExec
localBackend = BackendExec liftIO

data Opcode = Opcode
  { opName :: OpName
  , opTrust :: TrustLevel
  , opDesc :: Text
  , opInSchema :: Value
  , opOutSchema :: Value
  , opAuthorize :: Value -> Either Text ()
  , opRun :: BackendExec -> Value -> App OpResult
  }
