module Seal.Channel.Caps
  ( ChannelCaps(..)
  ) where

import Data.Text (Text)

-- | A channel's interaction capabilities as a record of IO functions
-- (house style: no type class; callers receive the handle and call fields
-- directly). Web deferral of prompts is a later phase; the CLI REPL
-- is always interactive.
data ChannelCaps = ChannelCaps
  { ccSend         :: Text -> IO ()   -- ^ Emit one line to the user
  , ccPrompt       :: Text -> IO Text -- ^ Visible prompt; returns typed line
  , ccPromptSecret :: Text -> IO Text -- ^ Hidden (no-echo) prompt
  }
