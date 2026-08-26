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
  , runApiTestOpts
  , ApiTestOptions (..)
  , defaultApiTestOptions
  , runApiTestLocal
  , runApiTestRemote
    -- * Test environment
  , ApiTestEnv (..)
    -- * Helpers
  , callApiNewTab
  , callSetupRepoRaw
  , sendMsgToSession
  , sendMsgToSessionRaw
  , getTranscript
  , assertTranscriptContains
  , setScript
  , uemLabel
  , ghEnvMarkerName
  , readGhEnvMarker
    -- * Dummy repo
  , DummyRepoConfig (..)
  , DummyRepo (..)
  , setupDummyRepo
  , readFileStrict
  , isInfixOfStr
  , testPatToken
    -- * Stub child worker
  , stubChildWorker
  ) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Seal.Session.ExecCache (newSessionExecCache)
import Control.Monad (when, void, unless)
import Control.Exception (catch, SomeException)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Builder qualified as BSB
import Data.Char (isAsciiLower, isAsciiUpper, isSpace)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, mapMaybe, maybeToList)
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
  ( createDirectoryIfMissing, doesFileExist, findExecutable
  , getHomeDirectory, getTemporaryDirectory )
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
import Seal.Agent.Runtime.Delegation
  ( AgentWorkerBuilder, ChildWorkerOutcome (..)
  , ChildExitReason (..) )
import Seal.Tools.Exec.Abort (newSessionAbortRegistry)
import Seal.Tools.Exec.Remote (RemoteRunner (..))
import Seal.Tools.Exec.Types (ExecError)
import Seal.Tools.Exec.Untrusted (UntrustedExecMode (..))
import Seal.Tabs (newTabsHandle)
import Seal.Web.UiState (newUiStateHandle)

-- ---------------------------------------------------------------------------
-- The test environment
-- ---------------------------------------------------------------------------

data ApiTestEnv = ApiTestEnv
  { ateApp         :: Application
  , ateDeps        :: ApiDeps
  , atePaths       :: SealPaths
  , ateMode        :: UntrustedExecMode
    -- ^ Which untrusted executor wiring this environment uses. The test
    -- body must NOT branch on this for assertions — both modes must assert
    -- the same contract. It exists so fixtures can observe the executor's
    -- own boundary (local: process env; remote: composed ssh command) and
    -- so diagnostics can label output.
  , ateProviderRef :: IORef [CompletionResponse]
  , ateDummyRepo   :: Maybe DummyRepo
  , ateCapturedSshArgv :: Maybe (IORef [([String], Maybe ByteString)])
    -- ^ Only set in remote mode with the fake remote runner
    -- ('atoFakeRemoteRunner'). Records every ssh argv (+ optional stdin
    -- payload) the session exec attempted, oldest-last. Diagnostics only —
    -- the contract itself is asserted via the shared gh-env marker file.
  }

-- | Human-readable label for a mode (diagnostics output only).
uemLabel :: UntrustedExecMode -> Text
uemLabel UemLocal  = "local"
uemLabel UemRemote = "remote"

-- | The PAT token seeded into the fake vault for @CredPat@ dummy repos.
-- Tests assert this exact value reaches the composed untrusted command's
-- env (never disk, never a log).
testPatToken :: Text
testPatToken = "seal-test-pat-token-12345"

