{-# LANGUAGE OverloadedStrings #-}
-- | WU5 tests (plan rev 3, tests 18b–33): the setup routes and handlers.
--
-- These drive the real 'apiApp', so the mutation guard and the dispatch table
-- are exercised for real, over a temp-dir seal home. The provisioning core is
-- injected (keygen + encryptor are seams, the config writer is the production
-- narrow writer), which keeps the suite free of @age-keygen@ except for the one
-- end-to-end case, which is @pendingWith@ when the binaries are absent.
module Seal.Gateway.SetupApiSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64Url
import Data.ByteString.Builder qualified as BSB
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive (mk)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Control.Monad (forM_, when)
import Data.Maybe (fromMaybe, isJust)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Types
  ( Header, Status, methodGet, methodPost, statusCode )
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestHeaders
  , requestMethod, responseStatus, responseToStream
  , setRequestBodyChunks )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, findExecutable, removeFile )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend)
import Seal.Command.Tab (noTabCloseNotifier)
import Seal.Config.BootPlan
  ( BootPlan (..) )
import Seal.Config.File
  ( RuntimeConfig (..), updateRuntimeConfig )
import Seal.Config.Paths
  ( SealPaths (..), configFilePath, securityFilePath, sshAgentsDir, vaultFilePath )
import Seal.Config.Security
  ( CredentialFileConfig (..), SecurityConfig (..), defaultSecurityConfig
  , saveSecurityConfig, updateVaultKeySection, WriteMode (..) )
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Gateway.API (ApiDeps (..), apiApp)
import Seal.Gateway.AccessControl
  ( NewAccess (..), accessControlMiddleware, newAccessControlHandle )
