{-# LANGUAGE OverloadedStrings #-}
-- | Rendering a message's 'MessageOrigin' into the text the model reads.
--
-- @conversation.jsonl@ stores each message's origin as a structured field
-- ('Seal.Providers.Class.msgOrigin'), never inside the text: the user's words
-- stay exactly as typed on disk, which keeps search, session naming, exports,
-- and the web transcript view clean. The model, however, only ever sees role +
-- content blocks — providers have no place to put a structured sender. So the
-- turn loop renders the origin as a short tag when it builds the provider
-- request ('annotateOrigins'), applying it to the WHOLE message list so every
-- user message in the history carries its own sender, not just the current
-- one. That is what lets the model tell several senders apart in a group chat.
--
-- The tag is therefore a rendering, not data: never persist an annotated
-- message back to the transcript, and never treat the tag as a parse target
-- (a user is free to type @[telegram:123]@ themselves — the stored origin is
-- the only trusted source).
module Seal.Transcript.Origin
  ( originFromSource
  , renderOriginTag
  , annotateOrigins
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.ChannelKind (channelKindToText)
import Seal.Core.MessageSource
  ( MessageSource (..), conversationIdText, userIdText )
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), MessageOrigin (..), Role (..) )

-- | The 'MessageOrigin' of an inbound chat-channel message.
--
-- Mirrors the @erMeta@ the loop stamps into @entries.jsonl@
-- ('Seal.Agent.Loop.requestMeta') so the entry-level and message-level
-- provenance agree. 'Nothing' (no 'MessageSource') means the message did not
-- arrive over an authenticated chat channel — the web gateway and the CLI
-- bypass 'MessageSource' — and such a message carries no origin at all.
originFromSource :: MessageSource -> MessageOrigin
originFromSource ms = MessageOrigin
  { moChannel = channelKindToText (msChannelKind ms)
  , moUserId = userIdText <$> msUserId ms
  , moConversationId = Just (conversationIdText (msConversationId ms))
  }

-- | The tag a message's origin renders to: @[channel:userId]@ when the
-- channel authenticated a sender, @[channel]@ otherwise. Neither the channel
-- tag (@[a-z]+@) nor a 'UserId' (whose charset excludes brackets and spaces)
-- can break the shape, so the tag is unambiguous and single-line.
renderOriginTag :: MessageOrigin -> Text
renderOriginTag o = case moUserId o of
  Just u  -> "[" <> moChannel o <> ":" <> u <> "]"
  Nothing -> "[" <> moChannel o <> "]"

-- | Render every user message's origin into its text, leaving everything else
-- alone. Applied to the message list of a provider request only — the result
-- is what the model reads, never what the transcript stores.
--
-- Assistant messages and tool-result messages carry no origin, so they pass
-- through untouched; a user message with no origin does too. Idempotent: a
-- text block that already starts with its own tag is left as is, so an
-- accidental second pass cannot double-prefix.
annotateOrigins :: [Message] -> [Message]
annotateOrigins = map annotateOne

-- | Render one message's origin, prefixing the first text block (a message
-- may lead with non-text blocks; the tag goes on the first text so it reads
-- before the words). A user message with no text block at all — a bare tool
-- result — has nowhere to put a tag and is returned unchanged.
annotateOne :: Message -> Message
annotateOne m = case (msgRole m, msgOrigin m) of
  (User, Just o) -> case tagFirstText (renderOriginTag o) (msgContent m) of
    Nothing     -> m
    Just blocks -> m { msgContent = blocks }
  _ -> m

-- | Prefix @tag@ to the first 'CbText' block, or 'Nothing' when there is none
-- (or when that block already starts with the tag).
tagFirstText :: Text -> [ContentBlock] -> Maybe [ContentBlock]
tagFirstText tag = go
  where
    go [] = Nothing
    go (CbText t : rest)
      | tag `T.isPrefixOf` t = Just (CbText t : rest)
      | otherwise            = Just (CbText (tag <> " " <> t) : rest)
    go (b : rest) = (b :) <$> go rest
