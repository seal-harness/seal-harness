{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ProviderSpec (spec) where

import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.IORef (newIORef)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Provider (ProviderRuntime (..), formatTestResult, pingRequest, providerCommandSpec)
import Seal.Command.Spec (CommandSpec (..), mkRegistry, runCommandAction)
import Seal.Config.File (FileConfig (..), loadFileConfig, providerBaseUrl, providerDefaultModel)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (ModelId (..))
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
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath   -- unused by /provider
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr, prCallCounter = cntRef }

runProv :: ProviderRuntime -> [String] -> ChannelCaps -> IO ()
runProv pr argv caps =
  case execParserPure defaultPrefs (csParserInfo (providerCommandSpec pr)) argv of
    Success act         -> runCommandAction act caps
    Failure _           -> expectationFailure ("parse failed: " <> show argv)
    CompletionInvoked _ -> expectationFailure "unexpected completion"

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
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
        Right cfg <- loadFileConfig cfgPath
        fcDefaultProvider cfg `shouldBe` Just "anthropic"
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
        sent <- getSent fc
        sent `shouldSatisfy` any ("Stored API key" `T.isInfixOf`)

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
        Right cfg <- loadFileConfig cfgPath
        fcDefaultProvider cfg `shouldBe` Nothing
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

    it "list filters out anthropic when no credential is stored" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        -- ollama (local) is always configured; anthropic is not (no key, no OAuth)
        T.unlines out `shouldSatisfy` ("ollama" `T.isInfixOf`)
        T.unlines out `shouldNotSatisfy` ("anthropic" `T.isInfixOf`)

    it "list shows anthropic when an API key is stored" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-x")]
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        T.unlines out `shouldSatisfy` ("anthropic" `T.isInfixOf`)

    it "list prints a hint when no providers are configured" $
      withSystemTempDirectory "prov" $ \dir -> do
        let cfg = dir </> "config.toml"
            unconfiguredOllama =
              "[providers.ollama]\nbase_url = \"https://ollama.com\"\n"
        -- a cloud URL with no key => ollama is NOT configured either
        _ <- appendFile cfg unconfiguredOllama
        vh <- makeFakeVault []
        pr <- mkPR cfg (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        T.unlines out `shouldSatisfy` ("no providers configured" `T.isInfixOf`)

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
        Right cfg <- loadFileConfig cfgPath
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
        Right cfg <- loadFileConfig cfgPath
        fcDefaultProvider cfg `shouldBe` Just "ollama"
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
        Right cfg <- loadFileConfig cfgPath
        fcDefaultProvider cfg `shouldBe` Just "ollama"

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

    it "reports when the vault is not configured" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        pr <- mkPR cfgPath Nothing      -- no vault handle
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        sent <- getSent fc
        sent `shouldSatisfy` any ("vault not configured" `T.isInfixOf`)

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
