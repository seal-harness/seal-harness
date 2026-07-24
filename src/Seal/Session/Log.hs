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
  ) where

import Control.Exception (catch, SomeException)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime, formatTime, defaultTimeLocale)
import System.IO (withFile, IOMode (AppendMode), hPutStr)

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