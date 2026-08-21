{-# LANGUAGE OverloadedStrings #-}
-- | The reusable gateway API integration test harness. Builds 'ApiDeps'
-- wired for local OR remote mode, with a mock LLM provider (via
-- 'ScriptProvider') and optional dummy repo setup (bare git repo + SSH
-- keypair + authorized_keys bracket). Tests written against this harness
-- run the same test body in both modes, giving local/remote parity for
-- free.
--
-- See @docs/superpowers/specs/2026-08-21-gateway-api-integration-test-harness-design.md@
-- for the full design.
module Seal.TestHelpers.ApiTestHarness
  ( -- * Entry point
    runApiTest
  , runApiTestLocal
  , runApiTestRemote
    -- * Test environment
  , ApiTestEnv (..)
    -- * Helpers
  , callApiNewTab
  , sendMsgToSession
  , sendMsgToSessionRaw
  , getTranscript
  , assertTranscriptContains
  , setScript
    -- * Dummy repo
  , DummyRepoConfig (..)
  , DummyRepo (..)
  , setupDummyRepo
  , readFileStrict
  , isInfixOfStr
  ) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (when, void, unless)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Builder qualified as BSB
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (methodGet, methodPost, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo
  , requestMethod, responseStatus, setRequestBodyChunks )
import Network.Wai.Internal (ResponseReceived (..), Response (..))
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, findExecutable, getHomeDirectory )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcessWithExitCode, proc, CreateProcess (..))
import Test.Hspec
  ( Spec, SpecWith, describe, it, pendingWith )

