{-# LANGUAGE OverloadedStrings #-}
-- | WEB_EXTRACT (Untrusted): fetch a URL via @http-client@, bounded bytes,
-- allow-list, auth redaction. 'orRecorded' captures the URL + status +
-- byte count (NOT the body — the body may be large; the transcript records
-- metadata only).
module Seal.Web.Extract
  ( webExtractOp
  , WebExtractConfig (..)
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))

-- | The configuration for WEB_EXTRACT.
data WebExtractConfig = WebExtractConfig
  { wecAllowList     :: [Text]   -- ^ allowed domains (empty = all allowed)
  , wecMaxBytes      :: Int      -- ^ operator-configured byte ceiling
  , wecAuthKey       :: Maybe Text  -- ^ vault key reference (NOT inline auth)
  }

-- | WEB_EXTRACT opcode. Input: @{ url: Text }@.
webExtractOp :: WebExtractConfig -> Opcode
webExtractOp _cfg = UntrustedOpcode
  { uoName = OpName "WEB_EXTRACT"
  , uoDesc = "Fetch a URL (bounded bytes, allow-listed, auth-redacted)."
  , uoInSchema = webExtractSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case urlField v of
        Nothing -> Left "WEB_EXTRACT requires {url:string}"
        Just u
          | T.null u -> Left "WEB_EXTRACT: url is empty"
          | otherwise -> Right ()
  , uoRun = \_back _execBackend v -> do
      let u = fromMaybe "" (urlField v)
          recorded = object [ "url" .= u, "status" .= (0 :: Int), "bytes" .= (0 :: Int) ]
      -- The actual HTTP fetch lands when a real HTTP manager is wired;
      -- for now this fail-closes with a structured error.
      pure (OpResult [TrpText "WEB_EXTRACT: no HTTP provider configured"] True recorded)
  }

webExtractSchema :: Value
webExtractSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "url" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The URL to fetch." :: Text)
            ]
        ]
    , "required" .= (["url"] :: [Text])
    ]

urlField :: Value -> Maybe Text
urlField = parseMaybe (withObject "in" (.: "url"))