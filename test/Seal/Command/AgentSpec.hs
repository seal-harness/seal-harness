{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.AgentSpec (spec) where

import Data.IORef (modifyIORef')
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend, adbUpdate)
import Seal.Agent.Def.Types (AgentDef (..), mkAgentDefId)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Agent (agentCommandSpec, renderAgentInfo, renderAgentLine)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.File (FileConfig (..), loadFileConfig)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Security.Policy (AllowList (..))
import Seal.TestHelpers.FakeCaps (FakeCaps (..), getSent, makeFakeCaps)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

mkDef :: Text -> Text -> Text -> IO AgentDef
mkDef did name prov =
  case mkAgentDefId did of
    Right i  -> pure AgentDef
      { adId = i, adName = name, adProvider = prov, adModel = ModelId "llama3"
      , adSystem = Just "be nice", adTools = AllowAll
      , adCreatedAt = aTime, adUpdatedAt = aTime, adSession = SessionId "s1" }
    Left e   -> error ("invalid agent def id: " <> T.unpack e)

-- | Run a /agent command against a backend preloaded with the given defs and a
-- temp config file for default get/set.
runAgentWith :: [AgentDef] -> [String] -> FakeCaps -> FilePath -> IO ()
runAgentWith defs argv fc cfgPath = do
  backend <- noneBackend
  mapM_ (adbUpdate backend) defs
  let caps = ChannelCaps
        { ccSend         = \t -> modifyIORef' (fcSent fc) (t :)
        , ccPrompt       = \_ -> pure ""
        , ccPromptSecret = \_ -> pure ""
        }
  case execParserPure defaultPrefs (csParserInfo (agentCommandSpec backend cfgPath)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Agent" $ do
  describe "pure renderers" $ do
    it "renderAgentLine shows id + name + provider/model" $ do
      d <- mkDef "worker" "worker" "ollama"
      renderAgentLine d `shouldBe` "worker  worker  (ollama/llama3)"

    it "renderAgentInfo includes id, name, provider, model, system, tools" $ do
      d <- mkDef "worker" "worker" "ollama"
      let ls = T.unlines (renderAgentInfo d)
      ls `shouldSatisfy` ("worker" `T.isInfixOf`)
      ls `shouldSatisfy` ("ollama" `T.isInfixOf`)
      ls `shouldSatisfy` ("llama3" `T.isInfixOf`)
      ls `shouldSatisfy` ("be nice" `T.isInfixOf`)
      ls `shouldSatisfy` ("tools:" `T.isInfixOf`)

    it "renderAgentInfo renders an AllowOnly tool list" $ do
      d0 <- mkDef "worker" "worker" "ollama"
      let tools = AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])
          d = d0 { adTools = tools }
      let ls = T.unlines (renderAgentInfo d)
      ls `shouldSatisfy` ("FILE_READ" `T.isInfixOf`)
      ls `shouldSatisfy` ("ASK_HUMAN" `T.isInfixOf`)

  describe "/agent commands" $ do
    it "list shows defined agent defs sorted by name" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        (fc, _) <- makeFakeCaps []
        d1 <- mkDef "zeta" "zeta" "ollama"
        d2 <- mkDef "alpha" "alpha" "anthropic"
        runAgentWith [d1, d2] ["list"] fc (root <> "/config.toml")
        sent <- getSent fc
        -- alpha (name) sorts before zeta (name)
        T.unlines sent `shouldSatisfy` ("alpha" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("zeta" `T.isInfixOf`)
        -- alpha appears before zeta
        case sent of
          (a:z:_) -> do
            ("alpha" `T.isInfixOf` a) `shouldBe` True
            ("zeta" `T.isInfixOf` z) `shouldBe` True
          _       -> expectationFailure "expected two lines"

    it "list reports none when empty" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        (fc, _) <- makeFakeCaps []
        runAgentWith [] ["list"] fc (root <> "/config.toml")
        sent <- getSent fc
        sent `shouldBe` ["no agent defs defined"]

    it "info shows the def fields" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        (fc, _) <- makeFakeCaps []
        d <- mkDef "worker" "worker" "ollama"
        runAgentWith [d] ["info", "worker"] fc (root <> "/config.toml")
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("worker" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("be nice" `T.isInfixOf`)

    it "info reports not found for a missing def" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        (fc, _) <- makeFakeCaps []
        runAgentWith [] ["info", "nope"] fc (root <> "/config.toml")
        sent <- getSent fc
        sent `shouldBe` ["agent def not found: nope"]

    it "default with no arg reports none set" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        let cfgPath = root <> "/config.toml"
        (fc, _) <- makeFakeCaps []
        runAgentWith [] ["default"] fc cfgPath
        sent <- getSent fc
        sent `shouldBe` ["no default agent set. Use /agent default <id> to set one."]

    it "default with an arg validates, persists, and confirms" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        let cfgPath = root <> "/config.toml"
        (fc, _) <- makeFakeCaps []
        d <- mkDef "worker" "worker" "ollama"
        runAgentWith [d] ["default", "worker"] fc cfgPath
        sent <- getSent fc
        sent `shouldBe` ["default agent set to: worker"]
        -- persisted to config.toml
        eCfg <- loadFileConfig cfgPath
        fcDefaultAgent <$> eCfg `shouldBe` Right (Just "worker")

    it "default with an unknown def refuses and does not persist" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        let cfgPath = root <> "/config.toml"
        (fc, _) <- makeFakeCaps []
        runAgentWith [] ["default", "nope"] fc cfgPath
        sent <- getSent fc
        sent `shouldBe` ["agent def not found: nope"]
        eCfg <- loadFileConfig cfgPath
        fcDefaultAgent <$> eCfg `shouldBe` Right Nothing

    it "default rejects an invalid id" $ do
      withSystemTempDirectory "seal-agent" $ \root -> do
        let cfgPath = root <> "/config.toml"
        (fc, _) <- makeFakeCaps []
        runAgentWith [] ["default", "bad/id"] fc cfgPath
        sent <- getSent fc
        sent `shouldBe` ["invalid agent def id: \"bad/id\""]