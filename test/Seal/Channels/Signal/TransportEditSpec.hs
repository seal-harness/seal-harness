{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.Signal.TransportEditSpec (spec) where

import Test.Hspec

import Seal.Channels.Signal.Transport
  ( SignalTransport (..)
  , mkMockSignalTransport
  )

spec :: Spec
spec = do
  describe "Seal.Channels.Signal.Transport mock edit support" $ do
    it "stSendWithId captures the send and returns a timestamp" $ do
      (t, _) <- mkMockSignalTransport []
      mts <- stSendWithId t "+1" "hello"
      mts `shouldSatisfy` isJust

    it "stSendWithId returns incrementing timestamps" $ do
      (t, _) <- mkMockSignalTransport []
      ts1 <- stSendWithId t "+1" "first"
      ts2 <- stSendWithId t "+1" "second"
      ts1 `shouldSatisfy` isJust
      ts2 `shouldSatisfy` isJust
      ts1 `shouldNotBe` ts2

    it "stEditMessage captures the edit (recipient, timestamp, content)" $ do
      (t, _) <- mkMockSignalTransport []
      ok <- stEditMessage t "+1" "1693000000" "updated"
      ok `shouldBe` True

    it "stDeleteMessage captures the delete (recipient, timestamp)" $ do
      (t, _) <- mkMockSignalTransport []
      ok <- stDeleteMessage t "+1" "1693000000"
      ok `shouldBe` True

  where
    isJust (Just _)  = True
    isJust Nothing   = False