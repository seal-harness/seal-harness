{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ProviderIconSpec (spec) where

import Test.Hspec
import Data.ByteString qualified as BS

import Seal.Gateway.ProviderIcon

spec :: Spec
spec = do
  describe "deriveRootUrl" $ do
    it "strips /v1 from an OpenAI-compatible base URL" $ do
      deriveRootUrl "https://api.openai.com/v1" `shouldBe` Just "https://api.openai.com"
    it "strips a trailing path after /v1" $ do
      deriveRootUrl "https://api.example.com/v1/" `shouldBe` Just "https://api.example.com"
    it "strips /v1 from a localhost endpoint" $ do
      deriveRootUrl "http://localhost:8000/v1" `shouldBe` Just "http://localhost:8000"
    it "returns the origin when there is no /v1 path" $ do
      deriveRootUrl "https://api.example.com/api/v2" `shouldBe` Just "https://api.example.com"
    it "returns the origin for a bare origin URL" $ do
      deriveRootUrl "https://api.example.com" `shouldBe` Just "https://api.example.com"
    it "handles a URL with a port" $ do
      deriveRootUrl "http://localhost:11434" `shouldBe` Just "http://localhost:11434"
    it "returns Nothing for an empty string" $ do
      deriveRootUrl "" `shouldBe` Nothing
    it "returns Nothing for whitespace only" $ do
      deriveRootUrl "   " `shouldBe` Nothing
    it "returns Nothing for a string without a scheme" $ do
      deriveRootUrl "not a url" `shouldBe` Nothing

  describe "resolveIconUrl" $ do
    let root = "https://api.example.com"
    it "resolves a root-relative href" $ do
      resolveIconUrl root "/favicon.ico" `shouldBe` Just "https://api.example.com/favicon.ico"
    it "passes through an already-absolute URL" $ do
      resolveIconUrl root "https://cdn.example.com/icon.png"
        `shouldBe` Just "https://cdn.example.com/icon.png"
    it "resolves a protocol-relative URL" $ do
      resolveIconUrl root "//cdn.example.com/icon.png"
        `shouldBe` Just "https://cdn.example.com/icon.png"
    it "resolves a relative path without leading slash" $ do
      resolveIconUrl root "favicon.ico"
        `shouldBe` Just "https://api.example.com/favicon.ico"
    it "returns Nothing for an empty href" $ do
      resolveIconUrl root "" `shouldBe` Nothing
    it "resolves a deeper path" $ do
      resolveIconUrl root "/public/icon-64x64.png"
        `shouldBe` Just "https://api.example.com/public/icon-64x64.png"

  describe "extractIconHref" $ do
    it "extracts href from <link rel=\"icon\">" $ do
      extractIconHref "<html><head><link rel=\"icon\" href=\"/favicon.ico\"></head></html>"
        `shouldBe` Just "/favicon.ico"
    it "extracts href from <link rel=\"shortcut icon\"> (case-insensitive)" $ do
      extractIconHref "<LINK REL=\"Shortcut Icon\" HREF=\"/favicon.png\">"
        `shouldBe` Just "/favicon.png"
    it "extracts the first icon link when multiple present" $ do
      extractIconHref "<link rel=\"icon\" href=\"/favicon.ico\"><link rel=\"icon\" href=\"/favicon.svg\">"
        `shouldBe` Just "/favicon.ico"
    it "returns Nothing when no icon link is present" $ do
      extractIconHref "<html><head><link rel=\"stylesheet\" href=\"/style.css\"></head></html>"
        `shouldBe` Nothing
    it "returns Nothing for empty HTML" $ do
      extractIconHref "" `shouldBe` Nothing
    it "extracts href with type attribute present" $ do
      extractIconHref "<link rel=\"icon\" type=\"image/svg+xml\" href=\"/icon.svg\">"
        `shouldBe` Just "/icon.svg"
    it "extracts an apple-touch-icon as a fallback" $ do
      extractIconHref "<link rel=\"apple-touch-icon\" href=\"/apple-touch-icon.png\">"
        `shouldBe` Just "/apple-touch-icon.png"
    it "extracts from multi-attribute link with sizes" $ do
      extractIconHref "<link rel=\"icon\" type=\"image/png\" sizes=\"64x64\" href=\"/public/icon-64x64.png\" />"
        `shouldBe` Just "/public/icon-64x64.png"

    it "extracts from realistic Ollama HTML" $ do
      let html = "<link rel=\"icon\" type=\"image/png\" sizes=\"16x16\" href=\"/public/icon-16x16.png\" />\
                 \<link rel=\"icon\" type=\"image/png\" sizes=\"32x32\" href=\"/public/icon-32x32.png\" />\
                 \<link rel=\"icon\" type=\"image/png\" sizes=\"48x48\" href=\"/public/icon-48x48.png\" />\
                 \<link rel=\"icon\" type=\"image/png\" sizes=\"64x64\" href=\"/public/icon-64x64.png\" />\
                 \<link rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"/public/apple-touch-icon.png\" />"
      extractIconHref (BS.pack (map (fromIntegral . fromEnum) html))
        `shouldBe` Just "/public/icon-16x16.png"

  describe "IconCache" $ do
    it "returns Nothing from an empty cache" $ do
      cache <- newIconCache
      result <- cachedIcon cache "https://api.example.com"
      result `shouldBe` Nothing

    it "stores and retrieves an icon result" $ do
      cache <- newIconCache
      storeIcon cache "https://api.example.com" (IconFound "png-bytes" "image/png")
      result <- cachedIcon cache "https://api.example.com"
      result `shouldBe` Just (IconFound "png-bytes" "image/png")

    it "stores and retrieves IconNotFound" $ do
      cache <- newIconCache
      storeIcon cache "https://api.example.com" IconNotFound
      result <- cachedIcon cache "https://api.example.com"
      result `shouldBe` Just IconNotFound
