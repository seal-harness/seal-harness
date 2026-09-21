{-# LANGUAGE OverloadedStrings #-}
-- | The Memory opcode group. The consolidated entry point is
-- 'memoryManageOp' (\"MEMORY_MANAGE\"), which dispatches on an @action@
-- field to one of five handlers: @write@, @read@, @list@, @search@,
-- @archive@.
--
-- The legacy opcodes ('memoryWriteOp', 'memoryReadOp', 'memoryListOp',
-- 'memorySearchOp', 'memoryArchiveOp') remain as thin shims that delegate
-- to the same handlers with a pre-set action. This preserves backward
-- compatibility during the transition period — existing call sites, tests,
-- and downstream consumers continue to work unchanged.
--
-- All memory opcodes are 'Trusted' — the dispatcher writes the session
-- transcript; the opcodes operate on the file-based memory store
-- ('Seal.Memory.Store') and the embedding backend ('Seal.Memory.Embedding').
--
-- The memory system is write-once: the @write@ action fails if the path
-- already exists in @active\/@. To update a fact, archive the old memory
-- (@archive@ action) then write the new one. Files are never deleted —
-- archive is a move from @active\/@ to @archived\/@ with a timestamp
-- prefix.
--
-- The @read@ action falls back to @archived\/@ if the file isn't in
-- @active\/@, returning the content with an @archived: true@ flag.
--
-- The @search@ action delegates to the 'EmbeddingBackend'. The null
-- backend returns empty results (not an error), with a substring fallback.
module Seal.ISA.Ops.Memory
  ( -- * Consolidated opcode
    memoryManageOp
    -- * Legacy shims (delegate to the same handlers)
  , memoryWriteOp
  , memoryReadOp
  , memoryListOp
  , memorySearchOp
  , memoryArchiveOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value (..), object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Key (fromText)
import Seal.Types.App (App)
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

-- ---------------------------------------------------------------------------
-- Action enum
-- ---------------------------------------------------------------------------

data MemoryAction
  = MemWrite
  | MemRead
  | MemList
  | MemSearch
  | MemArchive

parseMemoryAction :: Value -> Either Text MemoryAction
parseMemoryAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "write"   -> Right MemWrite
      "read"    -> Right MemRead
      "list"    -> Right MemList
      "search"  -> Right MemSearch
      "archive" -> Right MemArchive
      other     -> Left ("unknown memory action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- ---------------------------------------------------------------------------
-- Field extractors
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Handlers (shared between MEMORY_MANAGE and legacy shims)
-- ---------------------------------------------------------------------------

handleWrite :: MemoryStore -> EmbeddingBackend -> Value -> App OpResult
handleWrite store embedding v =
  case parsePath v of
    Left e -> pure (OpResult [TrpText ("invalid path: " <> e)] True (object []))
    Right mp -> do
      let content = contentField v
      result <- liftIO (msWrite store mp content)
      case result of
        Left e -> pure (OpResult [TrpText e] True (object ["path" .= memoryPathText mp]))
        Right _ -> do
          liftIO (ebIndex embedding (T.unpack (memoryPathText mp)) content)
          let recorded = object
                [ "path" .= memoryPathText mp
                , "content" .= content
                ]
          pure (OpResult [TrpText "stored"] False recorded)

handleRead :: MemoryStore -> Value -> App OpResult
handleRead store v =
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

handleList :: MemoryStore -> Value -> App OpResult
handleList store v = do
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

handleSearch :: EmbeddingBackend -> MemoryStore -> Value -> App OpResult
handleSearch embedding store v =
  case queryField v of
    Nothing -> pure (OpResult [TrpText "missing query"] True (object []))
    Just query -> do
      let limit = limitField v
          includeArchived = includeArchivedField v
      results <- liftIO (ebSearch embedding query limit)
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
  where
    renderEmbeddingResult sr =
      srPath sr <> " (score: " <> T.pack (show (srScore sr)) <> "):\n"
        <> srContent sr
    renderSubstringResult (mp, content) =
      memoryPathText mp <> ":\n" <> content

handleArchive :: MemoryStore -> EmbeddingBackend -> Value -> App OpResult
handleArchive store embedding v =
  case parsePath v of
    Left e -> pure (OpResult [TrpText ("invalid path: " <> e)] True (object []))
    Right mp -> do
      result <- liftIO (msArchive store mp)
      case result of
        Left e -> pure (OpResult [TrpText e] True (object ["path" .= memoryPathText mp]))
        Right archivedPath -> do
          liftIO (ebUnindex embedding (T.unpack (memoryPathText mp)))
          let recorded = object
                [ "path" .= memoryPathText mp
                , "archived_path" .= memoryPathText archivedPath
                ]
          pure (OpResult [TrpText ("archived: " <> memoryPathText archivedPath)] False recorded)

-- ---------------------------------------------------------------------------
-- Authorize gate helpers
-- ---------------------------------------------------------------------------

authorizeWrite :: Value -> Either Text ()
authorizeWrite v =
  case parsePath v of
    Left e -> Left e
    Right _ -> case pathField v of
      Just _ -> case contentField v of
        "" -> Left "write requires non-empty content"
        _  -> Right ()
      Nothing -> Left "write requires path"

authorizeRead :: Value -> Either Text ()
authorizeRead = either Left (const (Right ())) . parsePath

authorizeSearch :: Value -> Either Text ()
authorizeSearch v =
  case queryField v of
    Nothing -> Left "search requires query"
    Just _  -> Right ()

authorizeArchive :: Value -> Either Text ()
authorizeArchive = either Left (const (Right ())) . parsePath

-- | Authorize gate for MEMORY_MANAGE — dispatches per-action validation.
authorizeManage :: Value -> Either Text ()
authorizeManage v =
  case parseMemoryAction v of
    Left e -> Left e
    Right action -> case action of
      MemWrite   -> authorizeWrite v
      MemRead    -> authorizeRead v
      MemList    -> Right ()
      MemSearch  -> authorizeSearch v
      MemArchive -> authorizeArchive v

-- ---------------------------------------------------------------------------
-- Consolidated opcode: MEMORY_MANAGE
-- ---------------------------------------------------------------------------

-- | MEMORY_MANAGE: action-based entry point for all memory operations.
-- The @action@ field discriminates between @write@, @read@, @list@,
-- @search@, and @archive@. Per-action required-field validation happens
-- in the authorize gate.
memoryManageOp :: MemoryStore -> EmbeddingBackend -> Opcode
memoryManageOp store embedding = TrustedOpcode
  { toName = OpName "MEMORY_MANAGE"
  , toTrust = Trusted
  , toDesc = "Manage memory files. Use action to select: write (create, write-once), read (by path, falls back to archived/), list (by prefix), search (semantic), archive (move to archived/)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["write", "read", "list", "search", "archive"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "path" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Memory path relative to active/ (write, read, archive)." :: Text)
              ]
          , fromText "content" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Memory content, plain text (write only)." :: Text)
              ]
          , fromText "prefix" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Directory prefix to filter by (list only)." :: Text)
              ]
          , fromText "query" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Search query (search only)." :: Text)
              ]
          , fromText "limit" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Max search results (default: 10)." :: Text)
              ]
          , fromText "include_archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("Include archived memories (list, search; default: false)." :: Text)
              ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeManage
  , toBlocking = False
  , toRun = \_ v ->
      case parseMemoryAction v of
        Left e -> pure (OpResult [TrpText e] True (object []))
        Right action -> case action of
          MemWrite   -> handleWrite store embedding v
          MemRead    -> handleRead store v
          MemList    -> handleList store v
          MemSearch  -> handleSearch embedding store v
          MemArchive -> handleArchive store embedding v
  }

