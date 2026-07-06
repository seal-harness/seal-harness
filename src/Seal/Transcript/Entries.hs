{-# LANGUAGE OverloadedStrings #-}
-- | The @entries.jsonl@ model: one line per event, 1:1 with the old
-- 'TranscriptEntry' stream but payload-free. The giant 'tePayload' is replaced
-- by a @convLen@ prefix pointer (into @conversation.jsonl@) plus, for 'Request'
-- events, an envelope-delta recorded only when changed from the prior request
-- (omit-if-unchanged). 'Response' events store all 'CompletionResponse' fields
-- /except/ the content blocks (those live in @conversation.jsonl@ and are
-- re-inserted on reconstruction). 'Harness' and 'compaction' events keep their
-- metadata columns and a @convLen@.
--
-- Integrity, like the conversation file, rests on the append-only single-writer
-- + fsync — not a hash chain.
module Seal.Transcript.Entries
  ( EntryKind (..)
  , Envelope (..)
  , EnvelopeDelta (..)
  , EntryRecord (..)
  , emptyEnvelopeDelta
  , applyDelta
  , effectiveEnvelope
  , encodeEntryRecordRaw
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=), (.!=) )
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (withText)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Seal.Core.Types (ModelId)
import Seal.Providers.Class (StopReason, ToolChoice (..), ToolDefinition (..), Usage (..))

-- | Event discriminator. Mirrors the old 'Direction' plus the two call-less
-- kinds ('EKHarness', 'EKCompaction').
data EntryKind
  = EKRequest
  | EKResponse
  | EKHarness
  | EKCompaction
  deriving stock (Eq, Show, Generic)

instance ToJSON EntryKind where
  toJSON EKRequest    = "request"
  toJSON EKResponse   = "response"
  toJSON EKHarness    = "harness"
  toJSON EKCompaction = "compaction"

instance FromJSON EntryKind where
  parseJSON = withText "EntryKind" $ \t ->
    case t of
      "request"    -> pure EKRequest
      "response"   -> pure EKResponse
      "harness"    -> pure EKHarness
      "compaction" -> pure EKCompaction
      _            -> fail ("unknown EntryKind: " <> T.unpack t)

-- | The full envelope in effect at a given turn. Folded from deltas.
data Envelope = Envelope
  { envModel      :: ModelId
  , envSystem     :: Maybe Text
  , envTools      :: [ToolDefinition]
  , envToolChoice :: ToolChoice
  , envMaxTokens  :: Int
  } deriving stock (Eq, Show)

-- | A per-request change to the envelope. Each field is 'Maybe'; 'Nothing'
-- means \"inherit from the prior request\" (omit-if-unchanged). For
-- 'envSystem' the 'Maybe' is nested: 'Nothing' = inherit, @'Just' 'Nothing'@ =
-- clear the system prompt, @'Just' ('Just' t)@ = set it to @t@.
data EnvelopeDelta = EnvelopeDelta
  { edModel      :: Maybe ModelId
  , edSystem     :: Maybe (Maybe Text)
  , edTools      :: Maybe [ToolDefinition]
  , edToolChoice :: Maybe ToolChoice
  , edMaxTokens  :: Maybe Int
  } deriving stock (Eq, Show)

-- | The neutral delta: inherit everything. The writer compares the current
-- request's envelope against the prior effective envelope and emits a delta
-- with 'Just' only on the fields that differ.
emptyEnvelopeDelta :: EnvelopeDelta
emptyEnvelopeDelta = EnvelopeDelta Nothing Nothing Nothing Nothing Nothing

instance ToJSON EnvelopeDelta where
  toJSON d = object (catMaybes'
    [ ("model" .=)      <$> edModel d
    , ("tools" .=)      <$> edTools d
    , ("toolChoice" .=) <$> edToolChoice d
    , ("maxTokens" .=)  <$> edMaxTokens d
    ] <> systemField)
    where
      -- The nested Maybe on system distinguishes inherit (omit the key) from
      -- clear ("system": null) from set ("system": "text"). Omitting the key
      -- is the default aeson behavior for the outer Nothing; the inner cases
      -- are encoded explicitly so a clear is distinguishable from an inherit.
      systemField = case edSystem d of
        Nothing       -> []
        Just Nothing  -> ["system" .= A.Null]
        Just (Just t) -> ["system" .= t]

instance FromJSON EnvelopeDelta where
  parseJSON = withObject "EnvelopeDelta" $ \o -> do
    -- The nested Maybe on system distinguishes inherit (key absent) from clear
    -- (key present, value null) from set (key present, value string). aeson's
    -- '.:?' conflates absent and null, so we use 'KeyMap.lookup' to detect
    -- presence, then decode the value when present.
    let mSystem = case KeyMap.lookup (Key.fromString "system") o of
          Nothing -> Nothing                         -- inherit
          Just v  -> Just (case v of
            A.Null     -> Nothing                     -- clear
            A.String t -> Just t                      -- set
            _          -> Nothing)                    -- malformed: treat as clear
    EnvelopeDelta
      <$> o .:? "model"
      <*> pure mSystem
      <*> o .:? "tools"
      <*> o .:? "toolChoice"
      <*> o .:? "maxTokens"

