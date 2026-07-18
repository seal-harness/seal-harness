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
  , encodeRequest
  , decodeResponse
  ) where

import Control.Exception (try)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef)
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

-- Data type ----------------------------------------------------------------

data Ollama = Ollama
  { olModel   :: ModelId
  , olManager :: Manager
  , olBaseUrl :: Text          -- e.g. "http://localhost:11434" | "https://ollama.com"
  , olApiKey  :: Maybe ApiKey  -- Nothing = local (no auth); Just = cloud (Bearer)
  , olCallCounter :: IORef Int -- ^ monotonic counter for globally-unique tool-call ids
  }

mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> IO Ollama
mkOllama mgr base mKey model = do
  counter <- newIORef 0
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
          }
    httpLbs req (olManager o)
  case result of
    Left (_ :: HttpException) -> pure (Left (unreachableMsg (olBaseUrl o)))
    Right resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then case eitherDecode (responseBody resp) of
          Left e  -> pure (Left (T.pack e))
          Right v -> do
            startIdx <- atomicModifyIORef' (olCallCounter o) (\i -> (i, i))
            let toolCount = countToolCalls v
                nextIdx = startIdx + toolCount
            _ <- atomicModifyIORef' (olCallCounter o) (\_ -> (nextIdx, ()))
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

-- | GET {base}/api/tags → the installed model names.
listTags :: Manager -> Text -> RequestHeaders -> IO (Either Text [ModelId])
listTags mgr base hdrs = do
  result <- try $ do
    initReq <- parseRequest (T.unpack ("GET " <> tagsUrl base))
    httpLbs initReq { requestHeaders = hdrs } mgr
  case result of
    Left (_ :: HttpException) -> pure (Left (unreachableMsg base))
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

-- | Run @k@ with request headers built from the optional key; the key bytes
-- live only inside the 'withApiKey' continuation.
withHeaders :: Ollama -> (RequestHeaders -> IO r) -> IO r
withHeaders o k = case olApiKey o of
  Nothing  -> k (ollamaHeaders Nothing)
  Just key -> withApiKey key (k . ollamaHeaders . Just)
