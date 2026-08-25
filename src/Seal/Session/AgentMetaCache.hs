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
  , MetaCacheEnv (..)
  , agentMetaCacheDir
  , agentMetaCacheKeepN
  , agentMetaCacheKey
  , agentMetaMaxFileSize
  , agentMetaTransferArgv
  , agentMetaProbeCmd
  , buildRoutingWorkdirFs
  , ensureAgentMetaSnapshot
  , gcAgentMetaCache
  , parseGitConfigUrl
  , parseProbeHash
  , probeRepoUrlCmd
  , rsyncArgv
  , rsyncRshString
  , rsyncTransferIO
  , sanitizeSnapshot
  ) where

import Control.Exception (IOException, try)
import Data.Either (fromRight)
import Data.Maybe (isNothing)
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime, UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

import System.Directory
  ( createDirectoryIfMissing, doesFileExist, getModificationTime
  , listDirectory, removeDirectoryRecursive, removeFile, renameDirectory
  )
import System.FilePath ((</>))
import System.Posix.Files
  ( getSymbolicLinkStatus, isDirectory, isRegularFile, isSymbolicLink
  , setFileMode
  )
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess )

import Katip qualified as K

import Seal.Config.Paths (SealPaths (..))
import Control.Monad (forM, when)

import Seal.Logging.Global (globalLogIO)
import Seal.Security.Crypto (sha256Hash)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Local (readBounded, withManagedProcess)
import Seal.Tools.Exec.Remote (RemoteRunner (..), runRemoteShell)
import Seal.Tools.Exec.Types
  ( ExecError (..), RemotePath, SshConfig (..), getRemotePath, getSshHost
  , getSshUser, mkRemotePath
  )
import Seal.Tools.Exec.WorkdirFs
  ( WorkdirFs (..), WorkdirFsErr (..), mkLocalWorkdirFs
  )

-- | Debug-level logging for the agent-metadata cache. Routed through the
-- global logger so --log-level debug surfaces every gate: routing
-- decisions, probe results, cache hits/misses, and fallback reasons.
amcLog :: Text -> IO ()
amcLog msg = globalLogIO K.DebugS (K.ls ("[agent-meta] " <> msg))

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

-- | The fixed rsync argv pulling a remote directory tree into one local
-- dir. Element 0 is the PROGRAM NAME — 'rsyncTransferIO' splits it off
-- before spawning (spawning @proc "rsync" argv@ verbatim would hand rsync
-- a duplicated program name as a bogus source arg).
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

-- | The remote source for one repo's agent metadata: the CONTENTS of
-- @.agents/@ (trailing slash), so the snapshot root mirrors what discovery
-- reanchors at.
agentsSrcPath :: FilePath -> FilePath
agentsSrcPath repoDir = repoDir </> ".agents/"

-- | Transfer argv for one repo's @.agents/@ tree into a temp dir.
agentMetaTransferArgv :: SshConfig -> FilePath -> FilePath -> [String]
agentMetaTransferArgv cfg repoDir = rsyncArgv cfg (agentsSrcPath repoDir)

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
          then do
            amcLog ("snapshot: cache HIT " <> T.pack entry)
            pure (MetaSnapshot entry)   -- content-addressed cache hit: no transfer
          else do
            amcLog ("snapshot: cache MISS, transferring " <> T.pack entry)
            transferAndPublish entry contentHash
  pure (fromRight MetaFallback r)
  where
    runProbe = case mkShellCommand (agentMetaProbeCmd repoDir) of
      Left _    -> pure Nothing   -- unreachable: internally-built, no NULs
      Right cmd -> do
        eRes <- runRemoteShell runner cfg cmd
        let mh = either (const Nothing) parseProbeHash eRes
        when (isNothing mh) $
          amcLog ("snapshot: content-hash probe failed for " <> T.pack repoDir
                  <> " raw=" <> either (T.pack . show) id eRes)
        pure mh

    transferAndPublish entry contentHash = do
      createDirectoryIfMissing True cacheRoot
      let tmp = entry ++ ".tmp"
      -- A stale .tmp from a crashed prior attempt must not survive.
      _ <- try @IOException (removeDirectoryRecursive tmp)
      createDirectoryIfMissing True tmp
      xfer <- runTransfer (agentMetaTransferArgv cfg repoDir tmp) tmp
      case xfer of
        Left _ -> do
          amcLog ("snapshot: rsync failed for " <> T.pack repoDir
                  <> " — see [agent-meta rsync] line above if present")
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

-- | Canonical cache-root location: @<state>/repos/agent-meta-cache@.
agentMetaCacheDir :: SealPaths -> FilePath
agentMetaCacheDir paths = spState paths </> "repos" </> "agent-meta-cache"

-- | How many entries the startup GC keeps ('gcAgentMetaCache').
agentMetaCacheKeepN :: Int
agentMetaCacheKeepN = 20

