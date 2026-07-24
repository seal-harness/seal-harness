{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Shared 'Arbitrary' instances for the 'Seal.Core.Types' newtypes and the
-- provider-agnostic message model.
--
-- Import this module in any test suite that needs to generate values of
-- these types. Having a single source of truth avoids duplicate-instance
-- errors when multiple spec modules are compiled into the same test binary.
module Seal.TestHelpers.Arbitrary () where

import Data.Aeson (Value (..))
import Data.Either (fromRight)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.QuickCheck

import Seal.Core.Paging (PageParams (..))
import Seal.Core.Types (ModelId (..), OpName (..), ProviderId (..), SessionId, mkSessionId, mkSystemSessionId, ToolCallId (..))
import Seal.Providers.Class
  ( CompletionResponse (..), ContentBlock (..), Message (..)
  , Role (..), StopReason (..), Usage (..), ToolChoice (..)
  , ToolDefinition (..), ToolResultPart (..) )
import Seal.Transcript.Entries (EnvelopeDelta (..))
import Seal.Memory.Types (MemoryEntry (..), MemoryId (..), mkMemoryId)
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId)
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId)
import Seal.Security.Policy (AllowList (..))

instance Arbitrary ToolCallId where
  arbitrary = ToolCallId . pack <$> arbitrary

instance Arbitrary OpName where
  arbitrary = OpName . pack <$> arbitrary

instance Arbitrary ProviderId where
  arbitrary = ProviderId . pack <$> arbitrary

instance Arbitrary ModelId where
  arbitrary = ModelId . pack <$> arbitrary

-- | 'Data.Text.Text' wrapper around an arbitrary 'String'. Generates a small
-- alphabet of printable characters; no newlines (so a generated value is a
-- single line).
-- | A safe 'SessionId' generator producing valid ids ([A-Za-z0-9_-]+,
-- non-empty, no leading dot). Uses 'mkSessionId' (not the raw
-- constructor, which is locked down).
genSessionId :: Gen SessionId
genSessionId = do
  c  <- elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'])
  cs <- listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "_-"))
  pure (fromRight (mkSystemSessionId "x") (mkSessionId (pack (c : cs))))

instance Arbitrary Text where
  arbitrary = pack <$> listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> " .,!?"++"-_"))

-- | 'Seal.Core.Paging.PageParams' under the invariants
-- (1 <= ppFloor <= ppCeiling, ppCoeff >= 0).
instance Arbitrary PageParams where
  arbitrary = do
    floor'   <- chooseInt (1, 200)
    ceiling' <- (floor' +) <$> chooseInt (0, 400)
    coeff    <- choose (0, 100 :: Double)
    pure (PageParams floor' ceiling' coeff)

instance Arbitrary Role where
  arbitrary = elements [User, Assistant]

instance Arbitrary ToolResultPart where
  arbitrary = TrpText . pack <$> arbitrary

instance Arbitrary ContentBlock where
  arbitrary = oneof
    [ CbText . pack <$> arbitrary
    , CbToolUse <$> arbitrary <*> arbitrary <*> pure Null
    , CbToolResult <$> arbitrary <*> arbitrary <*> arbitrary
    ]

instance Arbitrary Message where
  arbitrary = Message <$> arbitrary <*> arbitrary

instance Arbitrary Usage where
  arbitrary = Usage <$> arbitrary <*> arbitrary

instance Arbitrary StopReason where
  arbitrary = oneof
    [ pure StopEnd
    , pure StopToolUse
    , pure StopMaxTokens
    , StopOther . pack <$> arbitrary
    ]

instance Arbitrary CompletionResponse where
  arbitrary = CompletionResponse <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary ToolDefinition where
  arbitrary = ToolDefinition <$> arbitrary <*> arbitrary <*> pure Null

instance Arbitrary ToolChoice where
  arbitrary = elements [ToolAuto, ToolNone]

instance Arbitrary EnvelopeDelta where
  arbitrary = EnvelopeDelta
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary

-- | A bounded 'UTCTime' generator: a day in 2020-2030 + a time-of-day in
-- [0, 24h). Keeps generated entries ordered-ish and avoids overflow.
instance Arbitrary UTCTime where
  arbitrary = do
    year  <- chooseInt (2020, 2030)
    month <- chooseInt (1, 12)
    day   <- chooseInt (1, 28)
    secs  <- chooseInt (0, 86399)
    pure (UTCTime (fromGregorian (fromIntegral year) month day)
                  (secondsToDiffTime (fromIntegral secs)))

-- | A 'MemoryId' generator producing valid ids ([A-Za-z0-9_-]+, non-empty).
instance Arbitrary MemoryId where
  arbitrary = do
    c  <- elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'])
    cs <- listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "_-"))
    pure (fromRight (MemoryId "x") (mkMemoryId (pack (c : cs))))

instance Arbitrary MemoryEntry where
  arbitrary = MemoryEntry
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> genSessionId

-- | A 'SkillId' generator producing valid ids ([A-Za-z0-9_-]+, non-empty).
instance Arbitrary SkillId where
  arbitrary = do
    c  <- elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'])
    cs <- listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "_-"))
    pure (fromRight (SkillId "x") (mkSkillId (pack (c : cs))))

instance Arbitrary Skill where
  arbitrary = Skill
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> genSessionId

-- | An 'AgentDefId' generator producing valid ids ([A-Za-z0-9_-]+, non-empty).
instance Arbitrary AgentDefId where
  arbitrary = do
    c  <- elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'])
    cs <- listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "_-"))
    pure (fromRight (AgentDefId "x") (mkAgentDefId (pack (c : cs))))

-- | An 'AllowList a' generator: half 'AllowAll', half a small 'AllowOnly'
-- set (kept small to avoid huge generated defs). Needs 'Ord' for 'Set.fromList'.
instance (Ord a, Arbitrary a) => Arbitrary (AllowList a) where
  arbitrary = oneof
    [ pure AllowAll
    , AllowOnly . Set.fromList <$> listOf arbitrary
    ]

instance Arbitrary AgentDef where
  arbitrary = AgentDef
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> genSessionId
