-- | A name-indexed opcode set; derives the provider tool-definition list the
-- agent is offered each turn.
module Seal.ISA.Registry
  ( Registry
  , mkRegistry
  , lookupOp
  , registryToolDefs
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

import Seal.Core.Types
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
