{-# LANGUAGE OverloadedStrings #-}
-- | Pure predicate: should this opcode invocation be written to the
-- cross-session audit log?
--
-- The audit log captures only /mutating/ operations on the evolutionary
-- stores (skills, agent definitions, vault secrets, memory). Read-only
-- operations and non-evolutionary mutations (agent lifecycle, session
-- creation, harness management) are excluded — their audit trail lives in
-- the session transcript and the in-process runtime registries.
--
-- The predicate is an explicit allowlist of @(opcode, action)@ pairs. An
-- opcode not listed here is never audited, regardless of its action. An
-- action not listed for a listed opcode is not audited. A 'Nothing' action
-- (opcode has no @action@ field) is never audited — all audited opcodes
-- are action-based.
module Seal.Audit.Predicate
  ( shouldAudit
  , extractAction
  , extractTargetId
  ) where

import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

import Seal.Core.Types (OpName (..))

-- | The audited actions for each opcode. Only the listed actions are
-- audited; all other actions (read, list, search, load) are excluded.
auditedActions :: Map OpName (Set Text)
auditedActions = Map.fromList
  [ (OpName "SKILL_MANAGE", Set.fromList ["write", "delete"])
  , (OpName "AGENT_DEF_MANAGE", Set.fromList ["write", "delete"])
  , (OpName "SECRET_MANAGE", Set.fromList ["put", "delete"])
  , (OpName "MEMORY_MANAGE", Set.fromList ["write", "archive"])
  ]

-- | Should this opcode invocation be written to the audit log?
-- Returns 'True' only when both the opcode and its action are in the
-- allowlist. A 'Nothing' action (no @action@ field in the input) is
-- never audited.
shouldAudit :: OpName -> Maybe Text -> Bool
shouldAudit opName mAction =
  case mAction of
    Nothing -> False
    Just action -> case Map.lookup opName auditedActions of
      Nothing -> False
      Just allowed -> Set.member action allowed

-- | Extract the @action@ field from an opcode's input JSON. Returns
-- 'Nothing' when the input has no @action@ field (e.g. legacy single-action
-- opcodes). All audited opcodes are action-based, so 'Nothing' means
-- "not audited".
extractAction :: Value -> Maybe Text
extractAction = parseMaybe (withObject "input" (.: "action"))

-- | Extract the target identifier from an opcode's input JSON. The field
-- name varies by opcode: @id@ for skills and agent defs, @name@ for vault
-- secrets, @path@ for memory. Falls back through these in order.
extractTargetId :: Value -> Text
extractTargetId v =
  let mId = parseMaybe (withObject "input" (.: "id")) v
      mName = parseMaybe (withObject "input" (.: "name")) v
      mPath = parseMaybe (withObject "input" (.: "path")) v
  in fromMaybe "-" (mId <|> mName <|> mPath)
