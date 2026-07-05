{-# LANGUAGE OverloadedStrings #-}
-- | The Memory opcode group: MEMORY_STORE, MEMORY_RECALL, MEMORY_UPDATE,
-- MEMORY_DELETE. All Audited — the dispatcher writes both the session
-- transcript and the Audited log; the opcodes mutate the in-memory/SQLite/
-- Markdown backend (the materialized view). 'orRecorded' carries the
-- secret-free 'MemoryId' + op name; the memory CONTENT is agent-visible data
-- (not a vault secret) and is recorded in full in both logs.
--
-- 'MEMORY_RECALL' uses the dynamic-retrieval pager ('Seal.Core.Paging'):
-- @page_size = clamp floor ceiling (round (coeff * sqrt total))@, where total
-- is the number of matching memories.
module Seal.ISA.Ops.Memory
  ( memoryStoreOp
  , memoryRecallOp
  , memoryUpdateOp
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

-- | MEMORY_STORE: insert or replace a memory by id. The content and tags are
-- recorded in full (agent-visible data); 'orRecorded' carries the id + op
-- name + content + tags (secret-free).
memoryStoreOp :: MemoryBackend -> SessionId -> Opcode
memoryStoreOp backend session = Opcode
  { opName = OpName "MEMORY_STORE"
  , opTrust = Audited
  , opDesc = "Store an agent memory by id (insert or replace)."
  , opInSchema = object
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
  , opOutSchema = object []
  , opAuthorize = maybe (Left "MEMORY_STORE requires {id:string}") checkId . idField
  , opRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkMemoryId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid memory id"] True (object []))
        Just mid -> do
          now <- liftIO getCurrentTime
          let entry = MemoryEntry
                { meId = mid
                , meContent = contentField v
                , meTags = tagsField v
                , meCreatedAt = now
                , meUpdatedAt = now
                , meSession = session
                }
          liftIO (mbStore backend entry)
          let recorded = object
                [ "id" .= memoryIdText mid
                , "content" .= meContent entry
                , "tags" .= meTags entry
                , "created_at" .= meCreatedAt entry
                , "updated_at" .= meUpdatedAt entry
                , "session" .= meSession entry
                ]
          pure (OpResult [TrpText "stored"] False recorded)
  }
  where
    checkId t = either (Left . ("invalid memory id: " <>)) (const (Right ())) (mkMemoryId t)

-- | MEMORY_RECALL: return a paged window of memories, optionally filtered by a
-- substring query. Uses the dynamic-retrieval pager.
memoryRecallOp :: PageParams -> MemoryBackend -> Opcode
memoryRecallOp params backend = Opcode
  { opName = OpName "MEMORY_RECALL"
  , opTrust = Audited
  , opDesc = "Recall agent memories, optionally filtered by a substring query."
  , opInSchema = object
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
  , opOutSchema = object []
  , opAuthorize = const (Right ())
  , opRun = \_ v -> do
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

-- | MEMORY_UPDATE: update an existing memory's content and/or tags. The
-- updated_at timestamp is bumped. If the memory does not exist, returns an
-- error result (the model should use MEMORY_STORE to create). The original
-- 'meSession' is preserved (the update is attributed to the session that
-- created the memory, not the session that updated it).
memoryUpdateOp :: MemoryBackend -> Opcode
memoryUpdateOp backend = Opcode
  { opName = OpName "MEMORY_UPDATE"
  , opTrust = Audited
  , opDesc = "Update an existing memory's content and/or tags."
  , opInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The memory id to update." :: Text)
              ]
          , fromText "content" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("New content (optional)." :: Text)
              ]
          , fromText "tags" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("New tags (optional)." :: Text)
              ]
          ]
      , "required" .= (["id"] :: [Text])
      ]
  , opOutSchema = object []
  , opAuthorize = maybe (Left "MEMORY_UPDATE requires {id:string}") checkId . idField
  , opRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkMemoryId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid memory id"] True (object []))
        Just mid -> do
          mExisting <- liftIO (mbRecall backend mid)
          case mExisting of
            Nothing -> pure (OpResult [TrpText "memory not found"] True (object ["id" .= memoryIdText mid]))
            Just existing -> do
              now <- liftIO getCurrentTime
              let newContent = case parseMaybe (withObject "in" (.:? "content")) v :: Maybe (Maybe Text) of
                    Just (Just c) -> c
                    _             -> meContent existing
                  newTags = case parseMaybe (withObject "in" (.:? "tags")) v :: Maybe (Maybe [Text]) of
                    Just (Just ts) -> ts
                    _              -> meTags existing
                  updated = existing
                    { meContent = newContent
                    , meTags = newTags
                    , meUpdatedAt = now
                    }
              liftIO (mbUpdate backend updated)
              let recorded = object
                    [ "id" .= memoryIdText mid
                    , "content" .= meContent updated
                    , "tags" .= meTags updated
                    , "updated_at" .= meUpdatedAt updated
                    , "session" .= meSession updated
                    ]
              pure (OpResult [TrpText "updated"] False recorded)
  }
  where
    checkId t = either (Left . ("invalid memory id: " <>)) (const (Right ())) (mkMemoryId t)

-- | MEMORY_DELETE: remove a memory by id. Idempotent (deleting a missing id is
-- a success with a "not present" message, not an error).
memoryDeleteOp :: MemoryBackend -> Opcode
memoryDeleteOp backend = Opcode
  { opName = OpName "MEMORY_DELETE"
  , opTrust = Audited
  , opDesc = "Delete an agent memory by id (idempotent)."
  , opInSchema = singleStringSchema "id" "The memory id to delete."
  , opOutSchema = object []
  , opAuthorize = maybe (Left "MEMORY_DELETE requires {id:string}") checkId . idField
  , opRun = \_ v -> do
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