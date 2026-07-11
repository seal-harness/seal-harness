{-# LANGUAGE OverloadedStrings #-}
module Seal.Media.TtsSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Media.Tts

spec :: Spec
spec = describe "TEXT_TO_SPEECH (fail-closed default)" $ do

  it "accepts a valid text" $ do
    let op = textToSpeechOp noTtsProvider
    uoAuthorize op (object ["text" .= ("hello world" :: String)]) `shouldBe` Right ()

  it "rejects an empty text" $ do
    let op = textToSpeechOp noTtsProvider
    uoAuthorize op (object ["text" .= ("" :: String)])
      `shouldBe` Left "TEXT_TO_SPEECH: text is empty"

  it "rejects a missing text field" $ do
    let op = textToSpeechOp noTtsProvider
    uoAuthorize op (object []) `shouldBe` Left "TEXT_TO_SPEECH requires {text:string}"