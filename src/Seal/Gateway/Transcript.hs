{-# LANGUAGE OverloadedStrings #-}
-- | Shared transcript-reading logic: read a session's on-disk transcript
-- (legacy @transcript.jsonl@ or the two-file @conversation.jsonl@ +
-- @entries.jsonl@) and convert it to the frontend's TranscriptEntry JSON
-- shape. Used by both the HTTP GET seed ('Seal.Gateway.API.handleTranscript')
-- and the WS broadcast path ('Seal.Gateway.Send' pushes new entries via the
-- broker after a turn completes). Extracted to a leaf module to avoid the
-- circular dependency between 'Seal.Gateway.API' (which imports
-- 'Seal.Gateway.Send') and 'Seal.Gateway.Send' (which needs the transcript
-- reader for broadcasting).
module Seal.Gateway.Transcript
  ( readTranscriptEntries
  , readTranscriptEntriesTimed
  , TranscriptSource (..)
  , TranscriptTimings (..)
  , renderServerTiming
  , setEncodeMs
  , firstUserMessageSnippet
  , lastUserMessageAt
  , showIso
  , reconEntryToFrontend
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import Data.Vector qualified as V
import System.Directory (doesFileExist)

import Seal.Config.Paths
  (SealPaths, sessionConversationPath, sessionEntriesPath, sessionTranscriptPath)
import Seal.Core.Types (SessionId)
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.Transcript.Reconstruct (reconstruct)
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

-- | Which on-disk source produced the entries. Surfaced in 'TranscriptTimings'
-- so the @Server-Timing@ header can name the path the request took.
data TranscriptSource
  = TSMissing      -- ^ no transcript file exists
  | TSLegacy       -- ^ legacy @transcript.jsonl@
  | TSConvEntries  -- @conversation.jsonl@ + @entries.jsonl@ (reconstructed)
  | TSConvOnly     -- @conversation.jsonl@ only (no entries sidecar)
  deriving (Eq, Show)

-- | Per-phase timings for a single 'readTranscriptEntries' call, in
-- milliseconds. Phase durations are measured with 'getCurrentTime' (wall
-- clock); for the small file sizes typical of a transcript, GHC's wall
-- clock has enough resolution. Phases are exclusive of each other EXCEPT
-- @ttTotal@, which spans the entire call. A phase that didn't run (e.g.
-- @ttReconstruct@ when the legacy path was taken) is 0.
data TranscriptTimings = TranscriptTimings
  { ttSource       :: TranscriptSource
  , ttEntryCount   :: Int           -- ^ number of frontend entries returned
  , ttFileReadMs   :: Integer       -- ^ time spent in 'TIO.readFile' (conv + entries files combined)
  , ttParseMs      :: Integer       -- ^ 'A.decode' of every line (both files combined)
  , ttReconstructMs :: Integer      -- @'reconstruct' (two-file path only)
  , ttRewriteMs    :: Integer        -- 'teLineToFrontend' / 'reconEntryToFrontend' / 'convLineToFrontend'
  , ttEncodeMs     :: Integer        -- ^ 'A.encode' of the frontend [Value] (set by 'handleTranscript', 0 for the bare reader)
  , ttTotalMs      :: Integer       -- ^ wall-clock total of the whole call
  }

-- | Format a 'TranscriptTimings' as a @Server-Timing@ header value per
-- <https://www.w3.org/TR/server-timing/>. Each phase is a separate
-- comma-separated token with a short name, a numeric @dur@ (milliseconds,
-- 3-decimal precision in the spec but we emit integers), and a @desc@
-- naming the phase. The frontend parses these via @performance.getEntriesByName@
-- or by reading the @Server-Timing@ response header directly.
--
-- Example output:
--   @tt;dur=42;desc="total", fr;dur=3;desc="file-read", pr;dur=18;desc="parse", rc;dur=12;desc="reconstruct", rw;dur=4;desc="rewrite", en;dur=8;desc="encode", src;desc="conv+entries", n;desc="127"@
renderServerTiming :: TranscriptTimings -> BC.ByteString
renderServerTiming t =
  let phase name ms desc =
        BC.pack name <> ";dur=" <> BC.pack (show ms) <> ";desc=\"" <> BC.pack desc <> "\""
      tag name desc = BC.pack name <> ";desc=\"" <> BC.pack desc <> "\""
      srcDesc = case ttSource t of
        TSMissing      -> "missing"
        TSLegacy       -> "legacy"
        TSConvEntries  -> "conv+entries"
        TSConvOnly     -> "conv-only"
      parts =
        [ phase "tt" (ttTotalMs t)       "total"
        , phase "fr" (ttFileReadMs t)    "file-read"
        , phase "pr" (ttParseMs t)        "parse"
        , phase "rc" (ttReconstructMs t) "reconstruct"
        , phase "rw" (ttRewriteMs t)      "rewrite"
        , phase "en" (ttEncodeMs t)       "encode"
        , tag  "src" srcDesc
        , tag  "n"   (show (ttEntryCount t))
        ]
  in BC.intercalate ", " parts

-- | Set the encode-phase duration + bump the total to span read+encode.
-- 'handleTranscript' uses this after timing 'A.encode' so the @en@ token
-- reflects the JSON-serialization cost (which dominates for transcripts
-- carrying large web_fetch / shell-output tool_result blocks) and @tt@
-- reflects the full read+encode cost.
setEncodeMs :: Integer -> Integer -> TranscriptTimings -> TranscriptTimings
setEncodeMs encodeMs totalMs tt = tt { ttEncodeMs = encodeMs, ttTotalMs = totalMs }

-- | 'zipWith' + 'mapMaybe': apply a partial function across two lists
-- in lockstep, dropping the elements for which the function returns
-- 'Nothing'.
zipWithMaybe :: (a -> b -> Maybe c) -> [a] -> [b] -> [c]
zipWithMaybe _ [] _ = []
zipWithMaybe _ _ [] = []
zipWithMaybe f (a : as) (b : bs) = case f a b of
  Just c  -> c : zipWithMaybe f as bs
  Nothing -> zipWithMaybe f as bs

-- | Read a session's transcript as the frontend's TranscriptEntry JSON shape.
-- Returns @[]@ for a missing/invalid session. Discards timing information;
-- see 'readTranscriptEntriesTimed' for the instrumented variant.
readTranscriptEntries
  :: SealPaths -> Text -> String -> SessionId -> IO [Value]
readTranscriptEntries paths model fallbackTs sid =
  fst <$> readTranscriptEntriesTimed paths model fallbackTs sid

-- | Instrumented variant of 'readTranscriptEntries': returns the frontend
-- values alongside per-phase wall-clock timings. Used by the @/transcript@
-- HTTP handler to emit a @Server-Timing@ header; other callers (broadcast,
-- snippet helpers) can use the plain 'readTranscriptEntries' and ignore the
-- overhead of timing capture.
readTranscriptEntriesTimed
  :: SealPaths -> Text -> String -> SessionId -> IO ([Value], TranscriptTimings)
readTranscriptEntriesTimed paths model fallbackTs sid = do
  tStart <- getCurrentTime
  let legacyPath = sessionTranscriptPath paths sid
      convPath   = sessionConversationPath paths sid
  legacyExists <- doesFileExist legacyPath
  convExists   <- doesFileExist convPath
  if legacyExists
    then do
      tFr0 <- getCurrentTime
      raw <- TIO.readFile legacyPath
      tFr1 <- getCurrentTime
      tPr0 <- getCurrentTime
      let vals = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                          (filter (not . T.null) (T.lines raw))
      tPr1 <- getCurrentTime
      tRw0 <- getCurrentTime
      let frontend = map teLineToFrontend vals
      tRw1 <- getCurrentTime
      tEnd <- getCurrentTime
      let tt = TranscriptTimings
            { ttSource        = TSLegacy
            , ttEntryCount    = length frontend
            , ttFileReadMs    = ms tFr0 tFr1
            , ttParseMs       = ms tPr0 tPr1
            , ttReconstructMs = 0
            , ttRewriteMs     = ms tRw0 tRw1
            , ttEncodeMs      = 0
            , ttTotalMs       = ms tStart tEnd
            }
      pure (frontend, tt)
    else if convExists
      then do
        tFr0 <- getCurrentTime
        raw <- TIO.readFile convPath
        tFr1 <- getCurrentTime
        tPr0 <- getCurrentTime
        let msgVals = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines raw)) :: [A.Value]
            msgs    = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines raw)) :: [Message]
        tPr1 <- getCurrentTime
        entriesExist <- doesFileExist (sessionEntriesPath paths sid)
        if entriesExist
          then do
            tFr2 <- getCurrentTime
            eraw <- TIO.readFile (sessionEntriesPath paths sid)
            tFr3 <- getCurrentTime
            tPr2 <- getCurrentTime
            let evs = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines eraw)) :: [EntryRecord]
            tPr3 <- getCurrentTime
            tRc0 <- getCurrentTime
            let reconstructed = reconstruct msgs evs
                frontend = zipWithMaybe reconEntryToFrontend [0..] reconstructed
            tRc1 <- getCurrentTime
            tEnd <- getCurrentTime
            let tt = TranscriptTimings
                  { ttSource        = TSConvEntries
                  , ttEntryCount    = length frontend
                  , ttFileReadMs    = ms tFr0 tFr1 + ms tFr2 tFr3
                  , ttParseMs       = ms tPr0 tPr1 + ms tPr2 tPr3
                  , ttReconstructMs = ms tRc0 tRc1
                  , ttRewriteMs     = 0  -- reconstruction includes rewrite
                  , ttEncodeMs      = 0
                  , ttTotalMs       = ms tStart tEnd
                  }
            pure (frontend, tt)
          else do
            tRw0 <- getCurrentTime
            let frontend = zipWith (convLineToFrontend model [] fallbackTs) [0..] msgVals
            tRw1 <- getCurrentTime
            tEnd <- getCurrentTime
            let tt = TranscriptTimings
                  { ttSource        = TSConvOnly
                  , ttEntryCount    = length frontend
                  , ttFileReadMs    = ms tFr0 tFr1
                  , ttParseMs       = ms tPr0 tPr1
                  , ttReconstructMs = 0
                  , ttRewriteMs     = ms tRw0 tRw1
                  , ttEncodeMs      = 0
                  , ttTotalMs       = ms tStart tEnd
                  }
            pure (frontend, tt)
      else do
        tEnd <- getCurrentTime
        let tt = TranscriptTimings
              { ttSource        = TSMissing
              , ttEntryCount    = 0
              , ttFileReadMs    = 0
              , ttParseMs       = 0
              , ttReconstructMs = 0
              , ttRewriteMs     = 0
              , ttEncodeMs      = 0
              , ttTotalMs       = ms tStart tEnd
              }
        pure ([], tt)
  where
    ms a b = round (realToFrac (b `diffUTCTime` a) * 1000 :: Double)

