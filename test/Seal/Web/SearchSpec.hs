{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.SearchSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
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