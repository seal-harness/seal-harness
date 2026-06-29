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

import Seal.Channel.Caps (ChannelCaps (..))

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
  let pop _prompt = do
        queue <- readIORef inputRef
        case queue of
          []     -> fail "FakeCaps: scripted input queue exhausted"
          (x:xs) -> writeIORef inputRef xs $> x
      caps = ChannelCaps
        { ccSend         = \t -> modifyIORef sentRef (t :)
        , ccPrompt       = pop
        , ccPromptSecret = pop
        }
  pure (FakeCaps sentRef inputRef, caps)

-- | Retrieve sent messages in chronological (send) order.
getSent :: FakeCaps -> IO [Text]
getSent fc = reverse <$> readIORef (fcSent fc)
