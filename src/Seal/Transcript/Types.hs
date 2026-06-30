-- | The append-only audit-entry model. Integrity comes from the append-only
-- handle plus keeping untrusted actions off the box that holds the log — not
-- from a hash chain. 'encodeEntryRaw' guarantees the on-disk JSONL line is the
-- canonical encoding, so a future "view raw" hides nothing.
module Seal.Transcript.Types
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

import Seal.Core.Types (ModelId)

data Direction = Request | Response
  deriving stock (Eq, Show, Generic)

instance ToJSON Direction
instance FromJSON Direction

data TranscriptEntry = TranscriptEntry
  { teId :: Text
  , teTimestamp :: UTCTime
  , teModel :: Maybe ModelId
  , teDirection :: Direction
  , tePayload :: Value
  , teDurationMs :: Maybe Int
  , teCorrelation :: Maybe Text
  , teMeta :: Map Text Value
  } deriving stock (Eq, Show, Generic)

instance ToJSON TranscriptEntry
instance FromJSON TranscriptEntry

-- | One JSONL line: the canonical aeson encoding, strict, no trailing newline.
-- The daemon appends the newline when writing.
encodeEntryRaw :: TranscriptEntry -> ByteString
encodeEntryRaw = BL.toStrict . A.encode
