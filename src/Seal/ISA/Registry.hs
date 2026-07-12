{-# LANGUAGE OverloadedStrings #-}
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

import Seal.Core.Types (OpName (..))
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

-- | The set of opcode names whose tool results may carry secrets and must be
-- redacted from the on-disk @conversation.jsonl@. Only opcodes that return a
-- vault secret value in 'orParts' belong here — currently just 'SECRET_GET'.
-- Other opcodes (MEMORY_RECALL, FILE_READ, SHELL_EXEC, etc.) return
-- agent-visible data that is safe to persist verbatim and display in the
-- frontend. Using trust level as a proxy was wrong: MEMORY_RECALL is Trusted
-- but returns memory content (not vault secrets), so redacting it hid
-- harmless output behind @<redacted:secret>@.
secretOpNames :: Registry -> Set OpName
secretOpNames (Registry m) =
  Set.fromList [ opName o | o <- Map.elems m, opName o `Set.member` secretOpcodes ]

-- | The static set of opcode names that return secret values in 'orParts'.
secretOpcodes :: Set OpName
secretOpcodes = Set.fromList [ OpName "SECRET_GET" ]
