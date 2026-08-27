{-# LANGUAGE OverloadedStrings #-}
module Seal.Channel.Caps
  ( ChannelCaps(..)
  , AskPrompt(..)
  ) where

import Data.Default (Default (..))
import Data.Text (Text)

import Seal.Handles.AskReply (QuestionOption (..))

-- | A structured prompt for 'ccPrompt': the question text plus the offered
-- 'QuestionOption's (empty for open-ended questions and the confirmation
-- gate). Channels render the options in the richest way their transport
-- supports (web: buttons + "Other" textarea; Signal/CLI: numbered list;
-- Telegram: inline keyboard) and return the human's chosen text.
data AskPrompt = AskPrompt
  { apQuestion :: !Text
  , apOptions  :: ![QuestionOption]
  }

-- | A channel's interaction capabilities as a record of IO functions
-- (house style: no type class; callers receive the handle and call fields
-- directly). Web deferral of prompts is a later phase; the CLI TUI
-- is always interactive.
data ChannelCaps = ChannelCaps
  { ccSend         :: Text -> IO ()   -- ^ Emit one line to the user
  , ccPrompt       :: AskPrompt -> IO Text -- ^ Visible prompt; returns typed line
  , ccPromptSecret :: Text -> IO Text -- ^ Hidden (no-echo) prompt
  , ccStreaming    :: Bool
  -- ^ Whether the channel wants per-delta sends during streaming (CLI,
  -- web). When 'False' (Telegram, Signal), the loop skips per-delta
  -- 'ccSend' and sends the accumulated text once at the end via the
  -- normal stop path — avoiding a flood of per-token messages.
  , ccShowHuman    :: Text -> IO ()
  -- ^ Display a message to the human operator, guaranteed to be shown
  -- regardless of channel-specific verbosity settings or streaming
  -- suppression. Unlike 'ccSend' (which may be subject to future
  -- verbosity / intermediate-output suppression in chat channels), this
  -- is the SHOW_HUMAN contract: the message WILL reach the user. Web
  -- channels can leave this as a no-op (the message surfaces via the
  -- transcript + ToolCallBlock rendering); chat channels wire it to
  -- their 'chSend'.
  }

-- | The default 'ChannelCaps': all IO actions are no-ops and streaming is
-- enabled. Production callers override at least @ccSend@, @ccPrompt@, and
-- @ccPromptSecret@; test callers often override only @ccSend@. The
-- @ccStreaming@ default is 'True' (matching the CLI and web channels, where
-- per-delta sends are desired or harmless).
instance Default ChannelCaps where
  def = ChannelCaps
    { ccSend         = \_ -> pure ()
    , ccPrompt       = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
    , ccStreaming    = True
    , ccShowHuman    = \_ -> pure ()
    }
