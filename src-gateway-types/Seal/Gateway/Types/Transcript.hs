{-# LANGUAGE DeriveGeneric #-}
-- | The append-only audit-entry model. Integrity comes from the append-only
-- handle plus keeping untrusted actions off the box that holds the log — not
-- from a hash chain. 'encodeEntryRaw' guarantees the on-disk JSONL line is the
-- canonical encoding, so a future "view raw" hides nothing.
--
-- Canonical home; 'Seal.Transcript.Types' in the server re-exports from
-- here.
module Seal.Gateway.Types.Transcript
  ( Direction (..)
  , TranscriptEntry (..)
  , encodeEntryRaw
  ) where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Seal.Gateway.Types.Core (ModelId)
import Seal.Gateway.Types.AesonUtils (stripPrefixToJSON, stripPrefixParseJSON)

data Direction = Request | Response
  deriving stock (Eq, Show, Generic)

instance ToJSON Direction where toJSON = stripPrefixToJSON
instance FromJSON Direction where parseJSON = stripPrefixParseJSON

-- | JSON keys (via 'stripPrefixToJSON'): @teId@→@id@, @teTimestamp@→@timestamp@,
-- @teModel@→@model@, @teDirection@→@direction@, @tePayload@→@payload@,
-- @teDurationMs@→@durationMs@, @teCorrelation@→@correlation@,
-- @teConvLen@→@convLen@, @teMeta@→@meta@.
data TranscriptEntry = TranscriptEntry
  { teId :: Text
  , teTimestamp :: UTCTime
  , teModel :: Maybe ModelId
  , teDirection :: Direction
  , tePayload :: Value
  , teDurationMs :: Maybe Int
  , teCorrelation :: Maybe Text
  -- | The conversation length AFTER this entry's messages — the branch
  -- anchor. The web frontend uses it to say "branch here", and the
  -- gateway uses it to copy that many @conversation.jsonl@ lines into a
  -- branched session.
  --
  -- 'Nothing' means "no anchor": either a legacy on-disk line that
  -- predates this field, or a row we cannot place in the conversation
  -- (the legacy @transcript.jsonl@ renderer). Callers must treat
  -- 'Nothing' as "branching is not offered here" rather than guessing a
  -- position.
  --
  -- Deliberately 'Maybe' rather than a required 'Int': this type is
  -- decoded from JSON on the legacy title-snippet path, so a required
  -- field would fail to parse every pre-existing line.
  , teConvLen :: !(Maybe Int)
  , teMeta :: Map Text Value
  } deriving stock (Eq, Show, Generic)

instance ToJSON TranscriptEntry where toJSON = stripPrefixToJSON
instance FromJSON TranscriptEntry where parseJSON = stripPrefixParseJSON

-- | One JSONL line: the canonical aeson encoding, strict, no trailing newline.
-- The daemon appends the newline when writing.
encodeEntryRaw :: TranscriptEntry -> ByteString
encodeEntryRaw = BL.toStrict . A.encode
