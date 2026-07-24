{-# LANGUAGE OverloadedStrings #-}
-- | BROWSER_* opcodes (Untrusted): a thin abstraction over a pluggable
-- browser driver (Playwright/headless-Chrome in a future phase). The
-- default driver is fail-closed (@noBrowserDriver@) — the opcodes
-- surface a structured error when no driver is configured.
module Seal.Web.Browser
  ( browserOpenOp
  , browserClickOp
  , browserReadOp
  , BrowserDriver (..)
  , noBrowserDriver
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))

-- | The browser-driver interface — a record of IO actions. A real
-- Playwright/headless-Chrome driver lands in a future phase; the default
-- is 'noBrowserDriver' (fail-closed).
data BrowserDriver = BrowserDriver
  { bdOpen  :: Text -> IO (Either Text Text)       -- ^ open a URL → page id
  , bdClick :: Text -> IO (Either Text Text)       -- ^ click a selector → ok
  , bdRead  :: Text -> IO (Either Text Text)       -- ^ read page text → content
  }

-- | The fail-closed default driver.
noBrowserDriver :: BrowserDriver
noBrowserDriver = BrowserDriver
  { bdOpen  = \_ -> pure (Left "BROWSER_OPEN: no browser driver configured")
  , bdClick = \_ -> pure (Left "BROWSER_CLICK: no browser driver configured")
  , bdRead  = \_ -> pure (Left "BROWSER_READ: no browser driver configured")
  }

-- | BROWSER_OPEN opcode. Input: @{ url: Text }@.
browserOpenOp :: BrowserDriver -> Opcode
browserOpenOp _drv = UntrustedOpcode
  { uoName = OpName "BROWSER_OPEN"
  , uoDesc = "Open a URL in a browser (driver-pluggable, fail-closed default)."
  , uoInSchema = browserSchema "url" "The URL to open."
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case urlField v of
        Nothing -> Left "BROWSER_OPEN requires {url:string}"
        Just u | T.null u -> Left "BROWSER_OPEN: url is empty"
               | otherwise -> Right ()
  , uoRun = \_uio v -> do
      let u = fromMaybe "" (urlField v)
          recorded = object [ "url" .= u ]
      pure (OpResult [TrpText "BROWSER_OPEN: no browser driver configured"] True recorded)
  }

-- | BROWSER_CLICK opcode. Input: @{ selector: Text }@.
browserClickOp :: BrowserDriver -> Opcode
browserClickOp _drv = UntrustedOpcode
  { uoName = OpName "BROWSER_CLICK"
  , uoDesc = "Click an element in a browser (driver-pluggable, fail-closed default)."
  , uoInSchema = browserSchema "selector" "The CSS selector to click."
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case selectorField v of
        Nothing -> Left "BROWSER_CLICK requires {selector:string}"
        Just s | T.null s -> Left "BROWSER_CLICK: selector is empty"
               | otherwise -> Right ()
  , uoRun = \_uio v -> do
      let s = fromMaybe "" (selectorField v)
          recorded = object [ "selector" .= s ]
      pure (OpResult [TrpText "BROWSER_CLICK: no browser driver configured"] True recorded)
  }

-- | BROWSER_READ opcode. Input: @{ selector: Text }@.
browserReadOp :: BrowserDriver -> Opcode
browserReadOp _drv = UntrustedOpcode
  { uoName = OpName "BROWSER_READ"
  , uoDesc = "Read text from a browser page (driver-pluggable, fail-closed default)."
  , uoInSchema = browserSchema "selector" "The CSS selector to read (or empty for the whole page)."
  , uoOutSchema = object []
  , uoAuthorize = \_v -> Right ()  -- selector is optional (empty = whole page)
  , uoRun = \_uio v -> do
      let s = fromMaybe "" (selectorField v)
          recorded = object [ "selector" .= s ]
      pure (OpResult [TrpText "BROWSER_READ: no browser driver configured"] True recorded)
  }

browserSchema :: Text -> Text -> Value
browserSchema fieldName desc =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText fieldName .= object
            [ "type" .= ("string" :: Text)
            , "description" .= desc
            ]
        ]
    , "required" .= [fieldName]
    ]

urlField :: Value -> Maybe Text
urlField = parseMaybe (withObject "in" (.: "url"))

selectorField :: Value -> Maybe Text
selectorField = parseMaybe (withObject "in" (.: "selector"))