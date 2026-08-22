{-# LANGUAGE OverloadedStrings #-}
-- | The workdir-scoped agent-definition discovery backend.
--
-- This module scans a session workdir (the workspace root, via the
-- 'WorkdirFs' handle) for agent definitions shipped by cloned
-- repositories. It is the single home for ALL workspace-derived agent-def
-- discovery; the user store lives in "Seal.Agent.Def.Backend" (§3.9).
--
-- **No direct filesystem access.** This module deliberately does NOT
-- import @System.Directory@ or @Data.Text.IO@ — every workspace read goes
-- through the 'WorkdirFs' handle (single SafePath-confined chokepoint,
-- §3.6). The compile-fail fixture
-- @Seal.Agent.Def.BackendNoDirectFsFailSpec@ asserts this invariant by
-- grepping this module's source for those import lines.
--
-- Two on-disk schemes are discovered (mirroring the user store):
--
-- 1. **FlatScheme** — one Markdown file per def at @agents\/\<id\>.md@,
--    frontmatter + body = system prompt.
-- 2. **DirScheme** (PureClaw-compatible) — a subdirectory per agent at
--    @agents\/\<id\>\/@, with optional TOML frontmatter on @AGENTS.md@
--    and the system prompt composed by reading bootstrap files
--    (@SOUL.md@, @USER.md@, @AGENTS.md@ body, @MEMORY.md@,
--    @IDENTITY.md@, @TOOLS.md@, @BOOTSTRAP.md@) in fixed order with
--    @--- SOUL ---@-style section markers.
--
-- For @.agents\/@, the [.agents Protocol](https://dotagentsprotocol.com) is
-- recognized: when @.agents\/@ contains @agents.md@ OR an @agents\/@
-- subdirectory, it is treated as a **protocol root** — the project-level
-- @.agents\/agents.md@ is loaded as an agent def (id @agents-md@), and each
-- @.agents\/agents\/\<id\>\/agent.md@ sub-agent is loaded. Otherwise
-- @.agents\/@ falls back to the legacy hybrid flat + DirScheme discovery.
--
-- @.seal\/agents@ and @agents@ always use the legacy discovery.
--
-- The re-exports from "Seal.Agent.Def.Backend" keep the public API
-- stable ('workdirAgentDefBackend', 'composeDirSystemPrompt',
-- 'encodeAgentDef', 'decodeAgentDef', etc.).
module Seal.Agent.Def.Workdir
  ( -- * Backend record
    AgentDefBackend (..)
    -- * Workdir backend
  , workdirAgentDefBackend
  , listWorkdirAgentDefs
  , listWorkdirAgentDefsSnap
  , staticAgentDefBackend
    -- * DirScheme composition (WorkdirFs-anchored)
  , composeDirSystemPrompt
  , readSection
  , loadDirAgentDef
  , loadDirAgentConfig
  , dirMTime
    -- * Protocol discovery (WorkdirFs-anchored)
  , listAgentsDotAgents
  , listProtocolAgentDefs
  , isProtocolRoot
  , loadProjectAgentDef
  , loadProtocolSubAgent
    -- * Flat codecs (shared with the user store)
  , encodeAgentDef
  , decodeAgentDef
    -- * DirScheme types + helpers
  , DirAgentConfig (..)
  , defaultDirAgentConfig
  , dirAgentConfigCodec
  , parseDirAgentConfig
  , SectionKind (..)
  , sectionFileName
  , sectionMarker
  , truncateSection
  , defaultSectionCharLimit
  , maxBootstrapFileBytes
  , decodeDirTools
  , decodeTools
  , renderTools
  , isoTime
  , parseTime
  , epochZero
  , deriveAgentsMdId
  ) where

import Control.Monad (forM, (<=<))
import Data.Aeson (Value (..), encode)
import Data.ByteString.Lazy qualified as BL
import Data.Char qualified as Char
import Data.Either (fromRight)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.Vector qualified as V

import Toml ((.=))
import Toml qualified

import Seal.Agent.Def.Types
  ( AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText
  , isValidAgentDefId
  )
import Seal.Core.Types (ModelId (..), OpName (..), mkSessionId, mkSystemSessionId, sessionIdText)
import Seal.Security.Policy (AllowList (..))
import Seal.Store.Markdown
  ( decodeDoc, encodeDoc, fmLookup, fmLookupList, splitFrontmatterRaw
  )
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath, getRemotePath)
import Seal.Tools.Exec.WorkdirFs
  ( WorkdirFs (..)
  , WorkspaceSnapshot
  , snapChildDirsAt, snapChildFilesAt, snapIsDirectoryAt, snapIsFileAt
  , snapTopDirs
  , wfsSnapshot
  )

-- ---------------------------------------------------------------------------
-- Backend record (lives here so the workdir backend can construct one
-- without an import cycle with "Seal.Agent.Def.Backend", which re-exports
-- this module's workdir API and builds the user store on top of it).
-- ---------------------------------------------------------------------------

-- | The agent-definition store capability. Each operation is IO; 'adbList'
-- returns all defs sorted by id.
data AgentDefBackend = AgentDefBackend
  { adbRead   :: AgentDefId -> IO (Maybe AgentDef)
  , adbUpdate :: AgentDef -> IO ()
  , adbList   :: IO [AgentDef]
  , adbDelete :: AgentDefId -> IO ()
  -- ^ Remove a def by id (delete the file + auto-commit; idempotent).
  }

-- ---------------------------------------------------------------------------
-- Conventions + protocol identifiers
-- ---------------------------------------------------------------------------

-- | The conventional agent-def directories a cloned repo may carry.
-- @.agents@ is the primary convention (mirrors @.skills@ for the
-- agentskills.io format). The others are back-compat.
workdirAgentDefConventions :: [FilePath]
workdirAgentDefConventions = [ ".agents", ".seal/agents", "agents" ]

-- | The synthetic 'AgentDefId' text for the project-level @.agents/agents.md@
-- (the @.agents Protocol@ project instructions file). The @-md@ suffix makes
-- accidental collision with a subdir name unlikely; the existing
-- flat-wins-on-conflict rule is the real guard. The suffix is the invariant
-- pinned by the QuickCheck property (§3.1).
deriveAgentsMdId :: Text
deriveAgentsMdId = "agents-md"

-- | The friendly display name for the project-level @agents.md@ when its
-- frontmatter has no @name@ field (so the synthetic id never leaks to the
-- UI — §3.1).
projectAgentsMdDisplayName :: Text
projectAgentsMdDisplayName = "Project (agents.md)"

-- ---------------------------------------------------------------------------
-- DirScheme types + pure helpers
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

-- | Maximum raw file size we will read. Anything larger is skipped. (The
-- 'WorkdirFs' byte ceiling is the live bound; this constant is retained as
-- the documented per-file cap and for the oversize test.)
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

-- ---------------------------------------------------------------------------
-- Flat codecs (shared with the user store in Seal.Agent.Def.Backend)
-- ---------------------------------------------------------------------------

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
        , adSession = fromRight (mkSystemSessionId "unknown") (mkSessionId (fromMaybe "unknown" (fmLookup "session" fm)))
        }

-- ---------------------------------------------------------------------------
-- Shared pure helpers (flat + dir)
-- ---------------------------------------------------------------------------

-- | Decode the @tools@ frontmatter value (a 'Maybe [Text]' from the TOML
-- codec): @Nothing@ -> 'AllowAll'; a list of opcode-name strings ->
-- 'AllowOnly'. The string @"all"@ is not special here (the TOML codec
-- produces a list, not a scalar); callers wanting @AllowAll@ simply omit
-- the @tools@ key.
decodeDirTools :: Maybe [Text] -> AllowList OpName
decodeDirTools Nothing     = AllowAll
decodeDirTools (Just [])   = AllowAll
decodeDirTools (Just ts)   = AllowOnly (Set.fromList (map OpName ts))

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

-- ---------------------------------------------------------------------------
-- DirScheme composition (WorkdirFs-anchored)
-- ---------------------------------------------------------------------------

-- | Read a single bootstrap section file, applying size/empty/truncation
-- rules. Returns 'Nothing' when the file is missing, empty
-- (including whitespace-only), or rejected as oversized. For @AGENTS.md@,
-- only the body after the TOML frontmatter fence is injected (the
-- frontmatter itself lives in 'DirAgentConfig').
--
-- Reads through the 'WorkdirFs' handle (single confinement chokepoint,
-- §3.6); the section file is looked up as @\<sectionFileName\>@ directly
-- under the anchor. The @limit@ is the per-section character cap; the
-- byte-level size cap is applied inside 'wfsReadFile'.
readSection :: WorkdirFs -> SectionKind -> Int -> IO (Maybe Text)
readSection fs kind limit = do
  let rel = T.pack (sectionFileName kind)
  eTxt <- wfsReadFile fs =<< rpOrDie rel
  case eTxt of
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
--
-- The 'WorkdirFs' is anchored at the agent directory (the section files
-- are looked up as @SOUL.md@\/@AGENTS.md@\/… directly under the anchor).
composeDirSystemPrompt :: WorkdirFs -> Int -> IO Text
composeDirSystemPrompt fs limit = do
  let kinds = [SoulK, UserK, AgentsK, MemoryK, IdentityK, ToolsK, BootstrapK]
  sections <- mapM (\k -> readSection fs k limit) kinds
  let rendered = [ sectionMarker k <> "\n" <> body
                 | (k, Just body) <- zip kinds sections
                 ]
  pure (T.intercalate "\n\n" rendered)

-- | Load a DirScheme agent def from @agents\/\<id\>\/@. Composes the
-- system prompt eagerly from the bootstrap files. Returns 'Nothing' if
-- the directory does not exist or the dirname fails 'isValidAgentDefId'.
--
-- The 'WorkdirFs' is anchored at the agents directory (the per-agent
-- subdirectory is @\<id\>@ under the anchor).
loadDirAgentDef :: WorkdirFs -> AgentDefId -> IO (Maybe AgentDef)
loadDirAgentDef fs aid = do
  let dirRp = agentDefIdText aid
  exists <- wfsDoesDirectoryExist fs =<< rpOrDie dirRp
  if not exists
    then pure Nothing
    else do
      let subFs = reanchorFs fs dirRp
      cfg  <- loadDirAgentConfig subFs
      body <- composeDirSystemPrompt subFs defaultSectionCharLimit
      mtime <- dirMTime subFs
      pure (Just AgentDef
        { adId = aid
        , adName = agentDefIdText aid
        , adProvider = fromMaybe "" (dacProvider cfg)
        , adModel = ModelId (fromMaybe "" (dacModel cfg))
        , adSystem = if T.null body then Nothing else Just body
        , adTools = decodeDirTools (dacTools cfg)
        , adCreatedAt = mtime
        , adUpdatedAt = mtime
        , adSession = mkSystemSessionId "manual"
        })

-- | Read and parse the @AGENTS.md@ frontmatter inside an agent directory.
-- Missing file or parse failure yields 'defaultDirAgentConfig'. The
-- 'WorkdirFs' is anchored at the agent directory.
loadDirAgentConfig :: WorkdirFs -> IO DirAgentConfig
loadDirAgentConfig fs = do
  eTxt <- wfsReadFile fs =<< rpOrDie "AGENTS.md"
  case eTxt of
    Left _   -> pure defaultDirAgentConfig
    Right txt -> pure (parseDirAgentConfig txt)

-- | Best-effort mtime for an agent directory: the mtime of @AGENTS.md@ if
-- present, else the mtime of @SOUL.md@, else epoch zero. (Unstable across
-- @git pull@ — see the design doc §3.2 timestamp note.) The 'WorkdirFs'
-- is anchored at the agent directory.
dirMTime :: WorkdirFs -> IO UTCTime
dirMTime fs = go ["AGENTS.md", "SOUL.md"]
  where
    go [] = pure epochZero
    go (p:ps) = do
      eMt <- wfsModificationTime fs =<< rpOrDie (T.pack p)
      case eMt of
        Left _  -> go ps
        Right t -> pure t

-- ---------------------------------------------------------------------------
-- Protocol discovery (WorkdirFs-anchored)
-- ---------------------------------------------------------------------------

-- | Decode the project-level @agents.md@ frontmatter + body into an
-- 'AgentDef' (id @agents-md@). Frontmatter @kind@/@name@/@provider@/@model@
-- honored; @kind@ is not required (its presence doesn't gate discovery —
-- @agents.md@ is the canonical project instructions file regardless).
decodeProjectAgentsMd :: Text -> Maybe AgentDef
decodeProjectAgentsMd content =
  case decodeDoc content of
    (fm, body) ->
      case mkAgentDefId deriveAgentsMdId of
        Left _ -> Nothing
        Right aid -> Just AgentDef
          { adId = aid
          , adName = fromMaybe projectAgentsMdDisplayName (fmLookup "name" fm)
          , adProvider = fromMaybe "" (fmLookup "provider" fm)
          , adModel = ModelId (fromMaybe "" (fmLookup "model" fm))
          , adSystem = if T.null body then Nothing else Just body
          , adTools = decodeTools fm
          , adCreatedAt = epochZero
          , adUpdatedAt = epochZero
          , adSession = mkSystemSessionId "manual"
          }

-- | Decode a protocol @agent.md@ frontmatter + body into an 'AgentDef'.
-- The id is the subdir name, unless frontmatter @id@ is present and valid
-- (then frontmatter wins). @enabled@ absent → enabled (appears); explicit
-- @enabled: false@ → 'Nothing' (skipped per §3.3). Frontmatter
-- @name@/@provider@/@model@ honored when present.
decodeProtocolAgentMd :: Text -> Text -> Maybe AgentDef
decodeProtocolAgentMd subDirName content =
  case decodeDoc content of
    (fm, body) ->
      case fmLookup "enabled" fm of
        Just v | T.strip v == "false" -> Nothing  -- disabled → skip
        _ ->
          let idText = fromMaybe subDirName (fmLookup "id" fm >>= validId)
          in case mkAgentDefId idText of
               Left _ -> Nothing
               Right aid -> Just AgentDef
                 { adId = aid
                 , adName = fromMaybe idText (fmLookup "name" fm)
                 , adProvider = fromMaybe "" (fmLookup "provider" fm)
                 , adModel = ModelId (fromMaybe "" (fmLookup "model" fm))
                 , adSystem = if T.null body then Nothing else Just body
                 , adTools = decodeTools fm
                 , adCreatedAt = epochZero
                 , adUpdatedAt = epochZero
                 , adSession = mkSystemSessionId "manual"
                 }
  where
    validId t = if isValidAgentDefId t then Just t else Nothing

-- | Load the project-level @.agents\/agents.md@ as an 'AgentDef' with id
-- @agents-md@ (§3.1). The 'WorkdirFs' is anchored at the @.agents\/@
-- directory (confinement is applied inside the handle — no 'mkSafePath'
-- call here, §3.6). Returns 'Nothing' when the file is missing, unconfined,
-- or unparseable.
loadProjectAgentDef :: WorkdirFs -> IO (Maybe AgentDef)
loadProjectAgentDef fs = do
  eContent <- wfsReadFile fs =<< rpOrDie "agents.md"
  case eContent of
    Left _        -> pure Nothing  -- symlink escape, missing, oversize → skip
    Right content -> pure (decodeProjectAgentsMd content)

-- | Load one protocol sub-agent from @agents\/\<id\>\/agent.md@ (§3.3). The
-- id is the subdir name, unless frontmatter @id@ is present and valid
-- (then frontmatter wins). @enabled: false@ → 'Nothing' (skipped). The
-- 'WorkdirFs' is anchored at the @.agents\/@ directory.
loadProtocolSubAgent :: WorkdirFs -> Text -> IO (Maybe AgentDef)
loadProtocolSubAgent fs subDirName = do
  let rel = "agents/" <> subDirName <> "/agent.md"
  eContent <- wfsReadFile fs =<< rpOrDie rel
  case eContent of
    Left _        -> pure Nothing  -- symlink escape, missing, oversize → skip
    Right content -> pure (decodeProtocolAgentMd subDirName content)

-- | The detection predicate (§3.3): @.agents\/@ is a protocol root iff it
-- contains @agents.md@ (a file) OR an @agents\/@ subdirectory. The
-- 'WorkdirFs' is anchored at the @.agents\/@ directory.
isProtocolRoot :: WorkdirFs -> IO Bool
isProtocolRoot fs = do
  hasAgentsMd  <- wfsDoesFileExist fs =<< rpOrDie "agents.md"
  hasAgentsSub <- wfsDoesDirectoryExist fs =<< rpOrDie "agents"
  pure (hasAgentsMd || hasAgentsSub)

-- | The protocol allow-list scan (§3.3). Scans only @agents\/\<id\>\/agent.md@
-- (sub-agents) + @agents.md@ (project def). Skips everything else
-- (@skills\/@, @tasks\/@, @memories\/@, @mcp.json@). The 'WorkdirFs' is
-- anchored at the @.agents\/@ directory.
listProtocolAgentDefs :: WorkdirFs -> IO [AgentDef]
listProtocolAgentDefs fs = do
  -- The project-level agents.md (id agents-md).
  mProject <- loadProjectAgentDef fs
  -- Sub-agents under agents/<id>/agent.md.
  subExists <- wfsDoesDirectoryExist fs =<< rpOrDie "agents"
  subDefs <- if not subExists
    then pure []
    else do
      eEntries <- wfsListDirectory fs =<< rpOrDie "agents"
      let entries = fromRight [] eEntries
          candidate e = do
            isDir <- wfsDoesDirectoryExist fs =<< rpOrDie ("agents/" <> e)
            pure (if isDir && isValidAgentDefId e then Just e else Nothing)
      mEntries <- mapM candidate (sortOn id entries)
      catMaybes <$> mapM (loadProtocolSubAgent fs) (catMaybes mEntries)
  let allDefs = catMaybes [mProject] <> subDefs
  pure (sortOn (agentDefIdText . adId) allDefs)

-- | Dispatch for the @.agents\/@ convention dir: protocol-root detection
-- (§3.3). When @.agents\/@ contains @agents.md@ OR an @agents\/@
-- subdirectory, scan the protocol allow-list; otherwise fall back to legacy
-- 'listAgentDefsFs' (DirScheme with @SOUL.md@\/@AGENTS.md@ bootstrap
-- files). The 'WorkdirFs' is anchored at the @.agents\/@ directory.
listAgentsDotAgents :: WorkdirFs -> IO [AgentDef]
listAgentsDotAgents fs = do
  isProto <- isProtocolRoot fs
  if isProto
    then listProtocolAgentDefs fs
    else listAgentDefsFs fs

-- ---------------------------------------------------------------------------
-- Workdir-scoped backend
-- ---------------------------------------------------------------------------

-- | A read-only 'AgentDefBackend' that scans a session workdir for agent
-- definitions shipped by cloned repositories. For each top-level directory
-- in the workdir (a cloned repo), it checks the conventional agent-def
-- locations (@.agents\/@, @.seal\/agents\/@, @agents\/@).
--
-- This backend is /read-only/: 'adbUpdate'/'adbDelete' are no-ops (repo-local
-- agent defs are immutable from the model's perspective). 'adbRead' scans
-- on every call (workdirs are small). Within-workdir collisions (two repos
-- ship a def with the same id): the alphabetically-first repo wins
-- (deterministic; same as the skill backend's policy).
--
-- Every file open goes through the 'WorkdirFs' handle (symlink-escape
-- confinement — §3.8; single chokepoint, §3.6) and is size-capped at
-- 'maxScanBytes' + 'truncateSection'.
workdirAgentDefBackend :: WorkdirFs -> IO AgentDefBackend
workdirAgentDefBackend fs = pure AgentDefBackend
    { adbRead   = \aid -> do
        defs <- listWorkdirAgentDefs fs
        pure (Map.lookup aid (Map.fromList [(adId d, d) | d <- defs]))
    , adbUpdate = \_ -> pure ()
    , adbList   = listWorkdirAgentDefs fs
    , adbDelete = \_ -> pure ()
    }

-- | Enumerate every agent def found under the conventional locations across
-- all top-level directories (cloned repos) in the workdir anchored at the
-- 'WorkdirFs'. The alphabetically-first repo wins on prefixed-id
-- collisions (deterministic). Missing or empty workdirs yield @[]@.
--
-- Each def's id is prefixed with its repo's top-level directory name + @"--"@
-- (e.g. @vtag--architect-agent@) and its @adName@ with @\<repo\>\/@ (e.g.
-- @vtag\/Architect Agent@). This disambiguates repo-local agents from the
-- user's own agents (and from other repos' agents) when the union backend
-- merges workdir ⊕ user. The @--@ separator is charset-safe
-- (@isValidAgentDefId@); the @/@ in the display name is for human
-- readability only.
--
-- /Round-trip economy/: all structural questions (which repos exist, which
-- convention dirs exist, which entries are dirs) are answered from ONE
-- 'wfsSnapshot' call; only file CONTENTS are read through 'wfsReadFile'
-- (the symlink-containment chokepoint). On @mode=remote@ this collapses a
-- scan from one SSH round trip per probe to one round trip + two calls per
-- discovered def file.
listWorkdirAgentDefs :: WorkdirFs -> IO [AgentDef]
listWorkdirAgentDefs fs = do
  eSnap <- wfsSnapshot fs
  case eSnap of
    -- Fail-soft-to-empty: a missing/stub/failing workdir yields no defs —
    -- the same terminal state as today's empty listings.
    Left _  -> pure []
    Right snap -> listWorkdirAgentDefsSnap snap fs

-- | 'listWorkdirAgentDefs' over a caller-supplied snapshot — lets a
-- consumer (the discovery cache) fetch ONE workspace snapshot and serve
-- both scanners from it.
listWorkdirAgentDefsSnap :: WorkspaceSnapshot -> WorkdirFs -> IO [AgentDef]
listWorkdirAgentDefsSnap snap fs = do
  let repos = snapTopDirs snap
  perRepo <- forM repos $ \repo -> do
    defs <- concat <$> forM workdirAgentDefConventions (\conv -> do
      let convRp = repo <> "/" <> T.pack conv
      if not (snapIsDirectoryAt snap convRp)
        then pure []
        else
          -- Dispatch: .agents/ is protocol-aware; the rest use legacy.
          if conv == ".agents"
            then listAgentsDotAgentsSnap snap fs convRp
            else listAgentDefsFsSnap snap fs convRp)
    pure (mapMaybe (prefixWorkdirDef repo) defs)
  let merge m [] = m
      merge m (d:ds) = merge (Map.insertWith (\_new old -> old) (adId d) d m) ds
      merged = merge Map.empty (concat perRepo)
  pure (Map.elems merged)

-- | Basename of a snapshot-relative path (@a\/b\/c@ → @c@). Inputs are
-- snapshot-derived paths, never user input.
snapBasename :: Text -> Text
snapBasename = snd . T.breakOnEnd "/"

-- | A read-only backend serving a PRE-COMPUTED def list (the discovery
-- cache's point-in-time scan of the workdir). Mirrors
-- 'workdirAgentDefBackend''s semantics: reads from memory, writes/deletes
-- are no-ops (repo-local defs are immutable from the model's perspective).
staticAgentDefBackend :: [AgentDef] -> IO AgentDefBackend
staticAgentDefBackend defs = pure AgentDefBackend
  { adbRead   = \aid -> pure (Map.lookup aid (Map.fromList [(adId d, d) | d <- defs]))
  , adbUpdate = \_ -> pure ()
  , adbList   = pure defs
  , adbDelete = \_ -> pure ()
  }

-- | Snapshot-driven dispatch for the @.agents\/@ convention dir: protocol-
-- root detection (§3.3) answered from the snapshot, contents read through
-- the anchored 'WorkdirFs'. Mirrors 'listAgentsDotAgents'.
listAgentsDotAgentsSnap :: WorkspaceSnapshot -> WorkdirFs -> Text -> IO [AgentDef]
listAgentsDotAgentsSnap snap fs anchor
  | snapIsFileAt snap (anchor <> "/agents.md")
      || snapIsDirectoryAt snap (anchor <> "/agents")
  = listProtocolAgentDefsSnap snap fs anchor
  | otherwise = listAgentDefsFsSnap snap fs anchor

-- | Snapshot-driven protocol allow-list scan (§3.3): @agents.md@ (project
-- def) + @agents\/\<id\>\/agent.md@ (sub-agents), mirroring
-- 'listProtocolAgentDefs' with structure from the snapshot.
listProtocolAgentDefsSnap :: WorkspaceSnapshot -> WorkdirFs -> Text -> IO [AgentDef]
listProtocolAgentDefsSnap snap fs anchor = do
  let anchored = reanchorFs fs anchor
      agentsPath = anchor <> "/agents"
  mProject <- loadProjectAgentDef anchored
  subDefs <-
    if not (snapIsDirectoryAt snap agentsPath)
      then pure []
      else do
        let candidates =
              filter isValidAgentDefId (map snapBasename (snapChildDirsAt snap agentsPath))
        catMaybes <$> mapM (loadProtocolSubAgent anchored) candidates
  pure (sortOn (agentDefIdText . adId) (catMaybes [mProject] <> subDefs))

-- | Snapshot-driven legacy enumerator (flat + DirScheme), mirroring
-- 'listAgentDefsFs' with structure from the snapshot. Flat @\<id\>.md@
-- files win on collision with same-id dirs.
listAgentDefsFsSnap :: WorkspaceSnapshot -> WorkdirFs -> Text -> IO [AgentDef]
listAgentDefsFsSnap snap fs anchor = do
  let mdFiles = [p | p <- snapChildFilesAt snap anchor, ".md" `T.isSuffixOf` p]
  flatDefs <- forM mdFiles $ \rel -> do
    eContent <- wfsReadFile fs =<< rpOrDie rel
    pure $ case eContent of
      Left _    -> Nothing
      Right txt -> decodeAgentDef txt
  let flatIds = Set.fromList (map (agentDefIdText . adId) (catMaybes flatDefs))
      dirNames =
        [ n | n <- map snapBasename (snapChildDirsAt snap anchor)
            , isValidAgentDefId n, not (Set.member n flatIds) ]
  dirDefs <- forM dirNames $ \n ->
    case mkAgentDefId n of
      Left _   -> pure Nothing
      Right aid -> loadDirAgentDef (reanchorFs fs anchor) aid
  pure (sortOn (agentDefIdText . adId) (catMaybes flatDefs <> catMaybes dirDefs))

-- | Prefix a workdir-discovered def's id with @\<repo\>--\<id\>@ and its
-- @adName@ with @\<repo\>\/\<name\>@. The id prefix uses @"--"@ (charset-safe
-- per 'isValidAgentDefId'); the display name uses @"/"@ for readability. If
-- the prefixed id fails validation (e.g. the repo dir has a char outside the
-- charset), the def is dropped ('Nothing' — fail-closed).
prefixWorkdirDef :: Text -> AgentDef -> Maybe AgentDef
prefixWorkdirDef repo d =
  let prefixedIdText = repo <> "--" <> agentDefIdText (adId d)
  in case mkAgentDefId prefixedIdText of
       Left _ -> Nothing
       Right aid -> Just d
         { adId = aid
         , adName = repo <> "/" <> adName d
         }

-- ---------------------------------------------------------------------------
-- Workdir-local legacy enumerator (flat + dir, over WorkdirFs)
-- ---------------------------------------------------------------------------

-- | The workdir-local legacy enumerator (mirrors the user store's
-- 'listAgentDefs' but over 'WorkdirFs'). Enumerates flat @\<id\>.md@ files
-- + DirScheme @\<id\>\/@ subdirectories under the anchor, sorted by id.
-- Malformed entries are skipped. On flat/dir collision for the same id,
-- the flat file wins and the dir is dropped. The 'WorkdirFs' is anchored
-- at the agents directory.
listAgentDefsFs :: WorkdirFs -> IO [AgentDef]
listAgentDefsFs fs = do
  eEntries <- wfsListDirectory fs =<< rpOrDie "."
  let entries = fromRight [] eEntries
  flatDefs <- collectFlatFs fs entries
  dirDefs  <- collectDirsFs fs entries (map adId flatDefs)
  pure (sortOn (agentDefIdText . adId) (flatDefs <> dirDefs))

-- | Decode all flat @.md@ files under the anchor (workdir-local legacy).
collectFlatFs :: WorkdirFs -> [Text] -> IO [AgentDef]
collectFlatFs fs entries = do
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` e]
  defs <- forM mdFiles $ \e -> do
    eContent <- wfsReadFile fs =<< rpOrDie e
    pure $ case eContent of
      Left _    -> Nothing
      Right txt -> decodeAgentDef txt
  pure (catMaybes defs)

-- | Load DirScheme defs from subdirectories under the anchor (workdir-local
-- legacy), skipping ids already provided by the flat scheme (flat wins on
-- conflict).
collectDirsFs :: WorkdirFs -> [Text] -> [AgentDefId] -> IO [AgentDef]
collectDirsFs fs entries flatIds = do
  let flatIdTexts = Set.fromList (map agentDefIdText flatIds)
      candidate e = do
        isDir <- wfsDoesDirectoryExist fs =<< rpOrDie e
        let validDir = isDir && isValidAgentDefId e
        pure (if validDir then Just e else Nothing)
  mEntries <- mapM candidate entries
  let dirNames = catMaybes mEntries
  defs <- forM dirNames $ \e -> do
    case mkAgentDefId e of
      Left _   -> pure Nothing
      Right aid ->
        if agentDefIdText aid `Set.member` flatIdTexts
          then pure Nothing  -- skip the dir def; flat wins
          else loadDirAgentDef fs aid
  pure (catMaybes defs)

-- ---------------------------------------------------------------------------
-- WorkdirFs re-anchoring + RemotePath helpers (internal)
-- ---------------------------------------------------------------------------

-- | Produce a 'WorkdirFs' "view" anchored at a sub-directory of the original
-- anchor. Every 'wfs*' call on the re-anchored handle prepends @prefix@ to
-- the supplied 'RemotePath'. Works for both the local and remote arms (no
-- new constructor — pure record wrapper). The prefix is a relative path
-- (e.g. @"my-repo\/.agents"@); the join uses @\/@ as the separator.
reanchorFs :: WorkdirFs -> Text -> WorkdirFs
reanchorFs fs prefix = WorkdirFs
  { wfsReadFile            = wfsReadFile fs           <=< joinRp prefix
  , wfsDoesFileExist       = wfsDoesFileExist fs      <=< joinRp prefix
  , wfsDoesDirectoryExist  = wfsDoesDirectoryExist fs <=< joinRp prefix
  , wfsListDirectory       = wfsListDirectory fs      <=< joinRp prefix
  , wfsFileSize            = wfsFileSize fs           <=< joinRp prefix
  , wfsModificationTime    = wfsModificationTime fs   <=< joinRp prefix
  , wfsSnapshot            = wfsSnapshot fs
    -- ^ Whole-workspace: re-anchoring changes where relative reads land,
    -- never the snapshot's root-relative frame.
  }

-- | Join a prefix and a (possibly @"\.@) relative 'RemotePath' into a single
-- 'RemotePath'. A @"\. "@ suffix collapses to the prefix (so re-anchoring at
-- @"\. "@ is the identity). Crashes on invalid input — the prefix/suffix
-- are internally generated from validated components, never user/LLM input.
joinRp :: Text -> RemotePath -> IO RemotePath
joinRp prefix rp' =
  let suffix = getRemotePath rp'
      joined
        | T.null prefix            = suffix
        | suffix == "."            = prefix
        | T.isPrefixOf "./" suffix = prefix <> "/" <> T.drop 2 suffix
        | otherwise                = prefix <> "/" <> suffix
  in case mkRemotePath joined of
       Right r  -> pure r
       Left err -> error ("joinRp: invalid remote path: " <> T.unpack err
                          <> ": " <> T.unpack joined)

-- | Construct a 'RemotePath', crashing on invalid input. Used only for
-- internally-generated, validated path components (never user/LLM input).
rpOrDie :: Text -> IO RemotePath
rpOrDie t = case mkRemotePath t of
  Right r  -> pure r
  Left err -> error ("rpOrDie: invalid remote path: " <> T.unpack err
                     <> ": " <> T.unpack t)