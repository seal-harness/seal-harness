{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.FetchSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Web.Fetch

spec :: Spec
spec = describe "WEB_FETCH" $ do

  it "accepts a valid URL" $ do
    let cfg = WebFetchConfig { wfcManager = Nothing, wfcAllowList = [], wfcMaxBytes = 65536, wfcAuthKey = Nothing }
        op = webFetchOp cfg
    uoAuthorize op (object ["url" .= ("https://example.com" :: String)]) `shouldBe` Right ()

  it "rejects an empty URL" $ do
    let cfg = WebFetchConfig Nothing [] 65536 Nothing
        op = webFetchOp cfg
    uoAuthorize op (object ["url" .= ("" :: String)])
      `shouldBe` Left "WEB_FETCH: url is empty"

  it "rejects a missing URL field" $ do
    let cfg = WebFetchConfig Nothing [] 65536 Nothing
        op = webFetchOp cfg
    uoAuthorize op (object []) `shouldBe` Left "WEB_FETCH requires {url:string}"

  it "rejects a URL whose domain is not in the allow-list" $ do
    let cfg = WebFetchConfig Nothing ["example.com"] 65536 Nothing
        op = webFetchOp cfg
    uoAuthorize op (object ["url" .= ("https://evil.com" :: String)])
      `shouldBe` Left "WEB_FETCH: domain not in allow-list: evil.com"

  it "accepts a URL whose domain is in the allow-list" $ do
    let cfg = WebFetchConfig Nothing ["example.com"] 65536 Nothing
        op = webFetchOp cfg
    uoAuthorize op (object ["url" .= ("https://example.com/page" :: String)]) `shouldBe` Right ()

  it "allows any domain when the allow-list is empty" $ do
    let cfg = WebFetchConfig Nothing [] 65536 Nothing
        op = webFetchOp cfg
    uoAuthorize op (object ["url" .= ("https://anything.com" :: String)]) `shouldBe` Right ()