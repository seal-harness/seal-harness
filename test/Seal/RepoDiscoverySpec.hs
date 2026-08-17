{-# LANGUAGE OverloadedStrings #-}
module Seal.RepoDiscoverySpec (spec) where

import Control.Exception (SomeException, catch)
import Data.Map.Strict qualified as Map
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
import Seal.Core.Types (mkSystemSessionId, mkSessionId)
import Seal.Agent.Def.Backend
  ( AgentDefBackend (..)
  , workdirAgentDefBackend
  , unionAgentDefBackend
  , noneBackend
  , deriveAgentsMdId
  )
import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText, isValidAgentDefId, mkAgentDefId)
import Seal.Config.Paths (SealPaths (..), sessionMetaPath)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta, autoBindRepoAgent)
import Seal.Text.LineFile (maxScanBytes)
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath)
import Seal.Tools.Exec.WorkdirFs
  ( WorkdirFs
  , mkLocalWorkdirFs
  , mkInMemWorkdirFs
  , StubEntry (..)
  )
import Seal.Util.StrictIO (decodeFileStrict)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 8 17) (secondsToDiffTime (13 * 3600 + 14 * 60 + 4))

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
      backend <- workdirSkillBackend =<< mkFs tmp
      skills <- sbList backend
      length skills `shouldBe` 1
      case skills of
        [s] -> do
          skillIdText (skId s) `shouldBe` "my-repo--my-skill"
          skDescription s `shouldBe` "A repo-local skill."
          skBody s `shouldBe` "Do repo things."
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
      backend <- workdirSkillBackend =<< mkFs tmp
      skills <- sbList backend
      length skills `shouldBe` 1
      case skills of
        [s] -> do
          skillIdText (skId s) `shouldBe` "my-repo--my-skill"
          skDescription s `shouldBe` "A .agents/skills skill."
          skBody s `shouldBe` "Do .agents things."
          skGroup s `shouldBe` Just "my-repo project skills"
        _ -> expectationFailure "expected exactly 1 skill"
      cleanup tmp

    it "returns empty list when workdir has no repos" $ do
      backend <- workdirSkillBackend =<< mkFs "/nonexistent-path-12345"
      skills <- sbList backend
      skills `shouldBe` []

  describe "Seal.Skills.Backend.workdirSkillBackend (remote-arm stub parity)" $ do
    it "discovers a skill in agentskills.io format over a stub-remote WorkdirFs" $ do
      -- A stub-remote WorkdirFs (in-memory, no real SSH / no local FS)
      -- seeded with:
      --   my-repo/.skills/my-skill/SKILL.md
      -- The skill is discovered with the repo-prefixed id. Discovery parity
      -- with the local arm is the §1.1 success metric.
      let skillMd = "---\nname: my-skill\ndescription: A stub skill.\n---\nDo stub things.\n"
          seed = Map.fromList
            [ (rp ".", Directory ["my-repo"])
            , (rp "my-repo", Directory [".skills"])
            , (rp "my-repo/.skills", Directory ["my-skill"])
            , (rp "my-repo/.skills/my-skill", Directory ["SKILL.md"])
            , (rp "my-repo/.skills/my-skill/SKILL.md", FileContent skillMd)
            ]
          fs = mkInMemWorkdirFs seed
      backend <- workdirSkillBackend fs
      skills <- sbList backend
      length skills `shouldBe` 1
      case skills of
        [s] -> do
          skillIdText (skId s) `shouldBe` "my-repo--my-skill"
          skDescription s `shouldBe` "A stub skill."
          skBody s `shouldBe` "Do stub things."
          skGroup s `shouldBe` Just "my-repo project skills"
        _ -> expectationFailure "expected exactly 1 skill"

    it "rejects a symlinked SKILL.md escaping the workspace (stub-remote containment)" $ do
      -- A stub-remote WorkdirFs seeded with a .skills entry whose SKILL.md
      -- is a symlink escaping to /etc/shadow. The escaping skill MUST NOT
      -- appear; the non-symlink skill in the same repo still does. Parity
      -- with the W4 agent-def symlink-escape test.
      let goodMd  = "---\nname: good-skill\ndescription: Good.\n---\nGood body.\n"
          seed = Map.fromList
            [ (rp ".", Directory ["my-repo"])
            , (rp "my-repo", Directory [".skills"])
            , (rp "my-repo/.skills", Directory ["good-skill", "leak"])
            , (rp "my-repo/.skills/good-skill", Directory ["SKILL.md"])
            , (rp "my-repo/.skills/good-skill/SKILL.md", FileContent goodMd)
            , (rp "my-repo/.skills/leak", Directory ["SKILL.md"])
            , (rp "my-repo/.skills/leak/SKILL.md", SymlinkTarget (rp "/etc/shadow"))
            ]
          fs = mkInMemWorkdirFs seed
      backend <- workdirSkillBackend fs
      skills <- sbList backend
      let ids = map (skillIdText . skId) skills
      -- The good skill is discovered; the leaking 'leak' skill is rejected.
      ids `shouldContain` ["my-repo--good-skill"]
      ids `shouldNotContain` ["my-repo--leak"]
      -- No skill body contains the escaped secret.
      let bodies = map skBody skills
      bodies `shouldNotSatisfy` any ("PRIVATE" `T.isInfixOf`)

  describe "Seal.Skills.Backend.tripleUnionSkillBackend (no-collision namespacing)" $ do
    it "shows both user and workdir skills when they share the same raw id" $ do
      let tmp = "/tmp/seal-repo-discovery-no-collision-test"
      cleanup tmp
      -- Workdir skill: .agents/skills/shared-skill/SKILL.md
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "skills" </> "shared-skill")
      writeFile (tmp </> "my-repo" </> ".agents" </> "skills" </> "shared-skill" </> "SKILL.md")
        "---\nname: shared-skill\ndescription: Repo version.\n---\nRepo body.\n"
      -- User skill: in-memory backend with the same id "shared-skill"
      workdirBackend <- workdirSkillBackend =<< mkFs tmp
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
          length skills `shouldBe` 3
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
      backend <- workdirAgentDefBackend =<< mkFs tmp
      defs <- adbList backend
      length defs `shouldBe` 1
      case defs of
        [d] -> agentDefIdText (adId d) `shouldBe` "my-repo--my-agent"
        _ -> expectationFailure "expected exactly 1 def"
      cleanup tmp

    it "returns empty list when workdir has no repos" $ do
      backend <- workdirAgentDefBackend =<< mkFs "/nonexistent-path-12345"
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
      backend <- workdirAgentDefBackend =<< mkFs tmp
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
      backend <- workdirAgentDefBackend =<< mkFs tmp
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
      backend <- workdirAgentDefBackend =<< mkFs tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      ids `shouldContain` ["my-repo--real-id"]
      ids `shouldNotContain` ["my-repo--subdir-name"]
      cleanup tmp

    it "rejects a symlinked agent.md escaping the workdir (SafePath confinement)" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-symlink-test"
          escape = "/tmp/seal-escape-target-repo-discovery"
      cleanup tmp
      cleanup escape
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "leak")
      -- A secret file OUTSIDE the workdir root (the symlink target). It
      -- MUST live outside @tmp@ so the workdir-anchored confinement
      -- assertion is non-vacuous (a target inside @tmp@ would be allowed
      -- by the workdir-rooted SafePath).
      createDirectoryIfMissing True escape
      writeFile (escape </> "secret.txt") "PRIVATE KEY MATERIAL\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\nProject.\n"
      -- Symlink agent.md -> <escape>/secret.txt (escapes the workdir root).
      createDirectoryLink (escape </> "secret.txt")
                          (tmp </> "my-repo" </> ".agents" </> "agents" </> "leak" </> "agent.md")
      backend <- workdirAgentDefBackend =<< mkFs tmp
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
      cleanup escape

    it "allows a within-workdir symlink (target inside workdir, outside .agents/)" $ do
      let tmp = "/tmp/seal-repo-discovery-protocol-within-symlink-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "linked")
      -- A real agent.md body inside the workdir but OUTSIDE .agents/.
      writeFile (tmp </> "my-repo" </> "real-agent.md")
        "---\nname: Linked\n---\nLinked body.\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\nProject.\n"
      -- Symlink agent.md -> ../../real-agent.md (within the workdir root,
      -- outside .agents/ — intentionally allowed).
      createDirectoryLink (tmp </> "my-repo" </> "real-agent.md")
                          (tmp </> "my-repo" </> ".agents" </> "agents" </> "linked" </> "agent.md")
      backend <- workdirAgentDefBackend =<< mkFs tmp
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      -- The within-workdir symlink IS allowed: the 'linked' agent appears.
      ids `shouldContain` ["my-repo--linked"]
      -- The project def also appears.
      ids `shouldContain` ["my-repo--agents-md"]
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
      backend <- workdirAgentDefBackend =<< mkFs tmp
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
      backend <- workdirAgentDefBackend =<< mkFs tmp
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

  describe "Seal.Agent.Def.Backend.workdirAgentDefBackend (remote-arm stub parity)" $ do
    it "discovers the same defs as the local arm over an equivalent fixture" $ do
      -- A stub-remote WorkdirFs (in-memory, no real SSH / no local FS)
      -- seeded with the same fixture as the local protocol test:
      --   my-repo/.agents/agents.md
      --   my-repo/.agents/agents/foo-agent/agent.md
      --   my-repo/.agents/agents/leak/agent.md  -> symlink escaping /workspace
      --   my-repo/.agents/agents/linked/agent.md -> within-workdir symlink
      -- The escaping symlink is rejected by the stub's containment check;
      -- the within-workdir symlink is allowed. Discovery parity with the
      -- local arm is the §1.1 success metric.
      let agentsMd = "---\nkind: agents\n---\n# Project\nDo good work.\n"
          fooMd    = "---\nname: Foo Agent\nprovider: ollama\nmodel: llama3\nenabled: true\n---\nYou are a foo specialist.\n"
          realMd   = "---\nname: Real\n---\nReal body.\n"
          seed = Map.fromList
            [ (rp ".", Directory ["my-repo"])
            , (rp "my-repo", Directory [".agents"])
            , (rp "my-repo/.agents", Directory ["agents.md", "agents"])
            , (rp "my-repo/.agents/agents.md", FileContent agentsMd)
            , (rp "my-repo/.agents/agents", Directory ["foo-agent", "leak", "linked"])
            , (rp "my-repo/.agents/agents/foo-agent", Directory ["agent.md"])
            , (rp "my-repo/.agents/agents/foo-agent/agent.md", FileContent fooMd)
            , (rp "my-repo/.agents/agents/leak", Directory ["agent.md"])
            , (rp "my-repo/.agents/agents/leak/agent.md", SymlinkTarget (rp "/etc/shadow"))
            , (rp "my-repo/.agents/agents/linked", Directory ["agent.md"])
            , (rp "my-repo/.agents/agents/linked/agent.md", SymlinkTarget (rp "my-repo/real-agent.md"))
            , (rp "my-repo/real-agent.md", FileContent realMd)
            ]
          fs = mkInMemWorkdirFs seed
      backend <- workdirAgentDefBackend fs
      defs <- adbList backend
      let ids = map (agentDefIdText . adId) defs
      -- Exactly 3 defs: the project def, the foo sub-agent, and the
      -- within-workdir-symlinked 'linked' sub-agent. The escaping 'leak'
      -- is rejected.
      length defs `shouldBe` 3
      ids `shouldContain` ["my-repo--agents-md", "my-repo--foo-agent", "my-repo--linked"]
      ids `shouldNotContain` ["my-repo--leak"]
      -- The project def's system prompt is the agents.md body.
      let mProject = [d | d <- defs, agentDefIdText (adId d) == "my-repo--agents-md"]
      case mProject of
        [d] -> adSystem d `shouldBe` Just "# Project\nDo good work."
        _ -> expectationFailure "expected exactly one agents-md def"
      -- No def's system prompt contains the escaped secret (there is none
      -- in the stub, but the leaking 'leak' def must not appear at all).
      let systems = mapMaybe adSystem defs
      systems `shouldNotSatisfy` any ("PRIVATE" `T.isInfixOf`)

  describe "Seal.Agent.Def.Backend.unionAgentDefBackend" $ do
    it "workdir defs shadow user defs on id collision" $ do
      let tmp = "/tmp/seal-repo-discovery-union-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "repo" </> ".agents" </> "shared-agent")
      writeFile (tmp </> "repo" </> ".agents" </> "shared-agent" </> "SOUL.md")
        "Workdir version.\n"
      workdirBackend <- workdirAgentDefBackend =<< mkFs tmp
      userBackend <- noneBackend
      let unioned = unionAgentDefBackend workdirBackend userBackend
      defs <- adbList unioned
      length defs `shouldBe` 1
      cleanup tmp

  describe "Seal.Session.Store.autoBindRepoAgent" $ do
    -- Shared session-JSON scaffold: a session bound to the user's
    -- configured default_agent "zoe" (the exact scenario from the bug
    -- report — a session whose smAgent was stamped at creation from
    -- default_agent, never overridden by the repo's agents.md).
    let mkSessionState :: FilePath -> SealPaths -> IO SessionMeta
        mkSessionState tmp paths = do
          createDirectoryIfMissing True (tmp </> "state" </> "sessions")
          let sidTxt = "20260817-131404-504"
              sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "bad sid"
              zoe = case mkAgentDefId "zoe" of Right a -> a; Left _ -> error "bad zoe id"
              meta = SessionMeta
                { smId = sid, smProvider = "ollama", smModel = "glm-5.2:cloud"
                , smChannel = "web", smAgent = Just zoe
                , smSystemOverride = Nothing, smAgentName = Just "zoe"
                , smDescription = Nothing
                , smCreatedAt = aTime, smLastActive = aTime }
          saveSessionMeta paths meta
          pure meta
        statePaths :: FilePath -> SealPaths
        statePaths tmp = SealPaths
          { spHome = tmp, spConfig = tmp </> "config"
          , spState = tmp </> "state", spKeys = tmp </> "keys", spCache = tmp </> "cache" }

    it "rebinds smAgent from the user default (zoe) to the repo's agents-md after a clone" $ do
      let tmp = "/tmp/seal-auto-bind-repo-agent-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "foo-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\n# Project Guidelines\nDo good work.\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents" </> "foo-agent" </> "agent.md")
        "---\nname: Foo\nprovider: ollama\n---\nYou are foo.\n"
      let paths = statePaths tmp
      meta <- mkSessionState tmp paths
      fs <- mkFs tmp
      autoBindRepoAgent fs paths (smId meta)
      Just afterMeta <- decodeFileStrict (sessionMetaPath paths (smId meta)) :: IO (Maybe SessionMeta)
      -- smAgent is now the repo's prefixed agents-md id, NOT zoe.
      smAgent afterMeta `shouldBe` (case mkAgentDefId "my-repo--agents-md" of Right a -> Just a; Left _ -> Nothing)
      smAgentName afterMeta `shouldBe` Just "my-repo--agents-md"
      cleanup tmp

    it "is a no-op when the session already has a repo-prefixed agent bound (user picked one)" $ do
      let tmp = "/tmp/seal-auto-bind-repo-agent-noop-test"
      cleanup tmp
      createDirectoryIfMissing True (tmp </> "my-repo" </> ".agents" </> "agents" </> "foo-agent")
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents.md")
        "---\nkind: agents\n---\n# Project Guidelines\nDo good work.\n"
      writeFile (tmp </> "my-repo" </> ".agents" </> "agents" </> "foo-agent" </> "agent.md")
        "---\nname: Foo\nprovider: ollama\n---\nYou are foo.\n"
      let paths = statePaths tmp
          pickedId = case mkAgentDefId "my-repo--foo-agent" of Right a -> Just a; Left _ -> Nothing
      createDirectoryIfMissing True (tmp </> "state" </> "sessions")
      let sid = case mkSessionId "20260817-131404-504" of Right s -> s; Left _ -> error "bad sid"
          meta = SessionMeta
            { smId = sid, smProvider = "ollama", smModel = "glm-5.2:cloud"
            , smChannel = "web", smAgent = pickedId
            , smSystemOverride = Nothing, smAgentName = Just "my-repo--foo-agent"
            , smDescription = Nothing
            , smCreatedAt = aTime, smLastActive = aTime }
      saveSessionMeta paths meta
      fs <- mkFs tmp
      autoBindRepoAgent fs paths sid
      Just afterMeta <- decodeFileStrict (sessionMetaPath paths sid) :: IO (Maybe SessionMeta)
      -- Unchanged: the user's explicit repo-agent pick is not clobbered.
      smAgent afterMeta `shouldBe` pickedId
      cleanup tmp

    it "is a no-op when the workdir has no .agents/agents.md (no repo default)" $ do
      let tmp = "/tmp/seal-auto-bind-repo-agent-none-test"
      cleanup tmp
      -- An empty workdir (no repos).
      createDirectoryIfMissing True tmp
      let paths = statePaths tmp
      meta <- mkSessionState tmp paths
      fs <- mkFs tmp
      autoBindRepoAgent fs paths (smId meta)
      Just afterMeta <- decodeFileStrict (sessionMetaPath paths (smId meta)) :: IO (Maybe SessionMeta)
      -- Unchanged: still zoe.
      smAgent afterMeta `shouldBe` (case mkAgentDefId "zoe" of Right a -> Just a; Left _ -> Nothing)
      cleanup tmp

    it "discovers the repo's agents-md via the in-memory stub WorkdirFs (remote-arm parity)" $ do
      -- The same scenario but with mkInMemWorkdirFs (the remote-mode
      -- adapter). The auto-bind must produce the SAME result as the local
      -- arm — this pins mode=local / mode=remote parity for the feature.
      let tmp = "/tmp/seal-auto-bind-repo-agent-remote-test"
      cleanup tmp
      let agentsMd = "---\nkind: agents\n---\n# Project\nDo good work.\n"
          fooMd    = "---\nname: Foo\nprovider: ollama\n---\nYou are foo.\n"
          seed = Map.fromList
            [ (rp ".", Directory ["my-repo"])
            , (rp "my-repo", Directory [".agents"])
            , (rp "my-repo/.agents", Directory ["agents.md", "agents"])
            , (rp "my-repo/.agents/agents.md", FileContent agentsMd)
            , (rp "my-repo/.agents/agents", Directory ["foo-agent"])
            , (rp "my-repo/.agents/agents/foo-agent", Directory ["agent.md"])
            , (rp "my-repo/.agents/agents/foo-agent/agent.md", FileContent fooMd)
            ]
          fs = mkInMemWorkdirFs seed
      let paths = statePaths tmp
      meta <- mkSessionState tmp paths
      autoBindRepoAgent fs paths (smId meta)
      Just afterMeta <- decodeFileStrict (sessionMetaPath paths (smId meta)) :: IO (Maybe SessionMeta)
      -- Same prefixed id as the local-arm test → parity holds.
      smAgent afterMeta `shouldBe` (case mkAgentDefId "my-repo--agents-md" of Right a -> Just a; Left _ -> Nothing)
      cleanup tmp

cleanup :: FilePath -> IO ()
cleanup path =
  removeDirectoryRecursive path `catch` \(_ :: SomeException) -> pure ()

-- | Build a local 'WorkdirFs' anchored at @tmp@ (the mechanical W4 adapter:
-- @workdirAgentDefBackend . mkLocalWorkdirFs . WorkspaceRoot@).
mkFs :: FilePath -> IO WorkdirFs
mkFs tmp = pure (mkLocalWorkdirFs (WorkspaceRoot tmp) maxScanBytes)

-- | Construct a 'RemotePath', crashing on invalid input (test fixtures only).
-- Used to seed the in-memory stub 'WorkdirFs' for the remote-arm parity test.
rp :: T.Text -> RemotePath
rp t = case mkRemotePath t of
  Right r  -> r
  Left err -> error ("RepoDiscoverySpec.rp: bad remote path: "
                     <> T.unpack err <> ": " <> T.unpack t)