import Seal.Gateway.Setup (SetupDeps (..))
import Seal.Gateway.Stream (StreamHealth (..))
import Seal.Git.Repo (openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Providers.Class (SomeProvider (..))
import Seal.Providers.Registry (KnownProvider (..))
import Seal.Security.AccessControl (credentialFromFile)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Vault
  ( UnlockMode (UnlockOnDemand), VaultConfig (..), VaultHandle (..), openVault )
import Seal.Security.Vault.Age (mkMockEncryptor)
import Seal.Security.WebAuthn.Types (AccessMode (..), Credential)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Skills.Backend qualified as Skill (noneBackend)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.Tabs (newTabsHandle)
import Seal.TestHelpers.FakeVault (makeFakeVault)
import Seal.TestHelpers.ScriptProvider (ScriptProvider (..))
import Seal.Tools.Exec.Abort (SessionAbortRegistry, newSessionAbortRegistry)
import Seal.Vault.Backend (ResolvedKey (..))
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Vault.Provision
  ( ProvisionDeps (..), ProvisionError (..), SetupEncryptor (..)
  , SetupKeygen (..), defaultProvisionDeps )
import Seal.Web.UiState (newUiStateHandle)

spec :: Spec
spec = describe "Seal.Gateway.Setup API" $ do

  describe "origin guard" $
    it "the setup routes are origin-guarded" $
      withHarness defaultHarness $ \h -> do
        getResp <- runApp (hApp h) =<< getReq "/api/setup" [origin "https://evil.example"]
        statusCode (responseStatus getResp) `shouldBe` 403
        postResp <- runApp (hApp h) =<< postJson "/api/setup/vault"
          [origin "https://evil.example"] "{\"backend\":\"local\"}"
        statusCode (responseStatus postResp) `shouldBe` 403
        -- Nothing ran: no vault file, no security.toml.
        doesFileExist (vaultFilePath (hPaths h)) `shouldReturn` False
        doesFileExist (securityFilePath (hPaths h)) `shouldReturn` False

  describe "GET /api/setup" $ do
    it "returns the documented shape" $
      withHarness defaultHarness $ \h -> do
        (status, hdrs, body) <- runAppBody (hApp h) =<< getReq "/api/setup" []
        statusCode status `shouldBe` 200
        lookup (mk "Cache-Control") hdrs `shouldBe` Just "no-store"
        body `shouldSatisfy` hasField "required_complete"
        body `shouldSatisfy` hasField "steps"
        body `shouldSatisfy` hasField "providers"
        body `shouldSatisfy` contains "\"vault\""
        body `shouldSatisfy` contains "\"provider\""
        -- Path-free: the temp home never appears in a web-readable body.
        body `shouldSatisfy` (not . contains (T.pack (spHome (hPaths h))))

    it "includes requires_base_url on each provider card" $
      withHarness defaultHarness $ \h -> do
        (_, _, body) <- runAppBody (hApp h) =<< getReq "/api/setup" []
        -- The generic OpenAI-compatible provider has no built-in endpoint,
        -- so its card must carry requires_base_url:true — without it the
        -- wizard never renders the endpoint field.
        body `shouldSatisfy` contains "\"openai\""
        body `shouldSatisfy` hasBoolField "requires_base_url" True
        -- Providers with a built-in endpoint (anthropic, ollama, openrouter)
        -- carry requires_base_url:false.
        body `shouldSatisfy` contains "\"anthropic\""
        body `shouldSatisfy` hasBoolField "requires_base_url" False

    it "never 500s on missing or undecodable files" $
      withHarness defaultHarness $ \h -> do
        let bad = "not = [valid toml"
        BS.writeFile (securityFilePath (hPaths h)) (TE.encodeUtf8 bad)
        BS.writeFile (configFilePath (hPaths h)) (TE.encodeUtf8 bad)
        (status, _, body) <- runAppBody (hApp h) =<< getReq "/api/setup" []
        statusCode status `shouldBe` 200
        body `shouldSatisfy` contains "blocked"

  describe "the passkey middleware" $
    it "the setup routes sit behind the passkey middleware" $
      withSystemTempDirectory "seal-setup-mw" $ \dir -> do
        let paths = testPaths dir
        createDirectoryIfMissing True (spConfig paths)
        unconfigured <- newAccessControlHandle paths unconfiguredPlan
        app <- harnessApp defaultHarness paths
        -- AccessUnconfigured: default-deny with the documented error code.
        respU <- runApp (accessControlMiddleware (naHandle unconfigured) app)
          =<< getReq "/api/setup" []
        statusCode (responseStatus respU) `shouldBe` 403
        forM_ ["/api/setup", "/api/setup/vault", "/api/setup/vault/reopen"] $ \path -> do
          r <- runApp (accessControlMiddleware (naHandle unconfigured) app)
                 =<< postJson path [] "{}"
          statusCode (responseStatus r) `shouldBe` 403
        -- AccessPasskey with no session: unauthenticated.
        passkey <- newAccessControlHandle paths passkeyPlan
        respP <- runApp (accessControlMiddleware (naHandle passkey) app)
          =<< getReq "/api/setup" []
        statusCode (responseStatus respP) `shouldBe` 401
        -- ...and reachable once the middleware authorises the caller. (The base
        -- branch admits a passkey session or the per-run service token; the
        -- token is the one a headless test can mint without a WebAuthn
        -- ceremony, and both land on the same decision.)
        respOK <- runApp (accessControlMiddleware (naHandle passkey) app)
          =<< getReq "/api/setup" [bearer (naServiceToken passkey)]
        statusCode (responseStatus respOK) `shouldBe` 200

  describe "POST /api/setup/vault" $ do
    it "local reports AlreadyExists when a key is recorded" $
      withHarness defaultHarness $ \h -> do
        recordKeyIn h Nothing
        resp <- runApp (hApp h) =<< postJson "/api/setup/vault" [] "{\"backend\":\"local\"}"
        statusCode (responseStatus resp) `shouldBe` 409

    it "resume succeeds where local is refused" $
      withHarness defaultHarness $ \h -> do
        recordKeyIn h Nothing
        local <- runApp (hApp h) =<< postJson "/api/setup/vault" [] "{\"backend\":\"local\"}"
        statusCode (responseStatus local) `shouldBe` 409
        resume <- runApp (hApp h) =<< postJson "/api/setup/vault" [] "{\"backend\":\"resume\"}"
        statusCode (responseStatus resume) `shouldBe` 201
        doesFileExist (vaultFilePath (hPaths h)) `shouldReturn` True

    it "maps ProvisionError to status codes" $
      withHarness defaultHarness $ \h -> do
        let post body = runApp (hApp h) =<< postJson "/api/setup/vault" [] body
        unknown <- post "{\"backend\":\"floppy\"}"
        statusCode (responseStatus unknown) `shouldBe` 400
        relative <- post
          "{\"backend\":\"user\",\"recipient\":\"age1qqq\",\"identity_path\":\"rel/keys.txt\"}"
        statusCode (responseStatus relative) `shouldBe` 400
        notJson <- post "not json"
        statusCode (responseStatus notJson) `shouldBe` 400
        -- 409: another setup holds the lock.
        let lockPath = securityFilePath (hPaths h) <> ".lock"
        BS.writeFile lockPath ""
        inProgress <- post "{\"backend\":\"local\"}"
        statusCode (responseStatus inProgress) `shouldBe` 409
        removeIfExists lockPath
        -- 422: the round-trip failed.
        withHarness defaultHarness { hcRoundTripFails = True } $ \h2 -> do
          r <- runApp (hApp h2) =<< postJson "/api/setup/vault" [] "{\"backend\":\"local\"}"
          statusCode (responseStatus r) `shouldBe` 422
        -- 422: the plugin needs a TTY.
        withHarness defaultHarness { hcYubiNeedsTty = True } $ \h3 -> do
          r <- runApp (hApp h3) =<< postJson "/api/setup/vault" [] "{\"backend\":\"yubikey\"}"
          statusCode (responseStatus r) `shouldBe` 422
        -- 500: the config write failed.
        withHarness defaultHarness { hcWriteFails = True } $ \h4 -> do
          r <- runApp (hApp h4) =<< postJson "/api/setup/vault" [] "{\"backend\":\"local\"}"
          statusCode (responseStatus r) `shouldBe` 500

    it "rejects a non-JSON content type" $
      withHarness defaultHarness $ \h -> do
        resp <- runApp (hApp h) =<< postWith "/api/setup/vault"
          [(mk "Content-Type", "text/plain")] "{\"backend\":\"local\"}"
        statusCode (responseStatus resp) `shouldBe` 415

    it "a setup body over the cap is rejected" $
      withHarness defaultHarness $ \h -> do
        resp <- runApp (hApp h) =<< postWith "/api/setup/vault"
          [(mk "Content-Type", "application/json")]
          ("{\"backend\":\"local\",\"pad\":\"" <> BS.replicate 9000 97 <> "\"}")
        statusCode (responseStatus resp) `shouldBe` 413

    it "the yubikey TTY path returns a runnable hint" $
      withHarness defaultHarness { hcYubiNeedsTty = True } $ \h -> do
        (status, _, body) <- runAppBody (hApp h)
          =<< postJson "/api/setup/vault" [] "{\"backend\":\"yubikey\"}"
        statusCode status `shouldBe` 422
        body `shouldSatisfy` contains "hint"
        body `shouldSatisfy` contains ".seal/keys"
        body `shouldSatisfy` contains "--touch-policy always"
        body `shouldSatisfy` contains "--pin-policy once"
        -- No key material, ever.
        body `shouldSatisfy` (not . contains "age1")

    it "the local backend end to end" $
      withHarness defaultHarness { hcRealProvisioning = True } $ \h -> do
        mKeygen <- findExecutable "age-keygen"
        mAge <- findExecutable "age"
        case (mKeygen, mAge) of
          (Just _, Just _) -> do
            (status, _, body) <- runAppBody (hApp h)
              =<< postJson "/api/setup/vault" [] "{\"backend\":\"local\"}"
            statusCode status `shouldBe` 201
            body `shouldSatisfy` contains "\"recipient\""
            body `shouldSatisfy` contains "\"key_type\":\"x25519\""
            -- The identity path is never in a response.
            body `shouldSatisfy` (not . contains "identity")
            -- ...and the wizard's vault step is now ready.
            (gStatus, _, gBody) <- runAppBody (hApp h) =<< getReq "/api/setup" []
            statusCode gStatus `shouldBe` 200
            gBody `shouldSatisfy` contains "\"ready\""
          _ -> pendingWith "age-keygen/age not on PATH"

  describe "POST /api/setup/vault/reopen" $ do
    it "reports no key, no file, unreadable" $
      withHarness defaultHarness $ \h -> do
        r1 <- runApp (hApp h) =<< postJson "/api/setup/vault/reopen" [] "{}"
        statusCode (responseStatus r1) `shouldBe` 409
        recordKeyIn h Nothing
        r2 <- runApp (hApp h) =<< postJson "/api/setup/vault/reopen" [] "{}"
        statusCode (responseStatus r2) `shouldBe` 409
        -- Present but not decryptable by the recorded key.
        BS.writeFile (vaultFilePath (hPaths h)) "ciphertext-from-another-key"
        (status3, _, body3) <- runAppBody (hApp h)
          =<< postJson "/api/setup/vault/reopen" [] "{}"
        statusCode status3 `shouldBe` 422
        body3 `shouldSatisfy` contains "hint"
        body3 `shouldSatisfy` contains "identity"

    it "opens and unlocks a startup-mode vault" $
      withHarness defaultHarness $ \h -> do
        writeMockVault h
        recordKeyIn h (Just "startup")
        (status, _, body) <- runAppBody (hApp h)
          =<< postJson "/api/setup/vault/reopen" [] "{}"
        statusCode status `shouldBe` 200
        body `shouldSatisfy` hasBoolField "opened" True
        body `shouldSatisfy` hasBoolField "locked" False
        (isJust <$> readIORef (hRef h)) `shouldReturn` True

  describe "POST /api/providers/:name/test" $ do
    it "uses the resolver seam" $
      withHarness defaultHarness $ \h -> do
        publishHandle h
        (okStatus, _, okBody) <- runAppBody (hApp h)
          =<< postJson "/api/providers/ollama/test" [] "{}"
        statusCode okStatus `shouldBe` 200
        okBody `shouldSatisfy` hasBoolField "ok" True
        unknown <- runApp (hApp h) =<< postJson "/api/providers/nope/test" [] "{}"
        statusCode (responseStatus unknown) `shouldBe` 400
        -- A provider failure is a 200 with ok:false, not an HTTP error.
        withHarness defaultHarness { hcResolverFails = True } $ \h2 -> do
          publishHandle h2
          (s2, _, b2) <- runAppBody (hApp h2)
            =<< postJson "/api/providers/ollama/test" [] "{}"
          statusCode s2 `shouldBe` 200
          b2 `shouldSatisfy` hasBoolField "ok" False
          b2 `shouldSatisfy` contains "error"

    it "answers 500 when the vault is not open" $
      withHarness defaultHarness $ \h -> do
        resp <- runApp (hApp h) =<< postJson "/api/providers/ollama/test" [] "{}"
        statusCode (responseStatus resp) `shouldBe` 500

    it "re-reads config" $
      withHarness defaultHarness $ \h -> do
        publishHandle h
        _ <- runApp (hApp h) =<< postJson "/api/providers/ollama/test" [] "{}"
        updateRuntimeConfig (configFilePath (hPaths h))
          (\cfg -> cfg { rcDefaultModel = Just "llama3.2:70b" })
          `shouldReturn` Right ()
        _ <- runApp (hApp h) =<< postJson "/api/providers/ollama/test" [] "{}"
        calls <- readIORef (hCalls h)
        map (modelText . snd) (reverse calls) `shouldBe` ["llama3.2", "llama3.2:70b"]

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

data HarnessConfig = HarnessConfig
  { hcCanonical        :: Maybe Text
  , hcRoundTripFails   :: Bool
  , hcWriteFails       :: Bool
  , hcYubiNeedsTty     :: Bool
  , hcRealProvisioning :: Bool
  , hcResolverFails    :: Bool
  }

defaultHarness :: HarnessConfig
defaultHarness = HarnessConfig
  { hcCanonical = Just canonical
  , hcRoundTripFails = False
  , hcWriteFails = False
  , hcYubiNeedsTty = False
  , hcRealProvisioning = False
  , hcResolverFails = False
  }

data Harness = Harness
  { hApp   :: Application
  , hPaths :: SealPaths
  , hRef   :: IORef (Maybe VaultHandle)
  , hCalls :: IORef [(KnownProvider, ModelId)]
  }

withHarness :: HarnessConfig -> (Harness -> IO a) -> IO a
withHarness config action =
  withSystemTempDirectory "seal-setup-api" $ \dir -> do
    let paths = testPaths dir
    createDirectoryIfMissing True (spConfig paths)
    createDirectoryIfMissing True (dir </> "config" </> "vault")
    ref <- newIORef Nothing
    calls <- newIORef []
    app <- harnessAppWith config paths ref calls
    action Harness { hApp = app, hPaths = paths, hRef = ref, hCalls = calls }

harnessApp :: HarnessConfig -> SealPaths -> IO Application
harnessApp config paths = do
  ref <- newIORef Nothing
  calls <- newIORef []
  harnessAppWith config paths ref calls

harnessAppWith
  :: HarnessConfig -> SealPaths
  -> IORef (Maybe VaultHandle) -> IORef [(KnownProvider, ModelId)]
  -> IO Application
harnessAppWith config paths ref calls = do
  tabsH <- newTabsHandle
  reg <- newHarnessRegistry
  adb <- noneBackend
  skills <- Skill.noneBackend
  activeRef <- newIORef fakeMeta
  uiState <- newUiStateHandle paths
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir paths)
  script <- newIORef []
  let sr = SessionRuntime
        { srPaths = paths
        , srConfigPath = configFilePath paths
        , srActive = activeRef
        }
      repoRegH = RepoRegistryHandle
        { rrhList = pure (Right [])
        , rrhMutate = \_ -> pure (Right ())
        }
      rt = VaultRuntime
        { vrPaths = paths
        , vrConfigPath = configFilePath paths
        , vrHandleRef = ref
        }
      resolver known model = do
        modifyIORef' calls ((known, model) :)
        pure $ if hcResolverFails config
          then Left "provider refused"
          else Right (SomeProvider (ScriptProvider script))
      deps = ApiDeps
        { adSessionRuntime = sr
        , adTabsHandle = tabsH
        , adHarnessRegistry = reg
        , adAdoptConsent = Just CcWeb
        , adAgentDefs = adb
        , adSkills = skills
        , adProviders = pure []
        , adUiState = uiState
        , adSend = Nothing
        , adDefaultAgent = pure Nothing
        , adBroker = Nothing
        , adTabCloseNotifier = noTabCloseNotifier
        , adRepoRegistry = repoRegH
        , adAgentRegistry = agentRegH
        , adConfigRepo = openConfigRepo "/tmp/nonexistent-seal-test"
        , adVault = rt
        , adPaths = paths
        , adCanonicalOrigin = hcCanonical config
        , adSetup = SetupDeps
            { sdProvision = provisionDepsFor config paths
            , sdResolveProvider = resolver
            }
        , adWsHealth = pure (StreamHealth "up" 8081)
        , adSecurityConfig = defaultSecurityConfig
        , adMkSessionExec = Nothing
        , adAbortReg = testAbortReg
        }
  pure (apiApp deps)

