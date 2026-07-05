{-# LANGUAGE OverloadedStrings #-}
-- | The skill store backend. A capability record ('SkillBackend') with one
-- in-memory implementation ('noneBackend') for M3; the Markdown backend follows
-- the same shape. All backends materialize by Audited-log replay at startup
-- ('materializeSkills').
--
-- The Audited log is canonical; the backend is a materialized view. Opcode
-- writes go through the backend (which mutates the in-memory/Markdown store)
-- AND through the dispatcher's Audited-log write (which is canonical). On a
-- cold start, 'materializeSkills' folds the Audited log into the backend so the
-- two stay in sync.
module Seal.Skills.Backend
  ( SkillBackend (..)
  , noneBackend
  , materializeSkills
  , SkillEvent (..)
  ) where

import Control.Monad (forM_)
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Value (..))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Audited.Replay (AuditedEvent (..))
import Seal.Audited.Types (AuditedKind (..))
import Seal.Core.Types (OpName (..))
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId)

-- | The skill store capability. Each operation is IO (a Markdown backend writes
-- to disk); 'sbList' returns all skills.
data SkillBackend = SkillBackend
  { sbCreate :: Skill -> IO ()
  -- ^ Insert or replace a skill by id.
  , sbRead   :: SkillId -> IO (Maybe Skill)
  -- ^ Fetch one skill by id.
  , sbList   :: IO [Skill]
  -- ^ All skills, in Map key order (deterministic for tests).
  , sbUpdate :: Skill -> IO ()
  -- ^ Update an existing skill (same as 'sbCreate' for the in-memory backend).
  }

-- | A store-agnostic mutation event derived from an 'AuditedEvent' whose
-- 'aeEvKind' is 'AKSkill'. The materializer dispatches on the opcode name to
-- produce one of these; the backend applies it.
newtype SkillEvent = SkillStore Skill

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests and by
-- the @none@ config option. The map is keyed by 'SkillId'.
noneBackend :: IO SkillBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map SkillId Skill)
  pure SkillBackend
    { sbCreate = \s -> modifyIORef' ref (Map.insert (skId s) s)
    , sbRead   = \sid -> Map.lookup sid <$> readIORef ref
    , sbList   = Map.elems <$> readIORef ref
    , sbUpdate = \s -> modifyIORef' ref (Map.insert (skId s) s)
    }

-- | Fold the Audited log into a skill backend, populating it from scratch. Each
-- 'AKSkill' event is routed to 'sbCreate' based on its opcode. Events for other
-- kinds are ignored. Idempotent: replaying the same log twice yields the same
-- backend state (Create is upsert).
materializeSkills :: [AuditedEvent] -> SkillBackend -> IO ()
materializeSkills events backend =
  forM_ events $ \ev ->
    case (aeEvKind ev, toSkillEvent ev) of
      (AKSkill, Just se) -> applySkillEvent backend se
      _                  -> pure ()

-- | Decode an 'AuditedEvent' into a 'SkillEvent' based on its opcode name. The
-- payload is the opcode INPUT (id/description/body for create/update); the
-- 'aeEvTs' and 'aeEvSession' fields of the event supply the timestamps and
-- provenance the input lacks, so the reconstructed 'Skill' is complete.
toSkillEvent :: AuditedEvent -> Maybe SkillEvent
toSkillEvent ev =
  case T.unpack (unOpName (aeEvOpcode ev)) of
    "SKILL_CREATE" -> SkillStore <$> decodeStorePayload ev
    "SKILL_UPDATE" -> SkillStore <$> decodeStorePayload ev
    _              -> Nothing
  where
    unOpName (OpName t) = t

-- | Decode a create/update payload (the opcode input) into a 'Skill', filling
-- in 'skCreatedAt'/'skUpdatedAt' from the event's timestamp and 'skSession'
-- from the event's session id. The input carries id/description/body.
decodeStorePayload :: AuditedEvent -> Maybe Skill
decodeStorePayload ev = do
  sid  <- idFromPayload (aeEvPayload ev)
  desc <- Just (descriptionFromPayload (aeEvPayload ev))
  body <- Just (bodyFromPayload (aeEvPayload ev))
  pure Skill
    { skId = sid
    , skDescription = desc
    , skBody = body
    , skCreatedAt = aeEvTs ev
    , skUpdatedAt = aeEvTs ev
    , skSession = aeEvSession ev
    }

-- | Extract the @id@ field from a payload object.
idFromPayload :: Value -> Maybe SkillId
idFromPayload (Object o) = case KeyMap.lookup (fromString "id") o of
  Just (String t) -> either (const Nothing) Just (mkSkillId t)
  _               -> Nothing
idFromPayload _ = Nothing

-- | Extract the @description@ field (defaults to empty when absent).
descriptionFromPayload :: Value -> Text
descriptionFromPayload (Object o) = case KeyMap.lookup (fromString "description") o of
  Just (String t) -> t
  _               -> ""
descriptionFromPayload _ = ""

-- | Extract the @body@ field (defaults to empty when absent).
bodyFromPayload :: Value -> Text
bodyFromPayload (Object o) = case KeyMap.lookup (fromString "body") o of
  Just (String t) -> t
  _               -> ""
bodyFromPayload _ = ""

-- | Apply one mutation to the backend.
applySkillEvent :: SkillBackend -> SkillEvent -> IO ()
applySkillEvent backend = \case
  SkillStore s -> sbCreate backend s