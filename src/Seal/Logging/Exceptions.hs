{-# LANGUAGE OverloadedStrings #-}
-- | Unified exception handling helper. Replaces the 6 duplicated @catch@
-- patterns across 'Seal.Channels.Loop', 'Seal.Gateway.Send', and
-- 'Seal.Channel.Cli' with a single function that:
--
-- 1. Catches /synchronous/ exceptions only. 'AsyncException' (including
--    'ThreadKilled') is rethrown after logging at 'InfoS' — shutdown must
--    propagate to the bracket, not be swallowed.
-- 2. Logs the full exception to the operator log via 'logIO' at 'ErrorS',
--    including the 'where' label and the logger's 'ChannelContext'.
-- 3. Returns a /sanitized/ 'Text' for the user (via 'Left'): a generic
--    message (@\"internal error (\<where\>) [ref: \<correlationId\>]"@)
--    with a short correlation id so the operator can correlate the user's
--    report to the log entry. 'TranscriptError' text passes through
--    unchanged (it's already user-facing).
-- 4. Calls the optional session-log path ('logTurnError') alongside the
--    katip emission, so the per-session @seal.log@ audit trail is kept.
-- 5. Escapes newlines in the exception text before logging (log-injection
--    defense).
module Seal.Logging.Exceptions
  ( withExceptionLogging
  ) where

import Control.Exception
  ( catch, throwIO, fromException, SomeException, AsyncException (..) )
import Data.Text (Text)
import Data.Text qualified as T
import System.Random (randomIO)

import Seal.Logging.Logger (SealLogger, logIO, escapeNewlines)
import Seal.Session.Log (logTurnError)
import Seal.Handles.Transcript (TranscriptError (..))

import Katip (Severity (..), ls)

-- | Run an 'IO' action, catching synchronous exceptions. Logs the exception
-- with the logger's context + the given 'where' label, calls the optional
-- session-log fallback, and returns either a sanitized error text (for the
-- caller to send to the user) or the original result.
--
-- 'AsyncException' (including 'ThreadKilled') is NOT caught — it is
-- rethrown after logging at 'InfoS', so shutdown propagates to the
-- bracket.
withExceptionLogging
  :: SealLogger
  -> Maybe FilePath          -- ^ session log path (for seal.log fallback)
  -> Text                    -- ^ 'where' label (e.g. "slash command", "turn")
  -> IO a
  -> IO (Either Text a)
withExceptionLogging logger mLogPath whereLabel action =
  (Right <$> action) `catch` \e -> do
    case (fromException e :: Maybe AsyncException) of
      Just asyncEx -> do
        logIO logger InfoS (escapeNewlines (ls $
          "shutdown signal in " <> whereLabel <> ": " <> showLs asyncEx))
        throwIO e
      Nothing -> do
        correlationId <- mkCorrelationId
        let (userMsg, fullDetail) = sanitizeException whereLabel e correlationId
        logIO logger ErrorS (escapeNewlines (ls fullDetail))
        logTurnError mLogPath fullDetail
        pure (Left userMsg)

-- | Generate a short correlation id (8 hex chars from a random nonce).
mkCorrelationId :: IO Text
mkCorrelationId = do
  n <- abs <$> randomIO :: IO Int
  pure (T.justifyRight 8 '0' (T.pack (show n)))

-- | Sanitize an exception for user-facing text. Returns:
-- * (userMsg, fullDetail) where userMsg is safe to send to the user
--   and fullDetail is the complete exception text for the operator log.
sanitizeException :: Text -> SomeException -> Text -> (Text, Text)
sanitizeException whereLabel e correlationId =
  case (fromException e :: Maybe TranscriptError) of
    Just (TranscriptError te) ->
      ("transcript error: " <> te, "transcript error: " <> te <> " (" <> whereLabel <> ")")
    Nothing ->
      ( "internal error (" <> whereLabel <> ") [ref: " <> correlationId <> "]"
      , whereLabel <> " failed: " <> T.pack (show e) <> " [ref: " <> correlationId <> "]"
      )

-- | Helper to show something as LogStr-compatible Text.
showLs :: Show a => a -> Text
showLs = T.pack . show