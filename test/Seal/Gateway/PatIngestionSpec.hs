{-# LANGUAGE OverloadedStrings #-}
-- | Cross-layer integration test: POST @/api/repos@ with a PAT token →
-- the token lands in the vault (NOT @repos.toml@, NOT the response, NOT
-- the gateway logs) → running @BIN_EXEC gh@ against the registered repo's
-- workdir injects @GH_TOKEN=<the pasted token>@ via 'uioBinExecEnv'.
--
-- This is the test the user explicitly requested: verify the generated
-- @gh@ command shape and that the @xyz@ PAT is properly passed, without
-- hitting GitHub or running a real @gh@ binary.
--
-- Approach (per design §3.6, "API + opcode direct" fallback): the test
-- exercises the real API (a WAI @POST /api/repos@ against a real
-- @mkRepoRegistryHandle@ pointed at a temp @repos.toml@ + a fake in-memory
-- vault) so the token is genuinely stored in the vault and the repo is
-- genuinely persisted to disk. It then builds the @BIN_EXEC@ opcode
-- directly ('binExecOp') with a recording 'UntrustedIO' (the
-- @ghFakeUio@ pattern from @BinGhSpec.hs@) whose 'CloneDeps' point at the
-- SAME real @RepoRegistryHandle@ + the SAME fake vault, and dispatches
-- @BIN_EXEC gh pr create@ through it. Because @rrhList@ re-reads the
-- @repos.toml@ file on each call, the opcode's pre-flight registry lookup
-- finds the POSTed repo and resolves the credential from the vault,
-- injecting @GH_TOKEN=xyz@.
--
-- This verifies the full cross-layer flow the user cares about: form
-- token → vault → opcode → exec seam. Whether the opcode is dispatched
-- via the agent loop or called directly is an implementation detail; the
-- assertion is on the command shape (the recorded @uioBinExecEnv@ env
-- extras), not the dispatch mechanism.
module Seal.Gateway.PatIngestionSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Builder qualified as BSB
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Types (methodPost, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestMethod, responseStatus
  , setRequestBodyChunks )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend)
import Seal.Command.Tab (noTabCloseNotifier)
import Seal.Config.Paths (SealPaths (..))
import Seal.Config.Security (defaultSecurityConfig)
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API (ApiDeps (..), apiApp)
import Seal.Git.Repo (openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.ISA.Opcode (OpResult (..), Opcode, uoRun)
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.Logging.Global (setGlobalLogger, unsetGlobalLogger)
import Seal.Logging.Logger (closeSealLogger, newSealLoggerWithScribe)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Providers.Registry (knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (AutonomyLevel (..), SecurityPolicy (..))
import Seal.Security.Vault (VaultHandle (vhGet))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Skills.Backend qualified as Skill (noneBackend)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Clone (CloneDeps (..))
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Registry (RepoRegistryHandle, mkRepoRegistryHandle)
import Seal.Tabs (newTabsHandle)
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.Tools.Args (textBinArg, textBinName)
import Seal.Tools.Exec.Abort (SessionAbortRegistry, newSessionAbortRegistry)
import Seal.Tools.Exec.Types (getRemotePath)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO (UntrustedIO (..), mkRemoteUntrustedIOStub)
import Seal.Tools.Ssh.Agent (SshAgentEnv (..), mkFakeSshAgentHandle)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Web.UiState (newUiStateHandle)

import Katip (Severity (..), Scribe (..), Verbosity (V2), jsonFormat, permitItem)

----------------------------------------------------------------------
-- Shared test abort registry (created once)
----------------------------------------------------------------------

testAbortReg :: SessionAbortRegistry
testAbortReg = unsafePerformIO newSessionAbortRegistry
{-# NOINLINE testAbortReg #-}

----------------------------------------------------------------------
-- A recording UntrustedIO (the ghFakeUio pattern from BinGhSpec.hs)
----------------------------------------------------------------------

-- | A recorded exec call — captures which 'UntrustedIO' method was used
-- and the env extras passed.
data GhRecordedExec = GhRecordedExec
  { greBinary     :: Text
  , greArgs       :: [Text]
  , greCwd        :: Maybe Text
  , greEnvExtras  :: [(String, String)]
  , greUsedGitEnv :: Bool
  , greUsedEnv    :: Bool
  , greUsedPlain  :: Bool
  } deriving stock (Eq, Show)

-- | Build a fake 'UntrustedIO' that records exec calls. The @remoteUrl@
-- is the canned output for the pre-flight @git config --get
-- remote.origin.url@ (matching the registered repo's URL); the
-- @finalOutput@ is the canned output for the actual @gh@ command. Does
-- NOT execute any binary.
ghFakeUio :: IORef [GhRecordedExec] -> Text -> Text -> UntrustedIO
ghFakeUio seen remoteUrl finalOutput =
  mkRemoteUntrustedIOStub
    { uioBinExec = \bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
            output = if binText == "git" && "config" `elem` argTexts
                       then remoteUrl
                       else finalOutput
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) [] False False True])
        pure (Right output)
    , uioBinExecEnv = \extras bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) extras False True False])
        pure (Right finalOutput)
    , uioBinExecGitEnv = \extras _mKnownHosts bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) extras True True False])
        pure (Right finalOutput)
    }

