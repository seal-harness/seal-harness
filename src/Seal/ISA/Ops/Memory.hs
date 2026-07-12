{-# LANGUAGE OverloadedStrings #-}
-- | The Memory opcode group: MEMORY_WRITE, MEMORY_RECALL, MEMORY_DELETE.
-- All Audited — the dispatcher writes both the session transcript and the
-- Audited log; the opcodes mutate the in-memory/SQLite/Markdown backend
-- (the materialized view). 'orRecorded' carries the secret-free 'MemoryId'
-- + op name + @was_new@ flag (so the audit log distinguishes create vs
-- update); the memory CONTENT is agent-visible data (not a vault secret)
-- and is recorded in full in both logs.
--
-- 'MEMORY_WRITE' is an upsert: if the memory already exists, its content
-- and/or tags are updated (the original 'meSession' provenance and
-- 'meCreatedAt' are preserved; only 'meUpdatedAt' is bumped); if not, a
-- fresh entry is created. This merges the former MEMORY_STORE +
-- MEMORY_UPDATE into a single opcode, eliminating one failure path.
--
-- 'MEMORY_RECALL' uses the dynamic-retrieval pager ('Seal.Core.Paging'):
-- @page_size = clamp floor ceiling (round (coeff * sqrt total))@, where total
-- is the number of matching memories.
module Seal.ISA.Ops.Memory
  ( memoryWriteOp
  , memoryRecallOp
  , memoryDeleteOp
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

import Seal.Core.Paging (Page (..), PageParams, paginate)
import Seal.Core.Types (OpName (..), SessionId, TrustLevel (..))
import Seal.ISA.Opcode
import Seal.Memory.Backend (MemoryBackend (..))
import Seal.Memory.Types (MemoryEntry (..), memoryIdText, mkMemoryId)
import Seal.Providers.Class (ToolResultPart (..))

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

-- | Extract the @content@ string field (defaults to empty when absent).
contentField :: Value -> Text
contentField v = fromMaybe "" (parseMaybe (withObject "in" (.: "content")) v)

-- | Extract the optional @tags@ array field (defaults to [] when absent).
tagsField :: Value -> [Text]
tagsField v =
  case parseMaybe (withObject "in" (.:? "tags")) v :: Maybe (Maybe [Text]) of
    Just (Just ts) -> ts
    _              -> []

-- | Extract the optional @query@ string field for RECALL (substring filter).
queryField :: Value -> Maybe Text
queryField v =
  case parseMaybe (withObject "in" (.:? "query")) v :: Maybe (Maybe Text) of
    Just (Just q) -> Just q
    _             -> Nothing

-- | Extract the optional @limit@ integer field for RECALL.
limitField :: Value -> Maybe Int
limitField v =
  case parseMaybe (withObject "in" (.:? "limit")) v :: Maybe (Maybe Int) of
    Just (Just n) | n >= 0 -> Just n
    _                      -> Nothing

-- | Extract the optional @offset@ integer field for RECALL (defaults to 0).
offsetField :: Value -> Int
offsetField v =
  case parseMaybe (withObject "in" (.:? "offset")) v :: Maybe (Maybe Int) of
    Just (Just n) | n >= 0 -> n
    _                      -> 0

-- | MEMORY_WRITE: upsert a memory by id. If the memory already exists, its
-- content and/or tags are updated (the original 'meSession' provenance and
-- 'meCreatedAt' are preserved; only 'meUpdatedAt' is bumped); if not, a
-- fresh entry is created with the current session as provenance. The
-- content and tags are recorded in full (agent-visible data); 'orRecorded'
-- carries the id + op name + content + tags + @was_new@ (secret-free).
memoryWriteOp :: MemoryBackend -> SessionId -> Opcode
memoryWriteOp backend session = TrustedOpcode
  { toName = OpName "MEMORY_WRITE"
  , toTrust = Trusted
  , toDesc = "Create or update an agent memory by id (upsert; preserves provenance on update)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Memory id ([A-Za-z0-9_-]+)." :: Text)
              ]
          , fromText "content" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The memory content (agent-visible)." :: Text)
              ]
          , fromText "tags" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("Optional tags." :: Text)
              ]
          ]
      , "required" .= (["id", "content"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = maybe (Left "MEMORY_WRITE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkMemoryId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid memory id"] True (object []))
        Just mid -> do
          mExisting <- liftIO (mbRecall backend mid)
          now <- liftIO getCurrentTime
          let (entry, wasNew) = case mExisting of
                Just existing ->
                  ( existing
                      { meContent = contentField v
                      , meTags = tagsField v
                      , meUpdatedAt = now
                      }
                  , False
                  )
                Nothing ->
                  ( MemoryEntry
                      { meId = mid
                      , meContent = contentField v
                      , meTags = tagsField v
                      , meCreatedAt = now
                      , meUpdatedAt = now
                      , meSession = session
                      }
                  , True
                  )
          liftIO (mbStore backend entry)
          let recorded = object
                [ "id" .= memoryIdText mid
                , "content" .= meContent entry
                , "tags" .= meTags entry
                , "created_at" .= meCreatedAt entry
                , "updated_at" .= meUpdatedAt entry
                , "session" .= meSession entry
                , "was_new" .= wasNew
                ]
          pure (OpResult [TrpText (if wasNew then "stored" else "updated")] False recorded)
  }
  where
    checkId t = either (Left . ("invalid memory id: " <>)) (const (Right ())) (mkMemoryId t)

