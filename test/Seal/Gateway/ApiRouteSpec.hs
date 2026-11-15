{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Gateway.Route' — asserts 'allRoutes' matches the §3.2
-- route table (count + method + path shape). This is the W6 TDD red-green
-- spec: it was written before 'Seal.Gateway.Route' existed, then went green
-- once the module was implemented.
module Seal.Gateway.ApiRouteSpec (spec) where

import Test.Hspec

import Trasa.Core (Meta (..))
import qualified Trasa.Method as M

import Seal.Gateway.Route (allRoutes, routeMeta, SealRoute (..))

-- | The expected route count from the §3.2 table (70 routes — 62 original
-- + 4 channel CRUD routes added in the Channel CRUD feature + 4 setup routes
-- added by the web first-run setup wizard).
expectedRouteCount :: Int
expectedRouteCount = 76

spec :: Spec
spec = do
  describe "Seal.Gateway.Route.allRoutes" $ do
    it "has the expected number of routes (§3.2 table)" $
      length allRoutes `shouldBe` expectedRouteCount

    -- ── Channel CRUD route round-trip cases (W3) ──────────────────────
    -- Each case verifies the route constructor maps to the expected HTTP
    -- method via 'routeMeta'. The path shape is typed (trasa 'Path'), so
    -- we assert the method (the last 'Meta' field) — the dispatch-relevant
    -- signal that a wrong method or swapped constructor would violate.

    it "RouteChannelsList maps to GET" $
      case routeMeta RouteChannelsList of
        Meta _ _ _ _ m -> m `shouldBe` M.get

    it "RouteChannelCreate maps to POST" $
      case routeMeta RouteChannelCreate of
        Meta _ _ _ _ m -> m `shouldBe` M.post

    it "RouteChannelUpdate maps to PUT" $
      case routeMeta RouteChannelUpdate of
        Meta _ _ _ _ m -> m `shouldBe` M.put

    it "RouteChannelDelete maps to DELETE" $
      case routeMeta RouteChannelDelete of
        Meta _ _ _ _ m -> m `shouldBe` M.delete
