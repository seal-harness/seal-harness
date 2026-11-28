{-# LANGUAGE OverloadedStrings #-}
-- | The transcript writer's exception type, in a leaf module.
--
-- Lives here rather than in 'Seal.Handles.Transcript' so that
-- 'Seal.Transcript.TurnFailure.classify' can probe it without the pure
-- classification module depending on @Seal.Handles.*@. That keeps
-- @Seal.Transcript.*@ a leaf layer (design §6, CTO suggestion 1): classifying
-- from @Seal.Session.TurnFailure@ instead would have imported
-- @Handles.Transcript@ into @Session.@, and @Handles.Transcript@ already
-- imports @Session.Log@, so the next change wanting to log a failure would
-- have closed the cycle.
--
-- The type is re-exported from 'Seal.Handles.Transcript' so every existing
-- import site keeps working unchanged.
module Seal.Transcript.Error
  ( TranscriptError (..)
  ) where

import Control.Exception (Exception, SomeException)
import Data.Text (Text)
import Data.Text qualified as T

-- | Raised by @itwRecordAndAck@ when the single-writer daemon has died (an I/O
-- error in @writeOne@ killed it), or when a write cannot be acknowledged.
--
-- The optional inner exception is the daemon's own fatal cause, carried up so
-- the user-facing failure report can name it. Without it the caller only ever
-- sees "the transcript became unavailable", which says nothing about /why/ —
-- the exact problem that made session @20261127-133020-166@ look like a silent
-- hang. See 'Seal.Handles.Transcript.itwLastFailure' for the read side.
--
-- 'Eq' and 'Show' are written by hand because 'SomeException' has neither, and
-- the type must stay comparable for tests and for 'Control.Exception' idioms.
-- Both instances deliberately look only at the /text/: two errors are equal
-- when their messages are, and 'Show' renders the message plus the inner
-- exception's own rendering (never a constructor dump, which for an arbitrary
-- exception can be enormous).
data TranscriptError = TranscriptError Text (Maybe SomeException)

instance Eq TranscriptError where
  TranscriptError a ma == TranscriptError b mb = a == b && fmap displayEx ma == fmap displayEx mb

instance Show TranscriptError where
  show (TranscriptError msg Nothing)  = "TranscriptError " <> show msg
  show (TranscriptError msg (Just e)) =
    "TranscriptError " <> show msg <> " (caused by: " <> T.unpack (displayEx e) <> ")"

-- | Render an exception the way @displayException@ does, so the 'Show' output
-- is a readable message rather than a nested constructor tree.
displayEx :: SomeException -> Text
displayEx = T.pack . show

instance Exception TranscriptError
