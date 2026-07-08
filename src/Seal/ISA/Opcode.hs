{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
-- | The ISA as data: an 'Opcode' is a GADT-style sum keyed by trust level.
-- A 'TrustedOpcode' carries 'toRun' (no 'ExecBackend'); an 'UntrustedOpcode'
-- carries 'uoRun' (which threads an 'ExecBackend'). This split makes the
-- capability-scoping guarantee type-level (spec §4 line 129, §8): a Trusted
-- opcode that shells out literally cannot be constructed — it has no
-- 'ExecBackend' in scope. The compile-fail fixture
-- ('Seal.Tools.Exec.CapabilityScopingFail') asserts this.
--
-- Untrusted opcodes run their effects through 'BackendExec' (the seam
-- Phase 4 swaps a remote executor into) PLUS the threaded 'ExecBackend'
-- (Local vs Remote SSH); Trusted opcodes use 'BackendExec' alone.
module Seal.ISA.Opcode
  ( OpResult (..)
  , Opcode (..)
  , BackendExec (..)
  , localBackend
  , opName
  , opTrust
  , opDesc
  , opInSchema
  , opOutSchema
  , opAuthorize
  , opRun
  , withAuthorize
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Text (Text)

import Seal.Core.Types
import Seal.Providers.Class (ToolResultPart)
import Seal.Types.App
import Seal.Tools.Exec.Types (ExecBackend)

data OpResult = OpResult
  { orParts :: [ToolResultPart]  -- ^ what the model sees (may include secret values)
  , orIsError :: Bool
  , orRecorded :: Value          -- ^ what the transcript records (secret-free)
  } deriving stock (Eq)

-- | Manual Show that never renders 'orParts': those slots may hold secret values
-- (e.g. vault credentials returned by SECRET_GET) that must not appear in logs.
instance Show OpResult where
  show r = "OpResult {orParts = <" <> show (length (orParts r)) <> " part(s) redacted>, orIsError = "
             <> show (orIsError r) <> ", orRecorded = " <> show (orRecorded r) <> "}"

-- | The execution seam. Untrusted opcodes funnel their IO through 'runLocal';
-- Phase 4 introduces a remote-SSH 'BackendExec' with the same shape.
newtype BackendExec = BackendExec { runLocal :: forall a. IO a -> App a }

localBackend :: BackendExec
localBackend = BackendExec liftIO

-- | The opcode sum. 'TrustedOpcode' covers both 'Trusted' and 'Audited'
-- (Audited is treated as Trusted by the dispatcher — record async, then
-- run; the 'toTrust' field carries the distinction for 'opTrust').
-- 'UntrustedOpcode' is always 'Untrusted' and carries the 'ExecBackend'
-- its 'uoRun' threads. The field-name prefixes (@to@ / @uo@) keep the two
-- constructors' record namespaces disjoint (Haskell requires this when
-- constructors share a type but have different fields).
data Opcode
  = TrustedOpcode
      { toName       :: OpName
      , toTrust      :: TrustLevel       -- ^ 'Trusted' or 'Audited'
      , toDesc       :: Text
      , toInSchema   :: Value
      , toOutSchema  :: Value
      , toAuthorize  :: Value -> Either Text ()
      , toRun        :: BackendExec -> Value -> App OpResult
      }
  | UntrustedOpcode
      { uoName       :: OpName
      , uoDesc       :: Text
      , uoInSchema   :: Value
      , uoOutSchema  :: Value
      , uoAuthorize  :: Value -> Either Text ()
      , uoRun        :: BackendExec -> ExecBackend -> Value -> App OpResult
      }

-- | Accessor: the opcode's name (works for both constructors).
opName :: Opcode -> OpName
opName (TrustedOpcode n _ _ _ _ _ _) = n
opName (UntrustedOpcode n _ _ _ _ _) = n

-- | Accessor: the trust level. 'UntrustedOpcode' is always 'Untrusted'.
opTrust :: Opcode -> TrustLevel
opTrust (TrustedOpcode _ tl _ _ _ _ _) = tl
opTrust (UntrustedOpcode {})  = Untrusted

-- | Accessor: the description (for tool definitions).
opDesc :: Opcode -> Text
opDesc (TrustedOpcode _ _ d _ _ _ _) = d
opDesc (UntrustedOpcode _ d _ _ _ _) = d

-- | Accessor: the input JSON schema.
opInSchema :: Opcode -> Value
opInSchema (TrustedOpcode _ _ _ s _ _ _) = s
opInSchema (UntrustedOpcode _ _ s _ _ _) = s

-- | Accessor: the output JSON schema.
opOutSchema :: Opcode -> Value
opOutSchema (TrustedOpcode _ _ _ _ s _ _) = s
opOutSchema (UntrustedOpcode _ _ _ s _ _) = s

-- | Accessor: the authorization gate.
opAuthorize :: Opcode -> Value -> Either Text ()
opAuthorize (TrustedOpcode _ _ _ _ _ a _) = a
opAuthorize (UntrustedOpcode _ _ _ _ a _) = a

-- | Accessor: the run action for a TRUSTED opcode. Calling this on an
-- 'UntrustedOpcode' is an error (use the dispatcher, which pattern-matches
-- the GADT and calls 'uoRun' for untrusted). Provided so legacy call
-- sites that read 'opRun' on a known-trusted opcode keep working.
opRun :: Opcode -> BackendExec -> Value -> App OpResult
opRun (TrustedOpcode _ _ _ _ _ _ r) = r
opRun UntrustedOpcode {} =
  error "opRun: UntrustedOpcode has no toRun; use the dispatcher's uoRun path"

-- | Helper for the one record-update site (DispatchSpec): replace the
-- authorize function on an opcode (GADTs forbid record-update on a sum
-- whose fields differ per constructor).
withAuthorize :: Opcode -> (Value -> Either Text ()) -> Opcode
withAuthorize (TrustedOpcode n tl d is os _ r) f =
  TrustedOpcode n tl d is os f r
withAuthorize (UntrustedOpcode n d is os _ r) f =
  UntrustedOpcode n d is os f r