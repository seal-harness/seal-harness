-- | The 'ChatChannel' type class — the seam a chat channel implements to
-- be wired into the generic loop ('Seal.Channels.Chat.Loop'). Each method
-- is an 'IO' action so the type is uniform between real and mock variants.
--
-- The class is minimal: receive from the platform, send to the platform,
-- send with a returned message id (for editing), edit a message, and a
-- label. The generic loop handles all routing, session tracking, WS
-- streaming, and ASK_HUMAN through the gateway API.
module Seal.Channels.Chat.Class
  ( ChatChannel (..)
  ) where

import Data.Text (Text)

import Seal.Channels.Chat.Types (InboundMessage, ChatMessageId)

-- | The seam a chat channel implements. Each method is an 'IO' action.
class ChatChannel c where
  -- | Receive one inbound message from the platform. Returns 'Nothing' on
  -- EOF (the platform connection closed + inbox drained).
  ccReceive :: c -> IO (Maybe InboundMessage)

  -- | Send a message to the platform (plain text, no returned id).
  ccSend :: c -> Text -> IO ()

  -- | Send a message and return its platform id (for later editing via
  -- 'ccEditMessage'). 'Nothing' if the send failed or the platform doesn't
  -- support message ids.
  ccSendWithId :: c -> Text -> IO (Maybe ChatMessageId)

  -- | Edit a previously sent message: message id, new content. Returns
  -- 'True' on success, 'False' on failure (or unsupported).
  ccEditMessage :: c -> ChatMessageId -> Text -> IO Bool

  -- | The channel's label (e.g. @"signal"@, @"telegram"@).
  ccLabel :: c -> Text
