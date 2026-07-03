{-# LANGUAGE OverloadedStrings #-}
-- | Session lifecycle over the @\<state\>\/sessions@ tree: id minting, creation,
-- atomic persistence (dir 0700, session.json 0600), and listing (newest first,
-- corrupt files skipped). No manifest file — the list is derived by enumerating
-- the directory. 'SessionRuntime' bundles the mutable active-session ref shared
-- between the /session and /model commands and the chat handler.
module Seal.Session.Store
  ( formatSessionId
  , newSession
  , saveSessionMeta
  , listSessions
  , defaultSessionSelection
  , initSession
  , SessionRuntime (..)
  ) where

import Control.Monad (filterM, forM)
import Data.Aeson (decode, encode)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef)
import Data.List (sortOn)
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

import Seal.Config.File (FileConfig (..))
import Seal.Config.Paths
  ( SealPaths, sessionDir, sessionMetaPath, sessionsRoot )
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Providers.Registry (KnownProvider (..), defaultModelFor, parseProvider)
import Seal.Session.Meta (SessionMeta (..))

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

-- | Create a fresh session directory + session.json for the given selection.
newSession :: SealPaths -> Text -> Text -> Text -> IO SessionMeta
newSession paths provider model channel = do
  now <- getCurrentTime
  sid <- case mkSessionId (formatSessionId now) of
    Right s -> pure s
    Left e  -> ioError (userError ("session id generation failed: " <> T.unpack e))
  let meta = SessionMeta
        { smId = sid, smProvider = provider, smModel = model
        , smChannel = channel, smCreatedAt = now, smLastActive = now }
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
defaultSessionSelection :: FileConfig -> (Text, Text)
defaultSessionSelection cfg =
  ( provLabel
  , fromMaybe fallbackModel (fcDefaultModel cfg) )
  where
    provLabel = fromMaybe "anthropic" (fcDefaultProvider cfg)
    ModelId fallbackModel =
      maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider provLabel)

-- | Create a new session from the config defaults, on the @cli@ channel.
initSession :: SealPaths -> FileConfig -> IO SessionMeta
initSession paths cfg =
  let (p, m) = defaultSessionSelection cfg
  in newSession paths p m "cli"
