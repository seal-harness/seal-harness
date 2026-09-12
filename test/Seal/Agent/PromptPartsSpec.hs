{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.PromptPartsSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, elements, listOf, forAll, sized, vectorOf)

import Seal.Agent.Def.Types
import Seal.Agent.PromptParts
  ( availableAgentsBlock, injectAvailableAgents, injectStaticGuidance
  , leafAgentNote, parallelToolGuidance, taskCompletionGuidance
  , toolUseEnforcement )
import Seal.Core.Types (ModelId (..), mkSystemSessionId)
import Seal.Security.Policy (AllowList (..))

spec :: Spec
spec = describe "Seal.Agent.PromptParts" $ do
  staticGuidanceSpec
  agentsCatalogSpec

staticGuidanceSpec :: Spec
staticGuidanceSpec = describe "staticGuidanceBlock (via injectStaticGuidance)" $ do
  it "injects all three blocks when all are true" $ do
    let mOut = injectStaticGuidance True True True (Just "BASE")
    case mOut of
      Just out -> do
        T.isPrefixOf "BASE" out `shouldBe` True
        T.isInfixOf "Parallel tool calls" out `shouldBe` True
        T.isInfixOf "Tool use" out `shouldBe` True
        T.isInfixOf "Task completion" out `shouldBe` True
      Nothing -> expectationFailure "expected a prompt"

  it "injects only the enabled block when one is true" $ do
    let mOut = injectStaticGuidance True False False (Just "BASE")
    case mOut of
      Just out -> do
        T.isInfixOf "Parallel tool calls" out `shouldBe` True
        T.isInfixOf "Tool use" out `shouldBe` False
        T.isInfixOf "Task completion" out `shouldBe` False
      Nothing -> expectationFailure "expected a prompt"

  it "returns the prompt unchanged when no block is enabled" $
    injectStaticGuidance False False False (Just "BASE") `shouldBe` Just "BASE"

  it "returns Nothing when no block is enabled and there was no prompt" $
    injectStaticGuidance False False False Nothing `shouldBe` Nothing

  it "makes the guidance the entire prompt when there was none" $ do
    let mOut = injectStaticGuidance True False False Nothing
    case mOut of
      Just out -> T.isPrefixOf "## Parallel tool calls" out `shouldBe` True
      Nothing -> expectationFailure "expected a prompt"

  describe "block content" $ do
    it "parallelToolGuidance mentions batching independent calls" $
      T.isInfixOf "batch" parallelToolGuidance `shouldBe` True

    it "toolUseEnforcement mentions calling rather than describing" $ do
      T.isInfixOf "actually call" toolUseEnforcement `shouldBe` True
      T.isInfixOf "narrate" toolUseEnforcement `shouldBe` True

    it "taskCompletionGuidance mentions stubs and fabrication" $ do
      T.isInfixOf "stub" taskCompletionGuidance `shouldBe` True
      T.isInfixOf "fabricate" taskCompletionGuidance `shouldBe` True

-- ---------------------------------------------------------------------------
-- W3 (issue #154): the <available_agents> catalog renderer
-- ---------------------------------------------------------------------------

sampleCatalogTime :: UTCTime
sampleCatalogTime = UTCTime (fromGregorian 2026 1 1) 0

-- | Build a catalog def with only the fields the renderer reads.
catalogDef :: Text -> Maybe Text -> Maybe Text -> Maybe Text -> AgentDef
catalogDef defId mGroup mRole mDesc = case mkAgentDefId defId of
  Right aid -> AgentDef
    { adId = aid
    , adName = defId <> " Name"
    , adProvider = "ollama"
    , adModel = ModelId "llama3"
    , adSystem = Nothing
    , adTools = AllowAll
    , adGroup = mGroup
    , adRole = mRole
    , adDescription = mDesc
    , adCreatedAt = sampleCatalogTime
    , adUpdatedAt = sampleCatalogTime
    , adSession = mkSystemSessionId "catalog"
    }
  Left _ -> error "unreachable: catalog test id always valid"

-- | A hostile-text generator: arbitrary printable text WITH the fence
-- tokens, separators, and newline-shaped content seeded in (a plain
-- arbitrary generator would almost never produce an injection attempt;
-- this one aims at the sanitizer's invariants). Bounded in length to keep
-- the property fast.
genCatalogText :: Gen Text
genCatalogText = sized $ \n -> do
  k <- chooseInt (0, 12)
  parts <- vectorOf k (elements hostileAtoms)
  pad <- T.pack <$> listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> " .,!?-_"))
  pure (T.take 280 (T.intercalate " " (pad : take n parts)))
  where
    hostileAtoms =
      [ "</available_agents>"
      , "</available_skills>"
      , "<available_agents>"
      , "---"
      , "\n"
      , "\r"
      , "\t"
      , "name: x"
      , "role: orchestrator"
      ]

