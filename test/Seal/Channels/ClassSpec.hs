{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.ClassSpec (spec) where

import Test.Hspec

import Seal.Channels.Class (Channel (..))
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, mkConversationId, mkMessageSource, mkUserId )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.TestHelpers.FakeChannel

src :: MessageSource
src = case mkConversationId "sig:+1" of
  Right cid -> case mkUserId "+1" of
    Right uid -> case mkMessageSource cid Signal (Just uid) mempty of
      Right ms -> ms
      Left e   -> error ("mkMessageSource: " <> show e)
    Left e   -> error ("mkUserId: " <> show e)
  Left e   -> error ("mkConversationId: " <> show e)

spec :: Spec
spec = describe "Seal.Channels.Class" $ do
  it "toHandle . newFakeChannel yields a handle with the configured streaming flag" $ do
    fc <- newFakeChannel True
    chStreaming (toHandle fc) `shouldBe` True
    fc2 <- newFakeChannel False
    chStreaming (toHandle fc2) `shouldBe` False

  it "driving chSend then getSent yields chronological order" $ do
    fc <- newFakeChannel True
    let h = toHandle fc
    chSend h "a"
    chSend h "b"
    getSent fc `shouldReturn` ["a", "b"]

  it "chReceive yields the scripted (MessageSource, Text), then empty" $ do
    fc <- newFakeChannelWith False [(src, "hello")] []
    let h = toHandle fc
    (m1, t1) <- chReceive h
    (m2, t2) <- chReceive h
    t1 `shouldBe` "hello"
    m1 `shouldBe` Just src
    t2 `shouldBe` ""
    m2 `shouldBe` Nothing

  it "chPrompt returns Right the scripted response, then AsyncQueued" $ do
    fc <- newFakeChannelWith False [] ["yes"]
    let h = toHandle fc
    r1 <- chPrompt h "q?"
    r2 <- chPrompt h "q?"
    r1 `shouldBe` Right "yes"
    r2 `shouldBe` Left AsyncQueued