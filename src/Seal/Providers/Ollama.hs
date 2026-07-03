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
  , chatUrl
  , tagsUrl
  , ollamaHeaders
  , ollamaErrorText
  , unreachableMsg
  , encodeRequest
  , decodeResponse
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
import Network.HTTP.Types.Header (RequestHeaders)

import Seal.Core.Types (ModelId, OpName (..), ToolCallId (..))
import Seal.Providers.Class
import Seal.Security.Secrets (ApiKey)

-- Data type ----------------------------------------------------------------

data Ollama = Ollama
  { olModel   :: ModelId
  , olManager :: Manager
  , olBaseUrl :: Text          -- e.g. "http://localhost:11434" | "https://ollama.com"
  , olApiKey  :: Maybe ApiKey  -- Nothing = local (no auth); Just = cloud (Bearer)
  }

mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> Ollama
mkOllama mgr base mKey model = Ollama model mgr base mKey

-- URL + headers ------------------------------------------------------------

defaultOllamaBaseUrl :: Text
defaultOllamaBaseUrl = "http://localhost:11434"

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
  object
    [ "type" .= ("function" :: Text)
    , "function" .= object ["name" .= n, "description" .= d, "parameters" .= sch]
    ]

-- Pure response mapping ----------------------------------------------------

decodeResponse :: Value -> Either Text CompletionResponse
decodeResponse = mapLeft T.pack . parseEither parseResp
  where mapLeft f = either (Left . f) Right

parseResp :: Value -> Parser CompletionResponse
parseResp = withObject "ollama response" $ \o -> do
  msg        <- o .: "message"
  content    <- msg .:? "content" .!= ""
  rawCalls   <- msg .:? "tool_calls" .!= ([] :: [Value])
  toolBlocks <- traverse parseToolCall (zip [0 :: Int ..] rawCalls)
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
