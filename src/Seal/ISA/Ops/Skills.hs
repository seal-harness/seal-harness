{-# LANGUAGE OverloadedStrings #-}
-- | The Skills opcode group: SKILL_WRITE, SKILL_READ, SKILL_LIST, SKILL_DELETE.
-- All Audited — the dispatcher writes both the session transcript and the
-- Audited log; the opcodes mutate the in-memory/Markdown backend (the
-- materialized view). 'orRecorded' carries the secret-free 'SkillId' + op name
-- + @was_new@ flag (so the audit log distinguishes create vs update); the
-- skill DESCRIPTION and BODY are agent-visible data (not a vault secret) and
-- are recorded in full in both logs.
--
-- 'SKILL_WRITE' is an upsert: if the skill already exists, its description
-- and/or body are updated (the original 'skSession' provenance and
-- 'skCreatedAt' are preserved; only 'skUpdatedAt' is bumped); if not, a
-- fresh skill is created. This merges the former SKILL_CREATE + SKILL_UPDATE
-- into a single opcode, eliminating one failure path.
module Seal.ISA.Ops.Skills
  ( skillWriteOp
  , skillReadOp
  , skillListOp
  , skillDeleteOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value, object, withObject, (.:), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Core.Types (OpName (..), SessionId, TrustLevel (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)

-- | Build a JSON-Schema object with a single required string property.
singleStringSchema :: Text -> Text -> Value
singleStringSchema fieldName fieldDesc =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [fromText fieldName .= object
           [ "type" .= ("string" :: Text)
           , "description" .= fieldDesc
           ]]
    , "required" .= ([fieldName] :: [Text])
    ]

-- | Extract the @id@ string field from a JSON object.
idField :: Value -> Maybe Text
idField = parseMaybe (withObject "in" (.: "id"))

-- | Extract the @description@ string field (defaults to empty when absent).
descriptionField :: Value -> Text
descriptionField v = fromMaybe "" (parseMaybe (withObject "in" (.: "description")) v)

-- | Extract the @body@ string field (defaults to empty when absent).
bodyField :: Value -> Text
bodyField v = fromMaybe "" (parseMaybe (withObject "in" (.: "body")) v)

-- | SKILL_WRITE: upsert a skill by id. If the skill already exists, its
-- description and body are updated (the original 'skSession' provenance and
-- 'skCreatedAt' are preserved; only 'skUpdatedAt' is bumped); if not, a
-- fresh skill is created with the current session as provenance. The
-- description and body are recorded in full (agent-visible data);
-- 'orRecorded' carries the id + op name + description + body + @was_new@
-- (secret-free).
skillWriteOp :: SkillBackend -> SessionId -> Opcode
skillWriteOp backend session = TrustedOpcode
  { toName = OpName "SKILL_WRITE"
  , toTrust = Trusted
  , toDesc = "Create or update an agent skill by id (upsert; preserves provenance on update)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Skill id ([A-Za-z0-9_-]+)." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Short human-readable description of the skill." :: Text)
              ]
          , fromText "body" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The skill body (Markdown). Agent-visible." :: Text)
              ]
          ]
      , "required" .= (["id", "description", "body"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = maybe (Left "SKILL_WRITE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkSkillId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid skill id"] True (object []))
        Just sid -> do
          mExisting <- liftIO (sbRead backend sid)
          now <- liftIO getCurrentTime
          let (skill, wasNew) = case mExisting of
                Just existing ->
                  ( existing
                      { skDescription = descriptionField v
                      , skBody = bodyField v
                      , skUpdatedAt = now
                      }
                  , False
                  )
                Nothing ->
                  ( Skill
                      { skId = sid
                      , skDescription = descriptionField v
                      , skBody = bodyField v
                      , skCreatedAt = now
                      , skUpdatedAt = now
                      , skSession = session
                      }
                  , True
                  )
          liftIO (sbCreate backend skill)
          let recorded = object
                [ "id" .= skillIdText sid
                , "description" .= skDescription skill
                , "body" .= skBody skill
                , "created_at" .= skCreatedAt skill
                , "updated_at" .= skUpdatedAt skill
                , "session" .= skSession skill
                , "was_new" .= wasNew
                ]
          pure (OpResult [TrpText (if wasNew then "created" else "updated")] False recorded)
  }
  where
    checkId t = either (Left . ("invalid skill id: " <>)) (const (Right ())) (mkSkillId t)

-- | SKILL_READ: return one skill by id. Audited — the agent reading its own
-- skills is an evolutionary event worth logging, with secret-free metadata.
-- The skill body is returned to the model (agent-visible) and recorded in full.
skillReadOp :: SkillBackend -> Opcode
skillReadOp backend = TrustedOpcode
  { toName = OpName "SKILL_READ"
  , toTrust = Trusted
  , toDesc = "Read one agent skill by id into the prompt."
  , toInSchema = singleStringSchema "id" "The skill id to read."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "SKILL_READ requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkSkillId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid skill id"] True (object []))
        Just sid -> do
          mSkill <- liftIO (sbRead backend sid)
          case mSkill of
            Nothing -> pure (OpResult [TrpText "skill not found"] True (object ["id" .= skillIdText sid]))
            Just s  -> do
              let rendered = "# " <> skillIdText (skId s) <> "\n\n"
                      <> skDescription s <> "\n\n---\n\n" <> skBody s
                  recorded = object
                    [ "id" .= skillIdText sid
                    , "description" .= skDescription s
                    , "body" .= skBody s
                    , "updated_at" .= skUpdatedAt s
                    , "session" .= skSession s
                    ]
              pure (OpResult [TrpText rendered] False recorded)
  }
  where
    checkId t = either (Left . ("invalid skill id: " <>)) (const (Right ())) (mkSkillId t)

-- | SKILL_DELETE: remove a skill by id. Idempotent (deleting a missing id is
-- a success with a "not present" message, not an error). Mirrors
-- 'Seal.ISA.Ops.Memory.memoryDeleteOp'.
skillDeleteOp :: SkillBackend -> Opcode
skillDeleteOp backend = TrustedOpcode
  { toName = OpName "SKILL_DELETE"
  , toTrust = Trusted
  , toDesc = "Delete an agent skill by id (idempotent)."
  , toInSchema = singleStringSchema "id" "The skill id to delete."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "SKILL_DELETE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkSkillId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid skill id"] True (object []))
        Just sid -> do
          mExisting <- liftIO (sbRead backend sid)
          liftIO (sbDelete backend sid)
          let msg = case mExisting of
                Nothing -> "deleted (was not present)"
                Just _  -> "deleted"
              recorded = object ["id" .= skillIdText sid]
          pure (OpResult [TrpText msg] False recorded)
  }
  where
    checkId t = either (Left . ("invalid skill id: " <>)) (const (Right ())) (mkSkillId t)

-- | SKILL_LIST: enumerate all defined skills (id + description). Audited —
-- listing is an evolutionary event worth logging, with secret-free metadata
-- (no skill bodies in the recorded payload; the model sees only the
-- id+description summary).
skillListOp :: SkillBackend -> Opcode
skillListOp backend = TrustedOpcode
  { toName = OpName "SKILL_LIST"
  , toTrust = Trusted
  , toDesc = "List all defined agent skills (id + description)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toRun = \_ _ -> do
      allSkills <- liftIO (sbList backend)
      let rendered = case allSkills of
            [] -> "(no skills defined)"
            _  -> T.intercalate "\n"
                    [ skillIdText (skId s) <> ": " <> skDescription s | s <- allSkills ]
          recorded = object
            [ "count" .= length allSkills
            , "ids" .= fmap (skillIdText . skId) allSkills
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }