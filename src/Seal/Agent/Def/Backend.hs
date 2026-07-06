{-# LANGUAGE OverloadedStrings #-}
-- | The agent-definition store backend. Disk is canonical. Two on-disk
-- schemes are discovered:
--
-- 1. **FlatScheme** — one Markdown file per def at @agents\/\<id\>.md@,
--    frontmatter (id\/name\/provider\/model\/tools\/timestamps\/session) +
--    body = system prompt. 'AGENT_DEF_CREATE' \/ 'AGENT_DEF_UPDATE' write
--    this form. This is the model-authored channel.
--
-- 2. **DirScheme** (PureClaw-compatible) — a subdirectory per agent at
--    @agents\/\<id\>\/@, with optional TOML frontmatter on @AGENTS.md@
--    (model\/provider\/tools) and the system prompt composed by reading
--    bootstrap files (@SOUL.md@, @USER.md@, @AGENTS.md@ body,
--    @MEMORY.md@, @IDENTITY.md@, @TOOLS.md@, @BOOTSTRAP.md@) in fixed
--    order with @--- SOUL ---@-style section markers. This is the
--    human-authored channel — drop a directory under @agents\/@ and it
--    is discovered.
--
-- **Conflict policy**: if both @agents\/\<id\>.md@ and @agents\/\<id\>\/@
-- exist, the flat file wins (it carries provenance and is the
-- model-authored form). The backend emits a warning on collision rather
-- than silently deduplicating.
--
-- **Directories are a one-time import path**: the first
-- 'AGENT_DEF_CREATE' \/ 'AGENT_DEF_UPDATE' for a DirScheme agent writes
-- @agents\/\<id\>.md@ (taking the composed prompt as the flat body),
-- after which the flat file takes precedence. The user can delete the
-- original directory at their leisure.
--
-- 'markdownAgentDefBackend' reads by enumerating the directory (both
-- schemes) and writes by atomic file replace + auto-commit.
-- 'noneBackend' (in-memory) is kept for tests.
--
-- The git repo is the versioning + audit layer; model-authored writes
-- (@AGENT_DEF_CREATE@ \/ @AGENT_DEF_UPDATE@, which are Trusted file writes)
-- auto-commit.
module Seal.Agent.Def.Backend
  ( AgentDefBackend (..)
  , noneBackend
  , markdownAgentDefBackend
  , encodeAgentDef
  , decodeAgentDef
  , composeDirSystemPrompt
  , defaultSectionCharLimit
  , maxBootstrapFileBytes
  , DirAgentConfig (..)
  , defaultDirAgentConfig
  , dirAgentConfigCodec
  , parseDirAgentConfig
  ) where

import Control.Exception qualified as Exc
import Control.Monad (forM, when)
import Data.Aeson (Value (..), encode)
import Data.ByteString.Lazy qualified as BL
import Data.Char qualified as Char
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.Vector qualified as V
import System.Directory (doesDirectoryExist, doesFileExist, getFileSize, getModificationTime, listDirectory, renameFile)
import System.FilePath ((</>), (<.>))
import System.Posix.Files (setFileMode)

import Toml ((.=))
import Toml qualified

import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText, isValidAgentDefId)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Security.Policy (AllowList (..))
import Seal.Store.Markdown (decodeDoc, encodeDoc, fmLookup, fmLookupList, splitFrontmatterRaw)

-- | The agent-definition store capability. Each operation is IO; 'adbList'
-- returns all defs sorted by id.
data AgentDefBackend = AgentDefBackend
  { adbRead   :: AgentDefId -> IO (Maybe AgentDef)
  , adbUpdate :: AgentDef -> IO ()
  , adbList   :: IO [AgentDef]
  }

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests.
noneBackend :: IO AgentDefBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map AgentDefId AgentDef)
  pure AgentDefBackend
    { adbRead   = \aid -> Map.lookup aid <$> readIORef ref
    , adbUpdate = \d -> modifyIORef' ref (Map.insert (adId d) d)
    , adbList   = Map.elems <$> readIORef ref
    }

-- | The Markdown backend. Discovers both flat @agents\/\<id\>.md@ files and
-- PureClaw-style @agents\/\<id\>\/@ subdirectories. Writes are atomic
-- (tmp → chmod 0600 → rename) and auto-committed to the config git repo.
-- Malformed files / dirs are skipped.
markdownAgentDefBackend :: FilePath -> ConfigRepo -> IO AgentDefBackend
markdownAgentDefBackend dir repo = pure AgentDefBackend
  { adbRead   = readAgentDef dir
  , adbUpdate = writeAgentDef dir repo
  , adbList   = listAgentDefs dir
  }

-- ---------------------------------------------------------------------------
-- FlatScheme (existing)
-- ---------------------------------------------------------------------------

-- | The filename for a def: @\<id\>.md@.
defFile :: FilePath -> AgentDefId -> FilePath
defFile dir aid = dir </> T.unpack (agentDefIdText aid) <.> "md"

-- | Encode an 'AgentDef' as a Markdown document (frontmatter + body, where
-- the body is the system prompt).
encodeAgentDef :: AgentDef -> Text
encodeAgentDef d = encodeDoc fm body
  where
    ModelId modelName = adModel d
    body = fromMaybe "" (adSystem d)
    fm = Map.fromList
      [ ("id", agentDefIdText (adId d))
      , ("name", adName d)
      , ("provider", adProvider d)
      , ("model", modelName)
      , ("tools", renderTools (adTools d))
      , ("created_at", isoTime (adCreatedAt d))
      , ("updated_at", isoTime (adUpdatedAt d))
      , ("session", sessionIdText (adSession d))
      ]
    sessionIdText (SessionId t) = t

-- | Decode a Markdown document into an 'AgentDef'. Returns 'Nothing' if the id
-- field is missing or fails 'mkAgentDefId'.
decodeAgentDef :: Text -> Maybe AgentDef
decodeAgentDef content =
  case decodeDoc content of
    (fm, body) -> do
      aidT <- fmLookup "id" fm
      aid  <- either (const Nothing) Just (mkAgentDefId aidT)
      Just AgentDef
        { adId = aid
        , adName = fromMaybe "" (fmLookup "name" fm)
        , adProvider = fromMaybe "" (fmLookup "provider" fm)
        , adModel = ModelId (fromMaybe "" (fmLookup "model" fm))
        , adSystem = if T.null body then Nothing else Just body
        , adTools = decodeTools fm
        , adCreatedAt = parseTime (fmLookup "created_at" fm)
        , adUpdatedAt = parseTime (fmLookup "updated_at" fm)
        , adSession = SessionId (fromMaybe "unknown" (fmLookup "session" fm))
        }

-- | Write one def to disk (atomic) and auto-commit.
writeAgentDef :: FilePath -> ConfigRepo -> AgentDef -> IO ()
writeAgentDef dir repo d = do
  let path = defFile dir (adId d)
      tmp  = path <.> "tmp"
  TIO.writeFile tmp (encodeAgentDef d)
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "agents" </> (T.unpack (agentDefIdText (adId d)) <.> "md")
  _ <- gitCommitAll repo rel ("seal: AGENT_DEF write " <> agentDefIdText (adId d))
  pure ()

-- ---------------------------------------------------------------------------
-- DirScheme (PureClaw-compatible)
-- ---------------------------------------------------------------------------

-- | Optional TOML frontmatter on @AGENTS.md@ inside an agent directory.
-- All fields are optional; unknown fields are ignored by the codec. A
-- missing @AGENTS.md@ or unparseable frontmatter yields
-- 'defaultDirAgentConfig'.
data DirAgentConfig = DirAgentConfig
  { dacModel    :: Maybe Text
  , dacProvider :: Maybe Text
  , dacTools    :: Maybe [Text]   -- ^ TOML array of opcode names; absent -> 'AllowAll'
  } deriving stock (Eq, Show)

-- | 'DirAgentConfig' with every field unset (the permissive fallback).
defaultDirAgentConfig :: DirAgentConfig
defaultDirAgentConfig = DirAgentConfig Nothing Nothing Nothing

-- | Bidirectional tomland codec for 'DirAgentConfig'. Mirrors the
-- @Toml.dioptional (Toml.text ...)@ pattern used in 'Seal.Config.File'.
-- @tools@ uses @Toml.arrayOf Toml._Text@ to decode a TOML array of
-- strings (e.g. @tools = ["FILE_READ", "ASK_HUMAN"]@).
dirAgentConfigCodec :: Toml.TomlCodec DirAgentConfig
dirAgentConfigCodec = DirAgentConfig
  <$> Toml.dioptional (Toml.text "model")              .= dacModel
  <*> Toml.dioptional (Toml.text "provider")           .= dacProvider
  <*> Toml.dioptional (Toml.arrayOf Toml._Text "tools") .= dacTools

-- | Parse the TOML frontmatter off an @AGENTS.md@ document. A document
-- with no frontmatter yields 'defaultDirAgentConfig'. Parse failures also
-- yield 'defaultDirAgentConfig' (permissive — matches PureClaw's
-- 'loadAgentConfig' fallback).
parseDirAgentConfig :: Text -> DirAgentConfig
parseDirAgentConfig input =
  case splitFrontmatterRaw input of
    (Nothing, _)   -> defaultDirAgentConfig
    (Just "", _)   -> defaultDirAgentConfig
    (Just toml, _) ->
      case Toml.decode dirAgentConfigCodec toml of
        Left _   -> defaultDirAgentConfig
        Right cfg -> cfg

-- | The directory for a def: @agents\/\<id\>@.
defDir :: FilePath -> AgentDefId -> FilePath
defDir dir aid = dir </> T.unpack (agentDefIdText aid)

-- | Bootstrap file types, in the fixed injection order (mirrors PureClaw's
-- 'SectionKind' list).
data SectionKind = SoulK | UserK | AgentsK | MemoryK | IdentityK | ToolsK | BootstrapK
  deriving stock (Eq, Show)

sectionFileName :: SectionKind -> FilePath
sectionFileName SoulK      = "SOUL.md"
sectionFileName UserK      = "USER.md"
sectionFileName AgentsK    = "AGENTS.md"
sectionFileName MemoryK    = "MEMORY.md"
sectionFileName IdentityK  = "IDENTITY.md"
sectionFileName ToolsK     = "TOOLS.md"
sectionFileName BootstrapK = "BOOTSTRAP.md"

sectionMarker :: SectionKind -> Text
sectionMarker SoulK      = "--- SOUL ---"
sectionMarker UserK      = "--- USER ---"
sectionMarker AgentsK    = "--- AGENTS ---"
sectionMarker MemoryK    = "--- MEMORY ---"
sectionMarker IdentityK  = "--- IDENTITY ---"
sectionMarker ToolsK     = "--- TOOLS ---"
sectionMarker BootstrapK = "--- BOOTSTRAP ---"

-- | Maximum raw file size we will read. Anything larger is skipped.
maxBootstrapFileBytes :: Integer
maxBootstrapFileBytes = 1024 * 1024

-- | Default per-file character limit for 'composeDirSystemPrompt'. Large
-- enough that typical SOUL/USER/AGENTS files fit intact; sections beyond
-- this are truncated with the PureClaw-style marker.
defaultSectionCharLimit :: Int
defaultSectionCharLimit = 65536

-- | Truncate a section body to @limit@ characters, appending the exact
-- truncation marker. Strings at or under the limit are returned as-is.
truncateSection :: Int -> Text -> Text
truncateSection limit txt
  | T.length txt <= limit = txt
  | otherwise =
      T.take limit txt
        <> "\n[...truncated at " <> T.pack (show limit) <> " chars...]"

-- | Read a single bootstrap section file, applying size/empty/truncation
-- rules. Returns 'Nothing' when the file is missing, empty
-- (including whitespace-only), or rejected as oversized. For @AGENTS.md@,
-- only the body after the TOML frontmatter fence is injected (the
-- frontmatter itself lives in 'DirAgentConfig').
readSection :: FilePath -> SectionKind -> Int -> IO (Maybe Text)
readSection dir kind limit = do
  let path = dir </> sectionFileName kind
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      size <- getFileSize path
      if size > maxBootstrapFileBytes
        then pure Nothing
        else do
          raw <- Exc.try (TIO.readFile path) :: IO (Either Exc.IOException Text)
          case raw of
            Left _ -> pure Nothing
            Right txt ->
              let contents = case kind of
                    AgentsK -> case splitFrontmatterRaw txt of
                      (_, body) -> body
                    _ -> txt
                  trimmed = T.dropWhileEnd Char.isSpace contents
              in if T.null (T.strip trimmed)
                   then pure Nothing
                   else pure (Just (truncateSection limit trimmed))

-- | Compose a system prompt from an agent directory's bootstrap files.
-- Files are read in the fixed injection order (SOUL, USER, AGENTS,
-- MEMORY, IDENTITY, TOOLS, BOOTSTRAP), missing/empty/oversized files are
-- skipped, and any section exceeding @limit@ characters is truncated with
-- the exact marker @"\\n[...truncated at \<limit\> chars...]"@. Returns
-- the empty string if every section is missing/empty.
composeDirSystemPrompt :: FilePath -> Int -> IO Text
composeDirSystemPrompt dir limit = do
  let kinds = [SoulK, UserK, AgentsK, MemoryK, IdentityK, ToolsK, BootstrapK]
  sections <- mapM (\k -> readSection dir k limit) kinds
  let rendered = [ sectionMarker k <> "\n" <> body
                 | (k, Just body) <- zip kinds sections
                 ]
  pure (T.intercalate "\n\n" rendered)

-- | Load a DirScheme agent def from @agents\/\<id\>\/@. Composes the
-- system prompt eagerly from the bootstrap files. Returns 'Nothing' if
-- the directory does not exist or the dirname fails 'isValidAgentDefId'.
loadDirAgentDef :: FilePath -> AgentDefId -> IO (Maybe AgentDef)
loadDirAgentDef agentsDir aid = do
  let dir = defDir agentsDir aid
  exists <- doesDirectoryExist dir
  if not exists
    then pure Nothing
    else do
      cfg <- loadDirAgentConfig dir
      body <- composeDirSystemPrompt dir defaultSectionCharLimit
      mtime <- dirMTime dir
      pure (Just AgentDef
        { adId = aid
        , adName = agentDefIdText aid
        , adProvider = fromMaybe "" (dacProvider cfg)
        , adModel = ModelId (fromMaybe "" (dacModel cfg))
        , adSystem = if T.null body then Nothing else Just body
        , adTools = decodeDirTools (dacTools cfg)
        , adCreatedAt = mtime
        , adUpdatedAt = mtime
        , adSession = SessionId "manual"
        })

-- | Read and parse the @AGENTS.md@ frontmatter inside an agent directory.
-- Missing file or parse failure yields 'defaultDirAgentConfig'.
loadDirAgentConfig :: FilePath -> IO DirAgentConfig
loadDirAgentConfig dir = do
  let path = dir </> "AGENTS.md"
  exists <- doesFileExist path
  if not exists
    then pure defaultDirAgentConfig
    else do
      raw <- Exc.try (TIO.readFile path) :: IO (Either Exc.IOException Text)
      case raw of
        Left _   -> pure defaultDirAgentConfig
        Right txt -> pure (parseDirAgentConfig txt)

-- | Best-effort mtime for an agent directory: the mtime of @AGENTS.md@ if
-- present, else the mtime of @SOUL.md@, else epoch zero. (Unstable across
-- @git pull@ — see the design doc §3.2 timestamp note.)
dirMTime :: FilePath -> IO UTCTime
dirMTime dir = do
  let candidates = [dir </> "AGENTS.md", dir </> "SOUL.md"]
  go candidates
  where
    go [] = pure epochZero
    go (p:ps) = do
      exists <- doesFileExist p
      if not exists
        then go ps
        else do
          mt <- Exc.try (getModificationTime p) :: IO (Either Exc.IOException UTCTime)
          case mt of
            Left _  -> go ps
            Right t -> pure t

-- | Decode the @tools@ frontmatter value (a 'Maybe [Text]' from the TOML
-- codec): @Nothing@ -> 'AllowAll'; a list of opcode-name strings ->
-- 'AllowOnly'. The string @"all"@ is not special here (the TOML codec
-- produces a list, not a scalar); callers wanting @AllowAll@ simply omit
-- the @tools@ key.
decodeDirTools :: Maybe [Text] -> AllowList OpName
decodeDirTools Nothing     = AllowAll
decodeDirTools (Just [])   = AllowAll
decodeDirTools (Just ts)   = AllowOnly (Set.fromList (map OpName ts))

-- ---------------------------------------------------------------------------
-- Hybrid discovery (flat + dir)
-- ---------------------------------------------------------------------------

-- | Read one def by id. Flat scheme takes precedence on conflict. Falls
-- back to the dir scheme if the flat file is absent. Returns 'Nothing' if
-- neither exists.
readAgentDef :: FilePath -> AgentDefId -> IO (Maybe AgentDef)
readAgentDef dir aid = do
  let flatPath = defFile dir aid
  flatExists <- doesFileExist flatPath
  if flatExists
    then do
      -- Conflict check: warn if a directory also exists.
      let dirPath = defDir dir aid
      dirExists <- doesDirectoryExist dirPath
      when dirExists $
        putStrLn ("warning: agent def " <> T.unpack (agentDefIdText aid)
                  <> " has both a flat file and a directory; flat file takes precedence")
      content <- TIO.readFile flatPath
      pure (decodeAgentDef content)
    else loadDirAgentDef dir aid

-- | Enumerate all defs in the directory (both schemes), sorted by id.
-- Malformed flat files and malformed dirs are skipped. On flat/dir
-- collision for the same id, the flat file wins and the dir is dropped.
listAgentDefs :: FilePath -> IO [AgentDef]
listAgentDefs dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      flatDefs <- collectFlat dir entries
      dirDefs  <- collectDirs dir entries (map adId flatDefs)
      pure (sortOn (agentDefIdText . adId) (flatDefs <> dirDefs))

-- | Decode all flat @.md@ files in the directory.
collectFlat :: FilePath -> [FilePath] -> IO [AgentDef]
collectFlat dir entries = do
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
  defs <- forM mdFiles $ \e -> do
    content <- TIO.readFile (dir </> e)
    pure (decodeAgentDef content)
  pure (catMaybes defs)

-- | Load DirScheme defs from subdirectories, skipping ids already
-- provided by the flat scheme (flat wins on conflict). Emits a warning
-- per collision.
collectDirs :: FilePath -> [FilePath] -> [AgentDefId] -> IO [AgentDef]
collectDirs dir entries flatIds = do
  let flatIdTexts = Set.fromList (map agentDefIdText flatIds)
      candidate e = do
        let full = dir </> e
        isDir <- doesDirectoryExist full
        let validDir = isDir && isValidAgentDefId (T.pack e)
        pure (if validDir then Just e else Nothing)
  mEntries <- mapM candidate entries
  let dirNames = catMaybes mEntries
  defs <- forM dirNames $ \e -> do
    case mkAgentDefId (T.pack e) of
      Left _   -> pure Nothing
      Right aid -> do
        if agentDefIdText aid `Set.member` flatIdTexts
          then do
            putStrLn ("warning: agent def " <> e
                      <> " has both a flat file and a directory; flat file takes precedence")
            pure Nothing  -- skip the dir def; flat wins
          else loadDirAgentDef dir aid
  pure (catMaybes defs)

-- ---------------------------------------------------------------------------
-- Shared helpers (flat + dir)
-- ---------------------------------------------------------------------------

-- | Render an 'AllowList OpName' as @"all"@ or a JSON array string.
renderTools :: AllowList OpName -> Text
renderTools AllowAll       = "all"
renderTools (AllowOnly xs) =
  TE.decodeUtf8 (BL.toStrict (encode (V.fromList [ String t | OpName t <- Set.toList xs ])))

-- | Decode the @tools@ frontmatter field (flat scheme): @"all"@ ->
-- 'AllowAll'; a JSON array of opcode-name strings -> 'AllowOnly';
-- absent/other -> 'AllowAll'.
decodeTools :: Map Text Text -> AllowList OpName
decodeTools fm = case Map.lookup "tools" fm of
  Nothing    -> AllowAll
  Just "all" -> AllowAll
  Just _     -> case fmLookupList "tools" fm of
    Just ts -> AllowOnly (Set.fromList (map OpName ts))
    Nothing -> AllowAll

-- | Render a 'UTCTime' as an ISO-8601 string (UTC, with @Z@ suffix).
isoTime :: UTCTime -> Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Parse an ISO-8601 'UTCTime' from a frontmatter value. Defaults to epoch 0
-- when absent or unparseable.
parseTime :: Maybe Text -> UTCTime
parseTime Nothing    = epochZero
parseTime (Just raw) = fromMaybe epochZero (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack raw))

-- | The epoch fallback for missing/unparseable timestamps.
epochZero :: UTCTime
epochZero = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)