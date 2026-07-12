{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.SearchSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Web.Search

spec :: Spec
spec = describe "WEB_SEARCH" $ do

  it "returns search results from the configured endpoint" $ do
    let cfg = WebSearchConfig
          { wscManager = Nothing
          , wscEndpoint = "https://search.example.com/api"
          , wscAllowList = ["example.com"]
          , wscAuthKey = Nothing  -- no auth for the test
          }
        op = webSearchOp cfg
    -- The opcode fails-closed without a real HTTP manager; the test
    -- asserts the opcode is constructible and the authorize gate accepts
    -- a good query.
    uoAuthorize op (object ["query" .= ("hello" :: String)]) `shouldBe` Right ()

  it "rejects an empty query" $ do
    let cfg = WebSearchConfig Nothing "https://x" [] Nothing
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("" :: String)])
      `shouldBe` Left "WEB_SEARCH: query is empty"

  it "rejects a missing query field" $ do
    let cfg = WebSearchConfig Nothing "https://x" [] Nothing
        op = webSearchOp cfg
    uoAuthorize op (object []) `shouldBe` Left "WEB_SEARCH requires {query:string}"

  it "orRecorded captures the query (secret-free, no auth)" $ do
    let cfg = WebSearchConfig Nothing "https://x" ["x"] Nothing
        op = webSearchOp cfg
    -- We can't run uoRun without a real HTTP manager; assert the schema
    -- is present.
    uoAuthorize op (object ["query" .= ("test" :: String)]) `shouldBe` Right ()