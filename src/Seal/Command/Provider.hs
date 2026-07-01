{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @/provider@ command group: configure, list, test, and remove model
-- providers. Credentials live in the vault; this module never holds key bytes
-- beyond handing them to the vault or to 'mkApiKey'.
module Seal.Command.Provider
  ( pingRequest
  , formatTestResult
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (ModelId)
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..), Role (..)
  , ToolChoice (..), Usage (..), textMsg )

-- | A minimal completion used to prove a provider responds.
pingRequest :: ModelId -> CompletionRequest
pingRequest m = CompletionRequest
  { crModel      = m
  , crSystem     = Nothing
  , crMessages   = [textMsg User "ping"]
  , crTools      = []
  , crToolChoice = ToolNone
  , crMaxTokens  = 16
  }

-- | Render the outcome of @/provider test@ for a provider labelled @label@.
formatTestResult :: Text -> Either Text CompletionResponse -> Text
formatTestResult label = \case
  Left e  -> label <> " test FAILED: " <> e
  Right r ->
    label <> " OK — model responded ("
      <> T.pack (show (uOutput (rsUsage r))) <> " output tokens, stop="
      <> T.pack (show (rsStop r)) <> ")"
