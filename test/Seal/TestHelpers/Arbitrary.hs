{-# OPTIONS_GHC -Wno-orphans #-}
-- | Shared 'Arbitrary' instances for the 'Seal.Core.Types' newtypes and the
-- provider-agnostic message model.
--
-- Import this module in any test suite that needs to generate values of
-- these types. Having a single source of truth avoids duplicate-instance
-- errors when multiple spec modules are compiled into the same test binary.
module Seal.TestHelpers.Arbitrary () where

import Data.Aeson (Value (..))
import Data.Text (Text, pack)
import Test.QuickCheck

import Seal.Core.Paging (PageParams (..))
import Seal.Core.Types (ModelId (..), OpName (..), ProviderId (..), ToolCallId (..))
import Seal.Providers.Class
  ( CompletionResponse (..), ContentBlock (..), Message (..)
  , Role (..), StopReason (..), Usage (..), ToolChoice (..)
  , ToolDefinition (..), ToolResultPart (..) )
import Seal.Transcript.Entries (EnvelopeDelta (..))

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