-- | Extract a short snippet of the first user message in a session's
-- transcript, for use as the default session title when the user has not
-- set an explicit description. Reads the two-file format
-- (@conversation.jsonl@) first, falling back to the legacy
-- @transcript.jsonl@. Returns 'Nothing' when the session has no transcript
-- or no user message with text content. The snippet is truncated to 80
-- characters (on a codepoint boundary) to keep the sessions list compact.
firstUserMessageSnippet :: SealPaths -> SessionId -> IO (Maybe Text)
firstUserMessageSnippet paths sid = do
  let legacyPath = sessionTranscriptPath paths sid
      convPath   = sessionConversationPath paths sid
  legacyExists <- doesFileExist legacyPath
  convExists   <- doesFileExist convPath
  if convExists
    then do
      raw <- TIO.readFile convPath
      let msgs = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                          (filter (not . T.null) (T.lines raw)) :: [Message]
      pure (snippetFromMessages msgs)
    else if legacyExists
      then do
        raw <- TIO.readFile legacyPath
        let entries = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines raw)) :: [TranscriptEntry]
        pure (snippetFromMessages (legacyRequestMessages entries))
      else pure Nothing

-- | Extract the first user message's text from a list of messages, truncated
-- to 80 characters. Tool-use and tool-result blocks are skipped (only the
-- first 'CbText' block of the first 'User' message is used).
snippetFromMessages :: [Message] -> Maybe Text
snippetFromMessages msgs =
  case filter (\m -> msgRole m == User) msgs of
    (m : _) -> case [t | CbText t <- msgContent m] of
      (t : _) -> Just (truncateSnippet 80 t)
      []      -> Nothing
    [] -> Nothing

