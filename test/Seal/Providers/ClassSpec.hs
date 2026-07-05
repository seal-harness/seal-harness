{-# LANGUAGE OverloadedStrings #-}
-- | Round-trip properties for the provider-agnostic message model.
module Seal.Providers.ClassSpec (spec) where

import Data.Aeson (decode, encode)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ((===))

import Seal.Providers.Class
import Seal.TestHelpers.Arbitrary ()

spec :: Spec
spec = describe "Seal.Providers.Class" $ do
  prop "Message round-trips" $ \m ->
    decode (encode (m :: Message)) === Just m
  prop "CompletionResponse round-trips" $ \r ->
    decode (encode (r :: CompletionResponse)) === Just r
