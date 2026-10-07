{-# LANGUAGE OverloadedStrings #-}
-- | BROWSER_MANAGE (Untrusted): consolidated action-based entry point for
-- all browser automation via the @agent-browser@ CLI
-- (<https://github.com/vercel-labs/agent-browser>). The opcode shells out
-- to @agent-browser@ via 'uioBinExec' — the existing 'UntrustedIO' capability
-- seam for named binaries with validated argv. This module never imports
-- 'System.Process'; all IO goes through the capability handle.
--
-- agent-browser manages its own daemon + Chromium lifecycle. Seal Harness
-- treats it as a black-box CLI that returns text or JSON on stdout. The
-- @--json@ flag is always passed so output is structured. The @--max-output@
-- flag bounds the response size (operator-configurable, default 15000 chars).
module Seal.ISA.Ops.Browser
  ( browserManageOp
  , BrowserAction (..)
  , NetworkFilters (..)
  , HarAction (..)
  , parseBrowserAction
  , buildBrowserArgs
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Tools.Args (BinArg, BinName, mkBinArg, mkBinName)
import Seal.Tools.Exec.UIO (renderUntrustedErr, uioBinExec)

-- | The action enum — discriminates between browser operations.
data BrowserAction
  = BaOpen       Text           -- ^ url
  | BaSnapshot
  | BaClick      Text           -- ^ ref (@eN) or CSS selector
  | BaFill       Text Text      -- ^ ref/selector, text
  | BaType       Text Text      -- ^ ref/selector, text
  | BaPress      Text           -- ^ key (Enter, Tab, etc.)
  | BaScroll     Text           -- ^ direction (up/down/left/right)
  | BaRead       (Maybe Text)   -- ^ optional URL
  | BaScreenshot (Maybe Text)   -- ^ optional path
  | BaEval       Text           -- ^ JavaScript
  | BaWait       Text           -- ^ selector or condition
  | BaClose
  | BaSession
  | BaNetworkRequests NetworkFilters  -- ^ network requests with optional filters
  | BaNetworkRequest  Text            -- ^ requestId for a single request detail
  | BaNetworkHar       HarAction      -- ^ HAR recording start/stop
  deriving stock (Eq, Show)

-- | Optional filter flags for @network requests@.
data NetworkFilters = NetworkFilters
  { nfFilter :: Maybe Text   -- ^ @--filter <pattern>@: URL substring or pattern
  , nfType   :: Maybe Text   -- ^ @--type <csv>@: resource type (script, image, xhr, fetch, ...)
  , nfMethod :: Maybe Text   -- ^ @--method <method>@: HTTP method (GET, POST, ...)
  , nfStatus :: Maybe Text   -- ^ @--status <status>@: exact status, family (2xx), or range
  , nfClear  :: Bool          -- ^ @--clear@: clear the tracked request log
  } deriving stock (Eq, Show)

-- | Discriminates between HAR start and stop sub-actions.
data HarAction
  = HarStart (Maybe Text)  -- ^ start recording; optional @--content@ mode (text, all, none)
  | HarStop  (Maybe Text)  -- ^ stop recording; optional output file path
  deriving stock (Eq, Show)

-- | The default max-output ceiling (characters). Operator-configurable
-- via config in a future task.
defaultMaxOutput :: Int
defaultMaxOutput = 15000

-- | BROWSER_MANAGE opcode. Input: @{ action: string, ...action-specific fields }@.
browserManageOp :: SecurityPolicy -> Opcode
browserManageOp policy = UntrustedOpcode
  { uoName = OpName "BROWSER_MANAGE"
  , uoDesc = "Browser automation via agent-browser CLI. Action: open (url), snapshot (interactive elements), click (ref/selector), fill (ref+text), type (ref+text), press (key), scroll (dir), read (url?), screenshot (path?), eval (js), wait (selector), close, session (list current), network-requests (filters?), network-request (requestId), network-har (harAction)."
  , uoInSchema = browserManageSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case parseBrowserAction v of
        Left e -> Left e
        Right _ -> checkAutonomy
  , uoRun = \v -> do
      let recorded = object [ "action" .= actionField v ]
      case parseBrowserAction v of
        Left e -> pure (OpResult [TrpText e] True recorded)
        Right action -> do
          let mSession = sessionField v
              maxOut = defaultMaxOutput
          case buildBrowserArgs action mSession maxOut of
            Left e -> pure (OpResult [TrpText e] True recorded)
            Right (binName, binArgs) -> do
              res <- uioBinExec binName binArgs Nothing
              pure $ case res of
                Left err -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                Right out -> OpResult [TrpText out] False recorded
  }
  where
    checkAutonomy = case spAutonomy policy of
      Deny -> Left "BROWSER_MANAGE denied by autonomy policy"
      _    -> Right ()

-- | Parse the action + action-specific fields from the input JSON.
parseBrowserAction :: Value -> Either Text BrowserAction
parseBrowserAction v =
  case actionField v of
    Nothing -> Left "BROWSER_MANAGE requires {action:string}"
    Just a
      | a == "open"             -> BaOpen <$> requireField a v "url"
      | a == "snapshot"         -> Right BaSnapshot
      | a == "click"            -> BaClick <$> refOrSelector a v
      | a == "fill"             -> BaFill <$> refOrSelector a v <*> requireField a v "text"
      | a == "type"             -> BaType <$> refOrSelector a v <*> requireField a v "text"
      | a == "press"            -> BaPress <$> requireField a v "key"
      | a == "scroll"           -> BaScroll <$> requireField a v "dir"
      | a == "read"             -> Right (BaRead (optionalField v "url"))
      | a == "screenshot"       -> Right (BaScreenshot (optionalField v "path"))
      | a == "eval"             -> BaEval <$> requireField a v "js"
      | a == "wait"             -> BaWait <$> requireField a v "selector"
      | a == "close"            -> Right BaClose
      | a == "session"          -> Right BaSession
      | a == "network-requests" -> Right (BaNetworkRequests (parseNetworkFilters v))
      | a == "network-request"  -> BaNetworkRequest <$> requireField a v "requestId"
      | a == "network-har"      -> BaNetworkHar <$> parseHarAction v
      | otherwise               -> Left ("BROWSER_MANAGE: unknown action \"" <> a <> "\"")

-- | Build the agent-browser argv from the parsed action.
-- Returns (binary name, argv args) or an error if a BinArg fails validation.
buildBrowserArgs :: BrowserAction -> Maybe Text -> Int
                -> Either Text (BinName, [BinArg])
buildBrowserArgs action mSession maxOut = do
  binName <- mkBinName "agent-browser"
  baseArgs <- traverse mkBinArg baseArgTexts
  cmdArgs <- traverse mkBinArg cmdArgTexts
  Right (binName, baseArgs ++ cmdArgs)
  where
    baseArgTexts :: [Text]
    baseArgTexts =
      [ "--json", "--max-output", T.pack (show maxOut) ]
      ++ sessionArgs

    sessionArgs :: [Text]
    sessionArgs = case mSession of
      Just s -> ["--session", s]
      Nothing -> []

    cmdArgTexts :: [Text]
    cmdArgTexts = case action of
      BaOpen url         -> ["open", url]
      BaSnapshot         -> ["snapshot", "-i"]
      BaClick ref        -> ["click", ref]
      BaFill ref text    -> ["fill", ref, text]
      BaType ref text    -> ["type", ref, text]
      BaPress key        -> ["press", key]
      BaScroll dir       -> ["scroll", dir]
      BaRead mUrl        -> case mUrl of
                             Just url -> ["read", url]
                             Nothing  -> ["read"]
      BaScreenshot mPath -> case mPath of
                             Just path -> ["screenshot", path]
                             Nothing   -> ["screenshot"]
      BaEval js          -> ["eval", js]
      BaWait sel         -> ["wait", sel]
      BaClose            -> ["close"]
      BaSession          -> ["session", "list"]
      BaNetworkRequests f -> ["network", "requests"] ++ filterArgTexts f
      BaNetworkRequest rid -> ["network", "request", rid]
      BaNetworkHar hAction -> case hAction of
        HarStart mContent -> ["network", "har", "start"] ++ contentArgTexts mContent
        HarStop  mPath    -> ["network", "har", "stop"]  ++ maybeToList mPath

-- | The input schema — a flat object with an action enum and action-specific
-- fields. All fields are optional except @action@; the authorize gate
-- validates per-action requirements.
browserManageSchema :: Value
browserManageSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText "action" .= object
            [ "type" .= ("string" :: Text)
            , "enum" .= (actionEnum :: [Text])
            , "description" .= ("Browser operation to perform." :: Text)
            ]
        , fromText "url" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("URL to open or read (open, read)." :: Text)
            ]
        , fromText "ref" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Element ref from snapshot, e.g. @e1 (click, fill, type)." :: Text)
            ]
        , fromText "selector" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("CSS selector (click, fill, type, wait — alternative to ref)." :: Text)
            ]
        , fromText "text" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Text to fill or type (fill, type)." :: Text)
            ]
        , fromText "key" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Key to press, e.g. Enter, Tab, Control+a (press)." :: Text)
            ]
        , fromText "dir" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Scroll direction: up, down, left, right (scroll)." :: Text)
            ]
        , fromText "path" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("File path for screenshot or HAR output (screenshot, network-har stop)." :: Text)
            ]
        , fromText "js" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("JavaScript to evaluate in page (eval)." :: Text)
            ]
        , fromText "session" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("agent-browser session name for isolation. Optional; defaults to the agent-browser default session." :: Text)
            ]
        , fromText "requestId" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Request ID from network-requests output (network-request)." :: Text)
            ]
        , fromText "harAction" .= object
            [ "type" .= ("string" :: Text)
            , "enum" .= (["start", "stop"] :: [Text])
            , "description" .= ("HAR sub-action: start or stop recording (network-har)." :: Text)
            ]
        , fromText "content" .= object
            [ "type" .= ("string" :: Text)
            , "enum" .= (["text", "all", "none"] :: [Text])
            , "description" .= ("HAR body capture mode: text (default), all (base64), none (network-har start)." :: Text)
            ]
        , fromText "filter" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Filter requests by URL substring or pattern (network-requests)." :: Text)
            ]
        , fromText "type" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Filter by resource type, comma-separated: script, image, font, xhr, fetch (network-requests)." :: Text)
            ]
        , fromText "method" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Filter by HTTP method, e.g. GET, POST (network-requests)." :: Text)
            ]
        , fromText "status" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Filter by status: exact (200), family (2xx), or range (200-299) (network-requests)." :: Text)
            ]
        , fromText "clear" .= object
            [ "type" .= ("boolean" :: Text)
            , "description" .= ("Clear the tracked request log (network-requests)." :: Text)
            ]
        ]
    , "required" .= (["action"] :: [Text])
    ]
  where
    actionEnum =
      [ "open", "snapshot", "click", "fill", "type", "press"
      , "scroll", "read", "screenshot", "eval", "wait", "close", "session"
      , "network-requests", "network-request", "network-har"
      ]

-- ── Network parsing helpers ──────────────────────────────────────────────

-- | Parse the optional filter fields for @network-requests@.
parseNetworkFilters :: Value -> NetworkFilters
parseNetworkFilters v = NetworkFilters
  { nfFilter = optionalField v "filter"
  , nfType   = optionalField v "type"
  , nfMethod = optionalField v "method"
  , nfStatus = optionalField v "status"
  , nfClear  = boolField v "clear"
  }

-- | Parse the @harAction@ discriminator and its sub-fields for @network-har@.
parseHarAction :: Value -> Either Text HarAction
parseHarAction v =
  case optionalField v "harAction" of
    Nothing -> Left "BROWSER_MANAGE: network-har requires {harAction:string}"
    Just ha
      | ha == "start" -> Right (HarStart (optionalField v "content"))
      | ha == "stop"  -> Right (HarStop (optionalField v "path"))
      | otherwise     -> Left ("BROWSER_MANAGE: network-har requires harAction \"start\" or \"stop\", got \"" <> ha <> "\"")

-- | Build the @--flag value@ argv tokens from 'NetworkFilters'.
filterArgTexts :: NetworkFilters -> [Text]
filterArgTexts f = concat
  [ maybe [] (\x -> ["--filter", x]) (nfFilter f)
  , maybe [] (\x -> ["--type", x])   (nfType f)
  , maybe [] (\x -> ["--method", x]) (nfMethod f)
  , maybe [] (\x -> ["--status", x]) (nfStatus f)
  , ["--clear" | nfClear f]
  ]

-- | Build the @--content@ argv token from an optional content mode.
contentArgTexts :: Maybe Text -> [Text]
contentArgTexts = maybe [] (\c -> ["--content", c])

-- ── Field accessors ──────────────────────────────────────────────────────

actionField :: Value -> Maybe Text
actionField = parseMaybe (withObject "in" (.: "action"))

sessionField :: Value -> Maybe Text
sessionField v = case parseMaybe (withObject "in" (.:? "session")) v :: Maybe (Maybe Text) of
  Just (Just s) | not (T.null s) -> Just s
  _                              -> Nothing

requireField :: Text -> Value -> Text -> Either Text Text
requireField act v field =
  case parseMaybe (withObject "in" (.: fromText field)) v of
    Nothing -> Left ("BROWSER_MANAGE: " <> act <> " requires {" <> field <> ":string}")
    Just s
      | T.null s -> Left ("BROWSER_MANAGE: " <> field <> " is empty")
      | otherwise -> Right s

optionalField :: Value -> Text -> Maybe Text
optionalField v field =
  case parseMaybe (withObject "in" (.:? fromText field)) v :: Maybe (Maybe Text) of
    Just (Just s) | not (T.null s) -> Just s
    _                              -> Nothing

-- | Read a boolean field from the input JSON (defaults to False).
boolField :: Value -> Text -> Bool
boolField v field =
  case parseMaybe (withObject "in" (.:? fromText field)) v :: Maybe (Maybe Bool) of
    Just (Just b) -> b
    _             -> False

-- | Get the ref or selector for click/fill/type actions.
refOrSelector :: Text -> Value -> Either Text Text
refOrSelector act v =
  case optionalField v "ref" of
    Just r -> Right r
    Nothing -> case optionalField v "selector" of
      Just s -> Right s
      Nothing -> Left ("BROWSER_MANAGE: " <> act <> " requires {ref:string} or {selector:string}")