-- | The provisioning deps the handlers see. Keygen and encryptor are seams;
-- the config writer is the production narrow writer.
provisionDepsFor :: HarnessConfig -> SealPaths -> ProvisionDeps
provisionDepsFor config paths
  | hcRealProvisioning config = defaultProvisionDeps paths
  | otherwise = ProvisionDeps
      { pdKeygen = SetupKeygen
          { skLocal = pure (Right testKey)
          , skYubi  = \_ touch pin ->
              if hcYubiNeedsTty config
                then pure (Left (ProvisionNeedsTty
                  ("age-plugin-yubikey --generate --touch-policy "
                    <> (if touch then "always" else "never")
                    <> " --pin-policy " <> (if pin then "once" else "never")
                    <> " > '~/.seal/keys/default.yubikey.txt'")))
                else pure (Right testKey)
          , skUser = \_ _ -> Right testKey
          }
      , pdEncryptor = SetupEncryptor
          { seMk = \_ _ -> pure (Right mkMockEncryptor)
          , seVerify = \_ -> if hcRoundTripFails config
              then pure (Left "nonce mismatch")
              else pure (Right ())
          }
      , pdWriteConfig =
          if hcWriteFails config
            then \_ -> pure (Left "security.toml is unreadable")
            else updateVaultKeySection (securityFilePath paths)
      , pdLockPath = securityFilePath paths <> ".lock"
      }