-- ---------------------------------------------------------------------------
-- Discovery wiring: per-repo URL probe + snapshot-routed WorkdirFs
-- ---------------------------------------------------------------------------

-- | Everything the discovery flow needs to route @.agents/@ reads through
-- content-addressed local snapshots. Built once per scan when the untrusted
-- executor is remote; 'Nothing' (local mode, tests) keeps the legacy path.
data MetaCacheEnv = MetaCacheEnv
  { mceRunner       :: RemoteRunner   -- ^ probe transport (pinned ssh)
  , mceSshCfg       :: SshConfig      -- ^ destination for rsync + probe anchor
  , mceCacheRoot    :: FilePath       -- ^ <state>/repos/agent-meta-cache
  , mceRunTransfer  :: [String] -> FilePath -> IO (Either ExecError ())
    -- ^ Performs one rsync (production: 'rsyncTransferIO'; tests: a fake
    -- that records the argv and materializes files).
  }

-- | The fixed remote command reading a repo clone's origin URL — the first
-- half of the cache key. One round trip; failure (not a git repo, detached
-- tree) simply excludes that repo from snapshot routing.
probeRepoUrlCmd :: FilePath -> Text
probeRepoUrlCmd repoDir =
  "cd " <> shellQuoteDir (T.pack repoDir)
  <> " && git config --get remote.origin.url"

-- | Parse @git config@ output: a single non-empty line, trimmed. Rejects
-- multi-line/garbage output (fail-closed to legacy routing).
parseGitConfigUrl :: Text -> Maybe Text
parseGitConfigUrl out =
  case lines (T.unpack out) of
    [l] -> let t = T.strip (T.pack l)
           in if T.null t then Nothing else Just t
    _   -> Nothing

-- | Read ceiling served to parsers from snapshots. Matches the remote arm's
-- bounded-read cap so consumers see identical truncation behavior.
metaReadCeilingBytes :: Int
metaReadCeilingBytes = 131072

-- | Build a WorkdirFs that routes reads falling under any successfully
-- snapshotted @<repo>/.agents@ subtree to the LOCAL sanitized snapshot,
-- passing everything else through to the underlying (remote) fs.
--
-- Structure truth stays remote: 'wfsSnapshot' is always a passthrough, so
-- SETUP_REPO invalidation and repo enumeration behave exactly as before —
-- only file content reads change lanes. Local serving goes through
-- 'mkLocalWorkdirFs', whose SafePath confinement keeps every read inside
-- its snapshot root (and snapshots contain no symlinks to escape with).
buildRoutingWorkdirFs
  :: MetaCacheEnv          -- ^ probe/transfer deps
  -> WorkdirFs             -- ^ underlying (remote) fs
  -> Text                  -- ^ the SESSION WORKDIR absolute path (the scan's
                           -- own anchor — NOT the ssh workspace; sessions nest
                           -- at <workspace>/workdirs/<sid>/)
  -> [Text]                -- ^ candidate repo top-dir names from wfsSnapshot
  -> IO WorkdirFs
buildRoutingWorkdirFs env underlying wsRootAbs topDirs = do
  amcLog ("routing: session-workdir=" <> wsRootAbs
          <> " candidates=" <> T.pack (show topDirs))
  routes <- concat <$> mapM routeOne topDirs
  if null routes
    then amcLog "routing: no routes established (all repos fell back)"
    else amcLog ("routing: " <> T.pack (show (map fst routes)))
  pure (applyRoutes routes underlying)
  where
    routeOne topDir = do
      let repoDirAbs = T.unpack wsRootAbs </> T.unpack topDir
      mUrl <- probeUrl repoDirAbs
      case mUrl of
        Nothing -> do
          amcLog ("routing: url probe failed for " <> topDir
                  <> " — falling back to legacy reads")
          pure []
        Just url -> do
          amcLog ("routing: url=" <> url <> " repo=" <> T.pack repoDirAbs)
          outcome <- ensureAgentMetaSnapshot (mceRunner env) (mceSshCfg env)
                       (mceCacheRoot env) url repoDirAbs (mceRunTransfer env)
          case outcome of
            MetaSnapshot dir -> do
              amcLog ("routing: snapshot OK for " <> T.pack repoDirAbs)
              pure [(topDir <> "/.agents", dir)]
            MetaFallback -> do
              amcLog ("routing: snapshot failed for " <> T.pack repoDirAbs
                      <> " — falling back to legacy reads")
              pure []
    probeUrl rd = case mkShellCommand (probeRepoUrlCmd rd) of
      Left _    -> pure Nothing   -- unreachable: internally built, no NULs
      Right cmd -> do
        eRes <- runRemoteShell (mceRunner env) (mceSshCfg env) cmd
        pure $ either (const Nothing) parseGitConfigUrl eRes

