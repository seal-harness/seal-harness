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
  , showIso
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.Vector qualified as V
import System.Directory (doesFileExist)

import Seal.Config.Paths
  (SealPaths, sessionConversationPath, sessionEntriesPath, sessionTranscriptPath)
import Seal.Core.Types (SessionId)
import Seal.Providers.Class (Message)
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.Transcript.Reconstruct (reconstruct)
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

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
-- Returns @[]@ for a missing/invalid session.
readTranscriptEntries
  :: SealPaths -> Text -> String -> SessionId -> IO [Value]
readTranscriptEntries paths model fallbackTs sid = do
  let legacyPath = sessionTranscriptPath paths sid
      convPath   = sessionConversationPath paths sid
  legacyExists <- doesFileExist legacyPath
  convExists   <- doesFileExist convPath
  if legacyExists
    then do
      raw <- TIO.readFile legacyPath
      let vals = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                          (filter (not . T.null) (T.lines raw))
      pure (map teLineToFrontend vals)
    else if convExists
      then do
        raw <- TIO.readFile convPath
        let msgVals = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines raw)) :: [A.Value]
            msgs    = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines raw)) :: [Message]
        entriesExist <- doesFileExist (sessionEntriesPath paths sid)
        if entriesExist
          then do
            eraw <- TIO.readFile (sessionEntriesPath paths sid)
            let evs = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                               (filter (not . T.null) (T.lines eraw)) :: [EntryRecord]
                reconstructed = reconstruct msgs evs
                frontend = zipWithMaybe reconEntryToFrontend [0..] reconstructed
            pure frontend
          else do
            pure (zipWith (convLineToFrontend model [] fallbackTs) [0..] msgVals)
      else pure []

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
      payloadStr = maybe mempty A.encode (KeyMap.lookup (k "tePayload") o)
  in object
     [ "id"        .= lookupT "teId"
     , "timestamp" .= lookupT "teTimestamp"
     , "direction" .= lookupT "teDirection"
     , "payload"   .= TE.decodeUtf8 (BL.toStrict payloadStr)
     , "harness"   .= lookupT "teCorrelation"
     , "model"     .= lookupT "teModel"
     , "raw"       .= TE.decodeUtf8 (BL.toStrict (A.encode rawLine))
     ]

-- | Synthesize a frontend TranscriptEntry from a conversation.jsonl line
-- (@msgRole@/@msgContent@). User → request; Assistant → response. The
-- line index (0-based) is used as the entry id — conversation.jsonl
-- carries no per-entry id, and the line index is stable across reads of
-- the same file, so the frontend's dedup-by-id works.
convLineToFrontend :: Text -> [String] -> String -> Int -> A.Value -> A.Value
convLineToFrontend model entryTimestamps fallbackTs idx rawLine =
  let o = case rawLine of
        A.Object m -> m
        _          -> KeyMap.empty
      k = Key.fromText
      role = case KeyMap.lookup (k "msgRole") o of
        Just (A.String t) -> t
        _                  -> "user"
      rawContent = case KeyMap.lookup (k "msgContent") o of
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
     , "payload"   .= TE.decodeUtf8 (BL.toStrict (A.encode payloadJson))
     , "harness"   .= (Nothing :: Maybe Text)
     , "model"     .= model
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
         , "id"    .= fromMaybe "" (lookupT "cbId" bo)
         , "name"  .= fromMaybe "" (lookupT "cbName" bo)
         , "input" .= fromMaybe A.Null (KeyMap.lookup (k "cbInput") bo)
         ]
       Just "CbToolResult" -> object
         [ "type"        .= ("tool_result" :: Text)
         , "tool_use_id" .= fromMaybe "" (lookupT "cbForId" bo)
         , "content"     .= toolResultPartsToFrontend (KeyMap.lookup (k "cbParts") bo)
         , "is_error"    .= fromMaybe False (lookupB "cbIsError" bo)
         ]
       _ -> fallback
  where
     fallback = object ["type" .= ("text" :: Text), "text" .= TE.decodeUtf8 (BL.toStrict (A.encode blk))]

-- | Rewrite the on-disk 'cbParts' value into the Anthropic-style array
-- the frontend parses (@[{type:"text", text:"..."}]@). 'ToolResultPart'
-- is a @newtype TrpText Text@, so aeson's derived 'ToJSON' serializes it
-- as a bare JSON string (not a 'TaggedObject'). The on-disk 'cbParts' is
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

-- | Map a reconstructed 'TranscriptEntry' (from 'reconstruct') to the
-- frontend's TranscriptEntry JSON shape.
reconEntryToFrontend :: Int -> TranscriptEntry -> Maybe A.Value
reconEntryToFrontend idx te =
  case tePayload te of
    A.Null -> Nothing
    A.Object o | KeyMap.member (Key.fromText "harness") o -> Nothing
    payloadVal -> Just $
      let dirStr = case teDirection te of
            Request  -> "request" :: Text
            Response -> "response"
          payloadJson = rewritePayload payloadVal (teDirection te)
          entryId = let raw = teId te in if T.null raw then T.pack (show idx) else raw
      in object
         [ "id"        .= entryId
         , "timestamp" .= T.pack (showIso (teTimestamp te))
         , "direction" .= dirStr
         , "payload"   .= TE.decodeUtf8 (BL.toStrict (A.encode payloadJson))
         , "harness"   .= (Nothing :: Maybe Text)
         , "model"     .= (Nothing :: Maybe Text)
         , "raw"       .= TE.decodeUtf8 (BL.toStrict (A.encode payloadVal))
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
              let uIn  = case KeyMap.lookup (k "uInput")  uo of
                    Just n -> Just n; _ -> Nothing
                  uOut = case KeyMap.lookup (k "uOutput") uo of
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
              <> passthrough (k "tools")
              <> passthrough (k "toolChoice")
              <> passthrough (k "maxTokens")
              <> rewriteMsgs
            Response ->
              passthrough (k "model")
              <> rewriteContent
              <> usageFields
              <> passthrough (k "stop")
              <> passthrough (k "durationMs")
      in A.object fields
    _ -> val

-- | Rewrite one GHC-Generics 'Message' (@{msgRole, msgContent: [...]}@)
-- to the Anthropic-style shape (@{role, content: [...]}@) the frontend
-- parses, with content blocks rewritten by 'cbToFrontend'. The role is
-- lowercased because GHC-Generics encodes 'User'/'Assistant' as
-- @"User"@/@"Assistant"@ but the frontend checks @msg.role === "user"@.
rewriteMessage :: A.Value -> A.Value
rewriteMessage msg =
  case msg of
    A.Object mo ->
      let k = Key.fromText
          role = case KeyMap.lookup (k "msgRole") mo of
            Just (A.String t) -> T.toLower t
            _                 -> "user" :: Text
          rawContent = case KeyMap.lookup (k "msgContent") mo of
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