{-# LANGUAGE OverloadedStrings #-}
-- | The agent-definition store backend. Disk is canonical: agent defs live as
-- Markdown files under @config\/agents\/\<id\>.md@ (frontmatter + body, where
-- the body is the system prompt and name/provider/model/tools/timestamps/
-- session live in frontmatter). 'markdownAgentDefBackend' reads by enumerating
-- the directory and writes by atomic file replace + auto-commit.
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
  ) where

import Control.Monad (forM)
import Data.Aeson (Value (..), encode)
import Data.ByteString.Lazy qualified as BL
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
import System.Directory (doesFileExist, listDirectory, renameFile)
import System.FilePath ((</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Security.Policy (AllowList (..))
import Seal.Store.Markdown (decodeDoc, encodeDoc, fmLookup, fmLookupList)

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

-- | The Markdown backend. One file per def under @dir@ (the @config/agents@
-- directory); writes are atomic (tmp → chmod 0600 → rename) and
-- auto-committed to the config git repo. Reads enumerate the directory.
-- Malformed files are skipped.
markdownAgentDefBackend :: FilePath -> ConfigRepo -> IO AgentDefBackend
markdownAgentDefBackend dir repo = pure AgentDefBackend
  { adbRead   = readAgentDef dir
  , adbUpdate = writeAgentDef dir repo
  , adbList   = listAgentDefs dir
  }

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

-- | Read one def by id. Returns 'Nothing' if the file is absent or malformed.
readAgentDef :: FilePath -> AgentDefId -> IO (Maybe AgentDef)
readAgentDef dir aid = do
  let path = defFile dir aid
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      pure (decodeAgentDef content)

-- | Enumerate all defs in the directory, sorted by id. Malformed files are
-- skipped.
listAgentDefs :: FilePath -> IO [AgentDef]
listAgentDefs dir = do
  entries <- listDirectory dir
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
  defs <- forM mdFiles $ \e -> do
    content <- TIO.readFile (dir </> e)
    pure (decodeAgentDef content)
  pure (sortOn (agentDefIdText . adId) (catMaybes defs))

-- | Render an 'AllowList OpName' as @\"all\"@ or a JSON array string.
renderTools :: AllowList OpName -> Text
renderTools AllowAll       = "all"
renderTools (AllowOnly xs) =
  TE.decodeUtf8 (BL.toStrict (encode (V.fromList [ String t | OpName t <- Set.toList xs ])))

-- | Decode the @tools@ frontmatter field: @\"all\"@ -> 'AllowAll'; a JSON
-- array of opcode-name strings -> 'AllowOnly'; absent/other -> 'AllowAll'.
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