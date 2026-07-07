{-# LANGUAGE OverloadedStrings #-}
-- | A pure static lookup table for model context windows and max output
-- tokens, keyed by model-id prefix. Used by the gateway's
-- @/api/providers/:p/models@ + @/api/providers/:p/models/:m/context@
-- endpoints (Phase 7b T11). The real @/v1/models@ upstream call needs vault
-- credentials + a live HTTP request and is out of scope for T11; this table
-- ships a static, best-known approximation. Unknown model ids yield @0@.
module Seal.Providers.ContextWindow
  ( modelContextWindow
  , modelMaxOutputTokens
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | The context window size for a model id, by prefix match. 0 if unknown.
modelContextWindow :: Text -> Int
modelContextWindow m
  | "claude-sonnet-" `T.isPrefixOf` m = 200000
  | "claude-opus-"   `T.isPrefixOf` m = 200000
  | "claude-haiku-"  `T.isPrefixOf` m = 200000
  | "gpt-4o-"        `T.isPrefixOf` m = 128000
  | "gpt-4-turbo"    `T.isPrefixOf` m = 128000
  | "llama3.1"       `T.isPrefixOf` m = 128000
  | "llama3"         `T.isPrefixOf` m = 8192
  | otherwise                          = 0

-- | The max output tokens for a model id, by prefix match. 0 if unknown.
modelMaxOutputTokens :: Text -> Int
modelMaxOutputTokens m
  | "claude-"   `T.isPrefixOf` m = 64000
  | "gpt-4o-"   `T.isPrefixOf` m = 16384
  | "llama3"    `T.isPrefixOf` m = 4096
  | otherwise                     = 0