-- | Publish a live handle so the provider-test handler finds an open vault.
publishHandle :: Harness -> IO ()
publishHandle h = makeFakeVault [] >>= \handle -> writeIORef (hRef h) (Just handle)

-- | Write a vault file the mock encryptor can open, so the reopen path has
-- something real to decrypt.
writeMockVault :: Harness -> IO ()
writeMockVault h = do
  handle <- openVault
    (VaultConfig (vaultFilePath (hPaths h)) "x25519" UnlockOnDemand)
    mkMockEncryptor
  _ <- vhInit handle
  pure ()

-- | Record the vault key on disk, optionally with an unlock mode.
recordKeyIn :: Harness -> Maybe Text -> IO ()
recordKeyIn h unlockMode = do
  saveSecurityConfig (securityFilePath (hPaths h))
    (defaultSecurityConfig
       { scVaultRecipient = Just testRecipient
       , scVaultIdentity  = Just (rkIdentity testKey)
       , scVaultKeyType   = Just "x25519"
       , scVaultUnlock    = unlockMode
       })
    PreserveCredentials `shouldReturn` Right ()

-- ---------------------------------------------------------------------------
-- Access-control plans
-- ---------------------------------------------------------------------------

unconfiguredPlan :: BootPlan
unconfiguredPlan = BootPlan
  { bpMode = AccessUnconfigured
  , bpOrigin = Nothing
  , bpRpId = Nothing
  , bpCreds = Map.empty
  , bpMintGrant = Nothing
  }

