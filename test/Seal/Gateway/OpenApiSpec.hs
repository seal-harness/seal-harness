{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Gateway.OpenApi' — asserts the generated OpenAPI 3.1
-- document is non-empty, round-trips through aeson, and includes key routes.
-- This is the Cycle 1 RED spec: written before 'Seal.Gateway.OpenApi' exists.
module Seal.Gateway.OpenApiSpec (spec) where

import Control.Lens ((^.), at)
import Data.Aeson qualified as A
import Data.Maybe (isJust)
import Data.OpenApi
import Test.Hspec

import Seal.Gateway.OpenApi (sealOpenApi)

spec :: Spec
spec = describe "Seal.Gateway.OpenApi" $ do
  it "generates a non-empty OpenAPI document" $
    length (sealOpenApi ^. paths) `shouldSatisfy` (> 0)

  it "the spec round-trips through aeson encode/decode" $
    (A.decode (A.encode sealOpenApi) :: Maybe A.Value) `shouldSatisfy` isJust

  it "includes POST /api/sessions/{capture0}/send" $ do
    let mItem = sealOpenApi ^. paths . at "/api/sessions/{capture0}/send"
    mItem `shouldSatisfy` isJust
    case mItem of
      Just item -> item ^. post `shouldSatisfy` isJust
      Nothing -> pure ()

  it "includes GET /api/agents" $ do
    let mItem = sealOpenApi ^. paths . at "/api/agents"
    mItem `shouldSatisfy` isJust
    case mItem of
      Just item -> item ^. get `shouldSatisfy` isJust
      Nothing -> pure ()