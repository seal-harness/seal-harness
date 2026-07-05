{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Round-trip properties for the provider-agnostic message model.
module Seal.Providers.ClassSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Text (pack)
import qualified Data.Aeson as A
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Providers.Class
import Seal.TestHelpers.Arbitrary ()

spec :: Spec
spec = describe "Seal.Providers.Class" $ do
  prop "Message round-trips" $ \m ->
    decode (encode (m :: Message)) === Just m
  prop "CompletionResponse round-trips" $ \r ->
    decode (encode (r :: CompletionResponse)) === Just r

-- ---------------------------------------------------------------------------
-- Arbitrary instances (orphans, suppressed above)
-- ---------------------------------------------------------------------------

instance Arbitrary Role where
  arbitrary = elements [User, Assistant]

instance Arbitrary ToolResultPart where
  arbitrary = TrpText . pack <$> arbitrary

instance Arbitrary ContentBlock where
  arbitrary = oneof
    [ CbText . pack <$> arbitrary
    , CbToolUse <$> arbitrary <*> arbitrary <*> pure A.Null
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