-- | Build 'CloneDeps' that share the SAME real 'RepoRegistryHandle' and
-- the SAME fake vault as the API, so the opcode's pre-flight
-- @uioCdRepoRegList@ sees the POSTed repo and the credential resolution
-- reads the token the API stored. Local mode (the @gh@ credential
-- injection is identical on both planes).
mkPatCloneDeps :: VaultRuntime -> RepoRegistryHandle -> IO CloneDeps
mkPatCloneDeps vr repoReg = do
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-patingestion-agentreg"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vr
    , cdRepoReg = repoReg
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-patingestion-keyfiles"
    , cdIsRemote = False
    }

----------------------------------------------------------------------
-- WAI test helpers (self-contained — mirrors ApiSpec.hs)
----------------------------------------------------------------------

-- | Build a POST request with a JSON body (one chunk then empty).
testPost :: [Text] -> BL.ByteString -> IO Request
testPost = testWithBody methodPost

-- | Build a request with a given method + a JSON body.
testWithBody :: BC.ByteString -> [Text] -> BL.ByteString -> IO Request
testWithBody mth path body = do
  usedRef <- newIORef False
  let readChunk = do
        already <- readIORef usedRef
        if already
          then pure BC.empty
          else do writeIORef usedRef True
                  pure (BL.toStrict body)
  pure (setRequestBodyChunks readChunk (defaultRequest { requestMethod = mth, pathInfo = path }))

-- | Run the app against a test request, capturing the status code + body.
runAppBody :: Application -> Request -> IO (Int, BL.ByteString)
runAppBody app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> do
    let st = statusCode (responseStatus resp)
        body = case resp of
          ResponseBuilder _ _ b -> BSB.toLazyByteString b
          _ -> BL.fromStrict BC.empty
    putMVar mv (st, body)
    pure ResponseReceived)
  takeMVar mv

----------------------------------------------------------------------
-- Log capture (mirrors ApiSpec.hs withCaptureGlobalLogger)
----------------------------------------------------------------------

