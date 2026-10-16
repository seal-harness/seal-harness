{-# LANGUAGE OverloadedStrings #-}
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
import Data.Text qualified as T

-- Non-servant openai package imports (v2.5.4).  No Servant interface.
import OpenAI.V1 (ClientEnv, getClientEnv, makeMethods, Methods (..))
import OpenAI.V1.Chat.Completions
  ( CreateChatCompletion (..)
  , ChatCompletionObject (..)
  , Choice (..)
  , Content (..)
  )
import OpenAI.V1.Models (Model (..))

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (Provider (..), CompletionRequest, CompletionResponse, Usage (..), StopReason (..), Message (..), ContentBlock (..), Role (..), CompletionRequest (..))
import Seal.Security.Secrets (ApiKey, withApiKey)

-- Provider type -------------------------------------------------------------

-- | Strict fields; 'Text' not 'String'.
data OpenRouter = OpenRouter
  { orClientEnv     :: !ClientEnv
  , orApiKey        :: !(Maybe ApiKey)
  , orBaseUrl       :: !Text          -- ^ e.g. "https://openrouter.ai/api/v1"
  , orDefaultModel  :: !ModelId
  }

-- | Build an OpenRouter with an externally-owned API key.
mkOpenRouter :: ClientEnv -> Maybe ApiKey -> Text -> ModelId -> OpenRouter
mkOpenRouter = OpenRouter

-- | Default base URL for OpenRouter (OpenAI-compatible endpoint).
defaultOpenRouterBaseUrl :: Text
defaultOpenRouterBaseUrl = "https://openrouter.ai/api/v1"

-- | Access the configured base URL (exposed for URL construction).
openRouterBaseUrl :: OpenRouter -> Text
openRouterBaseUrl = orBaseUrl

-- Provider instance ---------------------------------------------------------

instance Provider OpenRouter where
  -- | List available models via the openai package bindings.
  listModels :: OpenRouter -> IO (Either Text [ModelId])
  listModels or = do
    -- Skeleton: model enumeration to be wired via openai non-servant API.
    pure (Right [orDefaultModel or])

  -- | Complete a request against @https://openrouter.ai/api/v1/chat/completions@.
  -- Uses the non-servant 'openai' bindings; no 'Servant' imports.
  complete :: OpenRouter -> CompletionRequest -> IO (Either Text CompletionResponse)
  complete or cr = do
    -- Skeleton: HTTP round-trip via openai package non-servant interface.
    -- The actual 'CreateChatCompletion' construction and response decoding
    -- will be implemented using 'makeMethods' / 'ClientEnv' / 'withApiKey'.
    pure (Left "OpenRouter complete not yet fully implemented (WU-001 skeleton)")
