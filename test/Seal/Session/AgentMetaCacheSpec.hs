{-# LANGUAGE OverloadedStrings #-}
-- | Spec for 'Seal.Session.AgentMetaCache' — the content-addressed cache of
-- remote @.agents/@ trees (repo URL + content hash → local snapshot dir).
--
-- Covers the pure core (probe command shape, probe-output parsing, cache-key
-- derivation) and the sanitize walk (exec-bit strip + non-regular-file
-- pruning) that makes rsynced untrusted bytes safe to keep on the trusted
-- harness machine.
module Seal.Session.AgentMetaCacheSpec (spec) where

import Data.Bits ((.&.))
import Data.IORef
import Data.List (isPrefixOf, sort, tails)
import Data.Text qualified as T
import Data.Time
  ( NominalDiffTime, UTCTime (..), addUTCTime, getCurrentTime )
import Data.Time.Calendar (fromGregorian)
import System.FilePath ((</>))
import System.Directory
  ( createDirectory, createDirectoryIfMissing, createFileLink, doesFileExist
  , getPermissions, executable, listDirectory, setModificationTime
  )
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Environment (lookupEnv)
import System.Posix.Files
  ( FileStatus, fileMode, getFileStatus, setFileMode )
import Test.Hspec

import Seal.Security.Crypto ()
import Seal.Tools.Exec.Remote (RemoteRunner (..), mkFakeRemoteRunner, mkRealRemoteRunner)
import Seal.Tools.Exec.Types
  ( ExecError (..), SshConfig (..), getRemotePath, mkRemotePath
  , mkSshHost, mkSshUser
  )
import Seal.Tools.Exec.WorkdirFs (WorkdirFs (..))
import Seal.Session.AgentMetaCache

spec :: Spec
spec = pureCoreSpec >> transferSpec >> wiringSpec >> liveSpec

pureCoreSpec :: Spec
pureCoreSpec = describe "Seal.Session.AgentMetaCache" $ do

  describe "agentMetaProbeCmd" $ do

    it "anchors at the repo dir and hashes the whole tarred .agents tree" $ do
      let cmd = agentMetaProbeCmd "/Users/zoe/sandbox/workdirs/s1/my-repo"
      ("cd '/Users/zoe/sandbox/workdirs/s1/my-repo' && " `T.isPrefixOf` cmd)
        `shouldBe` True
      ("tar -cf - .agents" `T.isInfixOf` cmd) `shouldBe` True
      ("sha256sum" `T.isInfixOf` cmd) `shouldBe` True

    it "single-quotes the repo path (defense-in-depth; paths are SafePath-derived)" $ do
      let cmd = agentMetaProbeCmd "/srv/ws/repo name"
      ("cd '/srv/ws/repo name'" `T.isInfixOf` cmd) `shouldBe` True

  describe "parseProbeHash" $ do

    it "parses a sha256 line ('<hex>  -')" $
      parseProbeHash (T.replicate 64 "a" <> "  -\n")
        `shouldBe` Just (T.replicate 64 "a")

    it "accepts surrounding whitespace" $
      parseProbeHash ("  " <> T.replicate 64 "b" <> "  -\n\n")
        `shouldBe` Just (T.replicate 64 "b")

    it "rejects non-hex, short, and garbage output" $ do
      parseProbeHash (T.replicate 63 "a" <> "g  -") `shouldBe` Nothing
      parseProbeHash "tar: this does not look like a hash" `shouldBe` Nothing
      parseProbeHash "" `shouldBe` Nothing

  describe "agentMetaCacheKey" $ do

    it "is <urlhash>-<contenthash>, hex+dash charset only" $ do
      let k = agentMetaCacheKey "git@github.com:seal-harness/seal-harness.git"
                                (T.replicate 64 "0")
      T.all (`elem` ("0123456789abcdef-" :: String)) k `shouldBe` True
      T.length k `shouldBe` 64 + 1 + 64
      ("-" `T.isInfixOf` k) `shouldBe` True

    it "is deterministic and separates distinct urls and contents" $ do
      let u1 = "git@github.com:a/b.git"
          u2 = "git@github.com:c/d.git"
          h1 = T.replicate 64 "1"
          h2 = T.replicate 64 "2"
      agentMetaCacheKey u1 h1 `shouldBe` agentMetaCacheKey u1 h1
      (agentMetaCacheKey u1 h1 /= agentMetaCacheKey u2 h1) `shouldBe` True
      (agentMetaCacheKey u1 h1 /= agentMetaCacheKey u1 h2) `shouldBe` True

  describe "sanitizeSnapshot" $ do

    it "strips exec bits from files and tightens dirs to 0700" $
      withSystemTempDirectory "seal-amc" $ \root -> do
        let sub = root </> ".agents"
            file = sub </> "agent.md"
        createDirectory sub
        writeFile file "# def\n"
        -- Simulate hostile perms arriving from the transfer.
        setFileMode file 0o777
        setFileMode sub 0o777
        sanitizeSnapshot root
        fs <- getFileStatus file
        ds <- getFileStatus sub
        fileModeBits fs `shouldBe` 0o600
        fileModeBits ds `shouldBe` 0o700
        -- The Haskell-level Permissions view agrees (no exec anywhere).
        fp <- getPermissions file
        executable fp `shouldBe` False

    it "removes symlinks instead of following or keeping them" $
      withSystemTempDirectory "seal-amc" $ \root -> do
        let sub = root </> ".agents"
            link = sub </> "sneaky.md"
        createDirectory sub
        writeFile (root </> "outside.txt") "secret"
        createFileLink (root </> "outside.txt") link
        sanitizeSnapshot root
        stillThere <- doesFileExist link
        stillThere `shouldBe` False

    it "recurses into nested directories but not through links" $
      withSystemTempDirectory "seal-amc" $ \root -> do
        let deep = root </> ".agents" </> "architect-agent"
            nested = deep </> "skills"
            mdFile = nested </> "x.md"
        createDirectoryIfMissing True nested
        writeFile mdFile "x"
        setFileMode mdFile 0o755
        sanitizeSnapshot root
        fs <- getFileStatus mdFile
        fileModeBits fs `shouldBe` 0o600

-- | Mask off the file-type bits, keeping only the permission bits.
fileModeBits :: FileStatus -> Int
fileModeBits st = fromIntegral (fileMode st) .&. 0o777

-- ---------------------------------------------------------------------------
-- Transfer + integration
-- ---------------------------------------------------------------------------

transferSpec :: Spec
transferSpec = describe "Seal.Session.AgentMetaCache (transfer)" $ do

  describe "rsyncArgv / rsyncRshString" $ do

    it "uses minimal flags: recursive, size-capped, nothing preserved" $ do
      let argv = rsyncArgv sshCfg "/srv/ws/repo" "/cache/e.tmp"
      mapM_ (\f -> argv `shouldNotSatisfy` elem f)
        ["-a", "-p", "-o", "-g", "-t", "-rLptgoD"]
      argv `shouldSatisfy` elem "-r"
      argv `shouldSatisfy` elem "--max-size=1048576"

    it "carries host/user in the destination arg; rsh holds only pinned options" $ do
      case rsyncArgv sshCfg "/srv/ws/repo" "/cache/e.tmp" of
        [_rsync, _r, _max, "-e", rsh, src, dst] -> do
          rsh `shouldSatisfy` ("ssh -o 'StrictHostKeyChecking=yes'" `isPrefixOfS`)
          rsh `shouldSatisfy` ("'UserKnownHostsFile=/home/agent/.ssh/known_hosts'" `isInfixOfS`)
          rsh `shouldNotSatisfy` ("agent@" `isInfixOfS`)
          src `shouldBe` "agent@exec.internal:/srv/ws/repo"
          dst `shouldBe` "/cache/e.tmp/"
        _ -> expectationFailure "unexpected argv shape"

    it "adds -p/-i only when configured" $ do
      let cfg = sshCfg { scPort = 2222, scIdentity = Just "/keys/id" }
          rsh = rsyncRshString cfg
      ("-p 2222" `isInfixOfS` rsh) `shouldBe` True
      ("-i '/keys/id'" `isInfixOfS` rsh) `shouldBe` True

    it "single-quotes rsh values containing spaces (rsync runs -e via sh)" $ do
      let cfg = sshCfg { scKnownHosts = "/home/a b/kh" }
          rsh = rsyncRshString cfg
      "'UserKnownHostsFile=/home/a b/kh'" `isInfixOfS` rsh

  describe "ensureAgentMetaSnapshot" $ do

    it "miss → rsync → sanitize → publish; hit → no second transfer" $ do
      withSystemTempDirectory "seal-amc-flow" $ \root -> do
        transfers <- newIORef []
        let runner = mkFakeRemoteRunner (Right (T.replicate 64 "a" <> "  -\n"))
            runTransfer argv dest = do
              modifyIORef' transfers (++ [argv])
              writeFile (dest </> "agent.md") "# def\n"
              setFileMode (dest </> "agent.md") 0o755
              pure (Right ())
            cacheRoot = root </> "cache"
        o1 <- ensureAgentMetaSnapshot runner sshCfg cacheRoot
                "git@github.com:a/b.git" "/srv/ws/repo" runTransfer
        path1 <- expectSnapshot o1
        -- Sanitized on publish despite the hostile 0755 from the transfer.
        fs <- getFileStatus (path1 </> "agent.md")
        fileModeBits fs `shouldBe` 0o600
        -- Second call with identical content: cache hit, no transfer.
        n1 <- length <$> readIORef transfers
        o2 <- ensureAgentMetaSnapshot runner sshCfg cacheRoot
                "git@github.com:a/b.git" "/srv/ws/repo" runTransfer
        path2 <- expectSnapshot o2
        n2 <- length <$> readIORef transfers
        n1 `shouldBe` 1
        n2 `shouldBe` 1
        path2 `shouldBe` path1

    it "different content hashes land in different entries" $ do
      withSystemTempDirectory "seal-amc-keys" $ \root -> do
        ref <- newIORef (T.replicate 64 "1")
        let runner = mkFakeRemoteRunnerWithRef ref
            runTransfer _ dest =
              writeFile (dest </> "a.md") "x" >> pure (Right ())
        o1 <- ensureAgentMetaSnapshot runner sshCfg (root </> "c")
                "git@github.com:a/b.git" "/srv/ws/repo" runTransfer
        p1 <- expectSnapshot o1
        writeIORef ref (T.replicate 64 "2")
        o2 <- ensureAgentMetaSnapshot runner sshCfg (root </> "c")
                "git@github.com:a/b.git" "/srv/ws/repo" runTransfer
        p2 <- expectSnapshot o2
        (p1 /= p2) `shouldBe` True

    it "garbage probe output → MetaFallback, nothing cached" $ do
      withSystemTempDirectory "seal-amc-fb" $ \root -> do
        let runner = mkFakeRemoteRunner (Right "tar: .agents: Cannot open\n")
        o <- ensureAgentMetaSnapshot runner sshCfg (root </> "c")
               "git@github.com:a/b.git" "/srv/ws/repo"
               (\_ _ -> pure (Right ()))
        o `shouldBe` MetaFallback
        -- No cache root was even created.
        doesFileExist (root </> "c") `shouldReturn` False

    it "transfer failure → MetaFallback and the tmp dir is removed" $ do
      withSystemTempDirectory "seal-amc-xfer" $ \root -> do
        let runner = mkFakeRemoteRunner (Right (T.replicate 64 "3" <> "  -\n"))
        o <- ensureAgentMetaSnapshot runner sshCfg (root </> "c")
               "git@github.com:a/b.git" "/srv/ws/repo"
               (\_ _ -> pure (Left ExecRemoteUnreachable))
        o `shouldBe` MetaFallback
        entries <- listDirectory (root </> "c")
        entries `shouldBe` []

-- | A fake runner reading its canned stdout from an IORef (lets a test
-- change the remote content hash between calls).
mkFakeRemoteRunnerWithRef :: IORef T.Text -> RemoteRunner
mkFakeRemoteRunnerWithRef ref = RemoteRunner
  { runRemote      = \_ -> readIORef ref >>= \t -> pure (Right (t <> "  -\n"))
  , runRemoteStdin = \_ _ -> readIORef ref >>= \t -> pure (Right (t <> "  -\n"))
  , runRemoteEnv   = \_ _ -> readIORef ref >>= \t -> pure (Right (t <> "  -\n"))
  }

expectSnapshot :: AgentMetaOutcome -> IO FilePath
expectSnapshot (MetaSnapshot p) = pure p
expectSnapshot other = do
  expectationFailure ("expected MetaSnapshot, got " <> show other)
  pure "<unreachable>"

-- | Placeholder SSH config (mirrors LogRedactionSpec's fixture).
sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = either (error "fixture") id (mkRemotePath "/srv/agent-workspace")
  }

isPrefixOfS :: String -> String -> Bool
isPrefixOfS = isPrefixOf

isInfixOfS :: String -> String -> Bool
isInfixOfS needle haystack = any (isPrefixOf needle) (tails haystack)

-- ---------------------------------------------------------------------------
-- Discovery wiring (URL probe + routing + GC)
-- ---------------------------------------------------------------------------

wiringSpec :: Spec
wiringSpec = describe "Seal.Session.AgentMetaCache (discovery wiring)" $ do

  describe "probeRepoUrlCmd / parseGitConfigUrl" $ do
    it "anchors the git-config probe at the repo dir" $ do
      ("cd '/srv/ws/repo' && git config --get remote.origin.url"
         `T.isInfixOf` probeRepoUrlCmd "/srv/ws/repo") `shouldBe` True

    it "parses a single-line url; rejects empty and multi-line output" $ do
      parseGitConfigUrl "git@github.com:a/b.git\n" `shouldBe`
        Just "git@github.com:a/b.git"
      parseGitConfigUrl "  https://github.com/a/b.git  \n"
        `shouldBe` Just "https://github.com/a/b.git"
      parseGitConfigUrl "" `shouldBe` Nothing
      parseGitConfigUrl "\n" `shouldBe` Nothing
      parseGitConfigUrl "line1\nline2\n" `shouldBe` Nothing

  describe "gcAgentMetaCache" $
    it "keeps the newest N entries and removes the rest" $
      withSystemTempDirectory "seal-amc-gc" $ \root -> do
        now <- getCurrentTime
        let mkEntry i age =
              let d = root </> ("e" <> show i)
              in do createDirectory d
                    setModificationTime d (addUTCTime (-age) now)
        mapM_ (uncurry mkEntry)
          [(1 :: Int, 300 :: NominalDiffTime), (2, 200), (3, 100)]  -- e3 newest, e1 oldest
        gcAgentMetaCache root 2
        kept <- listDirectory root
        sort kept `shouldBe` ["e2", "e3"]

  describe "buildRoutingWorkdirFs" $ do

    it "serves <repo>/.agents reads from the snapshot; passes others through" $ do
      withSystemTempDirectory "seal-amc-route" $ \root -> do
        passed <- newIORef []
        let remoteFs = WorkdirFs
              { wfsReadFile = \rp -> do
                  modifyIORef' passed (++ [getRemotePath rp])
                  pure (Right "REMOTE")
              , wfsDoesFileExist = \_ -> pure False
              , wfsDoesDirectoryExist = \_ -> pure True
              , wfsListDirectory = \_ -> pure (Right [])
              , wfsFileSize = \_ -> pure (Right 0)
              , wfsModificationTime = \_ -> pure (Right unixEpoch)
              , wfsSnapshot = error "snapshot unused in routing test"
              }
            runner = seqFakeRunner
              [ "git@github.com:a/b.git\n"                 -- url probe
              , T.replicate 64 "a" <> "  -\n"              -- content hash
              ]
            cacheRoot = root </> "cache"
            runTransfer _ dest = do
              createDirectoryIfMissing True (dest </> "agents" </> "x")
              writeFile (dest </> "agents.md") "# local snapshot"
              pure (Right ())
            env = MetaCacheEnv runner sshCfg cacheRoot runTransfer
        fs' <- buildRoutingWorkdirFs env remoteFs ["my-repo"]
        -- Under the prefix: served LOCALLY (snapshot bytes, not "REMOTE").
        rLocal <- wfsReadFile fs' =<< either (const (error "fixture")) pure
                    (mkRemotePath "my-repo/.agents/agents.md")
        rLocal `shouldBe` Right "# local snapshot"
        -- Outside the prefix: passthrough to the underlying fs (recorded).
        rRemote <- wfsReadFile fs' =<< either (const (error "fixture")) pure
                     (mkRemotePath "other-repo/file.txt")
        rRemote `shouldBe` Right "REMOTE"
        passedNow <- readIORef passed
        passedNow `shouldBe` ["other-repo/file.txt"]
        -- Cache entry landed where expected (content-addressed).
        let key = agentMetaCacheKey "git@github.com:a/b.git" (T.replicate 64 "a")
        doesFileExist (cacheRoot </> T.unpack key </> "seal-meta.json")
          `shouldReturn` True

-- | A fake RemoteRunner answering each call with the next canned Text
-- (oldest-first), staying at the last one once exhausted.
seqFakeRunner :: [T.Text] -> RemoteRunner
seqFakeRunner canned = unsafePerformIO $ do
  ref <- newIORef canned
  pure RemoteRunner
    { runRemote      = \_ -> pop ref
    , runRemoteStdin = \_ _ -> pop ref
    , runRemoteEnv   = \_ _ -> pop ref
    }
  where
    pop ref = atomicModifyIORef' ref $ \case
      (t : ts)  -> (ts, Right t)
      []        -> ([], Left ExecRemoteUnreachable)

unixEpoch :: UTCTime
unixEpoch = UTCTime (fromGregorian 1970 1 1) 0

-- TEMPORARY live diagnostic (run with SEAL_LIVE_AMC=1; delete before merge)
liveSpec :: Spec
liveSpec = describe "LIVE agent-meta probe" $
  it "ensureAgentMetaSnapshot against the configured remote host" $ do
    enabled <- lookupEnv "SEAL_LIVE_AMC"
    case enabled of
      Nothing -> pendingWith "set SEAL_LIVE_AMC=1"
      Just _ -> do
        let fixture :: Either T.Text a -> a
            fixture = either (error . T.unpack) id
            host = fixture (mkSshHost "192.168.80.201")
            user = fixture (mkSshUser "zoe")
            ws   = fixture (mkRemotePath "/Users/zoe/sandbox")
            cfg = SshConfig
              { scHost = host, scUser = user, scPort = 22
              , scIdentity = Just "/Users/doug/.ssh/id_ed25519"
              , scKnownHosts = "/Users/doug/.seal/exec-known-hosts"
              , scWorkspace = ws
              }
            repoDir = "/Users/zoe/sandbox/workdirs/20260825-114413-797/seal-harness"
        o <- ensureAgentMetaSnapshot mkRealRemoteRunner cfg "/tmp/amc-cache"
               "https://github.com/seal-harness/seal-harness.git" repoDir
               (rsyncTransferIO cfg)
        putStrLn ("OUTCOME: " <> show o)
        o `shouldSatisfy` \case MetaSnapshot _ -> True; _ -> False
