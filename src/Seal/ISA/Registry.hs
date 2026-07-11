-- | A name-indexed opcode set; derives the provider tool-definition list the
-- agent is offered each turn.
module Seal.ISA.Registry
  ( Registry
  , mkRegistry
  , lookupOp
  , registryToolDefs
  , secretOpNames
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

import Seal.Core.Types (OpName, TrustLevel (..))
import Seal.Providers.Class (ToolDefinition (..))
import Seal.ISA.Opcode

newtype Registry = Registry (Map OpName Opcode)

mkRegistry :: [Opcode] -> Registry
mkRegistry ops = Registry (Map.fromList [(opName o, o) | o <- ops])

lookupOp :: Registry -> OpName -> Maybe Opcode
lookupOp (Registry m) n = Map.lookup n m

registryToolDefs :: Registry -> [ToolDefinition]
registryToolDefs (Registry m) =
  [ ToolDefinition (opName o) (opDesc o) (opInSchema o) | o <- Map.elems m ]

-- | The set of opcode names whose tool results may carry secrets (i.e.
-- 'Trusted'/'Audited' opcodes — 'Untrusted' opcodes have no access to vault
-- secrets). Used by the transcript writer to redact only the results that
-- actually need redaction, so non-secret tool output (shell, file read, etc.)
-- is preserved verbatim in @conversation.jsonl@ and visible in the frontend.
secretOpNames :: Registry -> Set OpName
secretOpNames (Registry m) =
  Set.fromList [ opName o | o <- Map.elems m, opTrust o /= Untrusted ]
