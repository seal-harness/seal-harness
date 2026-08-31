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
        map (skillIdText . skId) skills `shouldBe` ["core/alpha", "core/gamma", "ops/beta"]
        let byId = [ (skillIdText (skId s), skGroup s) | s <- skills ]
        byId `shouldBe`
          [ ("core/alpha", Just "core")
          , ("core/gamma", Just "core")
          , ("ops/beta", Just "ops")
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
        case [ s | s <- skills, skillIdText (skId s) == "core/dropped" ] of
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

  describe "markdownSkillBackend agentskills.io auto-detection" $ do
    -- A skill in agentskills.io format: <name>/SKILL.md with `name` +
    -- `description` frontmatter. The user store should auto-detect these
    -- alongside the native flat/grouped .md layout, deriving the skill id
    -- from the `name` field (per the agentskills.io spec, name must match the
    -- parent directory name).
    let agentSkillMd name desc body =
          "---\nname: " <> name <> "\ndescription: " <> desc <> "\n---\n\n" <> body <> "\n"

    it "lists a top-level <name>/SKILL.md skill (ungrouped)" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True (skillsDir </> "pdf-processing")
        TIO.writeFile (skillsDir </> "pdf-processing" </> "SKILL.md")
          (agentSkillMd "pdf-processing" "Extract PDF text." "Do the thing.")
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        skills <- sbList backend
        case [ s | s <- skills, skillIdText (skId s) == "pdf-processing" ] of
          [s] -> do
            skDescription s `shouldBe` "Extract PDF text."
            skBody s `shouldBe` "Do the thing."
            skGroup s `shouldBe` Nothing
          _   -> expectationFailure "agentskills.io skill not listed"

    it "lists a <group>/<name>/SKILL.md skill, stamped with the group" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True (skillsDir </> "core" </> "my-skill")
        TIO.writeFile (skillsDir </> "core" </> "my-skill" </> "SKILL.md")
          (agentSkillMd "my-skill" "A grouped agent skill." "Body here.")
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        skills <- sbList backend
        case [ s | s <- skills, skillIdText (skId s) == "core/my-skill" ] of
          [s] -> do
            skDescription s `shouldBe` "A grouped agent skill."
            skBody s `shouldBe` "Body here."
            skGroup s `shouldBe` Just "core"
          _   -> expectationFailure "grouped agentskills.io skill not listed"

    it "reads a single agentskills.io skill by id via sbRead" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True (skillsDir </> "code-review")
        TIO.writeFile (skillsDir </> "code-review" </> "SKILL.md")
          (agentSkillMd "code-review" "Review code." "Instructions.")
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        m <- sbRead backend (case mkSkillId "code-review" of Right i -> i; Left _ -> sampleSkillId)
        case m of
          Just s  -> do
            skDescription s `shouldBe` "Review code."
            skBody s `shouldBe` "Instructions."
          Nothing -> expectationFailure "agentskills.io skill not read back"

    it "skips an agentskills.io skill whose name fails mkSkillId" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        -- '.' is not in mkSkillId's charset, so the name fails validation
        createDirectoryIfMissing True (skillsDir </> "bad.name")
        TIO.writeFile (skillsDir </> "bad.name" </> "SKILL.md")
          (agentSkillMd "bad.name" "Bad name." "Body.")
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        skills <- sbList backend
        case [ s | s <- skills, skillIdText (skId s) == "bad.name" ] of
          []  -> pure ()
          _   -> expectationFailure "invalid-name agentskills.io skill should be skipped"

    it "still lists native flat .md files alongside agentskills.io skills" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        -- native flat
        let native = "---\nid: native-flat\ndescription: a native skill.\n\
                     \created_at: 2026-07-05T00:00:00Z\n\
                     \updated_at: 2026-07-05T00:00:00Z\n\
                     \session: manual\n---\n\nnative body\n"
        TIO.writeFile (skillsDir </> "native-flat.md") native
        -- agentskills.io
        createDirectoryIfMissing True (skillsDir </> "agent-dir")
        TIO.writeFile (skillsDir </> "agent-dir" </> "SKILL.md")
          (agentSkillMd "agent-dir" "An agent skill." "agent body")
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        skills <- sbList backend
        let ids = map (skillIdText . skId) skills
        "native-flat" `elem` ids `shouldBe` True
        "agent-dir"   `elem` ids `shouldBe` True

  describe "markdownSkillBackend group-scoping (duplicate ids across groups)" $ do
    it "lists both skills when two groups have a skill with the same bare id" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let mkG sid desc grp = (mkSkill desc "b")
              { skId = case mkSkillId sid of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Just grp
              }
        sbCreate backend (mkG "greet" "core greeting" "core")
        sbCreate backend (mkG "greet" "design greeting" "design")
        skills <- sbList backend
        let ids = map (skillIdText . skId) skills
        ids `shouldContain` ["core/greet"]
        ids `shouldContain` ["design/greet"]
        length skills `shouldBe` 2

    it "sbRead with a fully-qualified id returns the correct skill" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let mkG sid desc grp = (mkSkill desc "b")
              { skId = case mkSkillId sid of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Just grp
              }
        sbCreate backend (mkG "greet" "core greeting" "core")
        sbCreate backend (mkG "greet" "design greeting" "design")
        mCore <- sbRead backend (case mkSkillId "core/greet" of Right i -> i; Left _ -> sampleSkillId)
        case mCore of
          Just s -> skDescription s `shouldBe` "core greeting"
          Nothing -> expectationFailure "core/greet not found"
        mDesign <- sbRead backend (case mkSkillId "design/greet" of Right i -> i; Left _ -> sampleSkillId)
        case mDesign of
          Just s -> skDescription s `shouldBe` "design greeting"
          Nothing -> expectationFailure "design/greet not found"

    it "sbRead with a bare id returns Nothing when the id is ambiguous" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let mkG sid desc grp = (mkSkill desc "b")
              { skId = case mkSkillId sid of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Just grp
              }
        sbCreate backend (mkG "greet" "core greeting" "core")
        sbCreate backend (mkG "greet" "design greeting" "design")
        m <- sbRead backend (case mkSkillId "greet" of Right i -> i; Left _ -> sampleSkillId)
        m `shouldBe` Nothing

    it "sbRead with a bare id returns the skill when unambiguous" $
      withSystemTempDirectory "seal-skill" $ \root -> do
        let cfgRoot = root </> "config"
            skillsDir = cfgRoot </> "skills"
        ensureConfigRepo cfgRoot
        backend <- markdownSkillBackend skillsDir (openConfigRepo cfgRoot)
        let mkG sid desc grp = (mkSkill desc "b")
              { skId = case mkSkillId sid of Right i -> i; Left _ -> sampleSkillId
              , skGroup = Just grp
              }
        sbCreate backend (mkG "greet" "core greeting" "core")
        m <- sbRead backend (case mkSkillId "greet" of Right i -> i; Left _ -> sampleSkillId)
        case m of
          Just s -> skDescription s `shouldBe` "core greeting"
          Nothing -> expectationFailure "bare id greet should resolve to core/greet"

  describe "noneBackend group-scoping" $ do
    it "stores two skills with the same bare id in different groups when qualified" $ do
      backend <- noneBackend
      let mkFq g = case mkSkillId (g <> "/greet") of Right i -> i; Left _ -> sampleSkillId
          mkS g desc = Skill
            { skId = mkFq g, skDescription = desc, skBody = "b"
            , skGroup = Just g
            , skCreatedAt = sampleTime, skUpdatedAt = sampleTime
            , skSession = mkSystemSessionId "s1"
            }
      sbCreate backend (mkS "core" "core greeting")
      sbCreate backend (mkS "design" "design greeting")
      skills <- sbList backend
      length skills `shouldBe` 2
      mCore <- sbRead backend (case mkSkillId "core/greet" of Right i -> i; Left _ -> sampleSkillId)
      case mCore of
        Just s -> skDescription s `shouldBe` "core greeting"
        Nothing -> expectationFailure "core/greet not found in noneBackend"
      -- Bare id is ambiguous — should return Nothing
      mBare <- sbRead backend (case mkSkillId "greet" of Right i -> i; Left _ -> sampleSkillId)
      mBare `shouldBe` Nothing