-- | Options for 'runApiTestOpts'.
data ApiTestOptions = ApiTestOptions
  { atoFakeRemoteRunner :: Bool
    -- ^ In remote mode, inject a content-routed recording fake as the SSH
    -- runner (via 'sdRemoteRunner') instead of the real runner. The fake
    -- answers the SETUP_REPO call sequence (idempotency check → clone →
    -- verify) so the test is hermetic — no live gh/git/network on the SSH
    -- target — while still capturing the fully-composed remote command for
    -- assertion. Local mode is unaffected (the local executor has no runner
    -- seam; it really executes).
  , atoChildWorker :: Maybe AgentWorkerBuilder
    -- ^ When 'Just', inject a stub 'AgentWorkerBuilder' (via 'sdMkWorker' →
    -- 'tdMkWorker') so 'AGENT_START' can run through the gateway without a
    -- real provider call. 'Nothing' (the default — preserves existing
    -- tests' behavior) uses the production 'buildWorker' →
    -- 'mkDelegateWorker' path. Gateway API integration tests inject a stub
    -- that returns a 'ChildWorkerOutcome' immediately so the start completes
    -- synchronously.
  }

defaultApiTestOptions :: ApiTestOptions
defaultApiTestOptions = ApiTestOptions
  { atoFakeRemoteRunner = False
  , atoChildWorker = Nothing
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

  -- Generate a real SSH keypair. No passphrase — the integration test
  -- uses SHELL_EXEC (not BIN_EXEC credential injection), so the key
  -- doesn't need to be in an ssh-agent. A passphrase-less key works
  -- directly with ssh -i.
  (ec, _, err) <- readCreateProcessWithExitCode
    (proc "ssh-keygen"
      [ "-t", "ed25519"
      , "-f", keyfilePath
      , "-N", ""
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
runApiTest mRepoCfg =
  runApiTestOpts mRepoCfg defaultApiTestOptions

-- | 'runApiTest' with options (fake remote runner, etc.).
runApiTestOpts
  :: Maybe DummyRepoConfig
  -> ApiTestOptions
  -> (ApiTestEnv -> IO ())
  -> Spec
runApiTestOpts mRepoCfg opts body = do
  describe "local mode" $ runApiTestLocal mRepoCfg opts body
  describe "remote mode" $ runApiTestRemote mRepoCfg opts body

-- | Run the test body in local mode only.
runApiTestLocal
  :: Maybe DummyRepoConfig
  -> ApiTestOptions
  -> (ApiTestEnv -> IO ())
  -> SpecWith ()
runApiTestLocal mRepoCfg opts body = it "local" $ do
  withSystemTempDirectory "seal-api-test" $ \tmp -> do
    mRepo <- traverse (setupDummyRepo tmp) mRepoCfg
    env <- buildTestEnv tmp UemLocal mRepo opts
    body env

-- | Run the test body in remote mode only. Guards with 'pendingWith' when
-- sshd / ssh-keygen / ssh-keyscan are unavailable.
runApiTestRemote
  :: Maybe DummyRepoConfig
  -> ApiTestOptions
  -> (ApiTestEnv -> IO ())
  -> SpecWith ()
runApiTestRemote mRepoCfg opts body = it "remote" $ do
  let runBody = withSystemTempDirectory "seal-api-test" $ \tmp -> do
          mRepo <- traverse (setupDummyRepo tmp) mRepoCfg
          env <- buildTestEnv tmp UemRemote mRepo opts
          body env
  keygenExe <- findExecutable "ssh-keygen"
  case keygenExe of
    Nothing -> pendingWith "ssh-keygen not available"
    Just _ ->
      -- With the fake remote runner no live SSH host is needed — only
      -- ssh-keygen (setupDummyRepo generates a keypair unconditionally).
      -- The real-runner path additionally needs agent/keyscan/sshd AND a
      -- verified live ssh-to-localhost, because CI runners may have sshd
      -- listening without pubkey auth configured.
      if atoFakeRemoteRunner opts
        then runBody
        else do
          agentExe <- findExecutable "ssh-agent"
          keyscanExe <- findExecutable "ssh-keyscan"
          sshdExe <- findExecutable "sshd"
          case (agentExe, keyscanExe, sshdExe) of
            (Nothing, _, _) -> pendingWith "ssh-agent not available"
            (_, Nothing, _) -> pendingWith "ssh-keyscan not available"
            (_, _, Nothing) -> pendingWith "sshd not available (cannot SSH to localhost)"
            _ -> do
              -- Verify sshd is actually running AND SSH auth works by
              -- attempting a real SSH connection. Just checking port 22
              -- isn't enough.
              sshWorks <- testSshToLocalhost
              if not sshWorks
                then pendingWith "SSH to localhost not working (sshd not running or pubkey auth not configured)"
                else runBody

-- ---------------------------------------------------------------------------
-- Build the test environment
-- ---------------------------------------------------------------------------

buildTestEnv
  :: FilePath -> UntrustedExecMode -> Maybe DummyRepo -> ApiTestOptions
  -> IO ApiTestEnv
buildTestEnv tmp mode mRepo opts = do
  let stateRoot  = tmp </> "state"
      configRoot = tmp </> "config"
      sessionRoot = stateRoot </> "sessions"
  createDirectoryIfMissing True stateRoot
  createDirectoryIfMissing True configRoot
  createDirectoryIfMissing True sessionRoot
  createDirectoryIfMissing True (tmp </> "cache")
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

  -- Vault: fake unlocked, seeded with the repo's secret if needed.
  -- Deploy key: the keypair is passphrase-less, so the vault holds "".
  -- PAT: the vault holds 'testPatToken' (the value tests assert reaches
  -- the composed clone command's env).
  let mVaultSeed = case mRepo of
        Just dr -> case srCredential (drRepo dr) of
          CredDeployKey vk -> Just (vk, "")
          CredPat vk       -> Just (vk, TE.encodeUtf8 testPatToken)
          _                -> Nothing
        Nothing -> Nothing
  vaultRt <- makeFakeVaultRuntime (maybeToList mVaultSeed)

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
  currentUser <- if mode == UemRemote then whoami else pure ""
  let mKeyfilePath = mRepo >>= drKeyfilePath
      secCfg = if mode == UemRemote
        then buildRemoteSecurityConfig tmp currentUser mKeyfilePath
        else defaultSecurityConfig
  saveSecurityConfig (securityFilePath paths) secCfg

  logger <- testSealLogger
  execCache <- newSessionExecCache
  -- Fake remote runner (remote mode + atoFakeRemoteRunner): enforces the
  -- same observable contract the local-mode gh shim does — the clone only
  -- succeeds if GH_TOKEN/GIT_TERMINAL_PROMPT are scoped to the trailing
  -- gh command of the composed remote string. Both fixtures append what
  -- the gh invocation actually saw to the same marker file, so the test
  -- body asserts one contract with no mode branching.
  mCaptureRef <- if mode == UemRemote && atoFakeRemoteRunner opts
    then Just <$> newIORef []
    else pure Nothing
  mRunner <- case mCaptureRef of
    Just ref -> Just <$> mkSetupRepoFakeRunner (spHome paths </> ghEnvMarkerName) ref
    Nothing  -> pure Nothing
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
        , sdIsRemote = mode == UemRemote
        , sdExecCache = execCache
        , sdRemoteRunner = mRunner
        , sdMkWorker = atoChildWorker opts
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
    , ateCapturedSshArgv = mCaptureRef
    }

-- | The marker file (relative to the test's @spHome@) that BOTH gh-observer
-- fixtures append to: the local shim records the process env it was given;
-- the remote fake runner records the effective env of the trailing command
-- of the composed remote string. Lines are @KEY='value'@.
ghEnvMarkerName :: FilePath
ghEnvMarkerName = "gh-invocation.env"

-- | Read + parse a gh-env marker file into @[(key, value)]@. Errors with a
-- clear message if the file is absent — for the PAT suite that is itself a
-- contract failure (the gh invocation was never observed).
readGhEnvMarker :: FilePath -> IO [(Text, Text)]
readGhEnvMarker path = do
  exists <- doesFileExist path
  if not exists
    then error ("readGhEnvMarker: no gh invocation was observed (missing " <> path <> ")")
    else do
      content <- readFileStrict path
      pure [ (T.pack k, T.dropAround (== '\'') (T.pack v))
           | l <- lines content
           , not (null l)
           , let (k, rest) = break (== '=') l
           , not (null rest)
           , let v = drop 1 rest
           ]

-- | A content-routed recording fake 'RemoteRunner' that enforces the PAT
-- delivery contract by construction. Each invocation is recorded as
-- @(argv, mStdin)@ (oldest-last); the canned response is chosen by
-- inspecting the composed command string (the last argv element):
--
--   * contains @remote.origin.url@ → idempotency check → @__NONE__@ (empty
--     workspace: no existing clone)
--   * contains @__OK__@            → clone verify → @__OK__@ IFF the clone
--     call carried correctly-scoped credentials, else @__MISSING__@
--   * is the @gh repo clone …@ call → parse the effective env of the
--     TRAILING command of the composed string (POSIX scoping: an @env@
--     prefix before @cd &&@ binds only to @cd@) and append what gh would
--     actually see to the marker file. Wrong/missing token ⇒ the verify
--     call fails, so SETUP_REPO reports a clone failure — exactly as a
--     real remote host would reject the unauthenticated clone.
--   * anything else                → empty success (bootstrap/scans)
mkSetupRepoFakeRunner
  :: FilePath                                -- ^ marker file to append to
  -> IORef [([String], Maybe ByteString)]    -- ^ captured argvs
  -> IO RemoteRunner
mkSetupRepoFakeRunner markerPath ref = do
  cloneCredOkRef <- newIORef False
  let record argv mStdin = case reverse argv of
        (cmd : _) -> do
          modifyIORef' ref (++ [(argv, mStdin)])
          respondGhFake markerPath cloneCredOkRef cmd
        [] -> pure (Right "")
  pure RemoteRunner
    { runRemote      = (`record` Nothing)
    , runRemoteStdin = \argv stdin -> record argv (Just stdin)
    , runRemoteEnv   = \_env argv -> record argv Nothing
    }

-- | Respond to one recorded ssh invocation (see 'mkSetupRepoFakeRunner').
respondGhFake
  :: FilePath -> IORef Bool -> String -> IO (Either ExecError Text)
respondGhFake markerPath cloneCredOkRef cmdStr = do
  let cmd = T.pack cmdStr
  case () of
    _ | "remote.origin.url" `T.isInfixOf` cmd -> pure (Right "__NONE__\n")
      | "__OK__" `T.isInfixOf` cmd -> do
          ok <- readIORef cloneCredOkRef
          pure (Right (if ok then "__OK__\n" else "__MISSING__\n"))
      | otherwise -> case parseGhCloneCmd cmd of
          Nothing -> pure (Right "")  -- bootstrap / discovery scans
          Just (url, effEnv) -> do
            appendFile markerPath (ghMarkerLines url effEnv)
            writeIORef cloneCredOkRef (ghCredsOk effEnv)
            pure (Right "Cloning into 'seal-test'...\n")

ghCredsOk :: [(Text, Text)] -> Bool
ghCredsOk effEnv =
  lookup "GH_TOKEN" effEnv == Just testPatToken
  && lookup "GIT_TERMINAL_PROMPT" effEnv == Just "0"

-- | Parse a composed remote command of the shape
-- @cd '<ws>' && env K='V' … gh repo clone '<url>' '<dest>' -- --depth 1@
-- (the POST-fix form) into the token-free URL and the env visible to the
-- TRAILING command. Returns 'Nothing' when the trailing command is not an
-- env-prefixed gh clone — including the BUGGY pre-fix form where the env
-- prefix sits BEFORE the @cd@ and therefore binds nothing for gh.
parseGhCloneCmd :: Text -> Maybe (Text, [(Text, Text)])
parseGhCloneCmd cmd = case reverse (T.splitOn " && " cmd) of
  [] -> Nothing
  (final : _) -> do
    afterEnv <- T.stripPrefix "env " final
    let ws = T.words afterEnv
        (assigns, rest) = span isAssign ws
        effEnv = mapMaybe parseAssign assigns
        trailing = T.unwords rest
    url <- T.stripPrefix "gh repo clone '" trailing
    pure (T.takeWhile (/= '\x27') url, effEnv)
  where
    isAssign w = case T.uncons w of
      Just (c, _) -> c /= '\x27' && T.any (== '=') w && "=" `T.isPrefixOf` T.dropWhile isNameChar w
      Nothing     -> False
    isNameChar c = isAsciiLower c || isAsciiUpper c || c == '_'
    parseAssign w = case T.breakOn "=" w of
      (k, v) | not (T.null k), "='" `T.isPrefixOf` v ->
        Just (k, T.takeWhile (/= '\x27') (T.drop 2 v))
      _ -> Nothing

-- | The marker lines recording what the gh invocation saw.
ghMarkerLines :: Text -> [(Text, Text)] -> String
ghMarkerLines url effEnv = T.unpack (T.concat
  [ "URL='" <> url <> "'\n"
  , "GH_TOKEN='" <> fromMaybe "" (lookup "GH_TOKEN" effEnv) <> "'\n"
  , "GIT_TERMINAL_PROMPT='" <> fromMaybe "" (lookup "GIT_TERMINAL_PROMPT" effEnv) <> "'\n"
  ])

-- | Build a SecurityConfig for remote mode (SSH to localhost).
-- The identity (private key) must be set so sshExecArgv passes @-i <key>@.
-- Without it, SSH falls back to default keys (~/.ssh/id_*) and the agent,
-- neither of which has the test key.
buildRemoteSecurityConfig :: FilePath -> String -> Maybe FilePath -> SecurityConfig
buildRemoteSecurityConfig tmp user mKeyfilePath =
  defaultSecurityConfig
    { scUntrustedExec = Just UntrustedExecFileConfig
        { uefcMode = "remote"
        , uefcRemote = Just UntrustedExecRemoteFileConfig
            { uerfcHost = Just "localhost"
            , uerfcUser = Just (T.pack user)
            , uerfcPort = Nothing
            , uerfcIdentity = mKeyfilePath
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

-- | Clone a repo into a session's workdir via
-- @POST /api/sessions/:id/setup-repo@ — the endpoint the web combo box
-- calls. Returns the (status, body) for inspection.
callSetupRepoRaw :: ApiTestEnv -> Text -> Text -> IO (Int, BL.ByteString)
callSetupRepoRaw env sid url = do
  req <- testPost ["api", "sessions", sid, "setup-repo"]
    (A.encode (A.object ["url" .= url]))
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

-- | Test that SSH to localhost works: generate a throwaway passphrase-less
-- key, add it to authorized_keys, attempt an SSH echo, then clean up.
-- Returns True if SSH works, False otherwise.
testSshToLocalhost :: IO Bool
testSshToLocalhost =
  catch
    (do
      tmp <- getTemporaryDirectory
      let keyPath = tmp </> "seal-ssh-test-key"
      -- Generate a throwaway key.
      (genEc, _, _) <- readCreateProcessWithExitCode
        (proc "ssh-keygen" ["-t", "ed25519", "-f", keyPath, "-N", "", "-C", "seal-ssh-test"]) ""
      if genEc /= ExitSuccess then pure False else do
        -- Add the public key to authorized_keys.
        homeDir <- getHomeDirectory
        let sshDir = homeDir </> ".ssh"
            authKeysPath = sshDir </> "authorized_keys"
        createDirectoryIfMissing True sshDir
        pubKey <- readFileStrict (keyPath <> ".pub")
        appendFile authKeysPath (pubKey <> "\n")
        -- Try SSH.
        (sshEc, _, _) <- readCreateProcessWithExitCode
          (proc "ssh"
            [ "-o", "StrictHostKeyChecking=no"
            , "-o", "UserKnownHostsFile=/dev/null"
            , "-o", "IdentitiesOnly=yes"
            , "-o", "BatchMode=yes"
            , "-i", keyPath
            , "localhost", "echo", "ok"
            ]) ""
        -- Clean up the key from authorized_keys.
        exists <- doesFileExist authKeysPath
        when exists $ do
          content <- readFileStrict authKeysPath
          let filtered = unlines (filter (not . isInfixOfStr pubKey) (lines content))
          writeFile authKeysPath filtered
        pure (sshEc == ExitSuccess))
    (\(_ :: SomeException) -> pure False)

-- | A stub 'AgentWorkerBuilder' for gateway API integration tests that
-- exercise 'AGENT_START'. Returns a 'ChildWorkerOutcome' immediately — no
-- provider call, no real turn — so 'AGENT_START' completes synchronously
-- through the gateway without a live LLM. The child "completes" with the
-- 'SessionId' it was passed (the second argument), mirroring what the
-- production 'mkDelegateWorker' reports via 'cwoChildSession'. The
-- 'ChildRunHooks' are ignored (matching the production worker's discard of
-- them at 'Seal.Agent.Runtime.Delegation.Worker' line 155) — surfacing the
-- @_hooks@ no-op is the job of the integration tests, not this stub.
stubChildWorker :: AgentWorkerBuilder
stubChildWorker _def sid _task _hooks =
  pure (ChildWorkerOutcome (Just "child done") CerCompleted 0 0 (Just sid))