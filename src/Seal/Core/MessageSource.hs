{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The authenticated-transport-derived identity of an inbound message.
--
-- The critical security property: the 'ConversationId' is **server-derived
-- from transport metadata, never read from a message body**, so a sender
-- cannot forge it to hijack another conversation's tab cursor. This is
-- enforced structurally — 'mkMessageSource' takes a 'ConversationId' (which
-- itself is smart-constructed) and never reads a conversation id from the
-- open field map. The open map is also forbidden from carrying a
-- @conversationId@ key, so a future caller cannot smuggle a second id in.
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

import Data.Aeson (FromJSON, ToJSON)
import Data.Char (isControl)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Seal.Core.ChannelKind (ChannelKind)

-- ---------------------------------------------------------------------------
-- Bounds (exported for tests + callers that need to pre-validate)
-- ---------------------------------------------------------------------------

-- | Maximum length of a 'ConversationId' or 'UserId' (in characters).
maxConversationIdLen :: Int
maxConversationIdLen = 256

maxUserIdLen :: Int
maxUserIdLen = 256

-- | Maximum number of entries in the open metadata map. Bounds the
-- attacker-controlled metadata size so a malicious sender cannot bloat the
-- transcript or exhaust a cursor map.
maxOpenEntries :: Int
maxOpenEntries = 32

-- | Maximum length of any single open-map key or value (in characters).
maxOpenFieldLen :: Int
maxOpenFieldLen = 256

-- ---------------------------------------------------------------------------
-- ConversationId
-- ---------------------------------------------------------------------------

-- | A server-derived, transport-scoped conversation key. NEVER read from a
-- message body — always minted from authenticated transport metadata (e.g.
-- the Signal peer's phone number + UUID, the web session's authenticated
-- principal). Smart-constructed; the predicate bounds length and charset so
-- an attacker cannot bloat the transcript or exhaust a cursor map.
newtype ConversationId = ConversationId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | Charset: @A-Za-z0-9_-:@. Colon is included for composite keys like
-- @phone:uuid@. Leading dot is rejected (path-join defense-in-depth, even
-- though conversation ids are never path-joined today).
mkConversationId :: Text -> Either Text ConversationId
mkConversationId t
  | T.null t              = Left "conversation id is empty"
  | T.length t > maxConversationIdLen
                          = Left ("conversation id too long (>" <> T.pack (show maxConversationIdLen) <> ")")
  | T.head t == '.'       = Left "conversation id must not start with '.'"
  | not (T.all validConvChar t)
                          = Left "conversation id has invalid characters"
  | otherwise             = Right (ConversationId t)

validConvChar :: Char -> Bool
validConvChar c =
  c `Set.member` convChars
  where
    convChars :: Set Char
    convChars = Set.fromList
      $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-:+"

conversationIdText :: ConversationId -> Text
conversationIdText (ConversationId t) = t

-- ---------------------------------------------------------------------------
-- UserId
-- ---------------------------------------------------------------------------

-- | An authenticated user identity on a channel (e.g. a Signal phone number
-- or UUID, a Telegram user id, a web principal). Optional — some channels
-- (Background) have no user. Smart-constructed with the same predicate shape
-- as 'ConversationId', plus @+@ (common in E.164 phone numbers). No
-- leading-dot rule (user ids are transport-minted, never path-joined).
newtype UserId = UserId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

mkUserId :: Text -> Either Text UserId
mkUserId t
  | T.null t              = Left "user id is empty"
  | T.length t > maxUserIdLen
                          = Left ("user id too long (>" <> T.pack (show maxUserIdLen) <> ")")
  | not (T.all validUserChar t)
                          = Left "user id has invalid characters"
  | otherwise             = Right (UserId t)

validUserChar :: Char -> Bool
validUserChar c = c `Set.member` userChars
  where
    userChars :: Set Char
    userChars = Set.fromList
      $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_+-:"

userIdText :: UserId -> Text
userIdText (UserId t) = t

-- ---------------------------------------------------------------------------
-- MessageSource
-- ---------------------------------------------------------------------------

-- | The authenticated-transport-derived identity of an inbound message.
-- Constructed ONLY via 'mkMessageSource', which strips control characters
-- and bounds the length of every attacker-controlled string leaf.
data MessageSource = MessageSource
  { msConversationId :: ConversationId   -- ^ required; server-derived
  , msChannelKind    :: ChannelKind
  , msUserId         :: Maybe UserId     -- ^ optional; absent on Background
  , msOpen           :: Map Text Text    -- ^ bounded, control-char-stripped
  } deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Smart constructor. Strips control characters from every open-map key and
-- value, rejects any key or value over 'maxOpenFieldLen', rejects more than
-- 'maxOpenEntries' entries, and rejects a @conversationId@ key in the open
-- map (it is a structural field, not an open one — preventing a caller from
-- smuggling a second conversation id).
mkMessageSource
  :: ConversationId
  -> ChannelKind
  -> Maybe UserId
  -> Map Text Text
  -> Either Text MessageSource
mkMessageSource cid kind mUid open0
  | Map.size open0 > maxOpenEntries
      = Left ("open metadata map has too many entries (>" <> T.pack (show maxOpenEntries) <> ")")
  | Map.member "conversationId" open0
      = Left "open field key 'conversationId' is reserved"
  | otherwise =
      let open1 = Map.mapKeys stripControl open0
          open2 = Map.map stripControl open1
      in if anyTooLong open2
           then Left ("open field key/value too long (>" <> T.pack (show maxOpenFieldLen) <> ")")
           else Right MessageSource
                  { msConversationId = cid
                  , msChannelKind    = kind
                  , msUserId         = mUid
                  , msOpen           = open2
                  }
  where
    anyTooLong m = any (\(k,v) -> T.length k > maxOpenFieldLen || T.length v > maxOpenFieldLen)
                       (Map.toList m)

-- | Strip control characters from a Text leaf.
stripControl :: Text -> Text
stripControl = T.filter (not . isControl)