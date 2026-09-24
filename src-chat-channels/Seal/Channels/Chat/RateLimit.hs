{-# LANGUAGE OverloadedStrings #-}
-- | Pure rate-limiting functions for streaming text edits. Copied from
-- 'Seal.Channels.StreamProgress' (the server-side implementation) so the
-- chat-channel package can rate-limit WS @entry-update@ edits without
-- depending on server internals.
--
-- These are the same pure functions: 'shouldEdit' decides when enough time
-- or text has accumulated, 'addCursor' appends the cursor character for
-- intermediate edits, 'stripCursor' removes it for the final edit.
module Seal.Channels.Chat.RateLimit
  ( StreamProgressConfig (..)
  , defaultStreamProgressConfig
  , resolveStreamProgressConfig
  , shouldEdit
  , addCursor
  , stripCursor
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)

-- | Configuration for streaming text edits. Matches the server-side
-- 'Seal.Channels.StreamProgress.StreamProgressConfig' field-for-field.
data StreamProgressConfig = StreamProgressConfig
  { spcEnabled         :: Bool
  , spcEditIntervalMs  :: Int    -- ^ minimum ms between edits
  , spcBufferThreshold :: Int    -- ^ codepoint count that forces an edit
  , spcCursor          :: Text   -- ^ the cursor character for intermediate edits
  } deriving stock (Eq, Show)

-- | The default config: enabled, with sensible defaults matching the
-- server-side config.
defaultStreamProgressConfig :: StreamProgressConfig
defaultStreamProgressConfig = StreamProgressConfig
  { spcEnabled = True
  , spcEditIntervalMs = 1500
  , spcBufferThreshold = 80
  , spcCursor = "\x2589"  -- █ left-seven-eighths block
  }

-- | Resolve an optional config into a fully-populated one. 'Nothing' returns
-- the default. A present-but-partial config fills missing fields from
-- 'defaultStreamProgressConfig'. Pure.
resolveStreamProgressConfig :: Maybe StreamProgressConfig -> StreamProgressConfig
resolveStreamProgressConfig = fromMaybe defaultStreamProgressConfig

-- | Should the manager send an edit now? Returns 'True' when enough time has
-- passed since the last edit, or the buffer threshold is exceeded. Pure
-- (takes the current time as an argument).
shouldEdit :: StreamProgressConfig -> UTCTime -> Maybe UTCTime -> Int -> Bool
shouldEdit cfg now mLastEdit accumLen =
  accumLen >= spcBufferThreshold cfg || timeElapsed
  where
    timeElapsed = case mLastEdit of
      Nothing -> True
      Just lastEdit ->
        diffUTCTime now lastEdit * 1000
          >= fromIntegral (spcEditIntervalMs cfg)

-- | Append the cursor to the text for intermediate edits. Pure.
addCursor :: StreamProgressConfig -> Text -> Text
addCursor cfg text =
  if T.null (spcCursor cfg) then text else text <> spcCursor cfg

-- | Strip the cursor from the text for the final edit. Pure.
stripCursor :: StreamProgressConfig -> Text -> Text
stripCursor cfg text =
  if T.null (spcCursor cfg)
    then text
    else fromMaybe text (T.stripSuffix (spcCursor cfg) text)