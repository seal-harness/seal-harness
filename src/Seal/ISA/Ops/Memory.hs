{-# LANGUAGE OverloadedStrings #-}
-- | The Memory opcode group: MEMORY_WRITE, MEMORY_READ, MEMORY_LIST,
-- MEMORY_SEARCH, MEMORY_ARCHIVE. All Trusted — the dispatcher writes the
-- session transcript; the opcodes operate on the file-based memory store
-- ('Seal.Memory.Store') and the embedding backend
-- ('Seal.Memory.Embedding').
--
-- The memory system is write-once: 'MEMORY_WRITE' fails if the path
-- already exists in @active\/@. To update a fact, archive the old memory
-- ('MEMORY_ARCHIVE') then write the new one. Files are never deleted —
-- archive is a move from @active\/@ to @archived\/@ with a timestamp
-- prefix.
--
-- 'MEMORY_READ' falls back to @archived\/@ if the file isn't in @active\/@,
-- returning the content with an @archived: true@ flag.
--
-- 'MEMORY_SEARCH' delegates to the 'EmbeddingBackend'. The null backend
-- returns empty results (not an error).
module Seal.ISA.Ops.Memory
  ( memoryWriteOp
  , memoryReadOp
  , memoryListOp
  , memorySearchOp
  , memoryArchiveOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value, object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode
import Seal.Memory.Embedding (EmbeddingBackend (..), SearchResult (..))
import Seal.Memory.Path (MemoryPath, mkMemoryPath, memoryPathText)
import Seal.Memory.Store (MemoryStore (..))
import Seal.Providers.Class (ToolResultPart (..))

-- | Extract the @path@ string field from a JSON object.
pathField :: Value -> Maybe Text
pathField = parseMaybe (withObject "in" (.: "path"))

-- | Extract the @content@ string field (defaults to empty when absent).
contentField :: Value -> Text
contentField v = fromMaybe "" (parseMaybe (withObject "in" (.: "content")) v)

-- | Extract the optional @prefix@ string field for LIST.
prefixField :: Value -> Text
prefixField v =
  case parseMaybe (withObject "in" (.:? "prefix")) v :: Maybe (Maybe Text) of
    Just (Just t) -> t
    _             -> ""

-- | Extract the optional @include_archived@ bool field (defaults to False).
includeArchivedField :: Value -> Bool
includeArchivedField v =
  case parseMaybe (withObject "in" (.:? "include_archived")) v :: Maybe (Maybe Bool) of
    Just (Just b) -> b
    _             -> False

-- | Extract the optional @query@ string field for SEARCH.
queryField :: Value -> Maybe Text
queryField v =
  case parseMaybe (withObject "in" (.:? "query")) v :: Maybe (Maybe Text) of
    Just (Just q) -> Just q
    _             -> Nothing

-- | Extract the optional @limit@ integer field for SEARCH (defaults to 10).
limitField :: Value -> Int
limitField v =
  case parseMaybe (withObject "in" (.:? "limit")) v :: Maybe (Maybe Int) of
    Just (Just n) | n > 0 -> n
    _                     -> 10

-- | Validate and parse the path field into a 'MemoryPath'.
parsePath :: Value -> Either Text MemoryPath
parsePath v =
  case pathField v of
    Nothing -> Left "missing path field"
    Just t  -> mkMemoryPath t

-- | MEMORY_WRITE: write a new memory file. Write-once — fails if the path
-- already exists in @active\/@. After writing, the file is added to the
-- embedding index.
memoryWriteOp :: MemoryStore -> EmbeddingBackend -> Opcode
memoryWriteOp store embedding = TrustedOpcode
  { toName = OpName "MEMORY_WRITE"
  , toTrust = Trusted
  , toDesc = "Write a new memory file at the given path under active/. Fails if the file already exists (write-once)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "path" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Memory path relative to active/ (e.g. \"projects/architecture\")." :: Text)
              ]
          , fromText "content" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The memory content (plain text)." :: Text)
              ]
          ]
      , "required" .= (["path", "content"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = either Left (const (Right ())) . parsePath
  , toBlocking = False
  , toRun = \_ v -> do
      case parsePath v of
        Left e -> pure (OpResult [TrpText ("invalid path: " <> e)] True (object []))
        Right mp -> do
          let content = contentField v
          result <- liftIO (msWrite store mp content)
          case result of
            Left e -> pure (OpResult [TrpText e] True (object ["path" .= memoryPathText mp]))
            Right _ -> do
              -- Index the file (best-effort — null backend is a no-op).
              liftIO (ebIndex embedding (T.unpack (memoryPathText mp)) content)
              let recorded = object
                    [ "path" .= memoryPathText mp
                    , "content" .= content
                    ]
              pure (OpResult [TrpText "stored"] False recorded)
  }

-- | MEMORY_READ: read a memory by path. Falls back to @archived\/@ if not
-- in @active\/@, returning the content with an @archived: true@ flag.
memoryReadOp :: MemoryStore -> Opcode
memoryReadOp store = TrustedOpcode
  { toName = OpName "MEMORY_READ"
  , toTrust = Trusted
  , toDesc = "Read a memory file by path. Falls back to archived/ if not in active/."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "path" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Memory path relative to active/." :: Text)
              ]
          ]
      , "required" .= (["path"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = either Left (const (Right ())) . parsePath
  , toBlocking = False
  , toRun = \_ v -> do
      case parsePath v of
        Left e -> pure (OpResult [TrpText ("invalid path: " <> e)] True (object []))
        Right mp -> do
          result <- liftIO (msRead store mp)
          case result of
            Left _e -> do
              let recorded = object
                    [ "path" .= memoryPathText mp
                    , "exists" .= False
                    ]
              pure (OpResult [TrpText ("not found: " <> memoryPathText mp)] False recorded)
            Right (content, isArchived) -> do
              let recorded = object
                    [ "path" .= memoryPathText mp
                    , "content" .= content
                    , "exists" .= True
                    , "archived" .= isArchived
                    ]
                  msg = if isArchived
                          then "archived: " <> content
                          else content
              pure (OpResult [TrpText msg] False recorded)
  }

-- | MEMORY_LIST: list memory paths matching a prefix. By default, only
-- @active\/@ entries are returned; set @include_archived@ to also list
-- @archived\/@.
memoryListOp :: MemoryStore -> Opcode
memoryListOp store = TrustedOpcode
  { toName = OpName "MEMORY_LIST"
  , toTrust = Trusted
  , toDesc = "List memory file paths matching a prefix. Set include_archived to also list archived memories."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "prefix" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Directory prefix to filter by (e.g. \"projects/\")." :: Text)
              ]
          , fromText "include_archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("Include archived memories (default: false)." :: Text)
              ]
          ]
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ v -> do
      let prefix = prefixField v
          includeArchived = includeArchivedField v
      entries <- liftIO (msList store prefix includeArchived)
      let rendered = T.intercalate "\n" (map memoryPathText entries)
            <> "\n---\n" <> T.pack (show (length entries)) <> " entries"
          recorded = object
            [ "prefix" .= prefix
            , "include_archived" .= includeArchived
            , "count" .= length entries
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }

