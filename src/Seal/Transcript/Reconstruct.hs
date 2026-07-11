{-# LANGUAGE OverloadedStrings #-}
-- | Pure reconstruction from the new two-file format
-- (@conversation.jsonl@ + @entries.jsonl@) back to the old
-- 'TranscriptEntry' stream. The reconstructed entries are byte-identical to
-- what the old @transcript.jsonl@ format would have stored, modulo the
-- intentional uncapping improvement (the new format stores full messages
-- where the old format may have size-capped payloads).
--
-- A 'Request' entry @i@ is reconstructed with:
--
-- * @messages = conversation[0 .. convLen_i)@ (the prefix of conversation lines
--   in effect at that turn);
-- * the left-folded effective envelope at @i@ (model / system / tools /
--   toolChoice / maxTokens), wrapped into a 'CompletionRequest'-shaped
--   'Value';
-- * the same direction + meta as the stored entry.
--
-- A 'Response' entry is reconstructed by re-inserting the assistant content
-- blocks from @conversation.jsonl@ (the lines between the prior request's
-- @convLen@ and this response's @convLen@) into the stored response envelope.
--
-- 'EKHarness' and 'EKCompaction' events carry no envelope; they round-trip
-- their metadata + a 'Request'/'Response' direction derived from their kind
-- (a harness turn is a 'Request' from the user side; a compaction is a
-- boundary marker with 'Request' direction).
module Seal.Transcript.Reconstruct
  ( reconstruct
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Maybe (fromMaybe)

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (Message (..), ToolChoice (..))
import Seal.Transcript.Entries
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

-- | Reconstruct the old 'TranscriptEntry' stream from the two new files.
--
-- The input is the full conversation (the @conversation.jsonl@ contents decoded
-- into a @[Message]@) and the full entry stream (the @entries.jsonl@ contents
-- decoded into an @[EntryRecord]@). The output is one 'TranscriptEntry' per
-- 'EntryRecord', in order, with payloads rebuilt from the conversation prefix
-- and the effective envelope.
--
-- The first request's envelope is the initial envelope passed in (there is no
-- prior to delta against, so the first request's full envelope is the
-- baseline). Subsequent requests fold deltas on top.
reconstruct :: [Message] -> [EntryRecord] -> [TranscriptEntry]
reconstruct conv = go 0 Nothing
  where
    -- @start@ is the conversation-line index where the current turn's request
    -- messages begin (i.e. the prior response's convLen, or 0 for the first
    -- turn). @mEnv@ is the effective envelope at the most recent request (used
    -- to reconstruct response payloads, which carry the request's model).
    go :: Int -> Maybe Envelope -> [EntryRecord] -> [TranscriptEntry]
    go _ _       [] = []
    go start mEnv (e : es) =
      case erKind e of
        EKRequest ->
          let env = effectiveAt e mEnv
              end = erConvLen e
              -- erConvLen is ABSOLUTE (the total conversation length at this
              -- point), so the slice is conv[start:end], not take end (drop start).
              msgs = take (end - start) (drop start conv)
              payload = requestPayload env msgs
              entry = toEntry e Request payload
          in entry : go end (Just env) es
        EKResponse ->
          let end = erConvLen e
              msgs = take (end - start) (drop start conv)
              payload = responsePayload mEnv msgs e
              entry = toEntry e Response payload
          in entry : go end mEnv es
        EKHarness ->
          -- A harness entry (opcode invocation) adds no conversation lines
          -- (erConvLen = 0), so the conversation cursor is preserved — the
          -- next response entry must slice from the same @start@, not from 0.
          -- Resetting the cursor here would make the next response's
          -- @take end (drop 0 conv)@ return the ENTIRE conversation, which
          -- the frontend renders as one giant duplicate response row.
          let payload = harnessPayload (take (erConvLen e) (drop start conv)) e
              entry = toEntry e Request payload
          in entry : go start mEnv es
        EKCompaction ->
          let entry = toEntry e Request Null
          in entry : go (erConvLen e) mEnv es

    -- The effective envelope at a request entry. The first request has no
    -- prior envelope, so its delta is folded against a default baseline; in
    -- practice the writer always emits a full envelope on the first request,
    -- so the delta carries every field. We fall back to a sensible default
    -- only if the delta is absent (a malformed entry).
    effectiveAt :: EntryRecord -> Maybe Envelope -> Envelope
    effectiveAt e mEnv =
      let baseline = fromMaybe defaultEnv mEnv
      in case erEnvelope e of
           Nothing -> baseline
           Just d  -> applyDelta baseline d

    defaultEnv :: Envelope
    defaultEnv = Envelope (ModelId "") Nothing [] ToolAuto 0

-- | Build the old 'Request' payload: a 'CompletionRequest'-shaped JSON object
-- carrying the model, system, tools, toolChoice, maxTokens, and the message
-- prefix in effect at this turn. Mirrors the old 'ToJSON CompletionRequest'
-- encoding so a "view raw" reproduces the bytes the old format stored.
requestPayload :: Envelope -> [Message] -> Value
requestPayload env msgs = object
  [ "model"      .= envModel env
  , "system"     .= envSystem env
  , "messages"   .= msgs
  , "tools"      .= envTools env
  , "toolChoice" .= envToolChoice env
  , "maxTokens"  .= envMaxTokens env
  ]

-- | Build the old 'Response' payload: the assistant content blocks (drawn
-- from the conversation lines added since the prior turn) plus the usage /
-- stop / duration metadata stored on the entry.
responsePayload :: Maybe Envelope -> [Message] -> EntryRecord -> Value
responsePayload mEnv msgs e = object
  [ "model"    .= (envModel <$> mEnv)
  , "content"  .= concatMap msgContent msgs
  , "usage"    .= erUsage e
  , "stop"     .= erStop e
  , "durationMs" .= erDurationMs e
  ]

-- | A harness turn's payload: the conversation lines added since the prior
-- turn (the harness's input/output as messages), plus the harness name.
harnessPayload :: [Message] -> EntryRecord -> Value
harnessPayload msgs e = object
  [ "messages" .= msgs
  , "harness"  .= erHarness e
  ]

-- | Lift an 'EntryRecord' into a 'TranscriptEntry' with the given direction
-- and payload. The id, timestamp, duration, correlation, and meta are
-- carried over; the model is 'Nothing' (the dispatcher's opcode-invocation
-- entries set teModel = Nothing; the loop's provider entries set it from the
-- envelope — but the reconstructed old-format entry keeps teModel = Nothing
-- to match the existing dispatch path; the response payload carries the
-- model separately).
toEntry :: EntryRecord -> Direction -> Value -> TranscriptEntry
toEntry e dir payload = TranscriptEntry
  { teId = erId e
  , teTimestamp = erTimestamp e
  , teModel = Nothing
  , teDirection = dir
  , tePayload = payload
  , teDurationMs = erDurationMs e
  , teCorrelation = erCorrelation e
  , teMeta = erMeta e
  }