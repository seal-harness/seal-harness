{-# LANGUAGE OverloadedStrings #-}
-- | The content-addressed agent-metadata cache: a local, sanitized snapshot
-- of a remote repo's @.agents/@ tree, keyed by @(repo URL, content hash)@ so
-- every session working the same repo at the same content shares one entry.
--
-- Why: post-clone agent-def discovery reads @agents.md@ plus one
-- @agent.md@ per discovered agent over SSH — two round trips per file. On a
-- remote host with slow per-call setup this crawls; a single rsync of the
-- whole tree (or a cache hit) collapses it to one probe + one transfer.
--
-- Security posture (untrusted bytes land on the trusted harness machine):
--
--   * Consumers are pure Markdown parsers — nothing in a snapshot is ever
--     executed. This module enforces that structurally anyway:
--   * 'sanitizeSnapshot' strips exec bits (files 0600, dirs 0700) and
--     DELETES any non-regular entry — symlinks above all, so a malicious
--     repo cannot plant @agent.md -> ~/.ssh/id_ed25519@ and have a parser
--     read through it.
--   * The transfer uses a minimal fixed rsync argv (no @-a@/@-p@/@-o@/@-g@/
--     @-t@ — no owner/perms/times preservation), per-file size cap, and an
--     @-e@ rsh string built ONLY from our own pinned 'SshConfig' options.
--   * The probe hashes the tar stream (@tar -cf - .agents | sha256sum@):
--     headers make it sensitive to names/renames/deletes, and sha256 is
--     required because the input is adversarial — a weak checksum would let
--     a malicious repo serve different agent sets under one cache key.
--   * Any failure (rsync missing remotely, probe garbage, transfer error)
--     yields 'MetaFallback' and callers use the legacy per-file crawl.
module Seal.Session.AgentMetaCache
  ( AgentMetaOutcome (..)
  , agentMetaCacheKey
  , agentMetaMaxFileSize
  , agentMetaProbeCmd
  , ensureAgentMetaSnapshot
  , parseProbeHash
  , rsyncArgv
  , rsyncRshString
  , sanitizeSnapshot
  ) where

import Control.Exception (IOException, try)
import Data.Either (fromRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime, UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

import System.Directory
  ( createDirectoryIfMissing, doesFileExist, listDirectory
  , removeDirectoryRecursive, removeFile, renameDirectory
  )
import System.FilePath ((</>))
import System.Posix.Files
  ( getSymbolicLinkStatus, isDirectory, isRegularFile, isSymbolicLink
  , setFileMode
  )

import Seal.Security.Crypto (sha256Hash)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Remote (RemoteRunner (..), runRemoteShell)
import Seal.Tools.Exec.Types
  ( ExecError (..), SshConfig (..), getSshHost, getSshUser
  )

-- | The fixed remote probe command for a repo dir's @.agents/@ content
-- hash. Anchored with @cd@ (single-quoted — the path is SafePath-derived,
-- quoting is defense-in-depth), streams the whole tree through @tar@ so
-- names/sizes/types participate in the hash, and pipes into @sha256sum@
-- (GNU coreutils — present on Linux remotes; its absence fails the probe
-- and the caller falls back to the legacy crawl).
agentMetaProbeCmd :: FilePath -> Text
agentMetaProbeCmd repoDir =
  "cd " <> shellQuoteDir (T.pack repoDir)
  <> " && tar -cf - .agents 2>/dev/null | sha256sum"

-- | Single-quote a path for the remote shell (embedded quotes escaped via
-- the standard @'\\''@ idiom).
shellQuoteDir :: Text -> Text
shellQuoteDir t = "'" <> T.concatMap q t <> "'"
  where
    q :: Char -> Text
    q '\'' = "'\\''"
    q c    = T.singleton c

-- | Parse the probe output (@sha256sum@ prints @\<hex\>\\s\\s-@ for stdin).
-- Returns 'Nothing' unless the output leads with an exact 64-hex-digit
-- digest — anything else (tar errors leaking through, missing-sha256sum
-- diagnostics, empty output) fails the probe.
parseProbeHash :: Text -> Maybe Text
parseProbeHash out =
  case filter (not . T.null) (T.words out) of
    (hex : _)
      | T.length hex == 64
          && T.all (`elem` ("0123456789abcdefABCDEF" :: String)) hex
      -> Just (T.toLower hex)
    _ -> Nothing

-- | Derive the cache entry directory name:
-- @\<sha256(normalizedUrl)\>-\<sha256(content)\>@ — hex and dashes only, so
-- it is filesystem-safe by construction.
agentMetaCacheKey :: Text -> Text -> Text
agentMetaCacheKey normalizedUrl contentHash =
  hexOf normalizedUrl <> "-" <> hexOf contentHash
  where
    hexOf :: Text -> Text
    hexOf = T.toLower . TE.decodeUtf8 . sha256Hash . TE.encodeUtf8

-- | Sanitize a freshly-transferred snapshot directory, in place:
--
--   * dirs  → 0700
--   * files → 0600 (exec bit stripped — the point of the exercise)
--   * symlinks, fifos, devices, sockets → DELETED (never followed). A link
--     pointing outside the snapshot would otherwise hand every parser a
--     readable escape hatch onto the trusted machine.
sanitizeSnapshot :: FilePath -> IO ()
sanitizeSnapshot = go
  where
    go dir = do
      setFileMode dir 0o700
      names <- listDirectory dir
      mapM_ (handleEntry dir) names
    handleEntry parent name = do
      let path = parent </> name
      -- lstat semantics: judge the entry itself, never what a link points at.
      st <- getSymbolicLinkStatus path
      if isSymbolicLink st
        then ignoreIO (removeFile path)
        else if isDirectory st
          then go path
          else if isRegularFile st
            then setFileMode path 0o600
            else ignoreIO (removeFile path)  -- fifo / device / socket: prune
    ignoreIO :: IO () -> IO ()
    ignoreIO action = do
      _ <- try @IOException action
      pure ()

-- ---------------------------------------------------------------------------
-- Transfer (rsync)
-- ---------------------------------------------------------------------------

-- | Per-file transfer cap (1 MiB). Discovery parsers bound reads far below
-- this; the cap just stops a hostile repo from shipping a multi-gigabyte
-- file inside @.agents/@.
agentMetaMaxFileSize :: Int
agentMetaMaxFileSize = 1024 * 1024

-- | The local shell string rsync hands @-e@. Built EXCLUSIVELY from our own
-- pinned 'SshConfig' options — host/user/port travel in the destination
-- argument, never here — and every value is single-quoted because rsync
-- runs the rsh program via the local shell.
rsyncRshString :: SshConfig -> String
rsyncRshString cfg =
  unwords
    ( [ "ssh"
      , "-o", shq "StrictHostKeyChecking=yes"
      , "-o", shq "BatchMode=yes"
      , "-o", shq ("UserKnownHostsFile=" <> scKnownHosts cfg)
      ]
        <> portArgs
        <> identityArgs
    )
  where
    shq :: String -> String
    shq s = "'" <> concatMap esc s <> "'"
    esc :: Char -> String
    esc '\'' = "'\\''"
    esc c    = [c]
    portArgs = case scPort cfg of
      22 -> []
      p  -> ["-p", show p]
    identityArgs = case scIdentity cfg of
      Nothing -> []
      Just f  -> ["-i", shq f]

-- | The fixed rsync argv pulling one remote directory into one local dir:
--
-- @rsync -r --max-size=\<cap\> -e \<pinned rsh\> user\\@host:\<src\> \<dest\>/@
--
-- Deliberately NOT @-a@: no owner/group/perms/times preservation — every
-- entry arrives with fresh default perms, then 'sanitizeSnapshot' sets the
-- final tight modes.
rsyncArgv :: SshConfig -> FilePath -> FilePath -> [String]
rsyncArgv cfg srcAbs destDir =
  [ "rsync"
  , "-r"
  , "--max-size=" <> show agentMetaMaxFileSize
  , "-e", rsyncRshString cfg
  , T.unpack (getSshUser (scUser cfg)) <> "@" <> T.unpack (getSshHost (scHost cfg))
      <> ":" <> srcAbs
  , destDir ++ "/"
  ]

-- ---------------------------------------------------------------------------
-- Integration: probe → key → hit? → rsync → sanitize → atomic publish
-- ---------------------------------------------------------------------------

data AgentMetaOutcome
  = MetaSnapshot FilePath   -- ^ Local sanitized snapshot root for this repo's .agents
  | MetaFallback            -- ^ Anything failed — caller uses the legacy crawl
  deriving stock (Eq, Show)

-- | Ensure a content-addressed snapshot exists for @(normalizedUrl, current
-- remote .agents content)@ and return its path, or 'MetaFallback'.
--
-- @runTransfer@ receives the rsync argv and performs it (production: real
-- rsync via 'withManagedProcess'; tests: a fake that records the argv and
-- materializes files) so the flow stays hermetically testable.
ensureAgentMetaSnapshot
  :: RemoteRunner                    -- ^ probe transport (pinned ssh)
  -> SshConfig
  -> FilePath                        -- ^ cache root (<state>/repos/agent-meta-cache)
  -> Text                            -- ^ normalized repo URL (cache key part 1)
  -> FilePath                        -- ^ remote repo dir (absolute, SafePath-derived)
  -> ([String] -> FilePath -> IO (Either ExecError ()))
     -- ^ runTransfer argv destTmpDir
  -> IO AgentMetaOutcome
ensureAgentMetaSnapshot runner cfg cacheRoot normalizedUrl repoDir runTransfer = do
  r <- try @IOException $ do
    mHash <- runProbe
    case mHash of
      Nothing -> pure MetaFallback
      Just contentHash -> do
        let entry = cacheRoot </> T.unpack (agentMetaCacheKey normalizedUrl contentHash)
        hit <- doesFileExist (entry </> metaFileName)
        if hit
          then pure (MetaSnapshot entry)   -- content-addressed cache hit: no transfer
          else transferAndPublish entry contentHash
  pure (fromRight MetaFallback r)
  where
    runProbe = case mkShellCommand (agentMetaProbeCmd repoDir) of
      Left _    -> pure Nothing   -- unreachable: internally-built, no NULs
      Right cmd -> do
        eRes <- runRemoteShell runner cfg cmd
        pure $ either (const Nothing) parseProbeHash eRes

    transferAndPublish entry contentHash = do
      createDirectoryIfMissing True cacheRoot
      let tmp = entry ++ ".tmp"
      -- A stale .tmp from a crashed prior attempt must not survive.
      _ <- try @IOException (removeDirectoryRecursive tmp)
      createDirectoryIfMissing True tmp
      xfer <- runTransfer (rsyncArgv cfg repoDir tmp) tmp
      case xfer of
        Left _ -> do
          _ <- try @IOException (removeDirectoryRecursive tmp)
          pure MetaFallback
        Right () -> do
          sanitizeSnapshot tmp
          writeMeta tmp contentHash
          published <- publish entry tmp
          pure (MetaSnapshot published)

    writeMeta dir contentHash = do
      now <- getCurrentTime
      let metaPath = dir </> metaFileName
      writeFile metaPath (metaJson repoDir contentHash now)
      setFileMode metaPath 0o600

    -- Publish atomically: rename tmp→entry. On a concurrent-writer race,
    -- keep the winner and drop ours — both are sanitized equivalents of
    -- the same (url, content-hash).
    publish entry tmp = do
      exists <- doesFileExist (entry </> metaFileName)
      if exists
        then do removeDirectoryRecursive tmp; pure entry
        else do renameDirectory tmp entry; pure entry

metaFileName :: FilePath
metaFileName = "seal-meta.json"

-- | The entry's provenance record. Hand-rolled JSON over values we fully
-- control (a validated path, a hex digest, an RFC-3339 timestamp).
metaJson :: FilePath -> Text -> UTCTime -> String
metaJson repoDir contentHash now =
  "{\"repo_dir\":" <> show repoDir
  <> ",\"content_hash\":" <> show (T.unpack contentHash)
  <> ",\"synced_at\":" <> show (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
  <> "}"
