{-# LANGUAGE OverloadedStrings #-}
-- | A reusable fake 'Channel' for tests. Backed by 'IORef's: scripted prompt
-- responses and a scripted inbound inbox, plus captured send/error/chunk
-- lists. The first 'Channel' instance — used by 'Seal.Channels.ClassSpec'
-- and the 'Seal.Phase2aSpec' capstone.
module Seal.TestHelpers.FakeChannel
  ( FakeChannel (..)
  , newFakeChannel
  , newFakeChannelWith
  , getSent
  , getErrors
  , getChunks
  ) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)

import Seal.Channels.Class (Channel (..))
import Seal.Core.MessageSource (MessageSource)
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))

-- | The fake channel's mutable state. All fields are 'IORef's so the same
-- record is shared between the handle (which mutates them) and the test
-- (which reads them back).
data FakeChannel = FakeChannel
  { fcSent      :: IORef [Text]        -- captured sends, in reverse order
  , fcErrors    :: IORef [Text]
  , fcChunks    :: IORef [Text]
  , fcPromptSrc :: IORef [Text]        -- scripted prompt responses
  , fcInbox     :: IORef [(MessageSource, Text)]  -- scripted inbound
  , fcStreaming :: Bool
  }

-- | Build a fake with empty inbox + no scripted prompts.
newFakeChannel :: Bool -> IO FakeChannel
newFakeChannel streaming = newFakeChannelWith streaming [] []

-- | Build a fake with a scripted inbox and scripted prompt responses.
newFakeChannelWith
  :: Bool -> [(MessageSource, Text)] -> [Text] -> IO FakeChannel
newFakeChannelWith streaming inbox prompts = FakeChannel
  <$> newIORef []
  <*> newIORef []
  <*> newIORef []
  <*> newIORef prompts
  <*> newIORef inbox
  <*> pure streaming

instance Channel FakeChannel where
  toHandle fc = ChannelHandle
    { chSend         = \t -> modifyIORef' (fcSent fc) (t :)
    , chSendError    = \t -> modifyIORef' (fcErrors fc) (t :)
    , chSendChunk    = \t -> modifyIORef' (fcChunks fc) (t :)
    , chPrompt       = const (popPrompt fc)
    , chPromptSecret = const (popPrompt fc)
    , chStreaming    = fcStreaming fc
    , chReadSecret   = pure Nothing
    , chReceive      = popInbox fc
    }

popPrompt :: FakeChannel -> IO (Either Deferral Text)
popPrompt fc = do
  rs <- readIORef (fcPromptSrc fc)
  case rs of
    (x:xs) -> writeIORef (fcPromptSrc fc) xs >> pure (Right x)
    []     -> pure (Left AsyncQueued)

popInbox :: FakeChannel -> IO (Maybe MessageSource, Text)
popInbox fc = do
  ms <- readIORef (fcInbox fc)
  case ms of
    ((src,t):rest) -> writeIORef (fcInbox fc) rest >> pure (Just src, t)
    []             -> pure (Nothing, "")

-- | Read the captured sends in chronological order.
getSent :: FakeChannel -> IO [Text]
getSent fc = reverse <$> readIORef (fcSent fc)

getErrors :: FakeChannel -> IO [Text]
getErrors fc = reverse <$> readIORef (fcErrors fc)

getChunks :: FakeChannel -> IO [Text]
getChunks fc = reverse <$> readIORef (fcChunks fc)