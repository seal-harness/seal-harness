{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.ExecCacheSpec (spec) where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import System.FilePath ((</>))
import Test.Hspec

import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText)
import Seal.Config.Paths (SealPaths (..))
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..), defaultSecurityConfig
  )
import Seal.Core.Types (SessionId, mkSystemSessionId, sessionIdText)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.ExecCache
  ( cachedSessionExec, cachedWorkdirScan, invalidateExec
  , invalidateWorkdirScan, newSessionExecCacheWith
  )
import Seal.Session.Workdir (SessionExec (..))
import Seal.Tools.Exec.Remote (RemoteRunner (..))
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath)
import Seal.Tools.Exec.WorkdirFs
  ( WorkdirFs (..), mkInMemWorkdirFs, StubEntry (..)
  )
import Seal.TestHelpers.FixtureRepo (stubCloneDeps)

spec :: Spec
spec = describe "Seal.Session.ExecCache" $ do

  --------------------------------------------------------------------------
  -- cachedSessionExec (memoized mkSessionExec)
  --------------------------------------------------------------------------

  describe "cachedSessionExec" $ do

    it "builds once: a second call issues no additional SSH calls" $ do
      calls <- newIORef []
      cache <- newSessionExecCacheWith (pure fakeNow)
      deps <- stubCloneDeps
      let paths = tmpPaths "/tmp/seal-exec-cache-build-once"
      _ <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      n1 <- length <$> readIORef calls
      _ <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      n2 <- length <$> readIORef calls
      -- The first build runs the remote mkdir -p bootstrap; the cached hit
      -- must not run anything.
      (n1, n2) `shouldBe` (1 :: Int, 1 :: Int)

    it "rebuilds when the security config fingerprint changes" $ do
      calls <- newIORef []
      cache <- newSessionExecCacheWith (pure fakeNow)
      deps <- stubCloneDeps
      let paths = tmpPaths "/tmp/seal-exec-cache-fingerprint"
      _ <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      n1 <- length <$> readIORef calls
      _ <- cachedSessionExec cache paths otherRemoteSecCfg sidA deps (recordingRunner calls)
      n2 <- length <$> readIORef calls
      (n1, n2) `shouldBe` (1 :: Int, 2 :: Int)

    it "invalidateExec forces a rebuild on the next call" $ do
      calls <- newIORef []
      cache <- newSessionExecCacheWith (pure fakeNow)
      deps <- stubCloneDeps
      let paths = tmpPaths "/tmp/seal-exec-cache-invalidate"
      _ <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      invalidateExec cache sidA
      _ <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      n <- length <$> readIORef calls
      n `shouldBe` (2 :: Int)

    it "caches per session (different sids do not collide)" $ do
      calls <- newIORef []
      cache <- newSessionExecCacheWith (pure fakeNow)
      deps <- stubCloneDeps
      let paths = tmpPaths "/tmp/seal-exec-cache-persid"
      _ <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      _ <- cachedSessionExec cache paths remoteSecCfg sidB deps (recordingRunner calls)
      n <- length <$> readIORef calls
      n `shouldBe` (2 :: Int)

    it "does not poison the cache with a fail-closed exec" $ do
      calls <- newIORef []
      cache <- newSessionExecCacheWith (pure fakeNow)
      deps <- stubCloneDeps
      let paths = tmpPaths "/tmp/seal-exec-cache-failclosed"
          -- mode=remote with NO remote block → fail-closed at build time.
          brokenCfg = defaultSecurityConfig
            { scUntrustedExec = Just (UntrustedExecFileConfig "remote" Nothing) }
      e1 <- cachedSessionExec cache paths brokenCfg sidA deps (recordingRunner calls)
      execRoot e1 `shouldBe` "/nonexistent-workdir-fail-closed"
      -- The failed build was NOT cached; a later VALID config builds fresh.
      e2 <- cachedSessionExec cache paths remoteSecCfg sidA deps (recordingRunner calls)
      execRoot e2 `shouldBe` "/srv/agent-workspace/workdirs/" <> sessionIdText sidA

  --------------------------------------------------------------------------
  -- cachedWorkdirScan (fetch-or-scan agent defs + skills per session)
  --------------------------------------------------------------------------

  describe "cachedWorkdirScan" $ do

    it "scans once within the TTL: second call does not re-run wfsSnapshot" $ do
      snaps <- newIORef (0 :: Int)
      cache <- newSessionExecCacheWith (pure fakeNow)
      let fs = countingFs snaps protocolSeed
      r1@(defs1, skills1) <- cachedWorkdirScan cache sidA fs wsRoot
      r2 <- cachedWorkdirScan cache sidA fs wsRoot
      r1 `shouldBe` r2
      map defIdOf defs1 `shouldBe` ["my-repo--agents-md", "my-repo--foo-agent"]
      length skills1 `shouldBe` 0
      readIORef snaps `shouldReturn` 1

    it "re-scans after the TTL elapses (injected clock)" $ do
      nowRef <- newIORef fakeNow
      snaps <- newIORef (0 :: Int)
      cache <- newSessionExecCacheWith (readIORef nowRef)
      let fs = countingFs snaps protocolSeed
      _ <- cachedWorkdirScan cache sidA fs wsRoot
      modifyIORef' nowRef (addUTCTime 3600)
      _ <- cachedWorkdirScan cache sidA fs wsRoot
      readIORef snaps `shouldReturn` 2

    it "re-scans when the workspace root changes (config-switch guard)" $ do
      snaps <- newIORef (0 :: Int)
      cache <- newSessionExecCacheWith (pure fakeNow)
      let fs = countingFs snaps protocolSeed
      _ <- cachedWorkdirScan cache sidA fs wsRoot
      _ <- cachedWorkdirScan cache sidA fs (WorkspaceRoot "/other/workspace")
      readIORef snaps `shouldReturn` 2

    it "invalidates explicitly (the SETUP_REPO hook)" $ do
      snaps <- newIORef (0 :: Int)
      cache <- newSessionExecCacheWith (pure fakeNow)
      let fs = countingFs snaps protocolSeed
      _ <- cachedWorkdirScan cache sidA fs wsRoot
      invalidateWorkdirScan cache sidA
      _ <- cachedWorkdirScan cache sidA fs wsRoot
      readIORef snaps `shouldReturn` 2

    it "caches per session" $ do
      snaps <- newIORef (0 :: Int)
      cache <- newSessionExecCacheWith (pure fakeNow)
      let fs = countingFs snaps protocolSeed
      _ <- cachedWorkdirScan cache sidA fs wsRoot
      _ <- cachedWorkdirScan cache sidB fs wsRoot
      readIORef snaps `shouldReturn` 2

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