-- | Truncate a snippet to at most @n@ characters, appending an ellipsis when
-- truncation occurs. 'T.take' is codepoint-safe for UTF-8 'Text'.
truncateSnippet :: Int -> Text -> Text
truncateSnippet n t
  | T.length t <= n = t
  | otherwise       = T.take n t <> "…"

-- | Extract the request messages from legacy @transcript.jsonl@ entries.
-- Only 'Request'-direction entries carry a payload with a @messages@ array;
-- we collect messages from every request entry (the first user message is
-- always in the first request).
legacyRequestMessages :: [TranscriptEntry] -> [Message]
legacyRequestMessages = concatMap go
  where
    go te
      | teDirection te /= Request = []
      | otherwise = case tePayload te of
          A.Object o -> case KeyMap.lookup (Key.fromText "messages") o of
            Just (A.Array arr) -> mapMaybe decodeMsg (V.toList arr)
            _ -> []
          _ -> []
    decodeMsg v = case A.fromJSON v :: A.Result Message of
      A.Success m -> Just m
      A.Error _   -> Nothing

-- | Map a legacy on-disk transcript line (Haskell TranscriptEntry JSON
-- with @te*@-prefixed fields) to the frontend's TranscriptEntry shape.
teLineToFrontend :: A.Value -> A.Value
teLineToFrontend rawLine =
  let o = case rawLine of
        A.Object m -> m
        _          -> KeyMap.empty
      k = Key.fromText
      lookupT key = case KeyMap.lookup (k key) o of
        Just (A.String t) -> Just t
        _                 -> Nothing
      -- The on-disk `payload` field is a JSON string; decode it to a Value
      -- so we can send it as a JSON object (not a string) in the wire
      -- response. Falls back to the raw string when it's not valid JSON
      -- (defensive against a malformed on-disk line).
      payloadVal = case KeyMap.lookup (k "payload") o of
        Just (A.String s) -> case A.decode (BL.fromStrict (TE.encodeUtf8 s)) of
          Just v  -> v
          Nothing -> A.String s
        other -> fromMaybe A.Null other
      -- The legacy transcript.jsonl entry's `meta` field carries the
      -- channel label (stamped by runTurn's requestMeta). Extract it so
      -- the frontend can attribute user messages to their channel on the
      -- legacy path too. Null when absent (response entries, old entries).
      mChannel = case KeyMap.lookup (k "meta") o of
        Just (A.Object mo) -> case KeyMap.lookup (k "channel") mo of
          Just (A.String ch) -> Just ch
          _                  -> Nothing
        _ -> Nothing
  in object
     [ "id"        .= lookupT "id"
     , "timestamp" .= lookupT "timestamp"
     , "direction" .= lookupT "direction"
     , "payload"   .= payloadVal
     , "harness"   .= lookupT "correlation"
     , "model"     .= lookupT "model"
     , "channel"   .= mChannel
     , "raw"       .= TE.decodeUtf8 (BL.toStrict (A.encode rawLine))
     ]

-- | Synthesize a frontend TranscriptEntry from a conversation.jsonl line
-- (@role@/@content@). User → request; Assistant → response. The
-- line index (0-based) is used as the entry id — conversation.jsonl
-- carries no per-entry id, and the line index is stable across reads of
-- the same file, so the frontend's dedup-by-id works.
convLineToFrontend :: Text -> [String] -> String -> Int -> A.Value -> A.Value
convLineToFrontend model entryTimestamps fallbackTs idx rawLine =
  let o = case rawLine of
        A.Object m -> m
        _          -> KeyMap.empty
      k = Key.fromText
      role = case KeyMap.lookup (k "role") o of
        Just (A.String t) -> t
        _                  -> "user"
      rawContent = case KeyMap.lookup (k "content") o of
        Just (A.Array arr) -> arr
        _                  -> mempty
      contentBlocks = map cbToFrontend (V.toList rawContent)
      content = A.Array (V.fromList contentBlocks)
      direction :: Text
      direction = if T.toCaseFold role == "user" then "request" else "response"
      payloadJson = if direction == "request"
        then A.object ["messages" A..= [A.object ["role" A..= ("user" :: Text), "content" A..= content]]]
        else A.object ["content" A..= content]
      entryId = T.pack (show idx)
      ts = fromMaybe fallbackTs (lookup idx (zip [0..] entryTimestamps))
    in object
       [ "id"        .= entryId
       , "timestamp" .= T.pack ts
       , "direction" .= direction
       , "payload"   .= payloadJson
       , "harness"   .= (Nothing :: Maybe Text)
       , "model"     .= model
       , "channel"   .= (Nothing :: Maybe Text)
      , "raw"       .= TE.decodeUtf8 (BL.toStrict (A.encode rawLine))
      ]

-- | Rewrite one on-disk 'ContentBlock' (GHC-Generics 'TaggedObject' shape)
-- into the Anthropic-style block the frontend parses.
cbToFrontend :: A.Value -> A.Value
cbToFrontend blk =
  let bo = case blk of
        A.Object m -> m
        _          -> KeyMap.empty
      k = Key.fromText
      tag = case KeyMap.lookup (k "tag") bo of
        Just (A.String t) -> Just t
        _                  -> Nothing
      contents = KeyMap.lookup (k "contents") bo
      lookupT key m = case KeyMap.lookup (k key) m of
        Just (A.String t) -> Just t
        _                 -> Nothing
      lookupB key m = case KeyMap.lookup (k key) m of
        Just (A.Bool b) -> Just b
        _               -> Nothing
  in case tag of
       Just "CbText" -> case contents of
         Just (A.String t) -> object ["type" .= ("text" :: Text), "text" .= t]
         _                 -> fallback
       Just "CbToolUse" -> object
         [ "type"  .= ("tool_use" :: Text)
         , "id"    .= fromMaybe "" (lookupT "id" bo)
         , "name"  .= fromMaybe "" (lookupT "name" bo)
         , "input" .= fromMaybe A.Null (KeyMap.lookup (k "input") bo)
         ]
       Just "CbToolResult" -> object
         [ "type"        .= ("tool_result" :: Text)
         , "tool_use_id" .= fromMaybe "" (lookupT "forId" bo)
         , "content"     .= toolResultPartsToFrontend (KeyMap.lookup (k "parts") bo)
         , "is_error"    .= fromMaybe False (lookupB "isError" bo)
         ]
       _ -> fallback
  where
     fallback = object ["type" .= ("text" :: Text), "text" .= TE.decodeUtf8 (BL.toStrict (A.encode blk))]

-- | Rewrite the on-disk 'parts' value into the Anthropic-style array
-- the frontend parses (@[{type:"text", text:"..."}]@). 'ToolResultPart'
-- is a @newtype TrpText Text@, so aeson's derived 'ToJSON' serializes it
-- as a bare JSON string (not a 'TaggedObject'). The on-disk 'parts' is
-- thus @["text"]@, not @[{tag:"TrpText", contents:"text"}]@. Handles both
-- the bare-string shape and the object shape (defensive fallback).
toolResultPartsToFrontend :: Maybe A.Value -> A.Value
toolResultPartsToFrontend mparts =
  case mparts of
    Just (A.Array arr) ->
      A.Array (V.fromList (map trpToFrontend (V.toList arr)))
    other -> fromMaybe A.Null other

trpToFrontend :: A.Value -> A.Value
trpToFrontend blk =
  case blk of
    A.String t -> object ["type" .= ("text" :: Text), "text" .= t]
    A.Object m ->
      let tag = case KeyMap.lookup (Key.fromString "tag") m of
            Just (A.String t) -> Just t
            _                 -> Nothing
          contents = KeyMap.lookup (Key.fromString "contents") m
      in case tag of
           Just "TrpText" -> case contents of
             Just (A.String t) -> object ["type" .= ("text" :: Text), "text" .= t]
             _                 -> object ["type" .= ("text" :: Text), "text" .= TE.decodeUtf8 (BL.toStrict (A.encode blk))]
           _ -> object ["type" .= ("text" :: Text), "text" .= TE.decodeUtf8 (BL.toStrict (A.encode blk))]
    _ -> object ["type" .= ("text" :: Text), "text" .= TE.decodeUtf8 (BL.toStrict (A.encode blk))]

-- | The set of opcode names whose 'EKHarness' entries should surface to
-- the web frontend SPA as distinct harness entries (not be dropped by
-- 'reconEntryToFrontend'). v1: @SKILL_LOAD@ so /skill load invocations
-- appear in the transcript as identifiable skill-load events (per the
-- user's "properly identified as a skill load operation" requirement).
-- Approval-bearing entries always surface regardless of this whitelist.
-- A 'Set' rather than a list to make the shared-state surface
-- discoverable (see the design doc's §8 risk 2).
userSurfacingOps :: Set.Set Text
userSurfacingOps = Set.fromList ["SKILL_LOAD"]

-- | Predicate: does a harness payload's @op.name@ fall in
-- 'userSurfacingOps'? Returns 'False' for payloads with no @op@ key, a
-- non-object @op@, or no @name@ field — those are dropped by the filter
-- (matching the pre-v1 behavior for non-approval harness entries).
isUserSurfacingOp :: KeyMap.KeyMap Value -> Bool
isUserSurfacingOp o =
  case KeyMap.lookup (Key.fromText "op") o of
    Just (Object opObj) ->
      case KeyMap.lookup (Key.fromText "name") opObj of
        Just (String n) -> n `Set.member` userSurfacingOps
        _               -> False
    _ -> False

-- | Map a reconstructed 'TranscriptEntry' (from 'reconstruct') to the
-- frontend's TranscriptEntry JSON shape.
reconEntryToFrontend :: Int -> TranscriptEntry -> Maybe A.Value
reconEntryToFrontend idx te =
  case tePayload te of
    A.Null -> Nothing
    -- Drop harness entries (opcode invocations from the dispatcher) that
    -- carry a "harness" key in the payload — UNLESS they also carry an
    -- "approval" key (which marks them as approval-evidence entries that
    -- should surface so the user sees the confirmation decision in the
    -- transcript), OR their op.name is in 'userSurfacingOps' (which marks
    -- them as user-surfacing opcode invocations like /skill load that
    -- should appear as distinct harness entries, not be folded into the
    -- surrounding user/assistant bubbles).
    A.Object o
      | KeyMap.member (Key.fromText "harness") o,
        not (KeyMap.member (Key.fromText "approval") o),
        not (isUserSurfacingOp o) -> Nothing
    payloadVal -> Just $
      let dirStr = case teDirection te of
            Request  -> "request" :: Text
            Response -> "response"
          payloadJson = rewritePayload payloadVal (teDirection te)
          entryId = let raw = teId te in if T.null raw then T.pack (show idx) else raw
          -- The originating channel label (e.g. "telegram", "web", "cli"),
          -- stamped into the request entry's erMeta by runTurn's
          -- requestMeta (and into SKILL_LOAD entries by
          -- recordSkillLoadResult). Surfaced as a top-level `channel` field
          -- so the frontend can attribute user messages — and skill loads —
          -- to the channel they came from. Null when the entry carries no
          -- channel (e.g. response entries, CLI TUI turns with no
          -- MessageSource).
          mChannel = case Map.lookup "channel" (teMeta te) of
            Just (A.String ch) -> Just ch
            _                  -> Nothing
      in object
         [ "id"        .= entryId
         , "timestamp" .= T.pack (showIso (teTimestamp te))
         , "direction" .= dirStr
         -- `payload` is a JSON OBJECT (not a string) so the frontend can
         -- access its fields directly without a second JSON.parse pass.
         -- The old format encoded payload as a JSON string
         -- (TE.decodeUtf8 (A.encode payloadJson)), which forced the browser
         -- to parse the outer JSON (un-escaping every `\"` in the payload
         -- string), then call JSON.parse(payload) AGAIN to parse the inner
         -- JSON — two full parse passes with O(n) escape processing in
         -- between. For a 279KB body this took ~889ms; as an object it's a
         -- single pass and should be <10ms.
         , "payload"   .= payloadJson
         , "harness"   .= (Nothing :: Maybe Text)
         , "model"     .= (Nothing :: Maybe Text)
         , "channel"   .= mChannel
         -- The `raw` field is deliberately EMPTY for the reconstructed
         -- (two-file) path. The pre-rewrite payload Value is the same
         -- content as `payload` (just in GHC-Generics TaggedObject shape
         -- vs the Anthropic shape the frontend parses), so shipping it
         -- would double the wire payload for no information gain. The
         -- legacy path (teLineToFrontend) still ships the verbatim
         -- on-disk line because there the `raw` view is genuinely
         -- distinct from `payload`. The frontend's "View raw JSON"
         -- modal falls back to `payload` when `raw` is empty.
         , "raw"       .= ("" :: Text)
         ]

-- | Rewrite a reconstructed payload 'Value' from GHC-Generics
-- 'TaggedObject' encoding to the Anthropic-style JSON the frontend parses.
rewritePayload :: A.Value -> Direction -> A.Value
rewritePayload val dir =
  case val of
    A.Object o ->
      let k = Key.fromText
          rewriteMsgs = case KeyMap.lookup (k "messages") o of
            Just (A.Array arr) ->
              let msgs = map rewriteMessage (V.toList arr)
              in ["messages" .= A.Array (V.fromList msgs)]
            _ -> []
          rewriteContent = case KeyMap.lookup (k "content") o of
            Just (A.Array arr) ->
              let blocks = map cbToFrontend (V.toList arr)
              in ["content" .= A.Array (V.fromList blocks)]
            _ -> []
          passthrough key = case KeyMap.lookup key o of
            Just v  -> [key .= v]
            Nothing -> []
          usageFields = case KeyMap.lookup (k "usage") o of
            Just (A.Object uo) ->
              let uIn  = case KeyMap.lookup (k "input")  uo of
                    Just n -> Just n; _ -> Nothing
                  uOut = case KeyMap.lookup (k "output") uo of
                    Just n -> Just n; _ -> Nothing
              in case (uIn, uOut) of
                   (Just _, Just _) ->
                     [ "usage" .= object
                       [ "input_tokens"  .= uIn
                       , "output_tokens" .= uOut
                       ]
                     ]
                   _ -> []
            _ -> []
          fields = case dir of
            Request ->
              passthrough (k "system")
               <> passthrough (k "model")
               -- Replace the full tool definitions with names-only. The
               -- full definitions (with input_schema, description, etc.) are
               -- the same across every request turn and can be 11KB+ each;
               -- shipping them in all 73 request entries of a 146-turn
               -- session wastes ~840KB. The frontend's "Tools" collapsed
               -- row only needs the names + count for its header, and the
               -- expanded view's JSON is the names-only array (still useful
               -- for seeing WHAT tools were available, just not the full
               -- schemas). The frontend already deduplicates tools via
               -- `seenTools` so only the first occurrence renders.
               <> toolsNamesOnly o
               <> passthrough (k "toolChoice")
               <> passthrough (k "maxTokens")
               <> passthrough (k "approval")
               <> passthrough (k "op")
               -- Harness/opcode-invocation entries (EKHarness) carry the
               -- opcode's input + result under these keys (see
               -- Seal.Transcript.Reconstruct.harnessPayload). The SKILL_LOAD
               -- result entry is a Request-direction harness entry; without
               -- passing @input@ + @result@ through, the frontend's
               -- @transcriptToMessages@ sees @op.name = "SKILL_LOAD"@ but no
               -- @result@, so the skill-load tool-call box never renders.
                <> passthrough (k "input")
                <> passthrough (k "result")
                <> passthrough (k "channel")
                <> rewriteMsgs
            Response ->
              passthrough (k "model")
               <> rewriteContent
               <> usageFields
               <> passthrough (k "stop")
               <> passthrough (k "durationMs")
      in A.object fields
    _ -> val

-- | Extract just the tool NAMES from a tools array, dropping the full
-- definitions (description, input_schema, etc.) to keep the wire payload
-- small. Returns @["tools" .= [...]]@ where each element is
-- @{"name": "<toolName>"}@ — the shape the frontend's
-- 'extractToolDefNames' parses. Returns @[]@ when the tools field is
-- absent or not an array.
toolsNamesOnly :: KeyMap.KeyMap Value -> [(Key, Value)]
toolsNamesOnly o =
  case KeyMap.lookup (Key.fromText "tools") o of
    Just (A.Array arr) ->
      let names = map toolName (V.toList arr)
      in ["tools" .= A.Array (V.fromList names)]
    _ -> []
  where
    -- Extract {name: "..."} from a tool definition Value. Handles both
    -- the Anthropic shape ({name, description, input_schema}) and the
    -- Ollama shape ({type:"function", function:{name, ...}}).
    toolName v = case v of
      A.Object td ->
        case KeyMap.lookup (Key.fromText "name") td of
          Just n -> A.object ["name" .= n]
          Nothing -> case KeyMap.lookup (Key.fromText "function") td of
            Just (A.Object fn) -> case KeyMap.lookup (Key.fromText "name") fn of
              Just n -> A.object ["name" .= n]
              Nothing -> A.object ["name" .= A.Null]
            _ -> A.object ["name" .= A.Null]
      _ -> A.object ["name" .= A.Null]

-- | Rewrite one 'Message' (@{role, content: [...]}@, strip-prefix camelCase
-- JSON) to the Anthropic-style shape (@{role, content: [...]}@) the frontend
-- parses, with content blocks rewritten by 'cbToFrontend'. The role is
-- lowercased because GHC-Generics encodes 'User'/'Assistant' as
-- @"User"@/@"Assistant"@ but the frontend checks @msg.role === "user"@.
rewriteMessage :: A.Value -> A.Value
rewriteMessage msg =
  case msg of
    A.Object mo ->
      let k = Key.fromText
          role = case KeyMap.lookup (k "role") mo of
            Just (A.String t) -> T.toLower t
            _                 -> "user" :: Text
          rawContent = case KeyMap.lookup (k "content") mo of
            Just (A.Array arr) -> arr
            _                  -> mempty
          blocks = map cbToFrontend (V.toList rawContent)
      in A.object
         [ "role"    .= role
         , "content" .= A.Array (V.fromList blocks)
         ]
    _ -> msg

-- | ISO-8601 with milliseconds + Z (the frontend's expected timestamp shape).
showIso :: UTCTime -> String
showIso = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ"

-- | The ISO timestamp of the most recent @request@-direction entry in a
-- session's transcript (the last time the USER sent a message), or 'Nothing'
-- when the session has no transcript or no user message. Used by the sidebar
-- to sort tabs by last-user-message time (oldest first within each status
-- bucket). Reads the same transcript paths as 'firstUserMessageSnippet';
-- returns the timestamp as an ISO string (matching the frontend's
-- TranscriptEntry.timestamp shape).
lastUserMessageAt :: SealPaths -> SessionId -> IO (Maybe Text)
lastUserMessageAt paths sid = do
  -- model + fallbackTs are only used for synthesized conversation.jsonl
  -- entries that lack an entries.jsonl sidecar; the empty model + a
  -- neutral fallback keep that path consistent without affecting the
  -- entries.jsonl path (which carries real timestamps).
  entries <- readTranscriptEntries paths "" "" sid
  pure (lastRequestTimestamp entries)
  where
    -- Walk the frontend-shaped entries in reverse, return the first
    -- (i.e. most recent) @request@-direction entry's timestamp.
    lastRequestTimestamp :: [A.Value] -> Maybe Text
    lastRequestTimestamp vals =
      case reverse vals of
        [] -> Nothing
        xs -> go xs
      where
        k = Key.fromText
        isBlank (A.String t) = T.null t
        isBlank _ = True
        go [] = Nothing
        go (v : rest) =
          case v of
            A.Object o ->
              case ( KeyMap.lookup (k "direction") o
                   , KeyMap.lookup (k "timestamp") o ) of
                (Just (A.String d), Just (A.String t))
                  | d == "request" && not (isBlank (A.String t)) -> Just t
                _ -> go rest
            _ -> go rest