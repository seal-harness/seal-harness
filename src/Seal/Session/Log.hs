{-# LANGUAGE OverloadedStrings #-}
-- | Best-effort per-session diagnostic log (@\<sessionDir\>\/seal.log@).
--
-- Records turn lifecycle events (start/end/duration) and failures (exceptions,
-- provider errors) that are NOT already captured in @entries.jsonl@ or
-- @conversation.jsonl@. The transcript files record what the model + opcodes
-- did; this log records what the /harness/ did — where it started, where it
-- stopped, and why it failed when it failed.
--
-- Design constraints:
--
-- 1. /Best-effort, never throws./ A write error (full disk, permissions,
--    missing parent dir) is swallowed — the log must never break the agent
--    loop. The worst case is a missing log line, not a crashed session.
-- 2. /Append-only, one line per event./ Each line carries an ISO-8601
--    timestamp prefix + a level tag + the message. Human-readable,
--    grep-friendly.
-- 3. /No duplication of transcript data./ Message content, tool-call inputs,
--    and opcode results are already in @conversation.jsonl@ / @entries.jsonl@.
--    This log records only lifecycle boundaries + failure diagnostics.
module Seal.Session.Log
  ( appendSessionLog
  , logTurnStart
  , logTurnEnd
  , logTurnError
  , logProviderError
  , logMaxTurns
  , logTruncation
  , logTruncationGiveUp
  , logModelResponse
  , logStreamResult
  , logToolDispatch
  , logDegenerateResponse
  , logRetryAttempt
  , logRetryExhausted
  , maxLengthContinueRetries
  ) where

import Control.Exception (catch, SomeException)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime, formatTime, defaultTimeLocale)
import System.IO (withFile, IOMode (AppendMode), hPutStr)
import Seal.Providers.Class (StopReason (..), ContentBlock (..))
import Seal.Core.Types (OpName (..))

-- | Maximum number of auto-continuation retries when the provider returns
-- 'StopMaxTokens' with no tool calls (text was truncated mid-generation).
-- After this many retries the loop surfaces a user-visible truncation
-- notice and stops. Mirrors Hermes' @length_continue_retries < 3@ cap.
maxLengthContinueRetries :: Int
maxLengthContinueRetries = 3

-- | Append a single line to the session log. Best-effort: any IO error is
-- swallowed. The line is prefixed with an ISO-8601 timestamp and the given
-- level tag. A 'Nothing' path is a no-op (logging disabled).
appendSessionLog :: Maybe FilePath -> Text -> Text -> IO ()
appendSessionLog Nothing       _     _ = pure ()
appendSessionLog (Just path) level msg = do
  now <- getCurrentTime
  let line = T.unpack (formatLogLine now level msg)
  withFile path AppendMode (`hPutStr` (line <> "\n"))
    `catch` \(_ :: SomeException) -> pure ()

-- | Format a log line: @\<ISO-8601 ts\> [LEVEL] message@
formatLogLine :: UTCTime -> Text -> Text -> Text
formatLogLine ts level msg =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" ts)
  <> " [" <> level <> "] " <> msg

-- | Log a turn start. @turnN@ is the 0-based remaining-turns counter from
-- 'runTurn' (the first turn is @aeMaxTurns@).
logTurnStart :: Maybe FilePath -> Int -> IO ()
logTurnStart mPath turnN =
  appendSessionLog mPath "TURN" ("start (turns remaining: " <> T.pack (show turnN) <> ")")

-- | Log a turn end with a duration in milliseconds.
logTurnEnd :: Maybe FilePath -> Int -> Integer -> IO ()
logTurnEnd mPath turnN ms =
  appendSessionLog mPath "TURN" ("end (turns remaining: " <> T.pack (show turnN)
    <> ", " <> T.pack (show ms) <> "ms)")

-- | Log a turn failure (caught exception). The message is the exception text.
logTurnError :: Maybe FilePath -> Text -> IO ()
logTurnError mPath err =
  appendSessionLog mPath "ERROR" ("turn failed: " <> err)

-- | Log a provider error (the 'Left' branch of 'providerComplete').
logProviderError :: Maybe FilePath -> Text -> IO ()
logProviderError mPath err =
  appendSessionLog mPath "ERROR" ("provider error: " <> err)

-- | Log the max-turns stop (the loop hit @aeMaxTurns@ without a final text
-- response).
logMaxTurns :: Maybe FilePath -> IO ()
logMaxTurns mPath =
  appendSessionLog mPath "WARN" "stopped: too many tool turns (hit aeMaxTurns)"

