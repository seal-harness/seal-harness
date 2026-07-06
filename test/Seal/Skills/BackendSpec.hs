{-# LANGUAGE OverloadedStrings #-}
module Seal.Skills.BackendSpec (spec) where

import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Core.Types (SessionId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo, gitHasCommits)
import Seal.Skills.Backend
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId, skillIdText)
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleSkillId :: SkillId
sampleSkillId = case mkSkillId "s1" of
  Right sid -> sid
  Left _    -> SkillId "fallback"

mkSkill :: Text -> Text -> Skill
mkSkill desc body = Skill
  { skId = sampleSkillId
  , skDescription = desc
  , skBody = body
  , skCreatedAt = sampleTime
  , skUpdatedAt = sampleTime
  , skSession = SessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Skills.Backend" $ do
  describe "encodeSkill / decodeSkill" $ do
    it "round-trips a skill" $ do
      let s = mkSkill "greeting skill" "say hello warmly"
      decodeSkill (encodeSkill s) `shouldBe` Just s

    it "round-trips a skill with empty body" $ do
      let s = mkSkill "empty" ""
      decodeSkill (encodeSkill s) `shouldBe` Just s

  describe "noneBackend" $ do
    it "create then read round-trips" $ do
      backend <- noneBackend
      sbCreate backend (mkSkill "d" "b")
      sbRead backend sampleSkillId `shouldReturn` Just (mkSkill "d" "b")

    it "list returns all entries" $ do
      backend <- noneBackend
      sbCreate backend (mkSkill "a" "b")
      sbList backend `shouldReturn` [mkSkill "a" "b"]

  describe "markdownSkillBackend" $ do
    it "create writes a file and read reads it back" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        sbCreate backend (mkSkill "greeting skill" "say hello warmly")
        doesFileExist (skillsDir </> "s1.md") `shouldReturn` True
        m <- sbRead backend sampleSkillId
        case m of
          Just s  -> skBody s `shouldBe` "say hello warmly"
          Nothing -> expectationFailure "skill not read back"

    it "create auto-commits to the git repo" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        sbCreate backend (mkSkill "greeting skill" "say hi")
        gitHasCommits (openConfigRepo cfgRoot) `shouldReturn` True

    it "list enumerates the directory sorted by id" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        sbCreate backend ((mkSkill "z" "b") { skId = case mkSkillId "zeta" of Right i -> i; Left _ -> sampleSkillId })
        sbCreate backend ((mkSkill "a" "b") { skId = case mkSkillId "alpha" of Right i -> i; Left _ -> sampleSkillId })
        skills <- sbList backend
        map (skillIdText . skId) skills `shouldBe` ["alpha", "zeta"]