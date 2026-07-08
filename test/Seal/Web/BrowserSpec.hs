{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.BrowserSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Web.Browser

spec :: Spec
spec = describe "BROWSER_* opcodes (fail-closed default)" $ do

  describe "BROWSER_OPEN" $ do
    it "accepts a valid URL at the authorize gate" $ do
      let op = browserOpenOp noBrowserDriver
      uoAuthorize op (object ["url" .= ("https://example.com" :: String)]) `shouldBe` Right ()
    it "rejects an empty URL" $ do
      let op = browserOpenOp noBrowserDriver
      uoAuthorize op (object ["url" .= ("" :: String)])
        `shouldBe` Left "BROWSER_OPEN: url is empty"
    it "rejects a missing URL field" $ do
      let op = browserOpenOp noBrowserDriver
      uoAuthorize op (object []) `shouldBe` Left "BROWSER_OPEN requires {url:string}"

  describe "BROWSER_CLICK" $ do
    it "accepts a valid selector" $ do
      let op = browserClickOp noBrowserDriver
      uoAuthorize op (object ["selector" .= ("#submit" :: String)]) `shouldBe` Right ()
    it "rejects an empty selector" $ do
      let op = browserClickOp noBrowserDriver
      uoAuthorize op (object ["selector" .= ("" :: String)])
        `shouldBe` Left "BROWSER_CLICK: selector is empty"

  describe "BROWSER_READ" $ do
    it "accepts any input (selector optional)" $ do
      let op = browserReadOp noBrowserDriver
      uoAuthorize op (object ["selector" .= ("#content" :: String)]) `shouldBe` Right ()
    it "accepts an empty object (whole page)" $ do
      let op = browserReadOp noBrowserDriver
      uoAuthorize op (object []) `shouldBe` Right ()