{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.ExtractSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Web.Extract

spec :: Spec
spec = describe "WEB_EXTRACT" $ do

  it "accepts a valid URL" $ do
    let cfg = WebExtractConfig { wecAllowList = [], wecMaxBytes = 65536, wecAuthKey = Nothing }
        op = webExtractOp cfg
    uoAuthorize op (object ["url" .= ("https://example.com" :: String)]) `shouldBe` Right ()

  it "rejects an empty URL" $ do
    let cfg = WebExtractConfig [] 65536 Nothing
        op = webExtractOp cfg
    uoAuthorize op (object ["url" .= ("" :: String)])
      `shouldBe` Left "WEB_EXTRACT: url is empty"

  it "rejects a missing URL field" $ do
    let cfg = WebExtractConfig [] 65536 Nothing
        op = webExtractOp cfg
    uoAuthorize op (object []) `shouldBe` Left "WEB_EXTRACT requires {url:string}"