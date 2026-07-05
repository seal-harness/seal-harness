{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Def.BackendSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo, gitHasCommits)
import Seal.Security.Policy (AllowList (..))
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

mkDef :: Text -> AgentDef
mkDef name = AgentDef
  { adId = sampleDefId
  , adName = name
  , adProvider = "ollama"
  , adModel = ModelId "llama3"
  , adSystem = Just "be nice"
  , adTools = AllowAll
  , adCreatedAt = sampleTime
  , adUpdatedAt = sampleTime
  , adSession = SessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Agent.Def.Backend" $ do
  describe "encodeAgentDef / decodeAgentDef" $ do
    it "round-trips a def with AllowAll tools" $ do
      let d = mkDef "greeter"
      decodeAgentDef (encodeAgentDef d) `shouldBe` Just d

    it "round-trips a def with AllowOnly tools" $ do
      let tools = AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])
          d = (mkDef "toolsy") { adTools = tools }
      decodeAgentDef (encodeAgentDef d) `shouldBe` Just d

    it "round-trips a def with no system prompt" $ do
      let d = (mkDef "nosys") { adSystem = Nothing }
      decodeAgentDef (encodeAgentDef d) `shouldBe` Just d

  describe "noneBackend" $ do
    it "update then read round-trips" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "greeter")
      adbRead backend sampleDefId `shouldReturn` Just (mkDef "greeter")

    it "list returns all defs" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "a")
      adbList backend `shouldReturn` [mkDef "a"]

  describe "markdownAgentDefBackend" $ do
    it "update writes a file and read reads it back" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
        ensureConfigRepo cfgRoot
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        adbUpdate backend (mkDef "greeter")
        doesFileExist (agentsDir </> "a1.md") `shouldReturn` True
        m <- adbRead backend sampleDefId
        case m of
          Just d  -> adName d `shouldBe` "greeter"
          Nothing -> expectationFailure "def not read back"

    it "update auto-commits to the git repo" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
        ensureConfigRepo cfgRoot
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        adbUpdate backend (mkDef "greeter")
        gitHasCommits (openConfigRepo cfgRoot) `shouldReturn` True

    it "list enumerates the directory sorted by id" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
        ensureConfigRepo cfgRoot
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        case mkAgentDefId "zeta" of
          Right zid -> adbUpdate backend ((mkDef "z") { adId = zid })
          Left _    -> expectationFailure "invalid id"
        case mkAgentDefId "alpha" of
          Right aid -> adbUpdate backend ((mkDef "a") { adId = aid })
          Left _    -> expectationFailure "invalid id"
        defs <- adbList backend
        map (agentDefIdText . adId) defs `shouldBe` ["alpha", "zeta"]