-- | Log a @StopMaxTokens@ truncation that triggered an auto-continuation
-- retry. @attempt@ is 1-based (1 = first retry requested). Mirrors Hermes'
-- @↻ Requesting continuation (N/3)@ log line.
logTruncation :: Maybe FilePath -> Int -> IO ()
logTruncation mPath attempt =
  appendSessionLog mPath "WARN"
    ("response truncated (StopMaxTokens) - requesting continuation ("
      <> T.pack (show attempt) <> "/" <> T.pack (show maxLengthContinueRetries) <> ")")

-- | Log a @StopMaxTokens@ truncation after all continuation retries are
-- exhausted. The loop surfaces a user-visible truncation notice and stops.
logTruncationGiveUp :: Maybe FilePath -> IO ()
logTruncationGiveUp mPath =
  appendSessionLog mPath "WARN"
    ("stopped: response remained truncated after "
      <> T.pack (show maxLengthContinueRetries)
      <> " continuation attempts")

-- ── New logging for session-loop diagnostics ────────────────────────────

-- | Log a summary of the model response after aggregation. Records metadata
-- (stop reason, content block count, tool call count, text length) — NOT the
-- actual text content (which is in conversation.jsonl).
logModelResponse :: Maybe FilePath -> StopReason -> [ContentBlock] -> IO ()
logModelResponse mPath stopReason blocks =
  appendSessionLog mPath "DEBUG"
    ("model response: stop=" <> stopReasonText stopReason
      <> " blocks=" <> T.pack (show (length blocks))
      <> " toolCalls=" <> T.pack (show (length [ () | CbToolUse{} <- blocks ]))
      <> " textLen=" <> T.pack (show (sum [ T.length t | CbText t <- blocks ]))
      <> " thinkingLen=" <> T.pack (show (sum [ T.length t | CbThinking t <- blocks ])))

-- | Log the result of the stream race (success, timeout, abort, or error).
logStreamResult :: Maybe FilePath -> Either Text a -> IO ()
logStreamResult mPath result =
  appendSessionLog mPath "DEBUG" $
    case result of
      Right _ -> "stream result: success"
      Left err
        | err == "(stopped)" -> "stream result: aborted (user stop)"
        | "stream timed out" `T.isInfixOf` err -> "stream result: timeout"
        | otherwise -> "stream result: error (" <> err <> ")"

-- | Log a tool dispatch outcome. Records tool name, success/error, and
-- result size — NOT the actual result content.
logToolDispatch :: Maybe FilePath -> OpName -> Bool -> Int -> IO ()
logToolDispatch mPath (OpName name) isError resultSize =
  appendSessionLog mPath "DEBUG"
    ("tool dispatch: " <> name
      <> " result=" <> (if isError then "error" else "ok")
      <> " parts=" <> T.pack (show resultSize))

-- | Log a degenerate response warning (no tool calls, no text, stop ≠ MaxTokens).
logDegenerateResponse :: Maybe FilePath -> StopReason -> [ContentBlock] -> IO ()
logDegenerateResponse mPath stopReason blocks =
  appendSessionLog mPath "WARN"
    ("degenerate response: stop=" <> stopReasonText stopReason
      <> " blocks=" <> T.pack (show (length blocks))
      <> " — model returned no usable content (no tool calls, no text)")

-- | Log a retry attempt before it fires. Records attempt number, max,
-- reason, and backoff delay.
logRetryAttempt :: Maybe FilePath -> Int -> Int -> Text -> Int -> IO ()
logRetryAttempt mPath attempt maxRetries reason delayMs =
  appendSessionLog mPath "INFO"
    ("retry attempt " <> T.pack (show attempt) <> "/" <> T.pack (show maxRetries)
      <> ": reason=" <> reason
      <> " backoff=" <> T.pack (show delayMs) <> "ms")

-- | Log retry exhaustion after all attempts fail.
logRetryExhausted :: Maybe FilePath -> Int -> Text -> IO ()
logRetryExhausted mPath maxRetries reason =
  appendSessionLog mPath "ERROR"
    ("retry exhausted after " <> T.pack (show maxRetries)
      <> " attempts: " <> reason
      <> " — see seal.log for full diagnostic details")

-- | Render a 'StopReason' as short text for log lines.
stopReasonText :: StopReason -> Text
stopReasonText StopEnd        = "StopEnd"
stopReasonText StopToolUse    = "StopToolUse"
stopReasonText StopMaxTokens  = "StopMaxTokens"
stopReasonText (StopOther t)  = "StopOther:" <> t
