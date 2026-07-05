{-# OPTIONS_GHC -Wno-orphans #-}
-- | Shared 'Arbitrary' instances for the 'Seal.Core.Types' newtypes.
--
-- Import this module in any test suite that needs to generate values of
-- these types. Having a single source of truth avoids duplicate-instance
-- errors when multiple spec modules are compiled into the same test binary.
module Seal.TestHelpers.Arbitrary () where

import Data.Text (pack)
import Test.QuickCheck

import Seal.Core.Types (ModelId (..), OpName (..), ProviderId (..), ToolCallId (..))

instance Arbitrary ToolCallId where
  arbitrary = ToolCallId . pack <$> arbitrary

instance Arbitrary OpName where
  arbitrary = OpName . pack <$> arbitrary

instance Arbitrary ProviderId where
  arbitrary = ProviderId . pack <$> arbitrary

instance Arbitrary ModelId where
  arbitrary = ModelId . pack <$> arbitrary
