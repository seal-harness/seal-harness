{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ModelSpec (spec) where

import Data.Either (fromRight)
import Data.IORef (newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.ByteString qualified as BS
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (status200)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Model (ModelTranscriptWriter, modelCommandSpec, modelCommandSpecForSession, mkModelTranscriptWriter, noModelTranscriptWriter)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.File
  (ProviderConfig (..), loadRuntimeConfig, providerDefaultModel, updateRuntimeConfig, upsertProvider)
import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Core.TurnEngine (loadSessionMeta)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Security.Vault (VaultHandle)
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.TestHelpers.FakeVault (makeFakeVault)
import Seal.Transcript.Conv (readConversation)
import Seal.Vault.Commands (VaultRuntime (..))

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

mkSR :: FilePath -> IO SessionRuntime
mkSR root = do
  let sid = fromRight (error "invalid session id") (mkSessionId "20260701-120000-002")
      m0 = SessionMeta sid "anthropic" "claude-opus-4-8" "cli" Nothing Nothing Nothing Nothing aTime aTime
      paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys") (root </> "cache")
  ref <- newIORef m0
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

mkPR :: FilePath -> Maybe VaultHandle -> IO ProviderRuntime
mkPR cfgPath mvh = do
  ref <- newIORef mvh
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath cfgPath
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr, prCallCounter = cntRef }

runModel :: ProviderRuntime -> SessionRuntime -> [String] -> ChannelCaps -> IO ()
runModel pr sr argv caps =
  case execParserPure defaultPrefs (csParserInfo (modelCommandSpec pr sr noModelTranscriptWriter)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

-- | Run /model against a per-sid spec (the web-gateway / channel-loop shape),
-- closing over an explicit SessionId rather than srActive.
runModelForSession
  :: ProviderRuntime -> SealPaths -> IO SessionId
  -> Maybe ModelTranscriptWriter -> [String] -> ChannelCaps -> IO ()
runModelForSession pr paths resolveSid mWriter argv caps =
  let writer = fromMaybe noModelTranscriptWriter mWriter
      cmdSpec = modelCommandSpecForSession pr paths resolveSid writer
  in case execParserPure defaultPrefs (csParserInfo cmdSpec) argv of
       Success act -> runCommandAction act caps
       _           -> expectationFailure ("parse failed: " <> show argv)

-- | Run a mock ollama @/api/tags@ server on an ephemeral port for the
-- duration of the action, yielding the chosen port.
bracketMockOllama :: Network.Wai.Application -> (Int -> IO a) -> IO a
bracketMockOllama app =
  Network.Wai.Handler.Warp.testWithApplication (pure app)

-- | Variant of 'mkPR' that points ollama at a specific base URL (the mock
-- daemon). Writes the base URL into the config so 'listCmd' resolves it.
mkPRWithOllama :: FilePath -> VaultHandle -> Int -> IO ProviderRuntime
mkPRWithOllama cfgPath vh port = do
  ref <- newIORef (Just vh)
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath cfgPath
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
      baseUrl = "http://localhost:" <> T.pack (show port)
  _ <- updateRuntimeConfig cfgPath
         (upsertProvider "ollama" (\p -> p { pcBaseUrl = Just baseUrl }))
  pure ProviderRuntime
    { prConfigPath  = cfgPath
    , prVault       = vrt
    , prManager     = mgr
    , prCallCounter = cntRef
    }

spec :: Spec
spec = describe "Seal.Command.Model" $ do
  it "list shows configured providers and the active selection" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      -- No vault ⇒ only the keyless local ollama is configured; anthropic is
      -- hidden until a credential is stored. (The active line may still
      -- mention anthropic as the session's current provider.)
      let out = T.unlines sent
      out `shouldSatisfy` ("ollama" `T.isInfixOf`)
      out `shouldNotSatisfy` ("anthropic (default model" `T.isInfixOf`)
      out `shouldNotSatisfy` ("anthropic models (live)" `T.isInfixOf`)
      out `shouldSatisfy` ("active" `T.isInfixOf`)

  it "use updates the active selection and persists it" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["use", "anthropic", "claude-haiku-4-5"] caps
      active <- readIORef (srActive sr)
      smProvider active `shouldBe` "anthropic"
      smModel active    `shouldBe` "claude-haiku-4-5"
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("claude-haiku-4-5" `T.isInfixOf`)

  it "rejects an unknown provider without mutating the session" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["use", "bogus", "x"] caps
      active <- readIORef (srActive sr)
      smModel active `shouldBe` "claude-opus-4-8"   -- unchanged
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("unknown provider" `T.isInfixOf`)

  it "list <provider> rejects an unknown provider before any resolution" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list", "bogus"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("unknown provider" `T.isInfixOf`)

  it "list anthropic with no vault configured reports the resolve error" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list", "anthropic"] caps
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("could not list anthropic models" `T.isInfixOf`)
      out `shouldSatisfy` ("vault not configured" `T.isInfixOf`)

  it "default sets a provider's section default model" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["default", "ollama", "glm-5.2:cloud"] caps
      Right cfg <- loadRuntimeConfig (srConfigPath sr)
      providerDefaultModel cfg "ollama" `shouldBe` Just "glm-5.2:cloud"
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("glm-5.2:cloud" `T.isInfixOf`)

  it "use without a model uses the provider's default" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      _ <- updateRuntimeConfig (srConfigPath sr)
             (upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "glm-5.2:cloud" }))
      (_, caps) <- makeFakeCaps []
      runModel pr sr ["use", "ollama"] caps
      active <- readIORef (srActive sr)
      smProvider active `shouldBe` "ollama"
      smModel active    `shouldBe` "glm-5.2:cloud"

  it "use without a model and no config falls back to the hardcoded default" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      (_, caps) <- makeFakeCaps []
      runModel pr sr ["use", "ollama"] caps
      active <- readIORef (srActive sr)
      smModel active `shouldBe` "llama3.2"

  it "list shows a configured section default" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      _ <- updateRuntimeConfig (srConfigPath sr)
             (upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "glm-5.2:cloud" }))
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("glm-5.2:cloud" `T.isInfixOf`)

  it "list excludes providers that are not configured (no anthropic without a credential)" $
    withSystemTempDirectory "seal-model" $ \root -> do
      vh <- makeFakeVault []
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") (Just vh)
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("ollama" `T.isInfixOf`)
      out `shouldNotSatisfy` ("anthropic (default model" `T.isInfixOf`)
      out `shouldNotSatisfy` ("anthropic models (live)" `T.isInfixOf`)
      out `shouldSatisfy` ("active" `T.isInfixOf`)

  it "list includes anthropic once a credential is stored" $
    withSystemTempDirectory "seal-model" $ \root -> do
      vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-x")]
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") (Just vh)
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)

  it "list shows live ollama models from a running daemon" $
    withSystemTempDirectory "seal-model" $ \root -> do
      -- A mock ollama /api/tags endpoint on an ephemeral port.
      let tagsBody =
            "{\"models\":[{\"name\":\"llama3.2\"},{\"name\":\"glm-5.2:cloud\"}]}"
          app _req respond = respond (responseLBS status200 [] tagsBody)
      bracketMockOllama app $ \port -> do
        vh <- makeFakeVault []
        sr <- mkSR root
        pr <- mkPRWithOllama (root </> "config.toml") vh port
        (fc, caps) <- makeFakeCaps []
        runModel pr sr ["list"] caps
        sent <- getSent fc
        let out = T.unlines sent
        out `shouldSatisfy` ("ollama" `T.isInfixOf`)
        out `shouldSatisfy` ("llama3.2" `T.isInfixOf`)
        out `shouldSatisfy` ("glm-5.2:cloud" `T.isInfixOf`)

  it "list still reports ollama when the daemon is unreachable (live fetch fails gracefully)" $
    withSystemTempDirectory "seal-model" $ \root -> do
      vh <- makeFakeVault []
      sr <- mkSR root
      pr <- mkPRWithOllama (root </> "config.toml") vh 1 -- nothing on port 1
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("ollama" `T.isInfixOf`)

  -- ── Per-turn session targeting (the web-gateway / channel-loop shape) ──
  -- /model use must mutate the session bound to the resolver, NOT the
  -- process-global srActive. This is the regression guard for the Telegram
  -- "model change lost on the next turn" bug.

  let mkPaths root = SealPaths root (root </> "state") (root </> "config")
                                (root </> "keys") (root </> "cache")
      mkSid s = case mkSessionId s of Right x -> x; Left _ -> error "bad sid"

  it "model use via modelCommandSpecForSession targets the resolved session, not srActive" $
    withSystemTempDirectory "seal-model-forsession" $ \root -> do
      let paths = mkPaths root
      pr <- mkPR (root </> "config.toml") Nothing
      -- Two sessions on disk; srActive points at "active", but the resolver
      -- points at "target". /model use must update "target"'s session.json.
      let activeSid = mkSid "20260825-120000-active"
          targetSid = mkSid "20260825-120000-target"
      saveSessionMeta paths (SessionMeta activeSid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing aTime aTime)
      saveSessionMeta paths (SessionMeta targetSid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing aTime aTime)
      (fc, caps) <- makeFakeCaps []
      runModelForSession pr paths (pure targetSid) Nothing ["use","ollama","qwen3.8"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("session model set to ollama/qwen3.8" `T.isInfixOf`)
      -- The TARGET session's on-disk meta must reflect the new model.
      mTarget <- loadSessionMeta paths targetSid
      smModel (fromMaybe (error "target meta missing") mTarget) `shouldBe` "qwen3.8"
      -- The ACTIVE session's meta must be UNCHANGED.
      mActive <- loadSessionMeta paths activeSid
      smModel (fromMaybe (error "active meta missing") mActive) `shouldBe` "llama3.2"

  it "model use persists the change to disk (survives a restart / re-load)" $
    withSystemTempDirectory "seal-model-persist" $ \root -> do
      let paths = mkPaths root
      pr <- mkPR (root </> "config.toml") Nothing
      let sid = mkSid "20260825-120000-persist"
      saveSessionMeta paths (SessionMeta sid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing aTime aTime)
      (fc, caps) <- makeFakeCaps []
      runModelForSession pr paths (pure sid) Nothing ["use","ollama","glm-5.2:cloud"] caps
      _ <- getSent fc
      -- Re-load from disk as a fresh process would.
      mMeta <- loadSessionMeta paths sid
      smProvider (fromMaybe (error "meta missing") mMeta) `shouldBe` "ollama"
      smModel    (fromMaybe (error "meta missing") mMeta) `shouldBe` "glm-5.2:cloud"

  it "model use with a transcript writer records an EKResponse entry in the session's transcript" $
    withSystemTempDirectory "seal-model-transcript" $ \root -> do
      let paths = mkPaths root
      pr <- mkPR (root </> "config.toml") Nothing
      let sid = mkSid "20260825-120000-transcript"
      saveSessionMeta paths (SessionMeta sid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing aTime aTime)
      (fc, caps) <- makeFakeCaps []
      let writer = mkModelTranscriptWriter paths Nothing
      runModelForSession pr paths (pure sid) (Just writer) ["use","ollama","qwen3.8"] caps
      _ <- getSent fc
      -- The transcript's conversation.jsonl must contain the confirmation as
      -- an assistant message.
      let convPath = sessionDir paths sid </> "conversation.jsonl"
      raw <- BS.readFile convPath
      let msgs = readConversation raw
      case [ t | m <- msgs, msgRole m == Assistant, CbText t <- msgContent m ] of
        (t : _) -> t `shouldSatisfy` ("session model set to ollama/qwen3.8" `T.isInfixOf`)
        []      -> expectationFailure "no assistant confirmation in the transcript — /model use did not write to the transcript"

  it "model use against a missing session.json reports 'no active session' and does not crash" $
    withSystemTempDirectory "seal-model-nosession" $ \root -> do
      let paths = mkPaths root
      pr <- mkPR (root </> "config.toml") Nothing
      let sid = mkSid "20260825-120000-missing"  -- never seeded on disk
      (fc, caps) <- makeFakeCaps []
      runModelForSession pr paths (pure sid) Nothing ["use","ollama","qwen3.8"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("no active session" `T.isInfixOf`)