-- ---------------------------------------------------------------------------
-- Legacy shims (backward compatibility)
-- ---------------------------------------------------------------------------

-- | MEMORY_WRITE (legacy shim): delegates to the write handler.
memoryWriteOp :: MemoryStore -> EmbeddingBackend -> Opcode
memoryWriteOp store embedding = TrustedOpcode
  { toName = OpName "MEMORY_WRITE"
  , toTrust = Trusted
  , toDesc = "Write a new memory file at the given path under active/. Fails if the file already exists (write-once). (Legacy — prefer MEMORY_MANAGE with action=\"write\".)"
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
  , toAuthorize = authorizeWrite
  , toBlocking = False
  , toRun = \_ v -> handleWrite store embedding v
  }

-- | MEMORY_READ (legacy shim): delegates to the read handler.
memoryReadOp :: MemoryStore -> Opcode
memoryReadOp store = TrustedOpcode
  { toName = OpName "MEMORY_READ"
  , toTrust = Trusted
  , toDesc = "Read a memory file by path. Falls back to archived/ if not in active/. (Legacy — prefer MEMORY_MANAGE with action=\"read\".)"
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
  , toAuthorize = authorizeRead
  , toBlocking = False
  , toRun = \_ v -> handleRead store v
  }

-- | MEMORY_LIST (legacy shim): delegates to the list handler.
memoryListOp :: MemoryStore -> Opcode
memoryListOp store = TrustedOpcode
  { toName = OpName "MEMORY_LIST"
  , toTrust = Trusted
  , toDesc = "List memory file paths matching a prefix. Set include_archived to also list archived memories. (Legacy — prefer MEMORY_MANAGE with action=\"list\".)"
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
  , toRun = \_ v -> handleList store v
  }

-- | MEMORY_SEARCH (legacy shim): delegates to the search handler.
memorySearchOp :: EmbeddingBackend -> MemoryStore -> Opcode
memorySearchOp embedding store = TrustedOpcode
  { toName = OpName "MEMORY_SEARCH"
  , toTrust = Trusted
  , toDesc = "Semantic search over memory files. Returns ranked results by meaning. (Legacy — prefer MEMORY_MANAGE with action=\"search\".)"
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
  , toAuthorize = authorizeSearch
  , toBlocking = False
  , toRun = \_ v -> handleSearch embedding store v
  }

-- | MEMORY_ARCHIVE (legacy shim): delegates to the archive handler.
memoryArchiveOp :: MemoryStore -> EmbeddingBackend -> Opcode
memoryArchiveOp store embedding = TrustedOpcode
  { toName = OpName "MEMORY_ARCHIVE"
  , toTrust = Trusted
  , toDesc = "Move a memory from active/ to archived/. The file is never deleted. (Legacy — prefer MEMORY_MANAGE with action=\"archive\".)"
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
  , toAuthorize = authorizeArchive
  , toBlocking = False
  , toRun = \_ v -> handleArchive store embedding v
  }
