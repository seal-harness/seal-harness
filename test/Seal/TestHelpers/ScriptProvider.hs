{-# LANGUAGE OverloadedStrings #-}
-- | Centralized mock LLM provider for integration tests. A
-- 'ScriptProvider' pops one scripted 'CompletionResponse' per @complete@
-- call from an 'IORef'. When the script is exhausted, it returns a default
-- @done@ response. This lets tests script multi-turn tool-call round-trips
-- (e.g. @CbToolUse FILE_WRITE@ → @CbToolResult@ → @CbText "done"@) without
-- a real LLM or API key.
--
-- The pop is via 'atomicModifyIORef'' so concurrent children sharing the
-- same 'ScriptProvider' ref (e.g. batch-spawned subagents with
-- @atoChildProvider = True@) don't lose responses to a read/write race.
module Seal.TestHelpers.ScriptProvider
  ( ScriptProvider (..)
  ) where

import Data.IORef (IORef, atomicModifyIORef')

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
    let pop rs = case rs of
          (r : rest) -> (rest, Just r)
          []         -> ([], Nothing)
    mResp <- atomicModifyIORef' ref pop
    case mResp of
      Just r  -> pure (Right r)
      Nothing -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])
