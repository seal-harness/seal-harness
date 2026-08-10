{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Channel metadata attached to log entries via 'withChannelContext'.
-- Carries the channel kind (typed 'ChannelKind' enum, not a magic string),
-- a SHA-256 hash of the conversation id (first 12 hex chars — PII defense:
-- phone numbers and chat ids are never logged in full to the operator
-- console), and the session id (timestamp-derived, not PII).
--
-- The context is 'Maybe'-heavy so partial states (a reader thread with no
-- session yet, a slash command before the turn starts) can still log with
-- whatever metadata is available.
module Seal.Logging.ChannelContext
  ( ChannelContext (..)
  , ctxFromMessageSource
  , ctxFromSession
  , hashConversationId
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics (Generic)

import Katip (LogItem (..), ToObject (..), PayloadSelection (..))

import Seal.Core.ChannelKind (ChannelKind (..), channelKindToText, channelKindFromText)
import Seal.Core.MessageSource (MessageSource (..), conversationIdText)
import Seal.Core.Types (sessionIdText)
import Seal.Security.Crypto (sha256Hash)
import Seal.Session.Meta (SessionMeta (..))

-- | Structured channel metadata for log entries. Attached to a 'SealLogger'
-- via 'withChannelContext' at the start of each turn.
data ChannelContext = ChannelContext
  { ccChannelKind         :: Maybe ChannelKind
    -- ^ The typed channel enum ('Telegram', 'Signal', 'Web', 'Cli', etc.).
    -- Serialized via 'channelKindToText' in the 'ToJSON' instance.
  , ccConversationIdHash  :: Maybe Text
    -- ^ SHA-256 hash (first 12 hex chars) of the conversation id. PII
    -- defense: phone numbers (Signal) and chat ids (Telegram) are never
    -- logged in full to the operator console. The full conversation id is
    -- available only in the per-session @seal.log@.
  , ccSessionId           :: Maybe Text
    -- ^ The session id (timestamp-derived, not PII). Logged in full so the
    -- operator can correlate log lines to sessions.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ChannelContext where
  toJSON ctx = object
    [ "channelKind"        .= fmap channelKindToText (ccChannelKind ctx)
    , "conversationIdHash" .= ccConversationIdHash ctx
    , "sessionId"          .= ccSessionId ctx
    ]

instance ToObject ChannelContext

instance LogItem ChannelContext where
  payloadKeys _ _ = AllKeys

-- | Build a 'ChannelContext' from a 'MessageSource' (if available) and an
-- optional 'SessionMeta'. The conversation id is hashed (never logged in
-- full). Used by inbox channels (Telegram, Signal) which have a
-- 'MessageSource'.
ctxFromMessageSource :: Maybe MessageSource -> Maybe SessionMeta -> ChannelContext
ctxFromMessageSource mSrc mMeta =
  ChannelContext
    { ccChannelKind        = fmap msChannelKind mSrc
    , ccConversationIdHash = fmap (hashConversationId . conversationIdText . msConversationId) mSrc
    , ccSessionId          = fmap (sessionIdText . smId) mMeta
    }

-- | Build a 'ChannelContext' from a 'SessionMeta' alone (no 'MessageSource').
-- Used by the CLI and web paths which don't have a 'MessageSource' with
-- channel kind. The channel kind is derived from 'smChannel' if it
-- matches a known 'ChannelKind'.
ctxFromSession :: SessionMeta -> ChannelContext
ctxFromSession meta =
  ChannelContext
    { ccChannelKind        = channelKindFromText (smChannel meta)
    , ccConversationIdHash = Nothing
    , ccSessionId          = Just (sessionIdText (smId meta))
    }

-- | Hash a conversation id to its first 12 hex chars (SHA-256). This is
-- the PII defense: the operator log carries the hash, not the full id.
-- The hash is sufficient for correlation (matching log lines to a
-- conversation) without exposing phone numbers or chat ids.
hashConversationId :: Text -> Text
hashConversationId cid =
  T.take 12 (T.pack (show (sha256Hash (TE.encodeUtf8 cid))))