-- | MEMORY_RECALL: return a paged window of memories, optionally filtered by a
-- substring query. Uses the dynamic-retrieval pager.
memoryRecallOp :: PageParams -> MemoryBackend -> Opcode
memoryRecallOp params backend = TrustedOpcode
  { toName = OpName "MEMORY_RECALL"
  , toTrust = Trusted
  , toDesc = "Recall agent memories, optionally filtered by a substring query."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "query" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional substring filter over content+tags." :: Text)
              ]
          , fromText "limit" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Max items to return (clamped to the pager ceiling)." :: Text)
              ]
          , fromText "offset" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("0-based offset (defaults to 0)." :: Text)
              ]
          ]
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toRun = \_ v -> do
      let mQuery = queryField v
          offset = offsetField v
          mLimit = limitField v
      allEntries <- liftIO (mbList backend)
      let filtered = filter (matches mQuery) allEntries
          page = paginate params offset mLimit filtered
          rendered = T.intercalate "\n" (map renderEntry (pgItems page))
                    <> "\n---\npage " <> T.pack (show (pgOffset page))
                    <> " of " <> T.pack (show (pgTotal page))
                    <> if pgHasMore page then " (has more)" else " (end)"
      let recorded = object
            [ "query" .= mQuery
            , "offset" .= offset
            , "limit" .= mLimit
            , "total" .= pgTotal page
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }
  where
    matches mQuery e =
      case mQuery of
        Nothing -> True
        Just q  -> q `T.isInfixOf` meContent e || any (q `T.isInfixOf`) (meTags e)
    renderEntry e =
      memoryIdText (meId e) <> ": " <> meContent e

-- | MEMORY_DELETE: remove a memory by id. Idempotent (deleting a missing id is
-- a success with a "not present" message, not an error).
memoryDeleteOp :: MemoryBackend -> Opcode
memoryDeleteOp backend = TrustedOpcode
  { toName = OpName "MEMORY_DELETE"
  , toTrust = Trusted
  , toDesc = "Delete an agent memory by id (idempotent)."
  , toInSchema = singleStringSchema "id" "The memory id to delete."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "MEMORY_DELETE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkMemoryId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid memory id"] True (object []))
        Just mid -> do
          mExisting <- liftIO (mbRecall backend mid)
          liftIO (mbDelete backend mid)
          let msg = case mExisting of
                Nothing -> "deleted (was not present)"
                Just _  -> "deleted"
              recorded = object ["id" .= memoryIdText mid]
          pure (OpResult [TrpText msg] False recorded)
  }
  where
    checkId t = either (Left . ("invalid memory id: " <>)) (const (Right ())) (mkMemoryId t)