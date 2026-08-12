{-# LANGUAGE OverloadedStrings #-}
-- | Ollama provider (local host or Ollama Cloud). One provider; local vs cloud
-- is the configured base URL plus whether an API key is present. JSON mapping is
-- pure ('encodeRequest' / 'decodeResponse'); 'complete' adds the HTTP round-trip
-- and supplies the optional bearer key via the CPS 'withApiKey' accessor so the
-- key bytes only ever live on the request header inside the continuation.
-- Non-streaming. Ollama tool-calls carry no id, so ids are synthesized on decode
-- ("call_<i>") and dropped on encode (Ollama matches tool results by order).
module Seal.Providers.Ollama
  ( Ollama (..)
  , mkOllama
  , defaultOllamaBaseUrl
  , ollamaNeedsKey
  , chatUrl
  , tagsUrl
  , ollamaHeaders
  , ollamaErrorText
  , unreachableMsg
  , ollamaHttpExceptionMsg
  , encodeRequest
  , encodeStreamRequest
  , decodeResponse
  , decodeStreamChunk
  , StreamChunkState (..)
  , initialStreamChunkState
  , countToolCalls
  , claimToolCallIds
  ) where

import Control.Exception (try)
import Control.Monad (void, unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Vector qualified as V
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Header (RequestHeaders)

import Seal.Core.Types (ModelId (..), OpName (..), ToolCallId (..))
import Seal.Providers.Class
import Seal.Security.Secrets (ApiKey, withApiKey)

-- | Response timeout for Ollama @/api/chat@ requests, in microseconds.
-- The 'newTlsManager' default is 90 seconds, which is too short for
-- non-streaming requests to remote models proxied through the local Ollama
-- daemon (e.g. @glm-5.2:cloud@): with a large context (49k+ input tokens)
-- the model can take 74+ seconds to generate the full response before
-- returning it in one shot. A 5-minute timeout gives generous headroom for
-- large-context non-streaming generation. This is a per-request override
-- (the manager's default is not changed, so other HTTP clients in the
-- process keep their own timeouts).
ollamaResponseTimeoutMicro :: Int
ollamaResponseTimeoutMicro = 300_000_000  -- 5 minutes

-- Data type ----------------------------------------------------------------

data Ollama = Ollama
  { olModel   :: ModelId
  , olManager :: Manager
  , olBaseUrl :: Text          -- e.g. "http://localhost:11434" | "https://ollama.com"
  , olApiKey  :: Maybe ApiKey  -- Nothing = local (no auth); Just = cloud (Bearer)
  , olCallCounter :: IORef Int -- ^ monotonic counter for unique tool-call ids.
                               --   Shared across turns — the caller owns it
                               --   so ids stay unique across a whole session
                               --   (not just within one provider instance).
  }

-- | Build an 'Ollama' using an externally-owned counter. The counter must be
--   shared across every 'Ollama' built for the same process (typically held in
--   'ProviderRuntime') so tool-call ids never repeat across turns. The model
--   field is filled in by the caller.
mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> IORef Int -> IO Ollama
mkOllama mgr base mKey model counter =
  pure (Ollama model mgr base mKey counter)

-- URL + headers ------------------------------------------------------------

defaultOllamaBaseUrl :: Text
defaultOllamaBaseUrl = "http://localhost:11434"

-- | Does this Ollama base URL require an API key? Only the Ollama Cloud direct
-- API (@ollama.com@) does; a local or custom-host daemon needs none. A local
-- daemon that proxies @*:cloud@ models still needs no Seal-held key (the daemon
-- authenticates to the cloud itself).
ollamaNeedsKey :: Text -> Bool
ollamaNeedsKey base = "ollama.com" `T.isInfixOf` base

stripTrailingSlash :: Text -> Text
stripTrailingSlash t = fromMaybe t (T.stripSuffix "/" t)

chatUrl :: Text -> Text
chatUrl base = stripTrailingSlash base <> "/api/chat"

tagsUrl :: Text -> Text
tagsUrl base = stripTrailingSlash base <> "/api/tags"

-- | Local: content-type only. Cloud: add a bearer authorization header.
ollamaHeaders :: Maybe ByteString -> RequestHeaders
ollamaHeaders mKey =
  ("content-type", "application/json")
    : [ ("authorization", "Bearer " <> kb) | Just kb <- [mKey] ]

-- Pure request mapping -----------------------------------------------------

encodeRequest :: CompletionRequest -> Value
encodeRequest cr = object $
  [ "model"    .= crModel cr
  , "stream"   .= False
  , "messages" .= (systemMsgs <> concatMap encMsg (crMessages cr))
  , "options"  .= object ["num_predict" .= crMaxTokens cr]
  ]
  <> ["tools" .= map encTool (crTools cr) | not (null (crTools cr))]
  where
    systemMsgs =
      maybe []
        (\s -> [object ["role" .= ("system" :: Text), "content" .= s]])
        (crSystem cr)

-- | Like 'encodeRequest' but with @"stream" .= True@. Used by 'streamComplete'
-- for the streaming HTTP request.
encodeStreamRequest :: CompletionRequest -> Value
encodeStreamRequest cr =
  case encodeRequest cr of
    Object o -> Object (KeyMap.insert "stream" (Bool True) o)
    other    -> other

-- | Flatten one provider-agnostic message into zero or more Ollama messages.
-- A User message becomes a "user" message (its text, if any) followed by one
-- "tool" message per tool-result block. An Assistant message becomes one
-- "assistant" message carrying its text and any tool_calls.
encMsg :: Message -> [Value]
encMsg (Message User blocks) =
  let texts = [t | CbText t <- blocks]
      userMsg =
        [ object ["role" .= ("user" :: Text), "content" .= T.intercalate "\n" texts]
        | not (null texts) ]
      toolMsgs =
        [ object ["role" .= ("tool" :: Text), "content" .= renderToolContent isErr parts]
        | CbToolResult _ parts isErr <- blocks ]
  in userMsg <> toolMsgs
encMsg (Message Assistant blocks) =
  let content = T.intercalate "\n" [t | CbText t <- blocks]
      toolCalls =
        [ object ["function" .= object ["name" .= n, "arguments" .= inp]]
        | CbToolUse _ (OpName n) inp <- blocks ]
      tc = ["tool_calls" .= toolCalls | not (null toolCalls)]
  in [object (["role" .= ("assistant" :: Text), "content" .= content] <> tc)]

-- | Ollama's tool role carries no structured error flag, so an errored result
-- is marked in-band: its text is prefixed so the model can see the call failed.
renderToolContent :: Bool -> [ToolResultPart] -> Text
renderToolContent isErr parts =
  let body = T.intercalate "\n" [t | TrpText t <- parts]
  in if isErr then "[tool error] " <> body else body

encTool :: ToolDefinition -> Value
encTool (ToolDefinition (OpName n) d sch) =
  -- Omit parameters entirely when it's the on-demand stub (OpenAI/Ollama's
  -- parameters field is optional). Keeps the stub tools at zero schema-token
  -- cost; the model retrieves a tool's real schema via OPCODE_DESCRIBE.
  if sch == stubSchema
    then object
           [ "type" .= ("function" :: Text)
           , "function" .= object ["name" .= n, "description" .= d]
           ]
    else object
           [ "type" .= ("function" :: Text)
           , "function" .= object ["name" .= n, "description" .= d, "parameters" .= sch]
           ]

-- Pure response mapping ----------------------------------------------------

decodeResponse :: Value -> Either Text CompletionResponse
decodeResponse = decodeResponseFrom 0

-- | Like 'decodeResponse' but starts tool-call ids at the given index so
-- multiple responses in the same conversation get globally unique ids
-- (Ollama tool calls carry no id).
decodeResponseFrom :: Int -> Value -> Either Text CompletionResponse
decodeResponseFrom start = mapLeft T.pack . parseEither (parseRespFrom start)
  where mapLeft f = either (Left . f) Right

parseRespFrom :: Int -> Value -> Parser CompletionResponse
parseRespFrom start = withObject "ollama response" $ \o -> do
  msg        <- o .: "message"
  content    <- msg .:? "content" .!= ""
  rawCalls   <- msg .:? "tool_calls" .!= ([] :: [Value])
  toolBlocks <- traverse parseToolCall (zip [start ..] rawCalls)
  doneReason <- o .:? "done_reason"
  promptTok  <- o .:? "prompt_eval_count" .!= 0
  evalTok    <- o .:? "eval_count" .!= 0
  let textBlocks = [CbText content | not (T.null content)]
      blocks     = textBlocks <> toolBlocks
      stop       = if not (null toolBlocks) then StopToolUse else stopFromDone doneReason
  pure (CompletionResponse blocks stop (Usage promptTok evalTok))

-- | Ollama tool calls carry no id; synthesize a stable "call_<i>" per index.
parseToolCall :: (Int, Value) -> Parser ContentBlock
parseToolCall (i, v) = flip (withObject "tool_call") v $ \o -> do
  fn   <- o .: "function"
  name <- fn .: "name"
  args <- fn .:? "arguments" .!= object []
  pure (CbToolUse (ToolCallId ("call_" <> T.pack (show i))) (OpName name) args)

stopFromDone :: Maybe Text -> StopReason
stopFromDone (Just "length") = StopMaxTokens
stopFromDone (Just "stop")   = StopEnd
stopFromDone Nothing         = StopEnd
stopFromDone (Just other)    = StopOther other

-- Streaming chunk decoding --------------------------------------------------

-- | Accumulator state for decoding Ollama streaming NDJSON chunks into
-- 'StreamEvent's. Ollama streams one JSON object per line; each carries
-- incremental @message.content@ (text deltas) and, when the model emits tool
-- calls, a complete @tool_calls@ array in a single chunk (Ollama does not
-- stream tool-call arguments incrementally — the whole array appears at
-- once). The state tracks which tool ids have already been emitted so we
-- only fire 'StreamToolStart'/'StreamToolEnd' once per tool.
data StreamChunkState = StreamChunkState
  { scsToolIndex :: Int
    -- ^ The next tool-call index to assign (Ollama tool calls carry no id;
    -- we synthesize @call_\<i\>@ sequentially, matching the non-streaming path).
  , scsSeenToolIds :: [ToolCallId]
    -- ^ Tool ids already emitted via 'StreamToolStart'/'StreamToolEnd', so
    -- we don't re-emit them if the same chunk is processed twice or if
    -- subsequent chunks repeat the tool_calls array.
  , scsSawTools :: Bool
    -- ^ True once any tool call was emitted during this stream. Ollama's
    -- @done_reason@ for a tool-call response is still @"stop"@ (which maps
    -- to 'StopEnd'), but the non-streaming path overrides the stop reason
    -- to 'StopToolUse' when tool blocks are present (see 'parseRespFrom').
    -- This flag lets the streaming path do the same override in the
    -- 'StreamDone' chunk so the transcript's stop reason is accurate.
  }

-- | Initial streaming state (no tools seen yet).
initialStreamChunkState :: StreamChunkState
initialStreamChunkState = StreamChunkState 0 [] False

-- | Decode one Ollama streaming NDJSON chunk into zero or more 'StreamEvent's,
-- threading the accumulator state. A single chunk can carry:
--
--   * @message.content@ (a text delta) → 'StreamTextChunk'
--   * @message.tool_calls@ (complete tool calls) → 'StreamToolStart' +
--     'StreamToolEnd' per tool (Ollama emits these as complete objects, not
--     incremental deltas)
--   * @done == true@ → 'StreamDone' with stop reason + usage
--
-- Returns the updated state alongside the events.
decodeStreamChunk
  :: StreamChunkState -> Value -> Either Text (StreamChunkState, [StreamEvent])
decodeStreamChunk st = mapLeft T.pack . parseEither (parseStreamChunk st)
  where mapLeft f = either (Left . f) Right

parseStreamChunk :: StreamChunkState -> Value -> Parser (StreamChunkState, [StreamEvent])
parseStreamChunk st = withObject "ollama stream chunk" $ \o -> do
  done <- o .:? "done" .!= False
  if done
    then do
      doneReason <- o .:? "done_reason"
      promptTok  <- o .:? "prompt_eval_count" .!= 0
      evalTok    <- o .:? "eval_count" .!= 0
      let rawStop = stopFromDone doneReason
          -- Override StopEnd → StopToolUse when tools were emitted during
          -- this stream (Ollama reports done_reason="stop" even for
          -- tool-call responses; the non-streaming path does the same
          -- override in parseRespFrom).
          stop = if scsSawTools st && rawStop == StopEnd then StopToolUse else rawStop
      pure (st, [StreamDone stop (Usage promptTok evalTok)])
    else do
      msgVal <- o .:? "message" .!= object []
      (content, rawCalls) <- parseMsgFields msgVal
      let textEvents = [StreamTextChunk content | not (T.null content)]
          (st', toolEvents) = foldl processTool (st, []) rawCalls
      pure (st', textEvents <> toolEvents)
  where
    processTool (s, evs) rawCall = case parseEither parseToolCallRaw rawCall of
      Left _ -> (s, evs)
      Right (mTcid, name, args) ->
        let tcid = fromMaybe (ToolCallId ("call_" <> T.pack (show (scsToolIndex s)))) mTcid
        in if tcid `elem` scsSeenToolIds s
          then (s, evs)  -- already emitted; skip duplicate
          else
            let s' = s { scsToolIndex = scsToolIndex s + 1
                       , scsSeenToolIds = tcid : scsSeenToolIds s
                       , scsSawTools = True
                       }
            in (s', evs <> [StreamToolStart tcid name, StreamToolEnd tcid name args])

parseMsgFields :: Value -> Parser (Text, [Value])
parseMsgFields = withObject "stream message" $ \msg -> do
  content <- msg .:? "content" .!= ""
  rawCalls <- msg .:? "tool_calls" .!= ([] :: [Value])
  pure (content, rawCalls)

parseToolCallRaw :: Value -> Parser (Maybe ToolCallId, OpName, Value)
parseToolCallRaw = withObject "tool_call" $ \o -> do
  fn   <- o .: "function"
  name <- fn .: "name"
  args <- fn .:? "arguments" .!= object []
  mId  <- o .:? "id" .!= ("" :: Text)
  let mTcid = if T.null mId then Nothing else Just (ToolCallId mId)
  pure (mTcid, OpName name, args)

-- Error rendering ----------------------------------------------------------

-- | Render a non-2xx Ollama response, key-safely (the body carries no secret).
ollamaErrorText :: Int -> Text -> Text
ollamaErrorText 401 _ =
  "Ollama rejected the credential (HTTP 401) — check the key with /provider add ollama"
ollamaErrorText code body =
  "Ollama API returned HTTP " <> T.pack (show code) <> ": " <> body

-- | Transport failure (connection refused is the common "not running" case).
-- The base URL is not secret.
unreachableMsg :: Text -> Text
unreachableMsg base =
  "could not reach Ollama at " <> base
    <> " — is it running and the URL correct? (try: ollama serve)"

-- | Render an 'HttpException' as a user-facing error. A response timeout
-- (the model took longer than 'ollamaResponseTimeoutMicro' to generate)
-- gets a distinct message so the user knows the daemon is running but the
-- model was too slow — not that the daemon is down. Other transport errors
-- (connection refused, etc.) use the generic 'unreachableMsg'.
ollamaHttpExceptionMsg :: Text -> HttpException -> Text
ollamaHttpExceptionMsg base = \case
  HttpExceptionRequest _ ResponseTimeout ->
    "Ollama response timed out after "
      <> T.pack (show (ollamaResponseTimeoutMicro `div` 1_000_000))
      <> "s — the model (likely a remote/cloud model with a large context) \
         \took too long to respond. Try reducing the conversation context, \
         \switching to a faster/local model, or send \"continue\" to retry."
  _ -> unreachableMsg base

-- HTTP round-trip ----------------------------------------------------------

-- | POST {base}/api/chat with the given headers; decode, or return a key-safe
-- transport / HTTP-status error.
sendChat
  :: Ollama -> RequestHeaders -> CompletionRequest
  -> IO (Either Text CompletionResponse)
sendChat o hdrs cr = do
  result <- try $ do
    initReq <- parseRequest (T.unpack ("POST " <> chatUrl (olBaseUrl o)))
    let req = initReq
          { requestBody     = RequestBodyLBS (encode (encodeRequest cr))
          , requestHeaders  = hdrs
          , responseTimeout  = responseTimeoutMicro ollamaResponseTimeoutMicro
          }
    httpLbs req (olManager o)
  case result of
    Left (e :: HttpException) -> pure (Left (ollamaHttpExceptionMsg (olBaseUrl o) e))
    Right resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then case eitherDecode (responseBody resp) of
          Left e  -> pure (Left (T.pack e))
          Right v -> do
            startIdx <- claimToolCallIds (olCallCounter o) (countToolCalls v)
            pure (decodeResponseFrom startIdx v)
        else pure $ Left $ ollamaErrorText code
          (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict (responseBody resp)))

-- | Count how many tool_calls appear in the response (to advance the counter).
countToolCalls :: Value -> Int
countToolCalls v = case v of
  Object o -> case KeyMap.lookup (Key.fromString "message") o of
    Just (Object msg) -> case KeyMap.lookup (Key.fromString "tool_calls") msg of
      Just (Array arr) -> V.length arr
      _ -> 0
    _ -> 0
  _ -> 0

-- | Atomically claim @n@ contiguous tool-call ids, returning the inclusive
-- start of the claimed range. 'atomicModifyIORef'' advances the counter by
-- @n@ and returns the previous value in one CAS, so concurrent callers can
-- never overlap (the read-then-advance pattern raced here: two threads both
-- read 0 before either advanced, both emitted "call_0"). Claiming 0 is a
-- no-op read. Exposed for the concurrency test in 'OllamaSpec'.
claimToolCallIds :: IORef Int -> Int -> IO Int
claimToolCallIds counter n = atomicModifyIORef' counter (\i -> (i + n, i))

-- | GET {base}/api/tags → the installed model names.
listTags :: Manager -> Text -> RequestHeaders -> IO (Either Text [ModelId])
listTags mgr base hdrs = do
  result <- try $ do
    initReq <- parseRequest (T.unpack ("GET " <> tagsUrl base))
    httpLbs initReq { requestHeaders = hdrs } mgr
  case result of
    Left (e :: HttpException) -> pure (Left (ollamaHttpExceptionMsg base e))
    Right resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then pure $ case eitherDecode (responseBody resp) of
          Left e  -> Left (T.pack e)
          Right v -> parseTags v
        else pure $ Left $ ollamaErrorText code
          (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict (responseBody resp)))

parseTags :: Value -> Either Text [ModelId]
parseTags = mapLeft T.pack . parseEither p
  where
    mapLeft f = either (Left . f) Right
    p = withObject "tags" $ \o -> do
      models <- o .:? "models" .!= ([] :: [Value])
      traverse (withObject "model" (\m -> ModelId <$> m .: "name")) models

-- Provider instance --------------------------------------------------------

instance Provider Ollama where
  listModels o = withHeaders o (listTags (olManager o) (olBaseUrl o))
  complete o cr =
    withHeaders o (\hdrs -> sendChat o hdrs cr)
  streamComplete o cr k =
    withHeaders o (\hdrs -> sendChatStream o hdrs cr k)

-- | POST {base}/api/chat with @stream:true@ and stream NDJSON chunks to the
-- callback. Uses 'withResponse' (incremental body reading) instead of
-- 'httpLbs' (whole body), so the first chunk arrives as soon as the model
-- starts generating — avoiding the 90s response timeout that plagued
-- non-streaming requests to remote/cloud models.
sendChatStream
  :: Ollama -> RequestHeaders -> CompletionRequest
  -> (StreamEvent -> IO Bool)
  -> IO (Either Text StreamOutcome)
sendChatStream o hdrs cr k = do
  result <- try $ do
    initReq <- parseRequest (T.unpack ("POST " <> chatUrl (olBaseUrl o)))
    let req = initReq
          { requestBody     = RequestBodyLBS (encode (encodeStreamRequest cr))
          , requestHeaders  = hdrs
          , responseTimeout  = responseTimeoutMicro ollamaResponseTimeoutMicro
          }
    withResponse req (olManager o) $ \resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then streamBody (responseBody resp)
        else do
          -- Non-2xx: read the body for the error message and return it
          -- directly (not via an exception).
          body <- brReadSome (responseBody resp) 4096
          let errTxt = ollamaErrorText code
                (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict body))
          pure (Left errTxt)
  case result of
    Left (e :: HttpException) -> pure (Left (ollamaHttpExceptionMsg (olBaseUrl o) e))
    Right inner -> pure inner
  where
    -- Read the response body chunk by chunk, decode each line as a JSON
    -- chunk, emit StreamEvents to the callback. Returns False immediately if
    -- the callback returns False (abort). Accumulates the final stop+usage
    -- from the StreamDone event.
    streamBody body = go BS.empty initialStreamChunkState
      where
        go buf st' = do
          chunk <- brRead body
          if BS.null chunk
            then -- Stream ended without a done chunk; flush any remaining
                 -- buffer as a text chunk and treat as a clean stop.
                 do unless (BS.null buf) $
                      do (_, events) <- processBuffer buf st'
                         void (emitEvents events)
                    pure (Right (StreamOutcome StopEnd (Usage 0 0)))
            else do
              let combined = buf <> chunk
                  ls = BS.split 10 combined  -- split on '\n'
              if BS.null (last ls)
                then do
                  -- trailing newline → all complete lines
                  let lines' = filter (not . BS.null) (init ls)
                  mOut <- processLines st' lines'
                  case mOut of
                    Just outcome -> pure (Right outcome)
                    Nothing -> go BS.empty st'
                else do
                  -- no trailing newline → last element is a partial line
                  let lines' = filter (not . BS.null) (init ls)
                      partial = last ls
                  mOut <- processLines st' lines'
                  case mOut of
                    Just outcome -> pure (Right outcome)
                    Nothing -> go partial st'
    -- Decode a batch of complete lines, threading state. Returns Just
    -- outcome if a StreamDone was encountered (or the callback aborted),
    -- Nothing to continue reading.
    processLines _ [] = pure Nothing
    processLines st' (l:ls) =
      case eitherDecodeStrict l of
        Left _ -> processLines st' ls  -- skip malformed line
        Right v -> case decodeStreamChunk st' v of
          Left _ -> processLines st' ls
          Right (st'', events) -> do
            mOut <- emitEvents events
            case mOut of
              Just outcome -> pure (Just outcome)
              Nothing -> processLines st'' ls
    -- Emit events to the callback; return Just outcome if StreamDone or
    -- callback returned False (abort → treat as clean stop).
    emitEvents [] = pure Nothing
    emitEvents (e:es) = do
      continue <- k e
      if not continue
        then pure (Just (StreamOutcome StopEnd (Usage 0 0)))
        else case e of
          StreamDone stop usage -> pure (Just (StreamOutcome stop usage))
          _ -> emitEvents es
    -- Process a raw buffer (used for the final flush when the stream ends
    -- without a newline). Returns (state, events).
    processBuffer buf st' =
      case eitherDecodeStrict buf of
        Left _ -> pure (st', [])
        Right v -> case decodeStreamChunk st' v of
          Left _ -> pure (st', [])
          Right r -> pure r

-- | Run @k@ with request headers built from the optional key; the key bytes
-- live only inside the 'withApiKey' continuation.
withHeaders :: Ollama -> (RequestHeaders -> IO r) -> IO r
withHeaders o k = case olApiKey o of
  Nothing  -> k (ollamaHeaders Nothing)
  Just key -> withApiKey key (k . ollamaHeaders . Just)