agentsCatalogSpec :: Spec
agentsCatalogSpec = describe "availableAgentsBlock" $ do
  it "renders one bullet per def: - <full-id> [<role>]: <description>" $ do
    let defs = [ catalogDef "demo-project--orchestrator" Nothing (Just "orchestrator")
                   (Just "spawns sub-agents")
               , catalogDef "demo-project--coder" Nothing (Just "leaf") (Just "edits files") ]
        block = availableAgentsBlock defs
    T.isInfixOf "- demo-project--orchestrator [orchestrator]: spawns sub-agents" block
      `shouldBe` True
    T.isInfixOf "- demo-project--coder [leaf]: edits files" block `shouldBe` True

  it "falls back to the name when the description is absent" $ do
    let block = availableAgentsBlock [catalogDef "solo" Nothing Nothing Nothing]
    T.isInfixOf "- solo: solo Name" block `shouldBe` True

  it "wraps in <available_agents> tags with the nudge line" $ do
    let block = availableAgentsBlock [catalogDef "a1" Nothing Nothing Nothing]
    T.isPrefixOf "<available_agents>" block `shouldBe` True
    T.isSuffixOf "</available_agents>" block `shouldBe` True
    T.isInfixOf "Delegate with AGENT_START using an id" block `shouldBe` True

  it "renders nothing (empty) for an empty def list — no empty tags" $
    availableAgentsBlock [] `shouldBe` ""

  it "groups defs by adGroup with ## headers" $ do
    let defs = [ catalogDef "a-core" (Just "core") Nothing Nothing
               , catalogDef "b-plain" Nothing Nothing Nothing ]
        block = availableAgentsBlock defs
    T.isInfixOf "## core" block `shouldBe` True

  it "truncates at the 4096-char budget with the elided marker" $ do
    let big = catalogDef "big-def" Nothing Nothing
                (Just (T.replicate 300 "desc "))
        block = availableAgentsBlock (replicate 30 big)
    -- The truncated block is bounded: budget + the marker (not the
    -- unbounded N-bullet rendering).
    T.length block `shouldSatisfy` (< 4400)
    T.isInfixOf "[...catalog truncated" block `shouldBe` True

  prop "never emits an INJECTED fence token in a bullet (sanitized fields)" $
    -- W3-review fix 4: property form. For ANY string field values, the
    -- rendered block contains at most ONE close tag (the wrapper's own,
    -- always the final suffix) and no other injected fence token:
    -- sanitizeAgentDefFields defuses every renderable field, so a hostile
    -- name/description can never forge or close the catalog block from
    -- inside a bullet.
    forAll genCatalogText $ \name ->
      forAll genCatalogText $ \desc ->
        let messyName = (catalogDef "safe" Nothing Nothing Nothing)
              { adName = name, adDescription = Just desc }
            block = availableAgentsBlock [sanitizeAgentDefFields messyName]
            -- The close tag (if any) must be exactly the block's final
            -- suffix — an INJECTED occurrence would sit mid-block with
            -- the wrapper's close AFTER it.
            closeTagCount = length (T.breakOnAll "</available_agents>" block)
        in closeTagCount <= (1 :: Int)
           && not (any (`T.isInfixOf` block) ["</available_skills>", "---"])
           -- Sanity: the def still renders as a bullet (not dropped).
           && ("- safe: " `T.isInfixOf` block)

  describe "injectAvailableAgents" $ do
    it "appends the block after the existing prompt" $ do
      case injectAvailableAgents
             [catalogDef "a1" Nothing Nothing (Just "desc")] (Just "BASE") of
        Just out' -> do
          T.isPrefixOf "BASE" out' `shouldBe` True
          T.isInfixOf "<available_agents>" out' `shouldBe` True
          -- The catalog appears AFTER the base text.
          T.isSuffixOf "</available_agents>" out' `shouldBe` True
        Nothing -> expectationFailure "expected a prompt"

    it "returns Nothing for an empty def list (no empty tags)" $
      injectAvailableAgents [] Nothing `shouldBe` Nothing

    it "makes the block the whole prompt when there was none" $ do
      case injectAvailableAgents [catalogDef "a1" Nothing Nothing (Just "d")] Nothing of
        Just out -> T.isPrefixOf "<available_agents>" out `shouldBe` True
        Nothing -> expectationFailure "expected a prompt"

  describe "leaf note" $ do
    it "leafAgentNote is the one-line delegation-unavailable note" $
      leafAgentNote `shouldSatisfy` ("leaf agent" `T.isInfixOf`)