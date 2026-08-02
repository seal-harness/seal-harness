module Seal.Channel.Caps
  ( ChannelCaps(..)
  ) where

import Data.Text (Text)

-- | A channel's interaction capabilities as a record of IO functions
-- (house style: no type class; callers receive the handle and call fields
-- directly). Web deferral of prompts is a later phase; the CLI TUI
-- is always interactive.
data ChannelCaps = ChannelCaps
  { ccSend         :: Text -> IO ()   -- ^ Emit one line to the user
  , ccPrompt       :: Text -> IO Text -- ^ Visible prompt; returns typed line
  , ccPromptSecret :: Text -> IO Text -- ^ Hidden (no-echo) prompt
  , ccStreaming    :: Bool
  -- ^ Whether the channel wants per-delta sends during streaming (CLI,
  -- web). When 'False' (Telegram, Signal), the loop skips per-delta
  -- 'ccSend' and sends the accumulated text once at the end via the
  -- normal stop path — avoiding a flood of per-token messages.
  }