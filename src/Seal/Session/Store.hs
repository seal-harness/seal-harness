{-# LANGUAGE OverloadedStrings #-}
-- | Session lifecycle over the @\<state\>\/sessions@ tree: id minting, creation,
-- atomic persistence (dir 0700, session.json 0600), and listing (newest first,
-- corrupt files skipped). No manifest file — the list is derived by enumerating
-- the directory. 'SessionRuntime' bundles the mutable active-session ref shared
-- between the /session and /model commands and the chat handler.
module Seal.Session.Store
  ( formatSessionId
  , newSession
  , newSessionMeta
  , saveSessionMeta
  , listSessions
  , defaultSessionSelection
  , resolveDefaultAgent
  , initSession
  , initSessionMeta
  , updateSessionAgent
  , updateSessionSystemOverride
  , SessionRuntime (..)
  ) where

import Control.Monad (filterM, forM)
import Data.Aeson (decode, encode)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef)
import Data.List (sortOn)
import Control.Applicative ((<|>))
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( UTCTime (..), defaultTimeLocale, diffTimeToPicoseconds, formatTime, getCurrentTime )
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile )
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

import Seal.Agent.Def.Backend (AgentDefBackend (..))
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), agentDefIdText, mkAgentDefId)
import Seal.Config.File (RuntimeConfig (..), providerDefaultModel)
import Seal.Config.Paths
  ( SealPaths, sessionDir, sessionMetaPath, sessionsRoot )
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Providers.Registry (resolveDefaultModel)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Store.Markdown (decodeDoc, fmLookup)

-- | The mutable active-session ref plus the paths the commands need.
data SessionRuntime = SessionRuntime
  { srPaths      :: SealPaths
  , srConfigPath :: FilePath
  , srActive     :: IORef SessionMeta
  }

-- | @YYYYMMDD-HHMMSS-mmm@. Timestamp-leading so a lexicographic sort of ids is
-- chronological; only digits and dashes, so it is a valid 'SessionId'.
formatSessionId :: UTCTime -> Text
formatSessionId t =
  let base   = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" t
      millis = (diffTimeToPicoseconds (utctDayTime t) `div` 1000000000) `mod` 1000
      s      = show millis
      mmm    = replicate (3 - length s) '0' <> s
  in T.pack (base <> "-" <> mmm)

-- | Mint a fresh 'SessionMeta' (id + timestamps) for the given selection,
-- without writing anything to disk. Used by channels that want an
-- in-memory active session without polluting the sessions list — the
-- session is only persisted when the user actually sends a message.
newSessionMeta :: SealPaths -> Text -> Text -> Text -> Maybe AgentDefId -> IO SessionMeta
newSessionMeta _paths provider model channel mAgent = do
  now <- getCurrentTime
  sid <- case mkSessionId (formatSessionId now) of
    Right s -> pure s
    Left e  -> ioError (userError ("session id generation failed: " <> T.unpack e))
  pure SessionMeta
    { smId = sid, smProvider = provider, smModel = model
    , smChannel = channel, smAgent = mAgent
    , smSystemOverride = Nothing, smAgentName = Nothing
    , smCreatedAt = now, smLastActive = now }

-- | Create a fresh session directory + session.json for the given selection.
newSession :: SealPaths -> Text -> Text -> Text -> Maybe AgentDefId -> IO SessionMeta
newSession paths provider model channel mAgent = do
  meta <- newSessionMeta paths provider model channel mAgent
  saveSessionMeta paths meta
  pure meta

-- | Persist @session.json@ atomically: dir 0700, write @.tmp@, chmod 0600, rename.
saveSessionMeta :: SealPaths -> SessionMeta -> IO ()
saveSessionMeta paths meta = do
  let dir  = sessionDir paths (smId meta)
      path = sessionMetaPath paths (smId meta)
      tmp  = path <> ".tmp"
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  BL.writeFile tmp (encode meta)
  setFileMode tmp 0o600
  renameFile tmp path

