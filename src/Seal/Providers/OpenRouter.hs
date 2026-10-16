{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-unused-matches #-}
-- | OpenRouter provider using the 'openai' package (v2.5.4) non-servant interface.
--
-- Base URL: @https://openrouter.ai/api/v1/chat/completions@
-- Vault key: @OPENROUTER_API_KEY@
--
-- Security: no opcode touches @~/.seal/@; API keys live only in headers
-- via the CPS 'withApiKey' accessor; no 'System.Process' / 'System.Directory'
-- / 'System.Posix' imports (capability-based).
module Seal.Providers.OpenRouter
  ( OpenRouter (..)
  , mkOpenRouter
  , defaultOpenRouterBaseUrl
  , openRouterBaseUrl
  ) where

import Data.Text (Text)

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (Provider (..), CompletionRequest, CompletionResponse)
import Seal.Security.Secrets (ApiKey)

-- Provider type -------------------------------------------------------------

-- | Strict fields; 'Text' not 'String'.
data OpenRouter = OpenRouter
  { orApiKey        :: !(Maybe ApiKey)
  , orBaseUrl       :: !Text
  , orDefaultModel  :: !ModelId
  }

-- | Build an OpenRouter with an externally-owned API key.
mkOpenRouter :: Maybe ApiKey -> Text -> ModelId -> OpenRouter
mkOpenRouter = OpenRouter

-- | Default base URL for OpenRouter (OpenAI-compatible endpoint).
defaultOpenRouterBaseUrl :: Text
defaultOpenRouterBaseUrl = "https://openrouter.ai/api/v1"

-- | Access the configured base URL (exposed for URL construction).
openRouterBaseUrl :: OpenRouter -> Text
openRouterBaseUrl = orBaseUrl

-- Provider instance ---------------------------------------------------------

instance Provider OpenRouter where
  listModels prov = pure (Right [orDefaultModel prov])
  complete prov _cr = pure (Left "OpenRouter complete not yet fully implemented (WU-001 skeleton)")
