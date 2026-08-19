{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Gateway.Route' — asserts 'allRoutes' matches the §3.2
-- route table (count + method + path shape). This is the W6 TDD red-green
-- spec: it was written before 'Seal.Gateway.Route' existed, then went green
-- once the module was implemented.
module Seal.Gateway.ApiRouteSpec (spec) where

import Test.Hspec

import Seal.Gateway.Route (allRoutes)

-- | The expected route count from the §3.2 table (54 routes).
expectedRouteCount :: Int
expectedRouteCount = 54

spec :: Spec
spec = do
  describe "Seal.Gateway.Route.allRoutes" $ do
    it "has the expected number of routes (§3.2 table)" $
      length allRoutes `shouldBe` expectedRouteCount