-- | All sessions, newest 'smLastActive' first. Corrupt/undecodable session.json
-- files are silently skipped (a partial write never breaks the list).
listSessions :: SealPaths -> IO [SessionMeta]
listSessions paths = do
  let root = sessionsRoot paths
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      entries <- listDirectory root
      dirs    <- filterM (doesDirectoryExist . (root </>)) entries
      metas   <- forM dirs $ \e -> do
        let mp = root </> e </> "session.json"
        ok <- doesFileExist mp
        if not ok then pure Nothing else decode <$> BL.readFile mp
      pure (sortOn (Down . smLastActive) (catMaybes metas))

-- | The provider label + model a new session should start with: the configured
-- defaults, falling back to the configured provider's own default model (or
-- Anthropic when no provider is configured).
defaultSessionSelection :: RuntimeConfig -> (Text, Text)
defaultSessionSelection cfg =
  ( provLabel
  , fromMaybe fallbackModel (rcDefaultModel cfg) )
  where
    provLabel = fromMaybe "anthropic" (rcDefaultProvider cfg)
    ModelId fallbackModel = resolveDefaultModel (providerDefaultModel cfg provLabel) provLabel

-- | Resolve the default agent for a new session. Returns 'Nothing' if
-- @default_agent@ is unset, the id fails validation, or the def is not on
-- disk (a warning is emitted in the latter case). Otherwise returns the
-- bound 'AgentDefId' and the def's provider/model overrides (non-empty
-- values that should replace the config defaults).
resolveDefaultAgent
  :: AgentDefBackend -> RuntimeConfig -> IO (Maybe AgentDefId, Maybe Text, Maybe Text)
resolveDefaultAgent backend cfg =
  case rcDefaultAgent cfg of
    Nothing -> pure (Nothing, Nothing, Nothing)
    Just raw ->
      case mkAgentDefId raw of
        Left _ -> do
          putStrLn ("warning: default_agent " <> T.unpack raw <> " is not a valid id; proceeding without one")
          pure (Nothing, Nothing, Nothing)
        Right aid -> do
          mDef <- adbRead backend aid
          case mDef of
            Nothing -> do
              putStrLn ("warning: default agent " <> T.unpack raw <> " not found; proceeding without one")
              pure (Nothing, Nothing, Nothing)
            Just d  -> pure (Just aid, override (adProvider d), overrideModel (adModel d))
  where
    override t = if T.null t then Nothing else Just t
    overrideModel (ModelId m) = if T.null m then Nothing else Just m

-- | Create a new session from the config defaults, on the @cli@ channel.
-- If @default_agent@ is set and the def exists, its id is persisted in
-- 'smAgent' and its non-empty provider/model override the config defaults
-- (PureClaw @resolveOverride@ precedence: frontmatter > config > default).
initSession :: SealPaths -> RuntimeConfig -> AgentDefBackend -> IO SessionMeta
initSession paths cfg backend = do
  (mAgent, mProv, mModel) <- resolveDefaultAgent backend cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
  newSession paths provider model "cli" mAgent

-- | Build an in-memory 'SessionMeta' from the config defaults, on the @web@
-- channel, WITHOUT persisting to disk. The web gateway uses this so the
-- active-session ref has a valid meta (provider/model fallbacks) without
-- polluting the sessions list. The session is persisted only when the user
-- actually sends the first message (which writes the transcript).
initSessionMeta :: SealPaths -> RuntimeConfig -> AgentDefBackend -> IO SessionMeta
initSessionMeta paths cfg backend = do
  (mAgent, mProv, mModel) <- resolveDefaultAgent backend cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
  newSessionMeta paths provider model "web" mAgent

