{-# LANGUAGE OverloadedStrings #-}
-- | Centralized mock LLM provider for integration tests. A
-- 'ScriptProvider' pops one scripted 'CompletionResponse' per @complete@
-- call from an 'IORef'. When the script is exhausted, it returns a default
-- @done@ response. This lets tests script multi-turn tool-call round-trips
-- (e.g. @CbToolUse FILE_WRITE@ → @CbToolResult@ → @CbText "done"@) without
-- a real LLM or API key.
module Seal.TestHelpers.ScriptProvider
  ( ScriptProvider (..)
  ) where

import Data.IORef (IORef, readIORef, writeIORef)
import Test.Hspec () -- no-op; keeps hspec available for downstream

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( ContentBlock (..), CompletionResponse (..), Provider (..)
  , StopReason (..), Usage (..) )

-- | A fake provider that returns one canned assistant reply per turn,
-- popping from the 'IORef' script. When the script is exhausted, returns a
-- default @done@ response.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])
instance Provider ScriptProvider where
  complete (ScriptProvider ref) _ = do
    responses <- readIORef ref
    case responses of
      (r : rest) -> writeIORef ref rest >> pure (Right r)
      []         -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])