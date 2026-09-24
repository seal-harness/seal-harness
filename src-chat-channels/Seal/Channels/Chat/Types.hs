{-# LANGUAGE OverloadedStrings #-}
-- | Shared types for the chat-channel package. These types depend only on
-- 'seal-gateway-types' — no access to server internals. The 'ChatChannel'
-- type class lives in 'Seal.Channels.Chat.Class' (added in WU-3); this
-- module carries the leaf types both the class and the loop need.
module Seal.Channels.Chat.Types
  ( -- * Inbound messages
    InboundMessage (..)
  , ChatMessageId (..)
    -- * Session tracking
  , ConversationKey (..)
  , ReceivedMessage (..)
  , convKeyFromSource
  , SessionMap
  , newSessionMap
  , sessionLookup
  , sessionInsert
    -- * Gateway config
  , GatewayConfig (..)
  , defaultGatewayConfig
    -- * Streaming
  , StreamingState (..)
  , newStreamingState
  ) where

import Control.Concurrent.STM
  (TVar, atomically, newTVarIO, readTVarIO, modifyTVar')
import Data.IORef (IORef, newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Seal.Gateway.Types.Core (SessionId)
import Seal.Gateway.Types.ChannelKind (channelKindToText)
import Seal.Gateway.Types.MessageSource
  ( ConversationId
  , MessageSource
  , msChannelKind
  , msConversationId
  , conversationIdText
  )

-- | One inbound message from the platform (Signal, Telegram).
data InboundMessage = InboundMessage
  { imSource :: MessageSource
  , imBody   :: Text
  } deriving stock (Eq, Show)

-- | A raw received message from the transport: the conversation id, the
-- sender's user id (if available), and the message body. The transport
-- derives these from authenticated transport metadata (e.g. Telegram's
-- @chat.id@ + @from.id@, Signal's peer phone number + UUID). The body is
-- the message text. Pure data; the adapter's reader loop constructs a
-- 'MessageSource' from these fields.
data ReceivedMessage = ReceivedMessage
  { rmConversationId :: ConversationId
  , rmSender         :: Maybe Text
  , rmReplyTo        :: Text
    -- ^ The platform-specific reply target (Telegram chat id, Signal
    -- phone number). Used by the adapter to address sends/edits.
  , rmBody           :: Text
  } deriving stock (Eq, Show)

-- | A platform message identifier (opaque: a Telegram @message_id@ or a
-- Signal timestamp). Used for editing streaming bubbles.
newtype ChatMessageId = ChatMessageId Text
  deriving stock (Eq, Show)

-- | The per-conversation routing key: (channel-kind-text, conversation-id-text).
-- Derived from the 'MessageSource' (both fields are server-derived, never
-- user-supplied, so a sender cannot forge a key).
data ConversationKey = ConversationKey
  { ckChannel :: Text
  , ckConv    :: Text
  } deriving stock (Eq, Ord, Show)

-- | Derive the conversation key from a 'MessageSource'.
convKeyFromSource :: MessageSource -> ConversationKey
convKeyFromSource ms = ConversationKey
  { ckChannel = channelKindToText (msChannelKind ms)
  , ckConv = conversationIdText (msConversationId ms)
  }

-- | A client-side session map: conversation key → session id. Replaces the
-- server-side 'CursorStore'. Thread-safe via 'TVar'.
newtype SessionMap = SessionMap (TVar (Map ConversationKey SessionId))

-- | Create a new empty session map.
newSessionMap :: IO SessionMap
newSessionMap = SessionMap <$> newTVarIO Map.empty

-- | Look up the session id for a conversation key.
sessionLookup :: SessionMap -> ConversationKey -> IO (Maybe SessionId)
sessionLookup (SessionMap tv) key =
  Map.lookup key <$> readTVarIO tv

-- | Insert (or replace) a conversation's session id.
sessionInsert :: SessionMap -> ConversationKey -> SessionId -> IO ()
sessionInsert (SessionMap tv) key sid =
  atomically (modifyTVar' tv (Map.insert key sid))

-- | The gateway connection config: where the HTTP API and WS server live.
data GatewayConfig = GatewayConfig
  { gcHost     :: Text    -- ^ e.g. @"127.0.0.1"@
  , gcHttpPort :: Int     -- ^ e.g. 8080
  , gcWsPort   :: Int     -- ^ e.g. 8081
  , gcApiBase  :: Text    -- ^ e.g. @"http://127.0.0.1:8080/api"@
  , gcWsUrl    :: Text    -- ^ e.g. @"ws://127.0.0.1:8081"@
  } deriving stock (Eq, Show)

-- | Default config for localhost with typical ports.
defaultGatewayConfig :: GatewayConfig
defaultGatewayConfig = GatewayConfig
  { gcHost = "127.0.0.1"
  , gcHttpPort = 8080
  , gcWsPort = 8081
  , gcApiBase = "http://127.0.0.1:8080/api"
  , gcWsUrl = "ws://127.0.0.1:8081"
  }

-- | Mutable streaming state for one conversation's streaming bubble. Lives
-- in 'IORef's so the WS event handler can call create/edit without passing
-- state around.
data StreamingState = StreamingState
  { ssMsgId       :: IORef (Maybe ChatMessageId)
  , ssAccumulated :: IORef Text
  , ssLastEdit    :: IORef (Maybe UTCTime)
  , ssLastLen     :: IORef Int
    -- ^ Codepoints in the accumulated text at the last platform edit.
    -- The edit gate measures NEW text since the last edit, not the total.
  }

-- | Create fresh streaming state for one conversation.
newStreamingState :: IO StreamingState
newStreamingState = do
  msgId <- newIORef Nothing
  accum <- newIORef ""
  lastEdit <- newIORef Nothing
  lastLen <- newIORef 0
  pure StreamingState
    { ssMsgId = msgId
    , ssAccumulated = accum
    , ssLastEdit = lastEdit
    , ssLastLen = lastLen
    }
