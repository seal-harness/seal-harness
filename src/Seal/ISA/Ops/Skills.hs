{-# LANGUAGE OverloadedStrings #-}
-- | The Skills opcode group. The consolidated entry point is
-- 'skillManageOp' (\"SKILL_MANAGE\"), which dispatches on an @action@
-- field to one of four handlers: @write@, @load@, @list@, @delete@.
--
-- The legacy opcodes ('skillWriteOp', 'skillLoadOp', 'skillListOp',
-- 'skillDeleteOp') remain as thin shims that delegate to the same handlers.
-- This preserves backward compatibility — all downstream consumers that
-- match on the @SKILL_LOAD@ opcode name (Dispatch.hs, Command/Skill.hs,
-- Gateway/Transcript.hs, frontend) continue to work unchanged.
module Seal.ISA.Ops.Skills
  ( -- * Consolidated opcode
    skillManageOp
    -- * Legacy shims
  , skillWriteOp
  , skillLoadOp
  , skillListOp
  , skillDeleteOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value, object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Core.Types (OpName (..), SessionId, TrustLevel (..))
import Seal.Types.App (App)
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)

-- ---------------------------------------------------------------------------
-- Action enum
-- ---------------------------------------------------------------------------

data SkillAction = SkWrite | SkLoad | SkList | SkDelete

parseSkillAction :: Value -> Either Text SkillAction
parseSkillAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "write"  -> Right SkWrite
      "load"   -> Right SkLoad
      "list"   -> Right SkList
      "delete" -> Right SkDelete
      other    -> Left ("unknown skill action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- | Shared id validator.
checkSkillId :: Text -> Either Text ()
checkSkillId t = either (Left . ("invalid skill id: " <>)) (const (Right ())) (mkSkillId t)

-- ---------------------------------------------------------------------------
-- Field extractors
-- ---------------------------------------------------------------------------

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

-- | Extract the optional @group@ string field. 'Nothing' when absent or
-- empty (after stripping).
groupField :: Value -> Maybe Text
groupField v = do
  raw <- parseMaybe (withObject "in" (.:? "group")) v
  t <- raw
  let t' = T.strip t
  if T.null t' then Nothing else Just t'

-- ---------------------------------------------------------------------------
-- Handlers (shared between SKILL_MANAGE and legacy shims)
-- ---------------------------------------------------------------------------

handleSkillWrite :: SkillBackend -> SessionId -> Value -> App OpResult
handleSkillWrite backend session v = do
  let mId = idField v >>= either (const Nothing) Just . mkSkillId
      mNewGroup = groupField v
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
                  , skGroup = case mNewGroup of
                      Just g  -> Just g
                      Nothing -> skGroup existing
                  , skUpdatedAt = now
                  }
              , False
              )
            Nothing ->
              ( Skill
                  { skId = sid
                  , skDescription = descriptionField v
                  , skBody = bodyField v
                  , skGroup = mNewGroup
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
            , "group" .= skGroup skill
            , "created_at" .= skCreatedAt skill
            , "updated_at" .= skUpdatedAt skill
            , "session" .= skSession skill
            , "was_new" .= wasNew
            ]
      pure (OpResult [TrpText (if wasNew then "created" else "updated")] False recorded)

handleSkillLoad :: SkillBackend -> Value -> App OpResult
handleSkillLoad backend v = do
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
                , "group" .= skGroup s
                , "updated_at" .= skUpdatedAt s
                , "session" .= skSession s
                ]
          pure (OpResult [TrpText rendered] False recorded)

handleSkillList :: SkillBackend -> App OpResult
handleSkillList backend = do
  allSkills <- liftIO (sbList backend)
  let rendered = case allSkills of
        [] -> "(no skills defined)"
        _  -> T.intercalate "\n"
                [ skillIdText (skId s)
                    <> maybe "" (\g -> " [" <> g <> "]") (skGroup s)
                    <> ": " <> skDescription s
                | s <- sortBy (comparing (\s' -> (fromMaybe "" (skGroup s'), skillIdText (skId s')))) allSkills ]
      recorded = object
        [ "count" .= length allSkills
        , "ids" .= fmap (skillIdText . skId) allSkills
        ]
  pure (OpResult [TrpText rendered] False recorded)

handleSkillDelete :: SkillBackend -> Value -> App OpResult
handleSkillDelete backend v = do
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

-- ---------------------------------------------------------------------------
-- Authorize gate
-- ---------------------------------------------------------------------------

authorizeSkillManage :: Value -> Either Text ()
authorizeSkillManage v =
  case parseSkillAction v of
    Left e -> Left e
    Right action -> case action of
      SkWrite  -> maybe (Left "write requires {id:string}") checkSkillId . idField $ v
      SkLoad   -> maybe (Left "load requires {id:string}") checkSkillId . idField $ v
      SkList   -> Right ()
      SkDelete -> maybe (Left "delete requires {id:string}") checkSkillId . idField $ v

-- ---------------------------------------------------------------------------
-- Consolidated opcode: SKILL_MANAGE
-- ---------------------------------------------------------------------------

-- | SKILL_MANAGE: action-based entry point for all skill operations.
skillManageOp :: SkillBackend -> SessionId -> Opcode
skillManageOp backend session = TrustedOpcode
  { toName = OpName "SKILL_MANAGE"
  , toTrust = Trusted
  , toDesc = "Manage agent skills. Use action to select: write (create/update upsert), load (read by id), list (all skills), delete (by id, idempotent)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["write", "load", "list", "delete"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Skill id ([A-Za-z0-9_-]+) (write, load, delete)." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Short description (write)." :: Text)
              ]
          , fromText "body" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Skill body, Markdown (write)." :: Text)
              ]
          , fromText "group" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional category for grouping (write)." :: Text)
              ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeSkillManage
  , toBlocking = False
  , toRun = \_ v ->
      case parseSkillAction v of
        Left e -> pure (OpResult [TrpText e] True (object []))
        Right action -> case action of
          SkWrite  -> handleSkillWrite backend session v
          SkLoad   -> handleSkillLoad backend v
          SkList   -> handleSkillList backend
          SkDelete -> handleSkillDelete backend v
  }

-- ---------------------------------------------------------------------------
-- Legacy shims (backward compatibility)
-- ---------------------------------------------------------------------------

-- | SKILL_WRITE (legacy shim): delegates to the write handler.
skillWriteOp :: SkillBackend -> SessionId -> Opcode
skillWriteOp backend session = TrustedOpcode
  { toName = OpName "SKILL_WRITE"
  , toTrust = Trusted
  , toDesc = "Create or update an agent skill by id (upsert; preserves provenance on update). (Legacy — prefer SKILL_MANAGE with action=\"write\".)"
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
          , fromText "group" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional category for grouping in the available-skills catalog. When set, the skill is stored under config/skills/<group>/<id>.md; when omitted, the skill keeps its existing group (or is ungrouped on create)." :: Text)
              ]
          ]
      , "required" .= (["id", "description", "body"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = maybe (Left "SKILL_WRITE requires {id:string}") checkSkillId . idField
  , toBlocking = False
  , toRun = \_ v -> handleSkillWrite backend session v
  }

-- | SKILL_LOAD (legacy shim): delegates to the load handler.
skillLoadOp :: SkillBackend -> Opcode
skillLoadOp backend = TrustedOpcode
  { toName = OpName "SKILL_LOAD"
  , toTrust = Trusted
  , toDesc = "Load one agent skill by id into the current session. (Legacy — prefer SKILL_MANAGE with action=\"load\".)"
  , toInSchema = singleStringSchema "id" "The skill id to load."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "SKILL_LOAD requires {id:string}") checkSkillId . idField
  , toBlocking = False
  , toRun = \_ v -> handleSkillLoad backend v
  }

-- | SKILL_LIST (legacy shim): delegates to the list handler.
skillListOp :: SkillBackend -> Opcode
skillListOp backend = TrustedOpcode
  { toName = OpName "SKILL_LIST"
  , toTrust = Trusted
  , toDesc = "List all defined agent skills (id + description). (Legacy — prefer SKILL_MANAGE with action=\"list\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ _ -> handleSkillList backend
  }

-- | SKILL_DELETE (legacy shim): delegates to the delete handler.
skillDeleteOp :: SkillBackend -> Opcode
skillDeleteOp backend = TrustedOpcode
  { toName = OpName "SKILL_DELETE"
  , toTrust = Trusted
  , toDesc = "Delete an agent skill by id (idempotent). (Legacy — prefer SKILL_MANAGE with action=\"delete\".)"
  , toInSchema = singleStringSchema "id" "The skill id to delete."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "SKILL_DELETE requires {id:string}") checkSkillId . idField
  , toBlocking = False
  , toRun = \_ v -> handleSkillDelete backend v
  }