passkeyPlan :: BootPlan
passkeyPlan = BootPlan
  { bpMode = AccessPasskey
  , bpOrigin = Just canonical
  , bpRpId = Just "localhost"
  , bpCreds = runtimeCreds (BS.replicate 16 0x11) (BS.replicate 64 0x02)
  , bpMintGrant = Nothing
  }

runtimeCreds :: ByteString -> ByteString -> Map.Map Text Credential
runtimeCreds credId key64 =
  case traverse credentialFromFile (Map.toList (credMap credId key64)) of
    Right kvs -> Map.fromList kvs
    Left e    -> error ("fixture credential must decode: " <> T.unpack e)

credMap :: ByteString -> ByteString -> Map.Map Text CredentialFileConfig
credMap credId key64 = Map.singleton (b64 credId) CredentialFileConfig
  { cfcPublicKey = b64 key64
  , cfcSignCount = 1
  , cfcLabel = "test key"
  , cfcCreatedAt = "2026-10-30T14:00:00Z"
  , cfcRpId = "localhost"
  , cfcAddedVia = Nothing
  }

b64 :: ByteString -> Text
b64 = TE.decodeUtf8 . B64Url.encodeUnpadded

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

canonical :: Text
canonical = "http://localhost:8080"

testRecipient :: Text
testRecipient = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqysq0"

