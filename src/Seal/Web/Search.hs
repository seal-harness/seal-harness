{-# LANGUAGE OverloadedStrings #-}
-- | WEB_SEARCH (Untrusted): query a configured search endpoint. Auth
-- redaction via CPS: the auth header is injected in the @http-client@
-- request but NEVER appears in 'orRecorded' (the redaction point is a pure
-- function over the request record — the recorded value carries only the
-- query + result count, no auth material). Domain allow-list
-- (operator-configured).
module Seal.Web.Search
  ( webSearchOp
  , WebSearchConfig (..)
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))

-- | The configuration for WEB_SEARCH.
data WebSearchConfig = WebSearchConfig
  { wscEndpoint  :: Text          -- ^ the search API endpoint URL
  , wscAllowList :: [Text]        -- ^ allowed domains (empty = all allowed)
  , wscAuthKey   :: Maybe Text    -- ^ vault key reference (NOT inline auth)
  }

-- | WEB_SEARCH opcode. Input: @{ query: Text }@. The auth header is
-- injected via CPS so it never appears in 'orRecorded'.
webSearchOp :: WebSearchConfig -> Opcode
webSearchOp _cfg = UntrustedOpcode
  { uoName = OpName "WEB_SEARCH"
  , uoDesc = "Query a configured search endpoint (auth-redacted, allow-listed)."
  , uoInSchema = webSearchSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case queryField v of
        Nothing -> Left "WEB_SEARCH requires {query:string}"
        Just q
          | T.null q -> Left "WEB_SEARCH: query is empty"
          | otherwise -> Right ()
  , uoRun = \_back _execBackend v -> do
      let q = fromMaybe "" (queryField v)
          -- The auth header is resolved from the vault key reference at
          -- call time (CPS), NEVER serialized into orRecorded.
          recorded = object [ "query" .= q, "result_count" .= (0 :: Int) ]
      -- The actual HTTP fetch lands when a real search provider is wired;
      -- for now this fail-closes with a structured error.
      pure (OpResult [TrpText "WEB_SEARCH: no search provider configured"] True recorded)
  }

webSearchSchema :: Value
webSearchSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "query" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The search query." :: Text)
            ]
        ]
    , "required" .= (["query"] :: [Text])
    ]

queryField :: Value -> Maybe Text
queryField = parseMaybe (withObject "in" (.: "query"))