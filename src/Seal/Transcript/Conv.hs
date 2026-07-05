-- | The @conversation.jsonl@ model: one raw 'Message' per line, in order — the
-- pure content list of the session. Reading is @mapMaybe decode . lines@ →
-- @[Message]@, fed straight to the provider with zero transformation. Appending
-- a turn appends only the *new* message lines, so the file grows by deltas
-- rather than re-serializing the whole prior conversation each turn (the old
-- @transcript.jsonl@ format's O(N²) growth). No timestamps or ids live here —
-- those are derived from @entries.jsonl@ ('Seal.Transcript.Entries').
module Seal.Transcript.Conv
  ( ConvLine (..)
  , encodeConvLine
  , readConversation
  , appendMessages
  , diffNew
  ) where

import Data.Aeson (decode, encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)

import Seal.Providers.Class (Message (..))

-- | A single line of @conversation.jsonl@: a raw 'Message' (role + content
-- blocks). The on-disk form is the canonical aeson encoding of 'Message' with
-- no trailing newline; the writer appends the newline.
newtype ConvLine = ConvLine { clMessage :: Message }
  deriving stock (Eq, Show)

-- | Canonical strict encoding of one line, no trailing newline.
encodeConvLine :: ConvLine -> ByteString
encodeConvLine (ConvLine m) = BL.toStrict (encode m)

-- | Read @conversation.jsonl@ into the message list. Malformed lines are
-- skipped (a torn tail leaves at most one bad line, already tolerated here).
readConversation :: ByteString -> [Message]
readConversation bs = mapMaybe decodeLine (splitLines bs)
  where
    decodeLine l = decode (BL.fromStrict l)

-- | Split the file body into its non-empty component lines. A trailing newline
-- produces a final empty chunk that we drop; interior empty lines (which a
-- well-formed conversation file never has) are also dropped.
splitLines :: ByteString -> [ByteString]
splitLines = filter (not . BS.null) . BS.split 0x0a

-- | The minimal append: the messages from @incoming@ that are not already
-- present in @written@, taken as a suffix of the written list. The writer
-- calls this to find what to append, then writes one line per result.
--
-- Invariant (caller responsibility): @incoming@ is the full message list for
-- the turn (prior messages + new ones); @written@ is the conversation as it
-- exists on disk. The new messages are the suffix of @incoming@ beyond the
-- length of @written@, after verifying @written@ is a prefix of @incoming@.
-- If @written@ is not a prefix of @incoming@ (a divergence — should not happen
-- under the single-writer daemon), the whole @incoming@ is returned (a safe,
-- if redundant, fallback).
diffNew :: [Message] -> [Message] -> [Message]
diffNew incoming written = fromMaybe incoming (stripPrefixMessages written incoming)

-- | Append @newLines@ to @written@, returning the combined list. Kept as a
-- separate function so the writer's "diff then append" flow is one named step.
appendMessages :: [Message] -> [Message] -> [Message]
appendMessages written newLines = written <> newLines

-- | Like 'Data.List.stripPrefix' but compares 'Message's for equality. Returns
-- @Just remainder@ when @written@ is a leading prefix of @incoming@ (so the
-- remainder is the new suffix to append), or 'Nothing' on divergence.
stripPrefixMessages :: [Message] -> [Message] -> Maybe [Message]
stripPrefixMessages [] incoming              = Just incoming
stripPrefixMessages _   []                   = Nothing
stripPrefixMessages (w:ws) (i:is)
  | w == i    = stripPrefixMessages ws is
  | otherwise = Nothing