testKey :: ResolvedKey
testKey = ResolvedKey
  { rkRecipient = testRecipient
  , rkIdentity  = "/nonexistent/test/default.identity"
  , rkKeyType   = "x25519"
  }

testPaths :: FilePath -> SealPaths
testPaths dir = SealPaths
  { spHome   = dir
  , spConfig = dir </> "config"
  , spState  = dir </> "state"
  , spKeys   = dir </> "keys"
  , spCache  = dir </> "cache"
  }

origin :: Text -> Header
origin t = (mk "Origin", TE.encodeUtf8 t)

bearer :: Text -> Header
bearer t = (mk "Authorization", TE.encodeUtf8 ("Bearer " <> t))

getReq :: Text -> [Header] -> IO Request
getReq path hdrs = request methodGet path hdrs Nothing

postJson :: Text -> [Header] -> ByteString -> IO Request
postJson path hdrs body =
  request methodPost path ((mk "Content-Type", "application/json") : hdrs) (Just body)

postWith :: Text -> [Header] -> ByteString -> IO Request
postWith path hdrs body = request methodPost path hdrs (Just body)

-- | A one-shot body request: the first read returns the bytes, the next EOF.
request :: ByteString -> Text -> [Header] -> Maybe ByteString -> IO Request
request mth path hdrs mbody = do
  used <- newIORef False
  let readChunk = do
        already <- readIORef used
        if already
          then pure BS.empty
          else writeIORef used True >> pure (fromMaybe BS.empty mbody)
  pure $ setRequestBodyChunks readChunk defaultRequest
    { requestMethod = mth
    , pathInfo = splitPath path
    , requestHeaders = hdrs
    }

