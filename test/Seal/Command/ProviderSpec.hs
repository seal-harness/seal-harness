{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ProviderSpec (spec) where

import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.Either (fromRight, isLeft)
import Data.IORef (newIORef)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Provider
  ( AddPlan (..), BaseUrlPrompt (..), KeyPrompt (..), ProviderRuntime (..)
  , addPlanFor, formatTestResult, pingRequest, providerCommandSpec
  , resolveDefProvider, resolveSessionProvider )
import Seal.Command.Spec (CommandSpec (..), mkRegistry, runCommandAction)
import Data.Map.Strict qualified as Map
import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), loadRuntimeConfig, providerBaseUrl
  , providerDefaultModel, updateRuntimeConfig, upsertProvider )
import Seal.Providers.OpenAICompat (OpenAICompatSpec (..))
import Seal.Providers.Registry (KnownProvider (..), genericOpenAICompat)
import Seal.Config.Paths (SealPaths (..))
import Seal.Session.Meta (SessionMeta (..))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..)
  , StopReason (..), ToolChoice (..), Usage (..) )
import Seal.Security.Vault (VaultHandle, vhGet)
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.TestHelpers.FakeVault (makeFakeVault)
import Seal.Vault.Commands (VaultRuntime (..))

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

mkPR :: FilePath -> Maybe VaultHandle -> IO ProviderRuntime
mkPR cfgPath mvh = do
  ref <- newIORef mvh
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath cfgPath   -- unused by /provider
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr, prCallCounter = cntRef }