-- | Apply prefix→localRoot routing over a WorkdirFs record. Matching reads
-- are served by a SafePath-confined local arm rooted at the snapshot;
-- everything else — including 'wfsSnapshot', the structure source of truth —
-- passes through untouched. An empty route table returns the fs unchanged.
applyRoutes :: [(Text, FilePath)] -> WorkdirFs -> WorkdirFs
applyRoutes [] fs = fs
applyRoutes routes fs = fs
  { wfsReadFile           = \rp ->
      route rp (wfsReadFile fs) serveRead
  , wfsDoesFileExist      = \rp ->
      route rp (wfsDoesFileExist fs) (existsIn wfsDoesFileExist)
  , wfsDoesDirectoryExist = \rp ->
      route rp (wfsDoesDirectoryExist fs) (existsIn wfsDoesDirectoryExist)
  , wfsListDirectory      = \rp ->
      route rp (wfsListDirectory fs) serveList
  }
  where
    route
      :: RemotePath
      -> (RemotePath -> IO a)
      -> (FilePath -> Text -> IO a)
      -> IO a
    route rp onRemote onLocal =
      case matchRoute (getRemotePath rp) of
        Nothing          -> onRemote rp
        Just (root, rel) -> onLocal root rel
    matchRoute t = foldr
      (\(prefix, root) acc ->
        if t == prefix
          then Just (root, ".")
          else if (prefix <> "/") `T.isPrefixOf` t
            then Just (root, T.drop (T.length prefix + 1) t)
            else acc)
      Nothing routes
    localFs root = mkLocalWorkdirFs (WorkspaceRoot root) metaReadCeilingBytes
    -- The rel paths are internally generated (prefix-stripped snapshot
    -- paths), so a parse failure here is unreachable; it maps to WfsNotFound
    -- rather than inventing a PathError.
    toRp :: Text -> Either WorkdirFsErr RemotePath
    toRp rel = either (const (Left WfsNotFound)) Right (mkRemotePath rel)

    serveRead root rel =
      case toRp rel of
        Left e    -> pure (Left e)
        Right rp  -> wfsReadFile (localFs root) rp
    existsIn
      :: (WorkdirFs -> RemotePath -> IO Bool)
      -> FilePath -> Text -> IO Bool
    existsIn sel root rel =
      case toRp rel of
        Left _   -> pure False
        Right rp -> sel (localFs root) rp
    serveList root rel =
      case toRp rel of
        Left e    -> pure (Left e)
        Right rp  -> wfsListDirectory (localFs root) rp

-- ---------------------------------------------------------------------------
-- GC + production transfer
-- ---------------------------------------------------------------------------

-- | Startup sweep: keep only the newest @keepN@ cache entries (by entry
-- dir mtime). Best-effort — every error is swallowed; a full disk of stale
-- entries is untidy, not unsafe.
gcAgentMetaCache :: FilePath -> Int -> IO ()
gcAgentMetaCache root keepN = do
  _ <- try @IOException $ do
    names <- listDirectory root
    dated <- forM names $ \n -> do
      let p = root </> n
      mTime <- try @IOException (getModificationTime p)
      pure (either (const []) (\t -> [(t, p)]) mTime)
    let sorted = sortOn (Down . fst) (concat dated)
        stale  = drop keepN sorted
    mapM_ (removeDirectoryRecursive . snd) stale
  pure ()

-- | Production transfer runner: fixed-argv rsync via the managed-process
-- seam (process-group spawn, bounded output, group kill on cancel).
-- Non-zero exit → 'ExecError' (the caller falls back to the legacy crawl);
-- stderr is logged at debug for diagnosability.
rsyncTransferIO :: SshConfig -> [String] -> FilePath -> IO (Either ExecError ())
rsyncTransferIO cfg argv _destTmp = case argv of
  -- argv carries the program name at its head; spawn splits it off. An
  -- empty argv is unreachable (callers pass 'agentMetaTransferArgv' output).
  []                -> pure (Left ExecRemoteUnreachable)
  (prog : progArgs) ->
    let cp = (proc prog progArgs)
               { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
               , create_group = True
               }
    in runManagedRsync cfg cp

runManagedRsync :: SshConfig -> CreateProcess -> IO (Either ExecError ())
runManagedRsync cfg cp = do
  res <- try @IOException $
    withManagedProcess cp $ \ph _mIn hOut hErr -> do
      out <- readBounded hOut agentMetaMaxFileSize
      err <- readBounded hErr agentMetaMaxFileSize
      ec  <- waitForProcess ph
      pure (ec, out, err)
  case res of
    Left _ioErr -> pure (Left ExecRemoteUnreachable)
    Right (ExitSuccess, _, _) -> pure (Right ())
    Right (ExitFailure _n, _, err) -> do
      globalLogIO K.DebugS (K.ls (T.pack
        ("[agent-meta rsync] failed: " <> T.unpack (T.strip (T.takeEnd 400 err))
         <> " host=" <> show (getSshHost (scHost cfg)))))
      pure (Left ExecRemoteUnreachable)