splitPath :: Text -> [Text]
splitPath = filter (not . T.null) . T.splitOn "/" . T.dropWhile (== '/')

runApp :: Application -> Request -> IO Response
runApp app req = do
  mv <- newEmptyMVar
  _ <- app req (\resp -> putMVar mv resp >> pure ResponseReceived)
  takeMVar mv

runAppBody :: Application -> Request -> IO (Status, [Header], BL.ByteString)
runAppBody app req = do
  mv <- newEmptyMVar
  _ <- app req $ \resp -> do
    let (st, hdrs, withBody) = responseToStream resp
    ref <- newIORef []
    withBody $ \streamingBody ->
      streamingBody (\builder -> modifyIORef' ref (builder :)) (pure ())
    builders <- readIORef ref
    putMVar mv (st, hdrs, BSB.toLazyByteString (mconcat (reverse builders)))
    pure ResponseReceived
  takeMVar mv

hasField :: Text -> BL.ByteString -> Bool
hasField name = contains ("\"" <> name <> "\"")

hasBoolField :: Text -> Bool -> BL.ByteString -> Bool
hasBoolField name value =
  contains ("\"" <> name <> "\":" <> (if value then "true" else "false"))

contains :: Text -> BL.ByteString -> Bool
contains needle haystack =
  T.isInfixOf needle (TE.decodeUtf8Lenient (BL.toStrict haystack))

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  when exists (removeFile path)

modelText :: ModelId -> Text
modelText (ModelId m) = m

-- ---------------------------------------------------------------------------
-- Shared fixtures
-- ---------------------------------------------------------------------------

testAbortReg :: SessionAbortRegistry
testAbortReg = unsafePerformIO newSessionAbortRegistry
{-# NOINLINE testAbortReg #-}

fakeMeta :: SessionMeta
fakeMeta =
  let sid' = case mkSessionId "test" of
        Right s -> s
        Left e  -> error ("test session id: " <> show e)
  in SessionMeta sid' "ollama" "llama3" "cli" Nothing Nothing Nothing Nothing Nothing True
       Nothing Nothing
       (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)
