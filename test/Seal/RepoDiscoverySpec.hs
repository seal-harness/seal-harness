{-# LANGUAGE OverloadedStrings #-}
module Seal.RepoDiscoverySpec (spec) where

import Control.Exception (SomeException, catch)
import Data.Maybe (isJust, isNothing, mapMaybe)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, createDirectoryLink, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec

import Seal.Skills.Backend
  ( SkillBackend (..)
  , tripleUnionSkillBackend
  , workdirSkillBackend
  , workdirSkillConventions
  , decodeAgentSkill
  )
import qualified Seal.Skills.Backend as SkillBackend
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Seal.Core.Types (mkSystemSessionId)
import Seal.Agent.Def.Backend
  ( AgentDefBackend (..)
  , workdirAgentDefBackend
  , unionAgentDefBackend
  , noneBackend
  , deriveAgentsMdId
  )
import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText, isValidAgentDefId)

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
    it "includes .agents/skills as the second convention" $ do
      ".agents/skills" `elem` workdirSkillConventions `shouldBe` True
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
          skillIdText (skId s) `shouldBe` "my-repo--my-skill"
          skDescription s `shouldBe` "A repo-local skill."
          skBody s `shouldBe` "Do repo things.\n"
          skGroup s `shouldBe` Just "my-repo project skills"
        _ -> expectationFailure "expected exactly 1 skill"
      case mkSkillId "my-repo--my-skill" of
        Right sid -> do
          mSkill <- sbRead backend sid
          mSkill `shouldSatisfy` isJust
        Left _ -> expectationFailure "invalid skill id"
      cleanup tmp

  describe "Seal.Skills.Backend.workdirSkillBackend (.agents/skills directory)" $ do
    it "discovers skills in agentskills.io format under .agents/skills/" $ do
      let tmp = "/tmp/seal-repo-discovery-agents-skills-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "skills" </> "my-skill")
      writeFile (tmp </> "my-repo" </> ".agents" </> "skills" </> "my-skill" </> "SKILL.md")
        "---\nname: my-skill\ndescription: A .agents/skills skill.\n---\nDo .agents things.\n"
      backend <- workdirSkillBackend tmp
      skills <- sbList backend
      length skills `shouldBe` 1
      case skills of
        [s] -> do
          skillIdText (skId s) `shouldBe` "my-repo--my-skill"
          skDescription s `shouldBe` "A .agents/skills skill."
          skBody s `shouldBe` "Do .agents things.\n"
          skGroup s `shouldBe` Just "my-repo project skills"
        _ -> expectationFailure "expected exactly 1 skill"
      cleanup tmp

    it "returns empty list when workdir has no repos" $ do
      backend <- workdirSkillBackend "/nonexistent-path-12345"
      skills <- sbList backend
      skills `shouldBe` []

  describe "Seal.Skills.Backend.tripleUnionSkillBackend (no-collision namespacing)" $ do
    it "shows both user and workdir skills when they share the same raw id" $ do
      let tmp = "/tmp/seal-repo-discovery-no-collision-test"
      cleanup tmp
      -- Workdir skill: .agents/skills/shared-skill/SKILL.md
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "skills" </> "shared-skill")
      writeFile (tmp </> "my-repo" </> ".agents" </> "skills" </> "shared-skill" </> "SKILL.md")
        "---\nname: shared-skill\ndescription: Repo version.\n---\nRepo body.\n"
      -- User skill: in-memory backend with the same id "shared-skill"
      workdirBackend <- workdirSkillBackend tmp
      userBackend <- SkillBackend.noneBackend
      case mkSkillId "shared-skill" of
        Right sid -> do
          sbCreate userBackend Skill
            { skId = sid
            , skDescription = "User version."
            , skBody = "User body.\n"
            , skGroup = Just "metaswarm"
            , skCreatedAt = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)
            , skUpdatedAt = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)
            , skSession = mkSystemSessionId "manual"
            }
          let unioned = tripleUnionSkillBackend workdirBackend userBackend
          skills <- sbList unioned
          length skills `shouldBe` 2
          let ids = map (skillIdText . skId) skills
          ids `shouldContain` ["my-repo--shared-skill"]
          ids `shouldContain` ["shared-skill"]
        Left _ -> expectationFailure "invalid skill id"
      cleanup tmp

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
        [d] -> agentDefIdText (adId d) `shouldBe` "my-repo--my-agent"
        _ -> expectationFailure "expected exactly 1 def"
      cleanup tmp

    it "returns empty list when workdir has no repos" $ do
      backend <- workdirAgentDefBackend "/nonexistent-path-12345"
      defs <- adbList backend
      defs `shouldBe` []

  describe "Seal.Agent.Def.Backend.workdirAgentDefBackend (.agents Protocol)" $ do
    it "discovers .agents/agents/<id>/agent.md sub-agents + .agents/agents.md project def" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "foo-agent")
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "skills" </> "bar")
      -- The project-level agents.md (kind: agents frontmatter, no id).
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\n# Project Guidelines\nDo good work.\n"
      -- A sub-agent in protocol format.
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents" </> "foo-agent" </> "agent.md")
        "---\nname: Foo Agent\nprovider: ollama\nmodel: llama3\nenabled: true\n---\nYou are a foo specialist.\n"
      -- A skills dir that must NOT produce a bogus 'skills' agent.
      writeFile (tmp </> "my-repo" </> ".agents" </> "skills" </> "bar" </> "SKILL.md")
        "---\nname: bar\ndescription: a skill\n---\nbody\n"
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      -- Exactly 2 defs: the project def (my-repo--agents-md) + the sub-agent
      -- (my-repo--foo-agent). No bogus 'agents' or 'skills' empty-prompt entries.
      length defs `shouldBe` 2
      ids `shouldContain` ["my-repo--agents-md", "my-repo--foo-agent"]
      ids `shouldNotContain` ["agents"]
      ids `shouldNotContain` ["skills"]
      -- The project def's system prompt is the agents.md body (frontmatter stripped).
      let mProject = [d | d <- defs, agentDefIdText (adId d) == "my-repo--agents-md"]
      case mProject of
        [d] -> adSystem d `shouldBe` Just "# Project Guidelines\nDo good work."
        _ -> expectationFailure "expected exactly one agents-md def"
      -- The sub-agent's system prompt is the agent.md body.
      let mFoo = [d | d <- defs, agentDefIdText (adId d) == "my-repo--foo-agent"]
      case mFoo of
        [d] -> do
          adSystem d `shouldBe` Just "You are a foo specialist."
          adProvider d `shouldBe` "ollama"
        _ -> expectationFailure "expected exactly one foo-agent def"
      cleanup tmp

    it "skips a sub-agent with enabled: false" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-disabled-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "off-agent")
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "on-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\nProject.\n"
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "off-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents" </> "off-agent" </> "agent.md")
        "---\nname: Off\nenabled: false\n---\nDisabled body.\n"
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "on-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents" </> "on-agent" </> "agent.md")
        "---\nname: On\n---\nEnabled body.\n"
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      ids `shouldContain` ["my-repo--on-agent"]
      ids `shouldNotContain` ["my-repo--off-agent"]
      cleanup tmp

    it "frontmatter id overrides the subdir name when present and valid" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-override-id-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "subdir-name")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\nProject.\n"
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "subdir-name")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents" </> "subdir-name" </> "agent.md")
        "---\nid: real-id\nname: Real\n---\nBody.\n"
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      ids `shouldContain` ["my-repo--real-id"]
      ids `shouldNotContain` ["my-repo--subdir-name"]
      cleanup tmp

    it "rejects a symlinked agent.md escaping .agents/ (SafePath confinement)" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-symlink-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "leak")
      -- A secret file OUTSIDE the .agents/ dir (the symlink target).
      writeFile (tmp </> "my-repo" </> "secret.txt") "PRIVATE KEY MATERIAL\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\nProject.\n"
      -- Symlink agent.md -> ../../secret.txt (escapes .agents/).
      createDirectoryLink (tmp </> "my-repo" </> "secret.txt")
                          (tmp </> "my-repo" </> ".agents" </> "agents" </> "leak" </> "agent.md")
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      -- The leaking 'leak' agent must NOT appear (its body would be the secret).
      ids `shouldNotContain` ["my-repo--leak"]
      -- The project def still appears (it's not a symlink).
      ids `shouldContain` ["my-repo--agents-md"]
      -- No def's system prompt contains the secret.
      let systems = mapMaybe adSystem defs
      systems `shouldNotSatisfy` any ("PRIVATE KEY MATERIAL" `T.isInfixOf`)
      cleanup tmp

    it "falls back to legacy DirScheme for .agents/<id>/SOUL.md (no agents.md/agents/ subdir)" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-legacy-fallback-test"
      cleanup tmp
      -- Legacy layout: .agents/my-agent/SOUL.md (NO .agents/agents.md, NO .agents/agents/).
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "my-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "my-agent" </> "SOUL.md")
        "You are a legacy agent.\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "my-agent" </> "AGENTS.md")
        "---\nmodel: llama3\nprovider: ollama\n---\nAgent instructions.\n"
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      ids `shouldContain` ["my-repo--my-agent"]
      ids `shouldNotContain` ["my-repo--agents-md"]
      cleanup tmp

    it "deriveAgentsMdId always passes isValidAgentDefId and ends in '-md' (QuickCheck)" $ do
      let theId = deriveAgentsMdId
      isValidAgentDefId theId `shouldBe` True
      "-md" `T.isSuffixOf` theId `shouldBe` True

    it "prefixes repo-local agent ids + displayNames with the repo dir name to disambiguate collisions" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-prefix-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "vtag" </> ".agents" </> "agents" </> "architect-agent")
      writeFile (tmp </> "vtag" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\nProject.\n"
      writeFile (tmp </> "vtag" </> ".agents" </> "agents" </> "architect-agent" </> "agent.md")
        "---\nname: Architect Agent\n---\nYou are an architect.\n"
      backend <- workdirAgentDefBackend tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      -- Repo-local ids are prefixed with the repo dir + "--" so a user agent
      -- named "architect-agent" coexists with "vtag--architect-agent" (no
      -- workdir-wins shadowing between repo and user).
      ids `shouldContain` ["vtag--agents-md", "vtag--architect-agent"]
      ids `shouldNotContain` ["architect-agent"]
      -- The displayName uses "/" for human readability (vtag/Architect Agent).
      let arch = [d | d <- defs, agentDefIdText (adId d) == "vtag--architect-agent"]
      case arch of
        [d] -> adName d `shouldBe` "vtag/Architect Agent"
        _ -> expectationFailure "expected exactly one prefixed architect-agent def"
      cleanup tmp

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
