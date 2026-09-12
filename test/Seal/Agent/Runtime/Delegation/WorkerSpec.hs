{-# LANGUAGE OverloadedStrings #-}
-- | Pure-function tests for the W2 delegation mechanics (issue #154):
-- the role-aware child blocklist, the effective-role resolver, and the
-- def-tools intersection. The integration behavior (nested AGENT_START,
-- depth plumb) lives in Gateway.AgentIntegrationSpec.
module Seal.Agent.Runtime.Delegation.WorkerSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Seal.Agent.Runtime.Delegation.Worker
import Seal.Core.Types (OpName (..))
import Seal.Security.Policy (AllowList (..))
import Seal.TestHelpers.Arbitrary ()

agentStart :: OpName
agentStart = OpName "AGENT_START"

spec :: Spec
spec = describe "Seal.Agent.Runtime.Delegation.Worker" $ do
  describe "childBlocklist" $ do
    it "always drops AGENT_START (the gated nested op is the enforcement)" $ do
      Set.member agentStart (childBlocklist (Just "leaf") True) `shouldBe` False
      Set.member agentStart (childBlocklist Nothing True) `shouldBe` False
      Set.member agentStart (childBlocklist (Just "orchestrator") True) `shouldBe` False
      Set.member agentStart (childBlocklist (Just "orchestrator") False) `shouldBe` False

    it "always blocks the rest of the blocklist (membership)" $ do
      let bl = childBlocklist (Just "orchestrator") True
      Set.member (OpName "AGENT_DEF_WRITE") bl `shouldBe` True
      Set.member (OpName "AGENT_DEF_DELETE") bl `shouldBe` True
      Set.member (OpName "AGENT_INSTANCES") bl `shouldBe` True
      Set.member (OpName "AGENT_STATUS") bl `shouldBe` True
      Set.member (OpName "AGENT_STOP") bl `shouldBe` True
      Set.member (OpName "AGENT_INTERRUPT") bl `shouldBe` True

    it "is a subset of the static delegationBlocklist (property)" $
      property $ \r e ->
        Set.isSubsetOf (childBlocklist (roleText <$> r) e) delegationBlocklist

  describe "narrowAllowList (role-aware)" $ do
    it "keeps AGENT_START (present-but-rejecting via the gate)" $
      narrowAllowListWith
        (childBlocklist (Just "leaf") True)
        (AllowOnly (Set.fromList [agentStart, OpName "FILE_READ"]))
        `shouldBe` AllowOnly (Set.fromList [agentStart, OpName "FILE_READ"])

  describe "effectiveRole" $ do
    it "orchestrator def + no ctRole = orchestrator" $
      effectiveRole (Just "orchestrator") Nothing `shouldBe` Just "orchestrator"

    it "orchestrator def + ctRole leaf = leaf (narrowing)" $
      effectiveRole (Just "orchestrator") (Just "leaf") `shouldBe` Just "leaf"

    it "orchestrator def + ctRole orchestrator = orchestrator (no-op)" $
      effectiveRole (Just "orchestrator") (Just "orchestrator") `shouldBe` Just "orchestrator"

    it "orchestrator def + garbage ctRole = orchestrator (ignored, not widened)" $
      effectiveRole (Just "orchestrator") (Just "admin") `shouldBe` Just "orchestrator"

    it "leaf def + ctRole orchestrator = leaf (never widened)" $
      effectiveRole (Just "leaf") (Just "orchestrator") `shouldBe` Just "leaf"

    it "leaf def + garbage ctRole = leaf" $
      effectiveRole (Just "leaf") (Just "admin") `shouldBe` Just "leaf"

    it "no def role + anything = leaf" $ do
      effectiveRole Nothing Nothing `shouldBe` Nothing
      effectiveRole Nothing (Just "orchestrator") `shouldBe` Nothing

    it "a leaf def can never be widened by any task input (property)" $
      property $ \ct -> ioProperty $
        case effectiveRole (Just "leaf") (fmap roleText ct) of
          Nothing     -> pure ()
          Just "leaf" -> pure ()
          Just other  -> expectationFailure ("widened to: " <> T.unpack other)

  describe "intersectAllowList (def tools ∧ base ops)" $ do
    it "AllowOnly keeps only ops that exist in the base set" $ do
      let base = Set.fromList [agentStart, OpName "FILE_READ"]
      intersectAllowList (AllowOnly (Set.fromList [agentStart, OpName "GHOST_OP"]))
                         (`Set.member` base)
        `shouldBe` AllowOnly (Set.fromList [agentStart])

    it "unknown tool names silently drop (no error)" $ do
      let base = Set.fromList [OpName "FILE_READ"]
      intersectAllowList (AllowOnly (Set.fromList [OpName "GHOST_OP"]))
                         (`Set.member` base)
        `shouldBe` AllowOnly Set.empty

    it "AllowAll stays AllowAll" $
      intersectAllowList AllowAll (`Set.member` Set.empty) `shouldBe` AllowAll

    it "intersection is always a subset of base ops (property)" $
      property $ \allowList ->
        case intersectAllowList allowList (`Set.member` baseSet) of
          AllowOnly xs -> Set.isSubsetOf xs baseSet
          AllowAll     -> True

  where
    roleText :: Text -> Text
    roleText t = case T.strip t of
      "" -> "leaf"
      r  -> r

-- Placeholder base set for the intersection property (the real base ops
-- list lives in buildChildRegistry; the property only needs SOME universe).
baseSet :: Set.Set OpName
baseSet = Set.fromList
  [ agentStart, OpName "FILE_READ", OpName "FILE_WRITE", OpName "MEMORY_RECALL" ]