-- | The 'ChatChannel' type class — the seam a chat channel implements to
-- be wired into the generic loop ('Seal.Channels.Chat.Loop'). Each method
-- is an 'IO' action so the type is uniform between real and mock variants.
--
-- The class is minimal: receive from the platform, send to the platform,
-- send with a returned message id (for editing), edit a message, and a
-- label. The generic loop handles all routing, session tracking, WS
-- streaming, and ASK_HUMAN through the gateway API.
--
-- Optional methods ('ccSendWithOptions', 'ccAnswerCallback',
-- 'ccEditReplyMarkup', 'ccLastChatId') have default no-op / 'Nothing'
-- implementations so channels that don't support inline keyboards (Signal,
-- mock) fall back to the text-based question rendering.
module Seal.Channels.Chat.Class
  ( ChatChannel (..)
  , QuestionOption (..)
  ) where

import Data.Text (Text)

import Seal.Channels.Chat.Types (InboundMessage, ChatMessageId)

-- | One discrete choice offered alongside an ASK_HUMAN question. Mirrors
-- 'Seal.Handles.AskReply.QuestionOption' but lives in the chat-channel
-- package (no dependency on server internals). The label is the value
-- returned when the human picks this choice; the description is a one-line
-- explanation shown alongside the button.
data QuestionOption = QuestionOption
  { qoLabel       :: !Text
  , qoDescription :: !Text
  } deriving stock (Eq, Show)

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

  -- | Send a question with multiple-choice options as an inline keyboard
  -- (one button per option). The @askIdPrefix@ is the 8-hex prefix of the
  -- ask id — the channel embeds it in the callback_data
  -- (@\"<prefix>:<index>\"@) so the loop can tie a button tap back to the
  -- specific pending question. The body carries the full question + option
  -- descriptions; the buttons carry just the short labels. Returns the
  -- platform message id of the sent message (for later keyboard removal
  -- via 'ccEditReplyMarkup'). 'Nothing' if the channel doesn't support
  -- inline keyboards — the loop falls back to 'ccSend' with a numbered
  -- list. Default: 'Nothing' (unsupported).
  ccSendWithOptions
    :: c -> Text -> [QuestionOption] -> Text -> IO (Maybe ChatMessageId)
  ccSendWithOptions _ _ _ _ = pure Nothing

  -- | Acknowledge a callback query (dismiss the button's loading spinner).
  -- Best-effort: never throws. Default: no-op (unsupported).
  ccAnswerCallback :: c -> Text -> IO ()
  ccAnswerCallback _ _ = pure ()

  -- | Remove the inline keyboard from a previously sent message (disable
  -- buttons after a tap so they can't be re-clicked). Best-effort: never
  -- throws. Default: no-op (unsupported).
  ccEditReplyMarkup :: c -> ChatMessageId -> IO ()
  ccEditReplyMarkup _ _ = pure ()

  -- | The last chat id (the platform-specific reply target). 'Nothing' if
  -- no message has been received yet. Used by the loop to determine whether
  -- inline keyboard sends are possible. Default: 'Nothing'.
  ccLastChatId :: c -> IO (Maybe Text)
  ccLastChatId _ = pure Nothing