-- | Apply a delta to an envelope, producing the next effective envelope.
-- 'Nothing' fields inherit; the nested 'Maybe' on system distinguishes
-- inherit from clear.
applyDelta :: Envelope -> EnvelopeDelta -> Envelope
applyDelta env d = Envelope
  { envModel      = fromMaybe (envModel env) (edModel d)
  , envSystem     = case edSystem d of
      Nothing     -> envSystem env
      Just system -> system
  , envTools      = fromMaybe (envTools env) (edTools d)
  , envToolChoice = fromMaybe (envToolChoice env) (edToolChoice d)
  , envMaxTokens  = fromMaybe (envMaxTokens env) (edMaxTokens d)
  }

-- | Left-fold over the entry stream, returning the effective envelope at each
-- 'EKRequest' entry. Non-request entries inherit the prior envelope (so a
-- 'Response' knows the envelope in effect for its paired request). The fold
-- starts from the given initial envelope (typically the first request's full
-- envelope, since there is no prior to delta against).
--
-- Returns the pairs @(entry, effective-envelope-at-entry)@ in input order.
effectiveEnvelope :: Envelope -> [EntryRecord] -> [(EntryRecord, Envelope)]
effectiveEnvelope = go
  where
    go _ [] = []
    go env (e : es) =
      let env' = case erKind e of
            EKRequest -> case erEnvelope e of
              Nothing -> env
              Just d  -> applyDelta env d
            _ -> env
      in (e, env') : go env' es

-- | One event line. Fields are kind-specific; the 'Maybe' columns are present
-- only for the kinds that use them (e.g. 'erEnvelope' is 'Just' only for
-- 'EKRequest', 'erUsage' only for 'EKResponse'). The on-disk encoding omits
-- 'Nothing' fields (aeson's @omitIfNothing@ would do this; we encode manually to
-- keep the shape explicit and stable for reconstruction).
data EntryRecord = EntryRecord
  { erId          :: Text
  , erTimestamp   :: UTCTime
  , erKind        :: EntryKind
  , erConvLen     :: Int
  -- | 'EKRequest' only: the envelope delta vs the prior request. 'Nothing' on
  -- non-request kinds.
  , erEnvelope    :: Maybe EnvelopeDelta
  -- | 'EKResponse' only: token usage.
  , erUsage       :: Maybe Usage
  -- | 'EKResponse' only: stop reason.
  , erStop        :: Maybe StopReason
  -- | 'EKResponse' / 'EKHarness' only: wall-clock duration in ms.
  , erDurationMs  :: Maybe Int
  -- | 'EKHarness' only: the harness name.
  , erHarness     :: Maybe Text
  -- | Common: correlation id linking a request to its response.
  , erCorrelation :: Maybe Text
  -- | Common: extensible metadata (e.g. @op@ for opcode invocations).
  , erMeta        :: Map Text A.Value
  } deriving stock (Eq, Show)

instance ToJSON EntryRecord where
  toJSON e = object $
    [ "id"          .= erId e
    , "ts"          .= erTimestamp e
    , "kind"        .= erKind e
    , "convLen"     .= erConvLen e
    ] <> envelopeField <> responseFields <> harnessField <> commonFields
    where
      envelopeField   = maybe [] (\d -> ["envelope" .= d]) (erEnvelope e)
      responseFields  = case erKind e of
        EKResponse -> catMaybes'
          [ ("usage" .=)      <$> erUsage e
          , ("stop" .=)       <$> erStop e
          , ("durationMs" .=) <$> erDurationMs e
          ]
        _ -> []
      harnessField    = maybe [] (\h -> ["harness" .= h]) (erHarness e)
      commonFields    =
        catMaybes'
          [ ("correlation" .=) <$> erCorrelation e
          ] <> ["meta" .= erMeta e | not (null (erMeta e))]

instance FromJSON EntryRecord where
  parseJSON = withObject "EntryRecord" $ \o -> do
    kind <- o .: "kind"
    EntryRecord
      <$> o .:  "id"
      <*> o .:  "ts"
      <*> pure kind
      <*> o .:  "convLen"
      <*> o .:? "envelope"
      <*> o .:? "usage"
      <*> o .:? "stop"
      <*> o .:? "durationMs"
      <*> o .:? "harness"
      <*> o .:? "correlation"
      <*> o .:? "meta" .!= mempty

-- | Canonical strict encoding of one entry line, no trailing newline. The
-- writer appends the newline.
encodeEntryRecordRaw :: EntryRecord -> ByteString
encodeEntryRecordRaw = BL.toStrict . A.encode

-- | A small 'catMaybes' for key-value pairs that keeps the code warning-clean
-- under @-Wincomplete-record-updates@.
catMaybes' :: [Maybe (a, b)] -> [(a, b)]
catMaybes' = foldr (\mx acc -> maybe acc (: acc) mx) []