sidA, sidB :: SessionId
sidA = mkSystemSessionId "cache-a"
sidB = mkSystemSessionId "cache-b"

fakeNow :: UTCTime
fakeNow = UTCTime (fromGregorian 2026 8 22) (secondsToDiffTime (12 * 3600))

wsRoot :: WorkspaceRoot
wsRoot = WorkspaceRoot "/srv/agent-workspace"

remoteBlock :: UntrustedExecRemoteFileConfig
remoteBlock = UntrustedExecRemoteFileConfig
  { uerfcHost       = Just "exec.internal"
  , uerfcUser       = Just "agent"
  , uerfcPort       = Nothing
  , uerfcIdentity   = Nothing
  , uerfcKnownHosts = Just "/home/agent/.seal/exec-known-hosts"
  , uerfcWorkspace  = Just "/srv/agent-workspace"
  }

remoteSecCfg :: SecurityConfig
remoteSecCfg = defaultSecurityConfig
  { scUntrustedExec = Just (UntrustedExecFileConfig "remote" (Just remoteBlock)) }

otherRemoteSecCfg :: SecurityConfig
otherRemoteSecCfg = defaultSecurityConfig
  { scUntrustedExec = Just (UntrustedExecFileConfig "remote" (Just remoteBlock
      { uerfcWorkspace = Just "/srv/other-workspace" })) }

-- | A 'RemoteRunner' that records every invocation's argv and always
-- returns empty stdout (enough for the mkdir -p workdir bootstrap).
recordingRunner :: IORef [[String]] -> RemoteRunner
recordingRunner ref = RemoteRunner
  { runRemote      = \argv -> record argv >> pure (Right "")
  , runRemoteStdin = \argv _ -> record argv >> pure (Right "")
  , runRemoteEnv   = \_ argv -> record argv >> pure (Right "")
  }
  where
    record argv = modifyIORef' ref (++ [argv])

-- | Extract the workspace-root text from a built 'SessionExec'.
execRoot :: SessionExec -> Text
execRoot e = case seWorkspaceRoot e of
  WorkspaceRoot p -> T.pack p

tmpPaths :: FilePath -> SealPaths
tmpPaths tmp = SealPaths
  { spHome = tmp </> "home", spConfig = tmp </> "config"
  , spState = tmp </> "state", spKeys = tmp </> "keys", spCache = tmp </> "cache" }

-- | Wrap a stub 'WorkdirFs' so every actual 'wfsSnapshot' scan increments
-- the counter.
countingFs :: IORef Int -> Map.Map RemotePath StubEntry -> WorkdirFs
countingFs ref seed =
  let base = mkInMemWorkdirFs seed
  in base { wfsSnapshot = do
              r <- wfsSnapshot base
              modifyIORef' ref (+ 1)
              pure r }

protocolSeed :: Map.Map RemotePath StubEntry
protocolSeed = Map.fromList
  [ (rp ".", Directory ["my-repo"])
  , (rp "my-repo", Directory [".agents"])
  , (rp "my-repo/.agents", Directory ["agents.md", "agents"])
  , (rp "my-repo/.agents/agents.md"
    , FileContent "---\nkind: agents\n---\n# Project\nDo good work.\n")
  , (rp "my-repo/.agents/agents", Directory ["foo-agent"])
  , (rp "my-repo/.agents/agents/foo-agent", Directory ["agent.md"])
  , (rp "my-repo/.agents/agents/foo-agent/agent.md"
    , FileContent "---\nname: Foo Agent\nprovider: ollama\n---\nYou are foo.\n")
  ]

defIdOf :: AgentDef -> Text
defIdOf = agentDefIdText . adId

rp :: Text -> RemotePath
rp t = case mkRemotePath t of
  Right r  -> r
  Left err -> error ("ExecCacheSpec.rp: bad path: " <> T.unpack err <> ": " <> T.unpack t)
