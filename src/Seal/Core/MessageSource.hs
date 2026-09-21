-- | The authenticated-transport-derived identity of an inbound message.
--
-- The critical security property: the 'ConversationId' is **server-derived
-- from transport metadata, never read from a message body**, so a sender
-- cannot forge it to hijack another conversation's tab cursor. This is
-- enforced structurally — 'mkMessageSource' takes a 'ConversationId' (which
-- itself is smart-constructed) and never reads a conversation id from the
-- open field map. The open map is also forbidden from carrying a
-- @conversationId@ key, so a future caller cannot smuggle a second id in.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.MessageSource'
-- (the canonical home in the 'seal-gateway-types' library stanza).
module Seal.Core.MessageSource
  ( ConversationId (..)
  , mkConversationId
  , conversationIdText
  , UserId (..)
  , mkUserId
  , userIdText
  , MessageSource (..)
  , mkMessageSource
  , maxConversationIdLen
  , maxUserIdLen
  , maxOpenEntries
  , maxOpenFieldLen
  ) where

import Seal.Gateway.Types.MessageSource