-- | Update the bound agent for an existing session. Loads the current
-- 'SessionMeta' from disk, replaces 'smAgent' (Nothing when the supplied id
-- is empty/invalid), and persists atomically. Returns 'False' when the
-- session's @session.json@ can't be found or parsed (the caller surfaces a
-- 404/400); 'True' on a successful write.
--
-- /Mutual exclusion/: binding an agent clears any 'smSystemOverride'
-- (one-off uploaded file) — the two are alternative sources of the system
-- prompt, and the backend enforces they never coexist so the UI never
-- shows a stale \"agent X\" label while an uploaded file is actually
-- driving the prompt. The frontend only needs to fire this single PUT.
-- 'smAgentName' is set to the agent's id so the sidebar has a stable
-- display label.
updateSessionAgent :: SealPaths -> SessionId -> Maybe AgentDefId -> IO Bool
updateSessionAgent paths sid mAgent = do
  let mp = sessionMetaPath paths sid
  exists <- doesFileExist mp
  if not exists
    then pure False
    else do
      mMeta <- decode <$> BL.readFile mp :: IO (Maybe SessionMeta)
      case mMeta of
        Nothing  -> pure False
        Just meta -> do
          -- Clear the override + set the display name when binding an
          -- agent; clear both when clearing the agent.
          let next = case mAgent of
                Just aid -> meta { smAgent = mAgent
                                 , smSystemOverride = Nothing
                                 , smAgentName = Just (agentDefIdText aid) }
                Nothing  -> meta { smAgent = Nothing, smAgentName = Nothing }
          saveSessionMeta paths next
          pure True

-- | Update (or clear) the ad-hoc system prompt override for a session.
-- 'Nothing' clears the override (fall back to the bound agent's
-- 'adSystem'); 'Just t' sets it so 'plainTurn' uses @t@ verbatim as the
-- system prompt. Returns 'False' when the session's @session.json@ can't
-- be found or parsed; 'True' on a successful write.
--
-- The display label is resolved in this order:
-- 1. The @id@ field in the file's TOML frontmatter (when parseable).
-- 2. The caller-supplied @mFallbackName@ (e.g. the uploaded filename).
-- 3. 'Nothing' — no label.
--
-- /Mutual exclusion/: setting an override clears 'smAgent' so the session
-- doesn't display a stale agent label in the UI while an uploaded file is
-- actually driving the prompt. Clearing the override leaves 'smAgent'
-- untouched (the caller can re-bind an agent in a follow-up PUT if
-- desired). The frontend only needs to fire this single PUT.
updateSessionSystemOverride
  :: SealPaths
  -> SessionId
  -> Maybe Text          -- ^ the file content (Nothing = clear)
  -> Maybe Text          -- ^ fallback display label (e.g. filename) when no frontmatter id
  -> IO Bool
updateSessionSystemOverride paths sid mOverride mFallbackName = do
  let mp = sessionMetaPath paths sid
  exists <- doesFileExist mp
  if not exists
    then pure False
    else do
      mMeta <- decode <$> BL.readFile mp :: IO (Maybe SessionMeta)
      case mMeta of
        Nothing  -> pure False
        Just meta -> do
          let next = case mOverride of
                Just content ->
                  let label = parseAgentFileId content <|> mFallbackName
                  in meta { smSystemOverride = Just content
                          , smAgent = Nothing
                          , smAgentName = label }
                Nothing ->
                  -- Clearing: leave smAgentName untouched (the follow-up
                  -- updateSessionAgent from the Remove button will reset
                  -- it to the default agent's id).
                  meta { smSystemOverride = Nothing }
          saveSessionMeta paths next
          pure True

-- | Parse the @id@ field from an uploaded agent file's TOML frontmatter.
-- Returns 'Nothing' when the file has no frontmatter or no @id@ key.
parseAgentFileId :: Text -> Maybe Text
parseAgentFileId content =
  let (fm, _body) = decodeDoc content
  in case fmLookup "id" fm of
       Just t | not (T.null (T.strip t)) -> Just (T.strip t)
       _                                 -> Nothing
