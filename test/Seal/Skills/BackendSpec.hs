{-# LANGUAGE OverloadedStrings #-}
module Seal.Skills.BackendSpec (spec) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Core.Types (mkSystemSessionId)
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
  , skGroup = Nothing
  , skCreatedAt = sampleTime
  , skUpdatedAt = sampleTime
  , skSession = mkSystemSessionId "s1"
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

  describe "markdownSkillBackend grouped layout" $ do
    it "writes a grouped skill under <root>/<group>/<id>.md and reads it back" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let skill = (mkSkill "greeting skill" "say hello warmly")
              { skId = case mkSkillId "greet" of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Just "core"
              }
        sbCreate backend skill
        doesFileExist (skillsDir </> "core" </> "greet.md") `shouldReturn` True
        m <- sbRead backend (case mkSkillId "greet" of Right i -> i; Left _ -> sampleSkillId)
        case m of
          Just s -> do
            skBody s `shouldBe` "say hello warmly"
            skGroup s `shouldBe` Just "core"
          Nothing -> expectationFailure "grouped skill not read back"

    it "lists skills from group subdirectories, stamped with their group" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let mkG sid desc grp = (mkSkill desc "b")
              { skId = case mkSkillId sid of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Just grp
              }
        sbCreate backend (mkG "alpha" "a" "core")
        sbCreate backend (mkG "beta"  "b" "ops")
        sbCreate backend (mkG "gamma" "g" "core")
        skills <- sbList backend
        map (skillIdText . skId) skills `shouldBe` ["alpha", "beta", "gamma"]
        let byId = [ (skillIdText (skId s), skGroup s) | s <- skills ]
        byId `shouldBe`
          [ ("alpha", Just "core")
          , ("beta", Just "ops")
          , ("gamma", Just "core")
          ]

    it "stamps group from the directory when the frontmatter omitted it" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        -- Simulate a hand-dropped file with NO group frontmatter, under a
        -- group subdir. The read should infer the group from the path.
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        -- Write a grouped skill with skGroup = Nothing first, then move
        -- the file into a subdir by re-creating it through the backend
        -- with a group (the easy path). For the hand-drop path, drop a
        -- raw file with no group frontmatter directly.
        let raw = "---\nid: dropped\n\
                  \description: hand-dropped\n\
                  \created_at: 2026-07-05T00:00:00Z\n\
                  \updated_at: 2026-07-05T00:00:00Z\n\
                  \session: manual\n\
                  \---\n\n\
                  \body text\n"
        createDirectoryIfMissing True (skillsDir </> "core")
        TIO.writeFile (skillsDir </> "core" </> "dropped.md") raw
        skills <- sbList backend
        case [ s | s <- skills, skillIdText (skId s) == "dropped" ] of
          [s] -> skGroup s `shouldBe` Just "core"
          _   -> expectationFailure "hand-dropped grouped skill not listed"

    it "still reads flat-layout skills (back-compat) with no group" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let skill = (mkSkill "greeting skill" "say hi")
              { skId = case mkSkillId "flat" of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Nothing
              }
        sbCreate backend skill
        doesFileExist (skillsDir </> "flat.md") `shouldReturn` True
        m <- sbRead backend (case mkSkillId "flat" of Right i -> i; Left _ -> sampleSkillId)
        case m of
          Just s -> skGroup s `shouldBe` Nothing
          Nothing -> expectationFailure "flat skill not read back"

    it "deletes a grouped skill from its group directory" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let sid = case mkSkillId "del" of Right i -> i; Left _ -> sampleSkillId
            skill = (mkSkill "d" "b") { skId = sid, skGroup = Just "core" }
        sbCreate backend skill
        doesFileExist (skillsDir </> "core" </> "del.md") `shouldReturn` True
        sbDelete backend sid
        doesFileExist (skillsDir </> "core" </> "del.md") `shouldReturn` False