-- | MEMORY_SEARCH: semantic search over memory files via the
-- 'EmbeddingBackend'. Returns ranked results by meaning.
memorySearchOp :: EmbeddingBackend -> MemoryStore -> Opcode
memorySearchOp embedding store = TrustedOpcode
  { toName = OpName "MEMORY_SEARCH"
  , toTrust = Trusted
  , toDesc = "Semantic search over memory files. Returns ranked results by meaning."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "query" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Search query." :: Text)
              ]
          , fromText "limit" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Max results (default: 10)." :: Text)
              ]
          , fromText "include_archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("Search archived memories too (default: false)." :: Text)
              ]
          ]
      , "required" .= (["query"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ v -> do
      case queryField v of
        Nothing -> pure (OpResult [TrpText "missing query"] True (object []))
        Just query -> do
          let limit = limitField v
              includeArchived = includeArchivedField v
          results <- liftIO (ebSearch embedding query limit)
          -- Fall back to substring search when the embedding backend
          -- returns no results (e.g. null backend or no index).
          substringResults <-
            if null results
              then liftIO (msSearch store query includeArchived)
              else pure []
          let totalResults = length results + length substringResults
              allResults = map renderEmbeddingResult results
                        <> map renderSubstringResult substringResults
              rendered = if null allResults
                           then "No results."
                           else T.intercalate "\n" allResults
                       <> "\n---\n" <> T.pack (show totalResults) <> " results"
              recorded = object
                [ "query" .= query
                , "limit" .= limit
                , "total_matches" .= totalResults
                ]
          pure (OpResult [TrpText rendered] False recorded)
  }
  where
    renderEmbeddingResult sr =
      srPath sr <> " (score: " <> T.pack (show (srScore sr)) <> "):\n"
        <> srContent sr
    renderSubstringResult (mp, content) =
      memoryPathText mp <> ":\n" <> content

-- | MEMORY_ARCHIVE: move a memory file from @active\/@ to @archived\/@
-- with a timestamp prefix. This is the only way to "remove" a memory —
-- the file is never deleted.
memoryArchiveOp :: MemoryStore -> EmbeddingBackend -> Opcode
memoryArchiveOp store embedding = TrustedOpcode
  { toName = OpName "MEMORY_ARCHIVE"
  , toTrust = Trusted
  , toDesc = "Move a memory from active/ to archived/. The file is never deleted."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "path" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Memory path to archive." :: Text)
              ]
          ]
      , "required" .= (["path"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = either Left (const (Right ())) . parsePath
  , toBlocking = False
  , toRun = \_ v -> do
      case parsePath v of
        Left e -> pure (OpResult [TrpText ("invalid path: " <> e)] True (object []))
        Right mp -> do
          result <- liftIO (msArchive store mp)
          case result of
            Left e -> pure (OpResult [TrpText e] True (object ["path" .= memoryPathText mp]))
            Right archivedPath -> do
              -- Update the index (best-effort).
              liftIO (ebUnindex embedding (T.unpack (memoryPathText mp)))
              let recorded = object
                    [ "path" .= memoryPathText mp
                    , "archived_path" .= memoryPathText archivedPath
                    ]
              pure (OpResult [TrpText ("archived: " <> memoryPathText archivedPath)] False recorded)
  }
