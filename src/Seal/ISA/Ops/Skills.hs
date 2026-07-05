{-# LANGUAGE OverloadedStrings #-}
-- | The Skills opcode group: SKILL_CREATE, SKILL_READ, SKILL_UPDATE, SKILL_LIST.
-- All Audited — the dispatcher writes both the session transcript and the
-- Audited log; the opcodes mutate the in-memory/Markdown backend (the
-- materialized view). 'orRecorded' carries the secret-free 'SkillId' + op name;
-- the skill DESCRIPTION and BODY are agent-visible data (not a vault secret)
-- and are recorded in full in both logs.
module Seal.ISA.Ops.Skills
  ( skillCreateOp
  , skillReadOp
  , skillUpdateOp
  , skillListOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value, object, withObject, (.:), (.:?), (.=) )
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

-- | SKILL_CREATE: insert or replace a skill by id. The description and body are
-- recorded in full (agent-visible data); 'orRecorded' carries the id + op name
-- + description + body (secret-free).
skillCreateOp :: SkillBackend -> SessionId -> Opcode
skillCreateOp backend session = Opcode
  { opName = OpName "SKILL_CREATE"
  , opTrust = Trusted
  , opDesc = "Define an agent skill by id (insert or replace)."
  , opInSchema = object
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
  , opOutSchema = object []
  , opAuthorize = maybe (Left "SKILL_CREATE requires {id:string}") checkId . idField
  , opRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkSkillId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid skill id"] True (object []))
        Just sid -> do
          now <- liftIO getCurrentTime
          let skill = Skill
                { skId = sid
                , skDescription = descriptionField v
                , skBody = bodyField v
                , skCreatedAt = now
                , skUpdatedAt = now
                , skSession = session
                }
          liftIO (sbCreate backend skill)
          let recorded = object
                [ "id" .= skillIdText sid
                , "description" .= skDescription skill
                , "body" .= skBody skill
                , "created_at" .= skCreatedAt skill
                , "updated_at" .= skUpdatedAt skill
                , "session" .= skSession skill
                ]
          pure (OpResult [TrpText "created"] False recorded)
  }
  where
    checkId t = either (Left . ("invalid skill id: " <>)) (const (Right ())) (mkSkillId t)

-- | SKILL_READ: return one skill by id. Audited — the agent reading its own
-- skills is an evolutionary event worth logging, with secret-free metadata.
-- The skill body is returned to the model (agent-visible) and recorded in full.
skillReadOp :: SkillBackend -> Opcode
skillReadOp backend = Opcode
  { opName = OpName "SKILL_READ"
  , opTrust = Trusted
  , opDesc = "Read one agent skill by id into the prompt."
  , opInSchema = singleStringSchema "id" "The skill id to read."
  , opOutSchema = object []
  , opAuthorize = maybe (Left "SKILL_READ requires {id:string}") checkId . idField
  , opRun = \_ v -> do
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

-- | SKILL_UPDATE: update an existing skill's description and/or body. The
-- updated_at timestamp is bumped. If the skill does not exist, returns an error
-- result (the model should use SKILL_CREATE to define). The original
-- 'skSession' is preserved (the update is attributed to the session that
-- created the skill, not the session that updated it).
skillUpdateOp :: SkillBackend -> Opcode
skillUpdateOp backend = Opcode
  { opName = OpName "SKILL_UPDATE"
  , opTrust = Trusted
  , opDesc = "Update an existing skill's description and/or body."
  , opInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The skill id to update." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("New description (optional)." :: Text)
              ]
          , fromText "body" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("New body (optional)." :: Text)
              ]
          ]
      , "required" .= (["id"] :: [Text])
      ]
  , opOutSchema = object []
  , opAuthorize = maybe (Left "SKILL_UPDATE requires {id:string}") checkId . idField
  , opRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkSkillId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid skill id"] True (object []))
        Just sid -> do
          mExisting <- liftIO (sbRead backend sid)
          case mExisting of
            Nothing -> pure (OpResult [TrpText "skill not found"] True (object ["id" .= skillIdText sid]))
            Just existing -> do
              now <- liftIO getCurrentTime
              let newDesc = case parseMaybe (withObject "in" (.:? "description")) v :: Maybe (Maybe Text) of
                    Just (Just d) -> d
                    _             -> skDescription existing
                  newBody = case parseMaybe (withObject "in" (.:? "body")) v :: Maybe (Maybe Text) of
                    Just (Just b) -> b
                    _             -> skBody existing
                  updated = existing
                    { skDescription = newDesc
                    , skBody = newBody
                    , skUpdatedAt = now
                    }
              liftIO (sbUpdate backend updated)
              let recorded = object
                    [ "id" .= skillIdText sid
                    , "description" .= skDescription updated
                    , "body" .= skBody updated
                    , "updated_at" .= skUpdatedAt updated
                    , "session" .= skSession updated
                    ]
              pure (OpResult [TrpText "updated"] False recorded)
  }
  where
    checkId t = either (Left . ("invalid skill id: " <>)) (const (Right ())) (mkSkillId t)

-- | SKILL_LIST: enumerate all defined skills (id + description). Audited —
-- listing is an evolutionary event worth logging, with secret-free metadata
-- (no skill bodies in the recorded payload; the model sees only the
-- id+description summary).
skillListOp :: SkillBackend -> Opcode
skillListOp backend = Opcode
  { opName = OpName "SKILL_LIST"
  , opTrust = Trusted
  , opDesc = "List all defined agent skills (id + description)."
  , opInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , opOutSchema = object []
  , opAuthorize = const (Right ())
  , opRun = \_ _ -> do
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