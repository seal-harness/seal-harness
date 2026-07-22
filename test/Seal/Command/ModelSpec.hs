{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ModelSpec (spec) where

import Data.Either (fromRight)
import Data.IORef (newIORef, readIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.File
  (ProviderConfig (..), loadRuntimeConfig, providerDefaultModel, updateRuntimeConfig, upsertProvider)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Security.Vault (VaultHandle)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.Vault.Commands (VaultRuntime (..))

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

mkSR :: FilePath -> IO SessionRuntime
mkSR root = do
  let sid = fromRight (error "invalid session id") (mkSessionId "20260701-120000-002")
      m0 = SessionMeta sid "anthropic" "claude-opus-4-8" "cli" Nothing Nothing Nothing aTime aTime
      paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys")
  ref <- newIORef m0
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

mkPR :: FilePath -> Maybe VaultHandle -> IO ProviderRuntime
mkPR cfgPath mvh = do
  ref <- newIORef mvh
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr, prCallCounter = cntRef }

runModel :: ProviderRuntime -> SessionRuntime -> [String] -> ChannelCaps -> IO ()
runModel pr sr argv caps =
  case execParserPure defaultPrefs (csParserInfo (modelCommandSpec pr sr)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Model" $ do
  it "list shows known providers and the active selection" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      pr <- mkPR (root </> "config.toml") Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      T.unlines sent `shouldSatisfy` ("active" `T.isInfixOf`)

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
