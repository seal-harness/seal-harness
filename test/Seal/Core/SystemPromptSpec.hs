{-# LANGUAGE OverloadedStrings #-}
-- | Unit tests for the "Add Seal Harness front matter" toggle: when the
-- session's 'smSealFrontMatter' is 'False', the resolved system prompt is
-- the selected agent's prompt and NOTHING else — no static guidance
-- blocks, no auto-loaded skill, no codegraph skill, no available-skills
-- catalog, no available-agents catalog.
module Seal.Core.SystemPromptSpec (spec) where

import Data.Either (fromRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types
  ( AgentDef (..), mkAgentDefId )
import Seal.Core.TurnEngine (resolveSystemPrompt)
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Security.Policy (AllowList (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Skills.Backend qualified as Skill
import Seal.Skills.Types
  ( Skill (..), mkSkillId )

spec :: Spec
spec = describe "resolveSystemPrompt (Seal Harness front matter toggle)" $ do
  frontMatterOnSpec
  frontMatterOffSpec

-- ── Helpers ────────────────────────────────────────────────────────────

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) 0

-- | A session bound to the @zoe@ agent, with the given front-matter
-- setting.
metaWith :: Bool -> SessionMeta
metaWith frontMatter =
  let sid = fromRight (error "bad sid") (mkSessionId "20260701-120000-001")
      aid = fromRight (error "bad agent id") (mkAgentDefId "zoe")
  in SessionMeta
       { smId = sid, smProvider = "anthropic", smModel = "claude-opus-4-8"
       , smChannel = "web", smParent = Nothing, smAgent = Just aid, smSystemOverride = Nothing
       , smAgentName = Just "zoe", smDescription = Nothing
       , smSealFrontMatter = frontMatter
       , smRepoUrl = Nothing
       , smCreatedAt = sampleTime, smLastActive = sampleTime
       , smAllowedSecrets = Nothing }

-- | An agent def whose system prompt is a distinctive marker, so the test
-- can assert the agent's prompt IS (and IS ONLY) in the result.
defBackend :: IO Def.AgentDefBackend
defBackend = Def.staticAgentDefBackend [agentDef]

agentDef :: AgentDef
agentDef =
  let aid = fromRight (error "bad agent id") (mkAgentDefId "zoe")
  in AgentDef
       { adId = aid, adName = "zoe", adProvider = "anthropic"
       , adModel = ModelId "claude-opus-4-8"
       , adSystem = Just "AGENT_SYSTEM_MARKER"
       , adTools = AllowAll, adGroup = Nothing, adRole = Nothing
       , adDescription = Nothing
       , adAllowSpawn = Nothing
       , adCreatedAt = sampleTime, adUpdatedAt = sampleTime
       , adSession = fromRight (error "bad sid") (mkSessionId "20260701-120000-001") }

-- | A skill backend holding one skill, so the available-skills catalog and
-- the autoload injection have something to add.
skillBackend :: IO Skill.SkillBackend
skillBackend = Skill.staticSkillBackend [skill]

skill :: Skill
skill =
  let sid = fromRight (error "bad skill id") (mkSkillId "seal-usage")
  in Skill
       { skId = sid, skDescription = "the seal-usage skill"
       , skBody = "SKILL_BODY_MARKER", skGroup = Nothing
       , skCreatedAt = sampleTime, skUpdatedAt = sampleTime
       , skSession = fromRight (error "bad sid") (mkSessionId "20260701-120000-001") }

-- | Resolve the prompt with the front matter ENABLED (all injections on).
resolveOn :: SessionMeta -> IO (Maybe Text)
resolveOn meta = do
  defs <- defBackend
  skills <- skillBackend
  resolveSystemPrompt defs skills
    (Just "seal-usage")   -- autoload the skill
    True                  -- inject the available-skills catalog
    True                  -- inject the available-agents catalog
    [agentDef]
    True True True True   -- all four static guidance blocks
    (Just "CODEGRAPH_MARKER")
    meta

-- | Resolve the prompt with the front matter DISABLED.
resolveOff :: SessionMeta -> IO (Maybe Text)
resolveOff = resolveOn

-- ── Front matter ON (the default) ──────────────────────────────────────

frontMatterOnSpec :: Spec
frontMatterOnSpec = describe "front matter ON (default)" $ do
  it "includes the agent's prompt and the harness front matter" $ do
    out <- resolveOn (metaWith True)
    case out of
      Just s -> do
        T.isInfixOf "AGENT_SYSTEM_MARKER" s `shouldBe` True
        T.isInfixOf "Parallel tool calls" s `shouldBe` True
        T.isInfixOf "SKILL_BODY_MARKER" s `shouldBe` True
        T.isInfixOf "CODEGRAPH_MARKER" s `shouldBe` True
        T.isInfixOf "<available_skills>" s `shouldBe` True
        T.isInfixOf "<available_agents>" s `shouldBe` True
      Nothing -> expectationFailure "expected a system prompt"

-- ── Front matter OFF ───────────────────────────────────────────────────

frontMatterOffSpec :: Spec
frontMatterOffSpec = describe "front matter OFF (toggle off)" $ do
  it "returns ONLY the agent's prompt — nothing else is added" $ do
    out <- resolveOff (metaWith False)
    out `shouldBe` Just "AGENT_SYSTEM_MARKER"

  it "omits the static guidance blocks" $ do
    out <- resolveOff (metaWith False)
    case out of
      Just s -> do
        T.isInfixOf "Parallel tool calls" s `shouldBe` False
        T.isInfixOf "Tool use" s `shouldBe` False
        T.isInfixOf "Task completion" s `shouldBe` False
        T.isInfixOf "Credential-bearing tools" s `shouldBe` False
      Nothing -> expectationFailure "expected a system prompt"

  it "omits the auto-loaded skill body" $ do
    out <- resolveOff (metaWith False)
    fmap (T.isInfixOf "SKILL_BODY_MARKER") out `shouldBe` Just False

  it "omits the codegraph skill body" $ do
    out <- resolveOff (metaWith False)
    fmap (T.isInfixOf "CODEGRAPH_MARKER") out `shouldBe` Just False

  it "omits the available-skills and available-agents catalogs" $ do
    out <- resolveOff (metaWith False)
    case out of
      Just s -> do
        T.isInfixOf "<available_skills>" s `shouldBe` False
        T.isInfixOf "<available_agents>" s `shouldBe` False
      Nothing -> expectationFailure "expected a system prompt"

  it "uses the one-off system override verbatim when set" $ do
    let m = (metaWith False) { smSystemOverride = Just "OVERRIDE_MARKER" }
    out <- resolveOff m
    out `shouldBe` Just "OVERRIDE_MARKER"

  it "yields Nothing when no agent is bound and there is no override" $ do
    let m = (metaWith False) { smAgent = Nothing, smSystemOverride = Nothing }
    out <- resolveOff m
    out `shouldBe` Nothing
