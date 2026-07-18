{-# LANGUAGE OverloadedStrings #-}
-- | A name-indexed opcode set; derives the provider tool-definition list the
-- agent is offered each turn. Tool definitions preserve registration order
-- (not alphabetical) so the wiring layer controls which tools the model sees
-- first — many LLMs bias toward the first tool whose description matches,
-- so the order is a lever for steering tool selection (e.g. WEB_FETCH before
-- BROWSER_OPEN for simple page fetches).
module Seal.ISA.Registry
  ( Registry
  , mkRegistry
  , lookupOp
  , registryToolDefs
  , registryToolDefs'
  , stubSchema
  , secretOpNames
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

import Seal.Core.Types (OpName (..))
import Seal.Providers.Class (ToolDefinition (..), stubSchema)
import Seal.ISA.Opcode

-- | The registry carries both a name-indexed 'Map' (O(log n) dispatch
-- lookup) and the registration-ordered opcode list (for tool-definition
-- emission in a stable, wiring-controlled order).
data Registry = Registry (Map OpName Opcode) [Opcode]

mkRegistry :: [Opcode] -> Registry
mkRegistry ops = Registry (Map.fromList [(opName o, o) | o <- ops]) ops

lookupOp :: Registry -> OpName -> Maybe Opcode
lookupOp (Registry m _) n = Map.lookup n m

-- | The tool definitions the provider is offered each turn, in registration
-- order (the order 'mkRegistry' received). NOT alphabetical — the wiring
-- layer controls the order so it can steer which tools the model tries first.
registryToolDefs :: Registry -> [ToolDefinition]
registryToolDefs = registryToolDefs' False

-- | Like 'registryToolDefs' but with a flag to swap full @input_schema@s for
-- a minimal stub. When @useStub@ is 'True', each tool definition carries
-- 'stubSchema' instead of the opcode's real 'opInSchema' — the name and
-- description are preserved so the model still knows what tools exist, but
-- the per-opcode schema JSON (the bulk of the tokens) is omitted. The model
-- is expected to call the @OPCODE_DESCRIBE@ opcode to retrieve a tool's full
-- schema before calling it. When @useStub@ is 'False' this is identical to
-- 'registryToolDefs'. The provider encoders OMIT the @input_schema@ field
-- entirely when it equals 'stubSchema' (see 'Seal.Providers.Class'), so the
-- stub costs zero tokens on the wire rather than the few a real stub object
-- would cost.
registryToolDefs' :: Bool -> Registry -> [ToolDefinition]
registryToolDefs' useStub (Registry _ order) =
  [ ToolDefinition (opName o) (opDesc o) (if useStub then stubSchema else opInSchema o)
  | o <- order
  ]

-- | The set of opcode names whose tool results may carry secrets and must be
-- redacted from the on-disk @conversation.jsonl@. Only opcodes that return a
-- vault secret value in 'orParts' belong here — currently just 'SECRET_GET'.
-- Other opcodes (MEMORY_RECALL, FILE_READ, SHELL_EXEC, etc.) return
-- agent-visible data that is safe to persist verbatim and display in the
-- frontend. Using trust level as a proxy was wrong: MEMORY_RECALL is Trusted
-- but returns memory content (not vault secrets), so redacting it hid
-- harmless output behind @<redacted:secret>@.
secretOpNames :: Registry -> Set OpName
secretOpNames (Registry m _) =
  Set.fromList [ opName o | o <- Map.elems m, opName o `Set.member` secretOpcodes ]

-- | The static set of opcode names that return secret values in 'orParts'.
secretOpcodes :: Set OpName
secretOpcodes = Set.fromList [ OpName "SECRET_GET" ]