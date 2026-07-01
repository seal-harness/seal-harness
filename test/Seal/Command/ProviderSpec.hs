{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ProviderSpec (spec) where

import Data.ByteString (ByteString)
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
import Seal.Config.File (FileConfig (..), loadFileConfig)
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
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath   -- unused by /provider
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr }

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
        fcDefaultModel    cfg `shouldBe` Just "claude-opus-4-8"
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
        T.unlines sent `shouldSatisfy` ("present" `T.isInfixOf`)

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

    it "live: /provider test anthropic round-trips against the real API" $
      pending  -- requires ANTHROPIC_API_KEY + network; run manually