runProv :: ProviderRuntime -> [String] -> ChannelCaps -> IO ()
runProv pr argv caps =
  case execParserPure defaultPrefs (csParserInfo (providerCommandSpec pr)) argv of
    Success act         -> void (runCommandAction act caps)
    Failure _           -> expectationFailure ("parse failed: " <> show argv)
    CompletionInvoked _ -> expectationFailure "unexpected completion"

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec_main :: Spec
spec_main = do
  describe "Seal.Command.Provider helpers" $ do
    describe "pingRequest" $ do
      it "uses the given model, one message, no tools, a small token cap" $ do
        let req = pingRequest (ModelId "claude-opus-4-8")
        crModel req      `shouldBe` ModelId "claude-opus-4-8"
        length (crMessages req) `shouldBe` 1
        crTools req      `shouldBe` []
        crToolChoice req `shouldBe` ToolNone
        crMaxTokens req  `shouldSatisfy` (> 0)

    describe "formatTestResult" $ do
      it "reports success with the output-token count" $ do
        let r = formatTestResult "anthropic"
                  (Right (CompletionResponse [] StopEnd (Usage 3 7)))
        r `shouldSatisfy` ("anthropic" `T.isInfixOf`)
        r `shouldSatisfy` ("OK" `T.isInfixOf`)
        r `shouldSatisfy` ("7" `T.isInfixOf`)

      it "reports failure with the error text" $ do
        let r = formatTestResult "anthropic" (Left "boom")
        r `shouldSatisfy` ("FAILED" `T.isInfixOf`)
        r `shouldSatisfy` ("boom" `T.isInfixOf`)

  describe "/provider commands" $ do
    it "add stores the key and seeds defaults when unset" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (fc, caps) <- makeFakeCaps ["sk-secret"]
        runProv pr ["add", "anthropic"] caps
        vhGet vh "ANTHROPIC_API_KEY" >>= (`shouldBe` Right ("sk-secret" :: ByteString))
        Right cfg <- loadRuntimeConfig cfgPath
        rcDefaultProvider cfg `shouldBe` Just "anthropic"
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
        sent <- getSent fc
        sent `shouldSatisfy` any ("Configured anthropic" `T.isInfixOf`)

    it "list marks the default and shows credential presence" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk")]
        pr <- mkPR cfgPath (Just vh)
        (_, addCaps)  <- makeFakeCaps ["sk2"]      -- not used; ensures defaults
        runProv pr ["add", "anthropic"] addCaps     -- sets default_provider
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("default" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("api-key" `T.isInfixOf`)

    it "remove deletes the credential and clears a matching default" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk")]
        pr <- mkPR cfgPath (Just vh)
        (_, addCaps) <- makeFakeCaps ["sk"]
        runProv pr ["add", "anthropic"] addCaps      -- sets default
        (fc, caps) <- makeFakeCaps []
        runProv pr ["remove", "anthropic"] caps
        vhGet vh "ANTHROPIC_API_KEY" >>= (`shouldSatisfy` either (const True) (const False))
        Right cfg <- loadRuntimeConfig cfgPath
        rcDefaultProvider cfg `shouldBe` Nothing
        sent <- getSent fc
        sent `shouldSatisfy` any ("Removed" `T.isInfixOf`)

    it "list reports auth: oauth when an OAuth blob is stored" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", "{}")]
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        any ("oauth" `T.isInfixOf`) out `shouldBe` True

    it "list reports auth: api-key when only an API key is stored" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-x")]
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        any ("api-key" `T.isInfixOf`) out `shouldBe` True

    it "list reports auth: none when nothing is stored" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        any ("none" `T.isInfixOf`) out `shouldBe` True

    it "list shows every provider with its status (unconfigured included)" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- T.unlines <$> getSent fc
        -- Listing all providers answers "why doesn't my provider appear?":
        -- anthropic has no credential, ollama is keyless-local, the generic
        -- row has no base URL yet.
        out `shouldSatisfy` ("anthropic" `T.isInfixOf`)
        out `shouldSatisfy` ("anthropic \x2014 auth: none" `T.isInfixOf`)
        out `shouldSatisfy` ("ollama \x2014 auth: keyless" `T.isInfixOf`)
        out `shouldSatisfy` ("openai-compat \x2014 auth: none, base URL: not set"
                               `T.isInfixOf`)

    it "list shows anthropic when an API key is stored" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-x")]
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        T.unlines out `shouldSatisfy` ("anthropic" `T.isInfixOf`)

    it "list reports a cloud Ollama without a key as unconfigured" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
            unconfiguredOllama =
              "[providers.ollama]\nbase_url = \"https://ollama.com\"\n"
        _ <- appendFile cfg unconfiguredOllama
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("ollama \x2014 auth: none" `T.isInfixOf`)

    it "remove clears BOTH the API key and the OAuth blob" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault
                [ ("ANTHROPIC_API_KEY",      "sk-x")
                , ("ANTHROPIC_OAUTH_TOKENS", "{}")
                ]
        pr <- mkPR cfg (Just vh)
        (_, caps) <- makeFakeCaps []
        runProv pr ["remove", "anthropic"] caps
        gotKey <- vhGet vh "ANTHROPIC_API_KEY"
        gotTok <- vhGet vh "ANTHROPIC_OAUTH_TOKENS"
        gotKey `shouldSatisfy` isLeft
        gotTok `shouldSatisfy` isLeft

    it "add ollama saves the base url to config and stores a key when given" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        -- scripted answers: base url (ccPrompt) then key (ccPromptSecret)
        (_, caps) <- makeFakeCaps ["https://ollama.com", "k-cloud"]
        runProv pr ["add", "ollama"] caps
        vhGet vh "OLLAMA_API_KEY" >>= (`shouldBe` Right ("k-cloud" :: ByteString))
        Right cfg <- loadRuntimeConfig cfgPath
        providerBaseUrl cfg "ollama" `shouldBe` Just "https://ollama.com"
        providerDefaultModel cfg "ollama" `shouldBe` Just "llama3.2"

    it "add ollama with a blank key configures local (no key stored)" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        -- blank base url keeps the default; blank key => local
        (_, caps) <- makeFakeCaps ["", ""]
        runProv pr ["add", "ollama"] caps
        vhGet vh "OLLAMA_API_KEY" >>= (`shouldSatisfy` either (const True) (const False))

    it "list reports ollama as none (local) when no key is stored" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        T.unlines out `shouldSatisfy` ("ollama" `T.isInfixOf`)
        T.unlines out `shouldSatisfy` ("local" `T.isInfixOf`)

    it "default sets default_provider without needing a vault" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        pr <- mkPR cfgPath Nothing            -- no vault: config-only command
        (fc, caps) <- makeFakeCaps []
        runProv pr ["default", "ollama"] caps
        Right cfg <- loadRuntimeConfig cfgPath
        rcDefaultProvider cfg `shouldBe` Just "ollama"
        sent <- getSent fc
        -- confirmation names the provider and its resolved default model
        T.unlines sent `shouldSatisfy` ("ollama" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("llama3.2" `T.isInfixOf`)

    it "default reassigns an already-set default provider" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (_, addCaps) <- makeFakeCaps ["sk"]
        runProv pr ["add", "anthropic"] addCaps   -- seeds default_provider = anthropic
        (_, caps) <- makeFakeCaps []
        runProv pr ["default", "ollama"] caps      -- must override, not <|>-keep
        Right cfg <- loadRuntimeConfig cfgPath
        rcDefaultProvider cfg `shouldBe` Just "ollama"

    it "default rejects an unknown provider" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        pr <- mkPR cfgPath Nothing
        (fc, caps) <- makeFakeCaps []
        runProv pr ["default", "bogus"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("unknown provider" `T.isInfixOf`)

    it "rejects an unknown provider" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["test", "bogus"] caps
        sent <- getSent fc
        sent `shouldSatisfy` any ("unknown provider" `T.isInfixOf`)

    it "list works with no vault configured at all" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        pr <- mkPR cfgPath Nothing      -- no vault handle
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        sent <- getSent fc
        sent `shouldSatisfy` any ("keyless" `T.isInfixOf`)

    it "add of a keyed provider with no vault reports the setup step" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        pr <- mkPR cfgPath Nothing      -- no vault handle
        (fc, caps) <- makeFakeCaps ["sk-secret"]
        runProv pr ["add", "anthropic"] caps
        sent <- getSent fc
        sent `shouldSatisfy` any ("/vault setup" `T.isInfixOf`)

    it "the spec is in the Providers group" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        pr <- mkPR (dir </> "config.toml") Nothing
        csSynopsis (providerCommandSpec pr) `shouldSatisfy` (not . T.null)

    it "appears under the Providers group in the help index" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        pr <- mkPR (dir </> "config.toml") Nothing
        let idx = renderHelpIndex (mkRegistry [providerCommandSpec pr])
        idx `shouldSatisfy` ("Providers" `T.isInfixOf`)
        idx `shouldSatisfy` ("/provider" `T.isInfixOf`)

    it "live: /provider test anthropic round-trips against the real API"
      pending  -- requires ANTHROPIC_API_KEY + network; run manually

-- ---------------------------------------------------------------------------
-- Legacy provider-id recovery (issue #271: openrouter -> openai-compat)
-- ---------------------------------------------------------------------------

legacyMeta :: SessionMeta
legacyMeta =
  let t = posixSecondsToUTCTime 0
      sid = fromRight (error "bad sid") (mkSessionId "legacy")
  in SessionMeta
       { smId = sid, smProvider = "openrouter", smModel = "deepseek/x"
       , smChannel = "cli", smAgent = Nothing, smSystemOverride = Nothing
       , smAgentName = Nothing, smDescription = Nothing, smRepoUrl = Nothing
       , smCreatedAt = t, smLastActive = t
       }

legacySpec :: Spec
legacySpec = describe "legacy provider id recovery" $ do
  it "a session on openrouter names the rename and both repair commands" $
    withSystemTempDirectory "seal-provider-legacy" $ \root -> do
      pr <- mkPR (root </> "config.toml") Nothing
      r <- resolveSessionProvider pr legacyMeta
      case r of
        Left e -> do
          e `shouldSatisfy` ("renamed to openai-compat" `T.isInfixOf`)
          e `shouldSatisfy` ("/provider add openai-compat" `T.isInfixOf`)
          e `shouldSatisfy` ("/model use openai-compat" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  it "an agent def on openrouter names the rename and the provider line" $
    withSystemTempDirectory "seal-provider-legacy" $ \root -> do
      pr <- mkPR (root </> "config.toml") Nothing
      r <- resolveDefProvider pr "openrouter" (ModelId "m")
      case r of
        Left e -> do
          e `shouldSatisfy` ("renamed to openai-compat" `T.isInfixOf`)
          e `shouldSatisfy` ("provider line" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  it "/provider default names the missing model for a model-less provider" $
    withSystemTempDirectory "seal-provider-legacy" $ \root -> do
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runProv pr ["default", "openai-compat"] caps
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("default provider set to openai-compat" `T.isInfixOf`)
      out `shouldSatisfy` ("no default model" `T.isInfixOf`)

  it "an unknown (non-legacy) id lists the known providers" $
    withSystemTempDirectory "seal-provider-legacy" $ \root -> do
      pr <- mkPR (root </> "config.toml") Nothing
      r <- resolveDefProvider pr "nope" (ModelId "m")
      case r of
        Left e -> e `shouldSatisfy` ("(known: anthropic, ollama, openai-compat)" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

-- | All suites behind the module's single exported @spec@.
spec :: Spec
spec = spec_main >> legacySpec >> cliSpec

-- ---------------------------------------------------------------------------
-- Add flow, model-less providers, removal (issue #271)
-- ---------------------------------------------------------------------------

cliSpec :: Spec
cliSpec = describe "generic provider CLI" $ do

  describe "addPlanFor" $ do
    it "asks anthropic for a key only" $
      addPlanFor AnthropicProvider
        `shouldBe` AddPlan NoBaseUrl RequiredKey (Just (ModelId "claude-opus-4-8"))
    it "offers ollama its local URL and an optional key" $
      addPlanFor OllamaProvider
        `shouldBe` AddPlan (OptionalBaseUrl "http://localhost:11434") OptionalKey
                          (Just (ModelId "llama3.2"))
    it "requires a base URL and a model for the generic row" $
      addPlanFor (OpenAICompatProvider genericOpenAICompat)
        `shouldBe` AddPlan RequiredBaseUrl OptionalKey Nothing
    it "requires a key (and no URL prompt) for a key-required preset" $
      addPlanFor (OpenAICompatProvider presetSpec)
        `shouldBe` AddPlan NoBaseUrl RequiredKey (Just (ModelId "acme-large"))

  describe "add openai-compat" $ do
    it "aborts on a blank base URL without writing anything" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        -- three blank answers exhaust the required prompt
        (fc, caps) <- makeFakeCaps ["", "", ""]
        runProv pr ["add", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("nothing was saved" `T.isInfixOf`)
        Right cfg' <- loadRuntimeConfig cfg
        rcProviders cfg' `shouldSatisfy` not . Map.member "openai-compat"
        missing <- vhGet vh "OPENAI_COMPAT_API_KEY"
        missing `shouldSatisfy` isLeft

    it "rejects an unusable base URL with the reason" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps ["ftp://h/v1", "ftp://h/v1", "ftp://h/v1"]
        runProv pr ["add", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("not usable" `T.isInfixOf`)
        out `shouldSatisfy` ("scheme must be http or https" `T.isInfixOf`)

    it "stores the URL and model, and no key when blank" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps ["http://127.0.0.1:8000/v1", "qwen2.5-7b", ""]
        runProv pr ["add", "openai-compat"] caps
        Right cfg' <- loadRuntimeConfig cfg
        providerBaseUrl cfg' "openai-compat" `shouldBe` Just "http://127.0.0.1:8000/v1"
        providerDefaultModel cfg' "openai-compat" `shouldBe` Just "qwen2.5-7b"
        missing <- vhGet vh "OPENAI_COMPAT_API_KEY"
        missing `shouldSatisfy` isLeft
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("Configured openai-compat" `T.isInfixOf`)

    it "stores a supplied key in the vault" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (_, caps) <- makeFakeCaps ["https://gw.example/v1", "gpt-4o-mini", "sk-oc"]
        runProv pr ["add", "openai-compat"] caps
        vhGet vh "OPENAI_COMPAT_API_KEY" >>= (`shouldBe` Right ("sk-oc" :: ByteString))

    it "works keyless with no vault configured at all" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        pr <- mkPR cfg Nothing
        (fc, caps) <- makeFakeCaps ["http://127.0.0.1:8000/v1", "m1", ""]
        runProv pr ["add", "openai-compat"] caps
        Right cfg' <- loadRuntimeConfig cfg
        providerBaseUrl cfg' "openai-compat" `shouldBe` Just "http://127.0.0.1:8000/v1"
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("Configured openai-compat" `T.isInfixOf`)

    it "aborts on the web cancel sentinel" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        pr <- mkPR cfg Nothing
        (fc, caps) <- makeFakeCaps ["rejected"]
        runProv pr ["add", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("nothing was saved" `T.isInfixOf`)
        Right cfg' <- loadRuntimeConfig cfg
        rcProviders cfg' `shouldSatisfy` not . Map.member "openai-compat"

    it "warns when a key would be sent over plain http to a remote host" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps ["http://gw.example/v1", "m1", "sk-x"]
        runProv pr ["add", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("unencrypted" `T.isInfixOf`)

  describe "test openai-compat" $ do
    it "reports the transport failure verbatim against an unreachable endpoint" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        _ <- updateRuntimeConfig cfg
               (upsertProvider "openai-compat"
                  (\p -> p { pcBaseUrl = Just "http://127.0.0.1:1/v1"
                           , pcDefaultModel = Just "m1" }))
        (fc, caps) <- makeFakeCaps []
        runProv pr ["test", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("connection or transport error" `T.isInfixOf`)

    it "reports the missing model without touching the network" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        _ <- updateRuntimeConfig cfg
               (upsertProvider "openai-compat"
                  (\p -> p { pcBaseUrl = Just "http://127.0.0.1:1/v1" }))
        (fc, caps) <- makeFakeCaps []
        runProv pr ["test", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("has no model selected" `T.isInfixOf`)

  describe "remove openai-compat" $ do
    it "deconfigures a keyless provider with no vault and keeps Anthropic's OAuth" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", "{}")]
        pr <- mkPR cfg (Just vh)
        _ <- updateRuntimeConfig cfg
               (upsertProvider "openai-compat"
                  (\p -> p { pcBaseUrl = Just "http://127.0.0.1:8000/v1"
                           , pcDefaultModel = Just "m1" }))
        (_, caps) <- makeFakeCaps []
        runProv pr ["remove", "openai-compat"] caps
        Right cfg' <- loadRuntimeConfig cfg
        providerBaseUrl cfg' "openai-compat" `shouldBe` Nothing
        providerDefaultModel cfg' "openai-compat" `shouldBe` Just "m1"
        vhGet vh "ANTHROPIC_OAUTH_TOKENS" >>= (`shouldBe` Right ("{}" :: ByteString))

    it "works with no vault handle at all" $
      withSystemTempDirectory "seal-oc" $ \dir -> do
        let cfg = dir </> "config.toml"
        pr <- mkPR cfg Nothing
        (fc, caps) <- makeFakeCaps []
        runProv pr ["remove", "openai-compat"] caps
        out <- T.unlines <$> getSent fc
        out `shouldSatisfy` ("Removed OpenAI-compatible" `T.isInfixOf`)

-- Fixtures ------------------------------------------------------------------

presetSpec :: OpenAICompatSpec
presetSpec = OpenAICompatSpec
  { ocsId = "acme", ocsDisplayName = "Acme", ocsVaultKey = "ACME_API_KEY"
  , ocsBuiltinBaseUrl = Just "https://acme.example/v1"
  , ocsDefaultModel = Just (ModelId "acme-large"), ocsKeyRequired = True
  , ocsModels = [], ocsExtraHeaders = [] }