import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (mkRegistry)
import Seal.Command.Tab (noTabCloseNotifier)
import Seal.Config.Paths (SealPaths (..), securityFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..), defaultSecurityConfig
  , saveSecurityConfig )
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Gateway.API (ApiDeps (..), apiApp)
import Seal.Gateway.Send (SendDeps (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Ingest (emptyChain)
import Seal.Logging.Logger (testSealLogger)
import Seal.Providers.Class
  ( CompletionResponse (..), SomeProvider (..) )
import Seal.Providers.Registry (knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Policy qualified as Policy (AutonomyLevel (Full))
import Seal.Session.Lock (newSessionLocks, newReplyRegistry)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.TestHelpers.ScriptProvider (ScriptProvider (..))
import Seal.Tools.Exec.Abort (newSessionAbortRegistry)
import Seal.Tabs (newTabsHandle)
import Seal.Web.UiState (newUiStateHandle)

-- ---------------------------------------------------------------------------
-- The test environment
-- ---------------------------------------------------------------------------

data ApiTestEnv = ApiTestEnv
  { ateApp         :: Application
  , ateDeps        :: ApiDeps
  , atePaths       :: SealPaths
  , ateMode        :: Text          -- "local" | "remote"
  , ateProviderRef :: IORef [CompletionResponse]
  , ateDummyRepo   :: Maybe DummyRepo
  }

-- ---------------------------------------------------------------------------
-- Dummy repo
-- ---------------------------------------------------------------------------

data DummyRepoConfig = DummyRepoConfig
  { drcRepoId     :: Text
  , drcCredential :: RepoCredential
  }

data DummyRepo = DummyRepo
  { drBareRepoPath :: FilePath
  , drRepo         :: SourceRepo
  , drKeyfilePath  :: Maybe FilePath
  , drCleanup      :: IO ()
  }

-- | Set up a dummy bare git repo for testing git operations over SSH to
-- localhost. Generates a fresh SSH keypair, adds the public key to
-- @~/.ssh/authorized_keys@ (bracket cleanup), creates a bare repo, and
-- returns the 'SourceRepo' + cleanup action.
setupDummyRepo :: FilePath -> DummyRepoConfig -> IO DummyRepo
setupDummyRepo tmp cfg = do
  let repoIdText = drcRepoId cfg
      bareRepoPath = tmp </> "bare.git"
      -- The keyfiles dir must match repoKeysDir paths (spState </> "repos" </> "keys")
      -- so mkCloneDepsTurn finds the keyfile.
      keyfilesDir = tmp </> "state" </> "repos" </> "keys"
      keyfilePath = keyfilesDir </> T.unpack repoIdText
  createDirectoryIfMissing True keyfilesDir

  -- Create the bare repo.
  runProc "git" ["init", "--bare", bareRepoPath] Nothing

  -- Get the current user for the SSH URL.
  currentUser <- whoami

  -- Generate a real SSH keypair with a passphrase.
  let passphrase = "test-passphrase-12345"
  (ec, _, err) <- readCreateProcessWithExitCode
    (proc "ssh-keygen"
      [ "-t", "ed25519"
      , "-f", keyfilePath
      , "-N", passphrase
      , "-C", "seal-test"
      ]) ""
  case ec of
    ExitFailure _ -> error ("setupDummyRepo: ssh-keygen failed: " <> err)
    ExitSuccess -> pure ()

  -- Add the public key to ~/.ssh/authorized_keys.
  homeDir <- getHomeDirectory
  let sshDir = homeDir </> ".ssh"
      authorizedKeysPath = sshDir </> "authorized_keys"
      pubKeyPath = keyfilePath <> ".pub"
  createDirectoryIfMissing True sshDir
  pubKey <- readFileStrict pubKeyPath
  appendFile authorizedKeysPath (pubKey <> "\n")

  -- Scan localhost's host key.
  (scanEc, scanOut, _) <- readCreateProcessWithExitCode
    (proc "ssh-keyscan" ["-t", "ed25519", "localhost"]) ""
  let knownHostsPath = keyfilesDir </> "known_hosts"
  case scanEc of
    ExitFailure _ -> writeFile knownHostsPath ""  -- empty known_hosts; test body will pendingWith
    ExitSuccess -> writeFile knownHostsPath scanOut

  -- Build the SSH URL and SourceRepo.
  let sshUrl = T.pack (currentUser <> "@localhost:" <> bareRepoPath)
      rid = case mkRepoId repoIdText of Right i -> i; Left e -> error (show e)
      repo = SourceRepo
        { srId = rid
        , srUrl = sshUrl
        , srVcsKind = VcsGitHub
        , srCredential = drcCredential cfg
        , srDeployKeyPublic = Nothing
        , srKeyfilePath = Nothing
        }

  pure DummyRepo
    { drBareRepoPath = bareRepoPath
    , drRepo = repo
    , drKeyfilePath = Just keyfilePath
    , drCleanup = do
        exists <- doesFileExist authorizedKeysPath
        when exists $ do
          content <- readFileStrict authorizedKeysPath
          let filtered = unlines (filter (not . isInfixOfStr pubKey) (lines content))
          writeFile authorizedKeysPath filtered
    }

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Run a test body in both local and remote mode. The test body receives
-- an 'ApiTestEnv' carrying the WAI app, 'ApiDeps', paths, and dummy repo (if
-- requested). The mock provider starts empty — the test body should call
-- 'setScript' to inject the LLM responses (this allows the script to
-- reference dynamic values like the dummy repo's path).
runApiTest
  :: Maybe DummyRepoConfig
  -> (ApiTestEnv -> IO ())
  -> Spec
runApiTest mRepoCfg body = do
  describe "local mode" $ runApiTestLocal mRepoCfg body
  describe "remote mode" $ runApiTestRemote mRepoCfg body

-- | Run the test body in local mode only.
runApiTestLocal
  :: Maybe DummyRepoConfig
  -> (ApiTestEnv -> IO ())
  -> SpecWith ()
runApiTestLocal mRepoCfg body = it "local" $ do
  withSystemTempDirectory "seal-api-test" $ \tmp -> do
    mRepo <- traverse (setupDummyRepo tmp) mRepoCfg
    env <- buildTestEnv tmp "local" mRepo
    body env

-- | Run the test body in remote mode only. Guards with 'pendingWith' when
-- sshd / ssh-keygen / ssh-keyscan are unavailable.
runApiTestRemote
  :: Maybe DummyRepoConfig
  -> (ApiTestEnv -> IO ())
  -> SpecWith ()
runApiTestRemote mRepoCfg body = it "remote" $ do
  keygenExe <- findExecutable "ssh-keygen"
  agentExe <- findExecutable "ssh-agent"
  keyscanExe <- findExecutable "ssh-keyscan"
  sshdExe <- findExecutable "sshd"
  case (keygenExe, agentExe, keyscanExe, sshdExe) of
    (Nothing, _, _, _) -> pendingWith "ssh-keygen not available"
    (_, Nothing, _, _) -> pendingWith "ssh-agent not available"
    (_, _, Nothing, _) -> pendingWith "ssh-keyscan not available"
    (_, _, _, Nothing) -> pendingWith "sshd not available (cannot SSH to localhost)"
    _ -> withSystemTempDirectory "seal-api-test" $ \tmp -> do
      mRepo <- traverse (setupDummyRepo tmp) mRepoCfg
      env <- buildTestEnv tmp "remote" mRepo
      body env

-- ---------------------------------------------------------------------------
-- Build the test environment
-- ---------------------------------------------------------------------------

buildTestEnv
  :: FilePath -> Text -> Maybe DummyRepo
  -> IO ApiTestEnv
buildTestEnv tmp mode mRepo = do
  let stateRoot  = tmp </> "state"
      configRoot = tmp </> "config"
      sessionRoot = stateRoot </> "sessions"
  createDirectoryIfMissing True stateRoot
  createDirectoryIfMissing True configRoot
  createDirectoryIfMissing True sessionRoot
  ensureConfigRepo configRoot
  let configRepo = openConfigRepo configRoot
  backends <- newBackends configRoot configRepo
  tabsH <- newTabsHandle
  reg <- newHarnessRegistry
  tmuxR <- mkRealTmuxRunner
  askReply <- newAskReplyStore 0
  approvals <- newApprovalCache
  testReplies <- newReplyRegistry
  testLocks <- newSessionLocks
  testAbortReg <- newSessionAbortRegistry

  let paths = SealPaths
        { spHome = tmp, spState = stateRoot, spConfig = configRoot
        , spKeys = tmp </> "keys", spCache = tmp </> "cache"
        }
  providerRef <- newIORef []

  -- Vault: fake unlocked, seeded with deploy-key passphrase if needed.
  let vaultKey = case mRepo of
        Just dr -> case srCredential (drRepo dr) of
          CredDeployKey vk -> Just vk
          _ -> Nothing
        Nothing -> Nothing
  vaultRt <- case vaultKey of
    Just vk -> makeFakeVaultRuntime [(vk, "test-passphrase-12345")]
    Nothing -> makeFakeVaultRuntime []

  -- Session runtime.
  let meta0 = SessionMeta
        (case mkSessionId "test" of Right s -> s; Left _ -> error "sid")
        "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing
        (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)
  activeRef <- newIORef meta0
  let sr = SessionRuntime
        { srPaths = paths, srConfigPath = configRoot </> "config.toml"
        , srActive = activeRef }
  uiState <- newUiStateHandle paths
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0

  let rt = vaultRt
      pr = ProviderRuntime
        { prConfigPath = configRoot </> "config.toml", prVault = rt
        , prManager = mgr, prCallCounter = cntRef }

  -- Provider resolve stub.
  let resolveStub :: SessionMeta -> IO (Either Text (SomeProvider, ModelId))
      resolveStub _ = pure (Right (SomeProvider (ScriptProvider providerRef), ModelId "llama3.2"))

  -- Repo registry.
  let repos = maybeToList (drRepo <$> mRepo)
      repoRegH = RepoRegistryHandle
        { rrhList = pure (Right repos)
        , rrhMutate = \_ -> pure (Right ())
        }

  -- Security config: remote mode needs untrusted_execution.remote.
  -- Write it to security.toml so runTurnBody picks it up (the turn
  -- engine loads SecurityConfig from disk, not from ApiDeps).
  let secCfg = if mode == "remote"
        then buildRemoteSecurityConfig tmp
        else defaultSecurityConfig
  saveSecurityConfig (securityFilePath paths) secCfg

  logger <- testSealLogger
  let sendDeps = SendDeps
        { sdPaths = paths
        , sdVault = rt
        , sdRepoReg = repoRegH
        , sdProvider = pr
        , sdSession = sr
        , sdBackends = backends
        , sdConfigRepo = configRepo
        , sdPreprocess = emptyChain
        , sdRegistry = mkRegistry []
        , sdResolve = resolveStub
        , sdAutonomy = Policy.Full
        , sdBroker = Nothing
        , sdHarnessRegistry = reg
        , sdTmuxRunner = tmuxR
        , sdHttpManager = Just mgr
        , sdAskReply = askReply
        , sdApprovals = approvals
        , sdReplies = testReplies
        , sdLocks = testLocks
        , sdAbortReg = testAbortReg
        , sdTabsHandle = tabsH
        , sdLogger = logger
        , sdIsRemote = mode == "remote"
        }
      deps = ApiDeps
        { adSessionRuntime = sr
        , adTabsHandle = tabsH
        , adHarnessRegistry = reg
        , adAdoptConsent = Just CcWeb
        , adAgentDefs = bAgentDefs backends
        , adSkills = bSkills backends
        , adProviders = pure knownProviders
        , adUiState = uiState
        , adSend = Just sendDeps
        , adDefaultAgent = pure Nothing
        , adBroker = Nothing
        , adTabCloseNotifier = noTabCloseNotifier
        , adRepoRegistry = repoRegH
        , adConfigRepo = configRepo
        , adVault = rt
        , adPaths = paths
        , adWsPort = 8081
        , adAbortReg = testAbortReg
        , adSecurityConfig = secCfg
        , adMkSessionExec = Nothing
        }
      app = apiApp deps
  pure ApiTestEnv
    { ateApp = app
    , ateDeps = deps
    , atePaths = paths
    , ateMode = mode
    , ateProviderRef = providerRef
    , ateDummyRepo = mRepo
    }

-- | Build a SecurityConfig for remote mode (SSH to localhost).
buildRemoteSecurityConfig :: FilePath -> SecurityConfig
buildRemoteSecurityConfig tmp =
  defaultSecurityConfig
    { scUntrustedExec = Just UntrustedExecFileConfig
        { uefcMode = "remote"
        , uefcRemote = Just UntrustedExecRemoteFileConfig
            { uerfcHost = Just "localhost"
            , uerfcUser = Nothing  -- defaults to current user
            , uerfcPort = Nothing
            , uerfcIdentity = Nothing
            , uerfcKnownHosts = Just (tmp </> "state" </> "repos" </> "keys" </> "known_hosts")
            , uerfcWorkspace = Just (T.pack (tmp </> "cache" </> "remote-workspace"))
            }
        }
    }

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Create a provider tab via POST /api/tabs/new. Returns the session id.
callApiNewTab :: ApiTestEnv -> Text -> Text -> IO Text
callApiNewTab env provider model = do
  req <- testPost ["api", "tabs", "new"]
    (A.encode (A.object
      [ "kind" .= ("provider" :: Text)
      , "provider" .= provider
      , "model" .= model
      ]))
  (st, body) <- runAppBody (ateApp env) req
  if st /= 200
    then error ("callApiNewTab: expected 200, got " <> show st <> ": " <> show body)
    else case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> case KeyMap.lookup (Key.fromText "session_id") o of
        Just (A.String s) -> pure s
        _ -> error "callApiNewTab: no session_id in response"
      _ -> error "callApiNewTab: invalid JSON response"

-- | Send a message to a session via POST /api/sessions/:id/send.
-- Returns the response body for inspection.
sendMsgToSession :: ApiTestEnv -> Text -> Text -> IO BL.ByteString
sendMsgToSession env sid msg = do
  req <- testPost ["api", "sessions", sid, "send"]
    (A.encode (A.object ["message" .= msg]))
  (st, body) <- runAppBody (ateApp env) req
  when (st /= 200) (error ("sendMsgToSession: expected 200, got " <> show st <> ": " <> show body))
  pure body

-- | Like 'sendMsgToSession' but returns the (status, body) for debugging.
sendMsgToSessionRaw :: ApiTestEnv -> Text -> Text -> IO (Int, BL.ByteString)
sendMsgToSessionRaw env sid msg = do
  req <- testPost ["api", "sessions", sid, "send"]
    (A.encode (A.object ["message" .= msg]))
  runAppBody (ateApp env) req

-- | Get the transcript as a JSON array.
getTranscript :: ApiTestEnv -> Text -> IO [A.Value]
getTranscript env sid = do
  let req = testRequest ["api", "sessions", sid, "transcript"]
  (st, body) <- runAppBody (ateApp env) req
  if st /= 200
    then error ("getTranscript: expected 200, got " <> show st)
    else case A.decode body :: Maybe A.Value of
      Just (A.Array a) -> pure (toList a)
      _ -> pure []

-- | Assert the transcript contains the given text substring.
assertTranscriptContains :: ApiTestEnv -> Text -> Text -> IO ()
assertTranscriptContains env sid needle = do
  entries <- getTranscript env sid
  let bodyText = T.pack (show entries)
  unless (needle `T.isInfixOf` bodyText)
    (error ("assertTranscriptContains: \"" <> T.unpack needle <> "\" not found in transcript"))

-- | Replace the mock provider's script. Use after 'callApiNewTab' when the
-- test body needs to inject dynamic values (e.g. a clone URL that depends
-- on the dummy repo's temp path) into the LLM responses.
setScript :: ApiTestEnv -> [CompletionResponse] -> IO ()
setScript env = writeIORef (ateProviderRef env)

-- ---------------------------------------------------------------------------
-- WAI request helpers (self-contained — no ApiSpec dependency)
-- ---------------------------------------------------------------------------

testRequest :: [Text] -> Request
testRequest path = defaultRequest { requestMethod = methodGet, pathInfo = path }

testPost :: [Text] -> BL.ByteString -> IO Request
testPost path body = do
  usedRef <- newIORef False
  let readChunk = do
        already <- readIORef usedRef
        if already
          then pure BC.empty
          else do writeIORef usedRef True
                  pure (BL.toStrict body)
  pure (setRequestBodyChunks readChunk (defaultRequest { requestMethod = methodPost, pathInfo = path }))

runAppBody :: Application -> Request -> IO (Int, BL.ByteString)
runAppBody app req = do
  mv <- newEmptyMVar
  void $ app req (\resp -> do
    let st = statusCode (responseStatus resp)
        body = case resp of
          ResponseBuilder _ _ b -> BSB.toLazyByteString b
          _ -> BL.fromStrict BC.empty
    putMVar mv (st, body)
    pure ResponseReceived)
  takeMVar mv

-- ---------------------------------------------------------------------------
-- Misc helpers
-- ---------------------------------------------------------------------------

-- | Run a process with optional cwd, failing on non-zero exit.
runProc :: String -> [String] -> Maybe FilePath -> IO ()
runProc cmd args mCwd = do
  let cp = (proc cmd args) { cwd = mCwd }
  (ec, _, err) <- readCreateProcessWithExitCode cp ""
  case ec of
    ExitSuccess -> pure ()
    ExitFailure n -> error (cmd <> " exited " <> show n <> ": " <> err)

-- | Get the current OS username.
whoami :: IO String
whoami = do
  (ec, out, _) <- readCreateProcessWithExitCode (proc "whoami" []) ""
  case ec of
    ExitSuccess -> pure (filter (not . isSpace) out)
    ExitFailure _ -> pure "nobody"

-- | Strict file read (avoids lazy IO surprises).
readFileStrict :: FilePath -> IO String
readFileStrict path = do
  bs <- BC.readFile path
  pure (T.unpack (TE.decodeUtf8Lenient bs))

-- | isInfixOf for String.
isInfixOfStr :: String -> String -> Bool
isInfixOfStr needle = go
  where
    go [] = False
    go s@(_ : cs)
      | prefix needle s = True
      | otherwise = go cs
    prefix [] _ = True
    prefix _ [] = False
    prefix (p : ps) (q : qs) = p == q && prefix ps qs