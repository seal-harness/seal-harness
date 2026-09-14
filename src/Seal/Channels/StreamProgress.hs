{-# LANGUAGE OverloadedStrings #-}
-- | The streaming progress manager for chat channels. When enabled, the
-- agent loop routes text deltas and tool-call notifications through this
-- module, which sends progressive edits to the chat platform (Telegram via
-- @editMessageText@, Signal via @send@ with @editTimestamp@). Both
-- platforms support message editing, so the same edit-based algorithm
-- works for both — the message identifier is an opaque 'Text' to the
-- caller (a Telegram @message_id@ string or a Signal @timestamp@ string).
--
-- The module is in the library (not a channel-specific sub-module) because
-- the streaming logic is platform-agnostic; only the 'ChannelHandle' /
-- transport methods differ. Mirrors Hermes' @GatewayStreamConsumer@ but
-- adapted to Seal's @ReaderT AppEnv IO@ + handle pattern.
module Seal.Channels.StreamProgress
  ( StreamProgressConfig (..)
  , defaultStreamProgressConfig
  , resolveStreamProgressConfig
  ) where

import Data.Default (Default (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)

-- | Configuration for the stream progress manager. Loaded from the
-- @[chat_streaming]@ section of @config.toml@. When @spcEnabled@ is
-- 'False', the manager is inert (the existing behavior: no streaming,
-- no tool progress, final text sent once via 'replyFanout').
data StreamProgressConfig = StreamProgressConfig
  { spcEnabled         :: !Bool
    -- ^ Master switch. 'False' = existing behavior (no streaming).
  , spcToolProgress    :: !Bool
    -- ^ Send tool-call notifications as an editable progress bubble.
  , spcTextStreaming   :: !Bool
    -- ^ Progressive text edits as tokens arrive.
  , spcEditIntervalMs  :: !Int
    -- ^ Minimum milliseconds between edits (rate limiting).
  , spcBufferThreshold :: !Int
    -- ^ Codepoints accumulated before forcing an edit (debounce).
  , spcCursor          :: !Text
    -- ^ Cursor character appended to intermediate edits (removed on
    -- the final edit). Default: @▉@ (U+2589 LEFT ONE QUARTER BLOCK).
  } deriving stock (Eq, Show)

-- | The default config: disabled, with sensible defaults for the other
-- fields. When the operator enables @spcEnabled@, the rest of the fields
-- are already populated.
instance Default StreamProgressConfig where
  def = StreamProgressConfig
    { spcEnabled         = False
    , spcToolProgress    = True
    , spcTextStreaming   = True
    , spcEditIntervalMs  = 1500
    , spcBufferThreshold = 80
    , spcCursor          = "\x2589"
    }

-- | The canonical default for re-export. Same as 'def'.
defaultStreamProgressConfig :: StreamProgressConfig
defaultStreamProgressConfig = def

-- | Resolve an optional 'StreamProgressConfig' from the config file into a
-- fully-populated one. 'Nothing' (the @[chat_streaming]@ section is absent)
-- returns the disabled default. A present-but-partial section fills
-- missing fields from 'def'. Pure.
resolveStreamProgressConfig :: Maybe StreamProgressConfig -> StreamProgressConfig
resolveStreamProgressConfig = fromMaybe def