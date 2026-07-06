{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Handles.ChannelSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Test.Hspec

import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, mkConversationId, mkMessageSource, mkUserId )
import Seal.Handles.Channel

-- ---------------------------------------------------------------------------
-- A minimal inline fake for T3 (T4 introduces the reusable FakeChannel)
-- ---------------------------------------------------------------------------

data InlineFake = InlineFake
  { ifSent      :: IORef [Text]
  , ifErrors    :: IORef [Text]
  , ifChunks    :: IORef [Text]
  , ifPromptSrc :: IORef [Text]
  , ifInbox     :: IORef [(MessageSource, Text)]
  , ifStreaming :: Bool
  }

newInlineFake :: Bool -> [(MessageSource, Text)] -> [Text] -> IO InlineFake
newInlineFake streaming inbox prompts = InlineFake
  <$> newIORef []
  <*> newIORef []
  <*> newIORef []
  <*> newIORef prompts
  <*> newIORef inbox
  <*> pure streaming

inlineHandle :: InlineFake -> ChannelHandle
inlineHandle fc = ChannelHandle
  { chSend         = \t -> modifyIORef' (ifSent fc) (t :)
  , chSendError    = \t -> modifyIORef' (ifErrors fc) (t :)
  , chSendChunk    = \t -> modifyIORef' (ifChunks fc) (t :)
  , chPrompt       = const (popPrompt fc)
  , chPromptSecret = const (popPrompt fc)
  , chStreaming    = ifStreaming fc
  , chReadSecret   = pure Nothing
  , chReceive      = popInbox fc
  }

popPrompt :: InlineFake -> IO (Either Deferral Text)
popPrompt fc = do
  rs <- readIORef (ifPromptSrc fc)
  case rs of
    (x:xs) -> writeIORef (ifPromptSrc fc) xs >> pure (Right x)
    []     -> pure (Left AsyncQueued)

popInbox :: InlineFake -> IO (Maybe MessageSource, Text)
popInbox fc = do
  ms <- readIORef (ifInbox fc)
  case ms of
    ((ms',t):rest) -> writeIORef (ifInbox fc) rest >> pure (Just ms', t)
    []             -> pure (Nothing, "")

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

src :: MessageSource
src = case mkConversationId "sig:+1" of
  Right cid -> case mkUserId "+1" of
    Right uid -> case mkMessageSource cid Signal (Just uid) mempty of
      Right ms -> ms
      Left e   -> error ("mkMessageSource: " <> show e)
    Left e   -> error ("mkUserId: " <> show e)
  Left e   -> error ("mkConversationId: " <> show e)

spec :: Spec
spec = describe "Seal.Handles.Channel" $ do
  it "chSend captures to the send list" $ do
    fc <- newInlineFake True [] []
    chSend (inlineHandle fc) "hi"
    sent <- readIORef (ifSent fc)
    sent `shouldBe` ["hi"]

  it "chSendError / chSendChunk capture separately" $ do
    fc <- newInlineFake True [] []
    let h = inlineHandle fc
    chSendError h "boom"
    chSendChunk h "chunk1"
    errs   <- readIORef (ifErrors fc)
    chunks <- readIORef (ifChunks fc)
    errs   `shouldBe` ["boom"]
    chunks `shouldBe` ["chunk1"]

  it "chStreaming reflects the configured flag" $ do
    fc1 <- newInlineFake True  [] []
    fc2 <- newInlineFake False [] []
    chStreaming (inlineHandle fc1) `shouldBe` True
    chStreaming (inlineHandle fc2) `shouldBe` False

  it "chPrompt returns Right the scripted response, then AsyncQueued when empty" $ do
    fc <- newInlineFake False [] ["yes"]
    let h = inlineHandle fc
    r1 <- chPrompt h "q?"
    r2 <- chPrompt h "q?"
    r1 `shouldBe` Right "yes"
    r2 `shouldBe` Left AsyncQueued

  it "chReceive pops the scripted inbox, then (Nothing, \"\") when empty" $ do
    fc <- newInlineFake False [(src, "hello")] []
    let h = inlineHandle fc
    (m1, t1) <- chReceive h
    (m2, t2) <- chReceive h
    t1 `shouldBe` "hello"
    m1 `shouldBe` Just src
    t2 `shouldBe` ""
    m2 `shouldBe` Nothing

  it "chReadSecret is Nothing by default" $ do
    fc <- newInlineFake True [] []
    chReadSecret (inlineHandle fc) `shouldReturn` Nothing