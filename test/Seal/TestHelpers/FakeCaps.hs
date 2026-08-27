{-# LANGUAGE OverloadedStrings #-}
-- | In-process ChannelCaps for tests. ccSend appends (prepend + reverse on
-- read for O(1) writes); ccPrompt and ccPromptSecret both pop from the same
-- scripted-input queue in FIFO order.
module Seal.TestHelpers.FakeCaps
  ( FakeCaps (..)
  , makeFakeCaps
  , getSent
  ) where

import Data.Functor (($>))
import Data.IORef (IORef, modifyIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)

data FakeCaps = FakeCaps
  { fcSent   :: IORef [Text]   -- reversed accumulator; read via getSent
  , fcInputs :: IORef [Text]   -- remaining scripted answers (head = next)
  }

-- | Build a (FakeCaps, ChannelCaps) pair from a list of canned responses.
-- The pair shares mutable state; use FakeCaps for inspection after the action.
makeFakeCaps :: [Text] -> IO (FakeCaps, ChannelCaps)
makeFakeCaps inputs = do
  sentRef  <- newIORef []
  inputRef <- newIORef inputs
  let popPrompt (AskPrompt _ _) = popQueue inputRef
      popSecret _prompt = popQueue inputRef
      caps = def
        { ccSend         = \t -> modifyIORef sentRef (t :)
        , ccShowHuman    = \t -> modifyIORef sentRef (t :)
        , ccPrompt       = popPrompt
        , ccPromptSecret = popSecret
  , ccStreaming    = True  -- tests: streaming by default
        }
  pure (FakeCaps sentRef inputRef, caps)

-- | Pop the next scripted answer from the queue (FIFO). Fails if empty.
popQueue :: IORef [Text] -> IO Text
popQueue inputRef = do
  queue <- readIORef inputRef
  case queue of
    []     -> fail "FakeCaps: scripted input queue exhausted"
    (x:xs) -> writeIORef inputRef xs $> x

-- | Retrieve sent messages in chronological (send) order.
getSent :: FakeCaps -> IO [Text]
getSent fc = reverse <$> readIORef (fcSent fc)
