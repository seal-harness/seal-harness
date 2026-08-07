{-# LANGUAGE OverloadedStrings #-}
module Seal.RepoDiscoverySpec (spec) where

import Control.Exception (SomeException, catch)
import Data.Maybe (isJust, isNothing)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec

import Seal.Skills.Backend
  ( SkillBackend (..)
  , workdirSkillBackend
  , workdirSkillConventions
  , decodeAgentSkill
  )
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)
import Seal.Agent.Def.Backend
  ( AgentDefBackend (..)
  , workdirAgentDefBackend
  , unionAgentDefBackend
  , noneBackend
  )
import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText)

spec :: Spec
spec = do
  describe "Seal.Skills.Backend.decodeAgentSkill" $ do
    it "decodes a valid SKILL.md with name and description" $ do
      let skillMd = "---\nname: my-skill\ndescription: A test skill.\n---\nDo the thing.\n"
      case decodeAgentSkill skillMd of
        Nothing -> expectationFailure "expected Just Skill"
        Just s -> do
          skillIdText (skId s) `shouldBe` "my-skill"
          skDescription s `shouldBe` "A test skill."
          skBody s `shouldBe` "Do the thing.\n"

    it "returns Nothing when name is missing" $ do
      let skillMd = "---\ndescription: A test skill.\n---\nDo the thing.\n"
      decodeAgentSkill skillMd `shouldSatisfy` isNothing

    it "returns Nothing when name has invalid characters" $ do
      let skillMd = "---\nname: My Skill!\ndescription: test.\n---\nbody\n"
      decodeAgentSkill skillMd `shouldSatisfy` isNothing

    it "handles empty description gracefully" $ do
      let skillMd = "---\nname: bare-skill\n---\nbody\n"
      case decodeAgentSkill skillMd of
        Nothing -> expectationFailure "expected Just Skill"
        Just s -> skDescription s `shouldBe` ""

  describe "Seal.Skills.Backend.workdirSkillConventions" $ do
    it "includes .skills as the first convention" $ do
      ".skills" `elem` workdirSkillConventions `shouldBe` True
  describe "Seal.Skills.Backend.workdirSkillBackend (.skills directory)" $ do
    it "discovers skills in agentskills.io format" $ do
      let tmp = "/tmp/seal-repo-discovery-skills-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".skills" </> "my-skill")
      writeFile (tmp </> "my-repo" </> ".skills" </> "my-skill" </> "SKILL.md")
        "---\nname: my-skill\ndescription: A repo-local skill.\n---\nDo repo things.\n"
      backend <- workdirSkillBackend tmp
      skills <- sbList backend
      length skills `shouldBe` 1
      case skills of
        [s] -> do
          skillIdText (skId s) `shouldBe` "my-skill"
          skDescription s `shouldBe` "A repo-local skill."
          skBody s `shouldBe` "Do repo things.\n"
        _ -> expectationFailure "expected exactly 1 skill"
      case mkSkillId "my-skill" of
        Right sid -> do
          mSkill <- sbRead backend sid
          mSkill `shouldSatisfy` isJust
        Left _ -> expectationFailure "invalid skill id"
      cleanup tmp

    it "returns empty list when workdir has no repos" $ do
      backend <- workdirSkillBackend "/nonexistent-path-12345"
      skills <- sbList backend
      skills `shouldBe` []

  describe "Seal.Agent.Def.Backend.workdirAgentDefBackend" $ do
    it "discovers agent defs from .agents/ directory" $ do
      let tmp = "/tmp/seal-repo-discovery-agents-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "my-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "my-agent" </> "SOUL.md")
        "You are a test agent.\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "my-agent" </> "AGENTS.md")
        "---\nmodel: llama3\nprovider: ollama\n---\nAgent instructions.\n"
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      length defs `shouldBe` 1
      case defs of
        [d] -> agentDefIdText (adId d) `shouldBe` "my-agent"
        _ -> expectationFailure "expected exactly 1 def"
      cleanup tmp

    it "returns empty list when workdir has no repos" $ do
      backend <- workdirAgentDefBackend "/nonexistent-path-12345"
      defs <- adbList backend
      defs `shouldBe` []

  describe "Seal.Agent.Def.Backend.unionAgentDefBackend" $ do
    it "workdir defs shadow user defs on id collision" $ do
      let tmp = "/tmp/seal-repo-discovery-union-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "repo" </> ".agents" </> "shared-agent")
      writeFile (tmp </> "repo" </> ".agents" </> "shared-agent" </> "SOUL.md")
        "Workdir version.\n"
      workdirBackend <- workdirAgentDefBackend tmp
      userBackend <- noneBackend
      let unioned = unionAgentDefBackend workdirBackend userBackend
      defs <- adbList unioned
      length defs `shouldBe` 1
      cleanup tmp

cleanup :: FilePath -> IO ()
cleanup path =
  removeDirectoryRecursive path `catch` \(_ :: SomeException) -> pure ()
