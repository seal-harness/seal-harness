-- | The widened channel capability record — the target the Signal channel
-- (Phase 2b) and the web gateway (Phase 7) implement. Coexists with the
-- existing 'Seal.Channel.Caps.ChannelCaps' (kept for the CLI TUI, which is
-- not unified into this handle in Phase 2a). House style: no type class;
-- callers receive the handle and call fields directly.
module Seal.Handles.Channel
  ( ChannelHandle (..)
  , Deferral (..)
  ) where

import Data.Text (Text)

import Seal.Core.MessageSource (MessageSource)

-- | A structured deferral for interactive ops on request/response channels
-- (Signal, the future unified CLI). The web channel is async-only and never
-- returns 'Deferred' — it returns 'AsyncQueued'. Kept simple in 2a: the
-- payload is just a marker the caller can match; 2b fills in the real shape
-- (a continuation id + a timeout) when a real consumer demands it.
data Deferral = Deferred | AsyncQueued
  deriving stock (Eq, Show)

-- | The widened channel capability record. Every field is an IO action so the
-- type is uniform between real and fake variants.
data ChannelHandle = ChannelHandle
  { chSend        :: Text -> IO ()
  -- ^ Emit one line to the user.
  , chSendError   :: Text -> IO ()
  -- ^ Emit an error line (may be formatted differently on some channels).
  , chSendChunk   :: Text -> IO ()
  -- ^ Emit one streaming chunk (for tool output / long replies). Channels
  -- that do not stream may batch and call 'chSend' once.
  , chPrompt      :: Text -> IO (Either Deferral Text)
  -- ^ Visible prompt; returns 'Right' the typed line on interactive channels,
  -- 'Left Deferred' on channels that cannot answer inline (the caller must
  -- wait for a follow-on message), 'Left AsyncQueued' on async channels.
  , chPromptSecret :: Text -> IO (Either Deferral Text)
  -- ^ Hidden (no-echo) prompt; same return shape as 'chPrompt'.
  , chStreaming   :: Bool
  -- ^ Whether this channel benefits from streaming (web: yes; Signal: yes,
  -- chunked; CLI TUI: yes, line-by-line).
  , chReadSecret  :: IO (Maybe Text)
  -- ^ Pull a secret the channel itself holds (e.g. a pairing token).
  -- 'Nothing' on channels with no channel-held secret. NOT a vault accessor
  -- — the vault is reached via the vault handle, not the channel.
  , chReceive     :: IO (Maybe MessageSource, Text)
  -- ^ Pull the next inbound message from the channel's inbox, with its
  -- authenticated 'MessageSource'. Returns @(Nothing, "")@ when the inbox
  -- is empty (the caller may block or poll depending on the channel).
  }