{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.SearchSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text qualified as T
import Network.HTTP.Client.TLS (newTlsManager)
import Test.Hspec

import Seal.ISA.Opcode (OpResult (..), uoAuthorize)
import Seal.Web.Search

spec :: Spec
spec = describe "WEB_SEARCH" $ do

  it "authorize gate accepts a good query" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("hello" :: String)]) `shouldBe` Right ()

  it "rejects an empty query" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("" :: String)])
      `shouldBe` Left "WEB_SEARCH: query is empty"

  it "rejects a missing query field" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object []) `shouldBe` Left "WEB_SEARCH requires {query:string}"

  it "rejects a negative limit" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("test" :: String), "limit" .= ((-1) :: Int)])
      `shouldBe` Left "WEB_SEARCH: limit must be >= 1"

  it "accepts a valid limit" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("test" :: String), "limit" .= (5 :: Int)])
      `shouldBe` Right ()

  it "parseProvider maps known names correctly" $ do
    parseProvider "parallel"  `shouldBe` ProviderParallel
    parseProvider "searxng"   `shouldBe` ProviderSearXNG
    parseProvider "exa"       `shouldBe` ProviderExa
    parseProvider "firecrawl" `shouldBe` ProviderFirecrawl
    parseProvider "custom"    `shouldBe` ProviderCustom
    parseProvider "unknown"   `shouldBe` ProviderParallel

  it "providerName maps providers to strings" $ do
    providerName ProviderParallel  `shouldBe` "parallel"
    providerName ProviderSearXNG   `shouldBe` "searxng"
    providerName ProviderExa       `shouldBe` "exa"
    providerName ProviderFirecrawl `shouldBe` "firecrawl"
    providerName ProviderCustom    `shouldBe` "custom"

  it "encodeResults produces valid JSON with a results array" $ do
    let results = [SearchResult "Title" "https://example.com" "Description" 1]
        encoded = encodeResults results
    encoded `shouldSatisfy` ("results" `T.isInfixOf`)
    encoded `shouldSatisfy` ("Title" `T.isInfixOf`)
    encoded `shouldSatisfy` ("example.com" `T.isInfixOf`)

  -- Network-dependent: marked pending (xit) so CI never hits the network.
  -- Run manually by changing to `it` to verify the Parallel MCP endpoint.
  xit "Parallel MCP returns search results for a simple query" $ do
    mgr <- newTlsManager
    let cfg = defaultTestCfg
          { wscManager = Just mgr
          , wscEndpoint = ""  -- use the default MCP endpoint
          , wscMaxResults = 5
          }
    result <- dispatchSearch mgr cfg "Haskell programming language"
    orIsError result `shouldBe` False

  where
    defaultTestCfg :: WebSearchConfig
    defaultTestCfg = WebSearchConfig
      { wscManager     = Nothing
      , wscProvider    = ProviderParallel
      , wscEndpoint    = "https://x"
      , wscAllowList   = []
      , wscAuthKey     = Nothing
      , wscMaxResults  = 10
      , wscVault       = Nothing
      , wscSearXngUrl  = Nothing
      }