mkCaptureScribe :: IO (Scribe, IORef [Text])
mkCaptureScribe = do
  ref <- newIORef []
  let scribe = Scribe
        { liPush = \item -> do
            let rendered = jsonFormat False V2 item
            modifyIORef' ref (T.pack (show rendered) :)
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  pure (scribe, ref)

withCaptureGlobalLogger :: IO a -> IO (a, [Text])
withCaptureGlobalLogger action = do
  (scribe, ref) <- mkCaptureScribe
  logger <- newSealLoggerWithScribe scribe DebugS
  setGlobalLogger logger
  result <- action
  closeSealLogger logger
  lines_ <- readIORef ref
  unsetGlobalLogger
  pure (result, lines_)

----------------------------------------------------------------------
-- ApiDeps construction (real repos.toml + fake vault)
----------------------------------------------------------------------

fakePaths :: SealPaths
fakePaths = SealPaths
  { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "test" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing Nothing Nothing Nothing
       (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

-- | Build 'ApiDeps' with a REAL 'mkRepoRegistryHandle' (writing to a real
-- @repos.toml@ in the temp dir) + an UNLOCKED fake in-memory vault. The
-- repo registry handle is returned alongside so the opcode's 'CloneDeps'
-- can reference the same handle (so @rrhList@ reads the same file the
-- POST wrote).
mkVaultDeps :: VaultRuntime -> FilePath -> IO (ApiDeps, RepoRegistryHandle)
mkVaultDeps vr tmp = do
  tabsH <- newTabsHandle
  reg   <- newHarnessRegistry
  adb   <- noneBackend
  skills <- Skill.noneBackend
  activeRef <- newIORef fakeMeta
  let paths = fakePaths { spState = tmp }
  uiState <- newUiStateHandle paths
  repoRegH <- mkRepoRegistryHandle (tmp </> "repos.toml")
  let sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
      deps = ApiDeps
        { adSessionRuntime  = sr
        , adTabsHandle      = tabsH
        , adHarnessRegistry = reg
        , adAdoptConsent    = Just CcWeb
        , adAgentDefs       = adb
        , adSkills          = skills
        , adProviders       = pure knownProviders
        , adUiState         = uiState
        , adSend            = Nothing
        , adDefaultAgent    = pure Nothing
        , adBroker          = Nothing
        , adTabCloseNotifier = noTabCloseNotifier
        , adRepoRegistry     = repoRegH
        , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
        , adVault            = vr
        , adPaths            = paths
        , adWsPort           = 8081
        , adAbortReg         = testAbortReg
        , adSecurityConfig   = defaultSecurityConfig
        , adMkSessionExec    = Nothing
        }
  pure (deps, repoRegH)

----------------------------------------------------------------------
-- Opcode + input
----------------------------------------------------------------------

-- | The BIN_EXEC opcode with a permissive policy (the test only exercises
-- the @gh@ branch, which is credential injection — not the authorize
-- gate).
testOp :: Opcode
testOp = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing

ghPrCreateInput :: A.Value
ghPrCreateInput = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= (["pr", "create"] :: [Text])
  ]

-- | Run the opcode against the recording 'UntrustedIO' + 'CloneDeps'.
runOp :: UntrustedIO -> CloneDeps -> Opcode -> A.Value -> IO OpResult
runOp uio deps op input =
  runUIOWithEnv (mkTestUIOEnv uio deps) (uoRun op input)

-- | Get the @n@th recorded exec (0-indexed) after asserting there are at
-- least @n+1@ entries. Test-only partial (the test owns the invariant).
getExec :: IORef [GhRecordedExec] -> Int -> IO GhRecordedExec
getExec ref idx = do
  recorded <- readIORef ref
  case drop idx recorded of
    (e : _) -> pure e
    _       -> error ("getExec: expected at least " <> show (idx + 1) <> " entries (test invariant violation)")

----------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Gateway.PatIngestion (cross-layer integration)" $ do

  it "POST /api/repos with token: \"xyz\" → 201; vault has xyz; repos.toml has no xyz; BIN_EXEC gh injects GH_TOKEN=xyz" $
    withSystemTempDirectory "seal-patingestion" $ \tmp -> do
      -- 1. Build ApiDeps with a real repos.toml + a fake (empty) vault.
      vr <- makeFakeVaultRuntime []
      (deps, repoRegH) <- mkVaultDeps vr tmp
      let app = apiApp deps

      -- 2. Capture gateway logs during the POST (defensive — no xyz leak).
      req <- testPost ["api", "repos"]
        (A.encode (A.object
          [ "id"       .= ("test" :: Text)
          , "url"      .= ("git@github.com:owner/test.git" :: Text)
          , "vcs_kind" .= ("github" :: Text)
          , "credential" .= A.object
              [ "kind"      .= ("pat" :: Text)
              , "vault_key" .= ("seal-pat-test" :: Text)
              ]
          , "token"    .= ("xyz" :: Text)
          ]))
      ((status, body), logLines) <- withCaptureGlobalLogger (runAppBody app req)

      -- 4. Assert response is 201 + no "xyz" in the response body.
      status `shouldBe` 201
      let bodyText = T.pack (BC.unpack (BL.toStrict body))
      "xyz" `T.isInfixOf` bodyText `shouldBe` False

      -- 9. Assert no log line contains "xyz" (defensive — reviewer B7).
      let allLogs = T.unlines logLines
      "xyz" `T.isInfixOf` allLogs `shouldBe` False

      -- 5. Assert the fake vault has "seal-pat-test" → "xyz".
      mh <- readIORef (vrHandleRef vr)
      case mh of
        Just vh -> vhGet vh "seal-pat-test" `shouldReturn` Right "xyz"
        Nothing -> expectationFailure "vault handle missing"

      -- 6. Assert repos.toml (the real file) does NOT contain "xyz".
      tomlExists <- doesFileExist (tmp </> "repos.toml")
      tomlExists `shouldBe` True
      tomlBytes <- BL.readFile (tmp </> "repos.toml")
      let tomlText = T.pack (BC.unpack (BL.toStrict tomlBytes))
      "xyz" `T.isInfixOf` tomlText `shouldBe` False

      -- 7-8. Build the BIN_EXEC opcode with a recording UntrustedIO whose
      -- CloneDeps share the same repo registry + vault, and dispatch
      -- `gh pr create`. The canned remote.origin.url matches the
      -- registered repo's URL (so the pre-flight finds it).
      seen <- newIORef []
      let registeredUrl = "git@github.com:owner/test.git\n"
          uio = ghFakeUio seen registeredUrl "done\n"
      cloneDeps <- mkPatCloneDeps vr repoRegH
      result <- runOp uio cloneDeps testOp ghPrCreateInput

      -- The opcode succeeds (the recording fake returns Right "done\n").
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]

      -- Two exec calls: pre-flight `git config --get remote.origin.url`,
      -- then `gh pr create` via uioBinExecEnv with GH_TOKEN.
      recorded <- readIORef seen
      length recorded `shouldBe` 2
      preflight <- getExec seen 0
      greBinary preflight `shouldBe` "git"
      greArgs preflight `shouldBe` ["config", "--get", "remote.origin.url"]
      greUsedPlain preflight `shouldBe` True
      ghExec <- getExec seen 1
      greBinary ghExec `shouldBe` "gh"
      greArgs ghExec `shouldBe` ["pr", "create"]
      greUsedEnv ghExec `shouldBe` True
      greUsedGitEnv ghExec `shouldBe` False
      greUsedPlain ghExec `shouldBe` False
      -- The key assertion: GH_TOKEN=xyz is in the env extras.
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Just "xyz"