{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Handles.HarnessSpec (spec) where

import Data.Char (chr)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Handles.Harness
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text instance

spec :: Spec
spec = do
  describe "Seal.Handles.Harness.noOpHarnessHandle" $ do
    it "send succeeds" $ do
      r <- hhSend noOpHarnessHandle "hi"
      r `shouldBe` Right ()
    it "receive returns Right []" $ do
      r <- hhReceive noOpHarnessHandle
      r `shouldBe` Right []
    it "snapshot returns Right empty" $ do
      r <- hhSnapshot noOpHarnessHandle
      r `shouldBe` Right ""
    it "status returns Right HsIdle" $ do
      r <- hhStatus noOpHarnessHandle
      r `shouldBe` Right HsIdle
    it "stop succeeds" $ do
      r <- hhStop noOpHarnessHandle
      r `shouldBe` Right ()

  describe "Seal.Handles.Harness.stripAnsi" $ do
    it "plain ASCII is identity" $
      stripAnsi "hello world" `shouldBe` "hello world"
    it "removes a CSI color sequence" $
      stripAnsi "\x1b[31mred\x1b[0m text" `shouldBe` "red text"
    it "removes a cursor-move CSI" $
      stripAnsi "a\x1b[2;3Hb" `shouldBe` "ab"
    it "empty input -> empty" $ stripAnsi "" `shouldBe` ""
    prop "never emits ESC" $ \t ->
      not (T.any (== '\x1b') (stripAnsi t))
    prop "idempotent" $ \t ->
      stripAnsi (stripAnsi t) === stripAnsi t

  describe "Seal.Handles.Harness.stripControl" $ do
    it "removes NUL/BEL/BS/DEL" $
      stripControl (T.pack ['a', chr 0, 'b', chr 7, 'c', chr 8, 'd', chr 0x7f, 'e'])
        `shouldBe` "abcde"
    it "plain ASCII is identity" $
      stripControl "hello" `shouldBe` "hello"
    prop "idempotent" $ \t ->
      stripControl (stripControl t) === stripControl t
    prop "removes all control chars" $ \t ->
      not (T.any isControl (stripControl t))
      where
        isControl c = c < ' ' || c == '\x7f'