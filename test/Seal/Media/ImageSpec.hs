{-# LANGUAGE OverloadedStrings #-}
module Seal.Media.ImageSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Media.Image

spec :: Spec
spec = describe "IMAGE_* opcodes (fail-closed default)" $ do

  describe "IMAGE_GENERATE" $ do
    it "accepts a valid prompt" $ do
      let op = imageGenerateOp noImageProvider
      uoAuthorize op (object ["prompt" .= ("a cat" :: String)]) `shouldBe` Right ()
    it "rejects an empty prompt" $ do
      let op = imageGenerateOp noImageProvider
      uoAuthorize op (object ["prompt" .= ("" :: String)])
        `shouldBe` Left "IMAGE_GENERATE: prompt is empty"
    it "rejects a missing prompt" $ do
      let op = imageGenerateOp noImageProvider
      uoAuthorize op (object []) `shouldBe` Left "IMAGE_GENERATE requires {prompt:string}"

  describe "IMAGE_DESCRIBE" $ do
    it "accepts a valid image ref" $ do
      let op = imageDescribeOp noImageProvider
      uoAuthorize op (object ["image" .= ("https://x.com/cat.png" :: String)]) `shouldBe` Right ()
    it "rejects an empty image" $ do
      let op = imageDescribeOp noImageProvider
      uoAuthorize op (object ["image" .= ("" :: String)])
        `shouldBe` Left "IMAGE_DESCRIBE: image is empty"