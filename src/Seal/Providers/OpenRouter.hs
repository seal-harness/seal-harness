{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
-- | OpenRouter provider using the @openai@ package's *types* (v2.5.4) with our
-- own HTTP round-trip (mirroring 'Seal.Providers.Anthropic' / 'Ollama'). We do
-- NOT use 'OpenAI.V1.makeMethods' (the servant-client convenience wrapper) —
-- that would unwrap the 'ApiKey' to 'Text' and surface 'servant-client'
-- runtime exceptions. Instead the request is built as a
-- 'OpenAI.V1.Chat.Completions.CreateChatCompletion', @encode@d to JSON, and
-- POSTed with 'Network.HTTP.Client'; the response is @eitherDecode@d as a
-- 'OpenAI.V1.Chat.Completions.ChatCompletionObject'. The API key bytes live
-- only on the @Authorization: Bearer@ header built inside the CPS 'withApiKey'
-- accessor — never returned, never logged.
--
-- Base URL: @https://openrouter.ai/api/v1/chat/completions@
-- Vault key: @OPENROUTER_API_KEY@
--
-- Security: capability-based — no opcode touches the agent-immutable home
-- state dir; this module imports only the openai types, the HTTP client
-- library, and the CPS secret accessor. It never spawns a process, never
-- touches the filesystem directly, and never imports the web-client library
-- whose types it borrows (see AGENTS.md §Security).
module Seal.Providers.OpenRouter
  ( OpenRouter (..)
  , mkOpenRouter
  , defaultOpenRouterBaseUrl
  , openRouterBaseUrl
  , encodeRequest
  , decodeResponse
  , mapFinishReason
  , bearerHeaders
  , sendChatCompletion
  , httpErrorText
  ) where

import Control.Exception (try)
import Data.Aeson (Value (Null), eitherDecode, encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Vector qualified as V
import Network.HTTP.Client
  ( HttpException, Manager, RequestBody (RequestBodyLBS), Response
  , httpLbs, parseRequest, requestBody, requestHeaders, responseBody
  , responseStatus )
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Header (RequestHeaders)

import qualified OpenAI.V1.Chat.Completions as Chat
import qualified OpenAI.V1.Models as OAM
import qualified OpenAI.V1.Tool as OAT
import qualified OpenAI.V1.ToolCall as OATC
import qualified OpenAI.V1.Usage as UAU

import Seal.Core.Types (ModelId (ModelId), OpName (OpName), ToolCallId (ToolCallId))
import Seal.Providers.Class
  ( CompletionRequest (crMaxTokens, crMessages, crModel, crSystem, crToolChoice, crTools)
  , CompletionResponse (CompletionResponse)
  , ContentBlock (CbText, CbToolResult, CbToolUse)
  , Message (Message)
  , Provider (complete, listModels)
  , Role (Assistant, User)
  , StopReason (StopEnd, StopMaxTokens, StopOther, StopToolUse)
  , ToolChoice (ToolAuto, ToolNone)
  , ToolDefinition (ToolDefinition)
  , ToolResultPart (TrpText)
  , Usage (Usage, uInput, uOutput)
  )
import Seal.Security.Secrets (ApiKey, withApiKey)

-- Provider type -------------------------------------------------------------

-- | Strict fields; 'Text' not 'String'. The 'Manager' is shared with the
-- caller (mirrors 'Seal.Providers.Ollama.olManager' /
-- 'Seal.Providers.Anthropic.anManager') so the TLS context isn't rebuilt per
-- call.
data OpenRouter = OpenRouter
  { orApiKey       :: !(Maybe ApiKey)
  , orBaseUrl      :: !Text
  , orDefaultModel :: !ModelId
  , orManager      :: !Manager
  }

-- | Build an 'OpenRouter' with an externally-owned 'Manager' and an optional
-- API key ('Nothing' => 'complete' returns an actionable error without
-- touching the network).
mkOpenRouter :: Manager -> Maybe ApiKey -> Text -> ModelId -> OpenRouter
mkOpenRouter mgr key base model = OpenRouter key base model mgr

-- | Default base URL for OpenRouter (OpenAI-compatible endpoint).
defaultOpenRouterBaseUrl :: Text
defaultOpenRouterBaseUrl = "https://openrouter.ai/api/v1"

-- | Access the configured base URL.
openRouterBaseUrl :: OpenRouter -> Text
openRouterBaseUrl = orBaseUrl

-- Pure request mapping ------------------------------------------------------

-- | Build the OpenAI-compatible chat-completion request from our shape. The
-- system prompt becomes a leading 'Chat.System' message; 'CbThinking' blocks
-- are dropped (no OpenAI equivalent); 'CbToolUse' becomes the assistant's
-- @tool_calls@; 'CbToolResult' becomes a 'Chat.Tool' role message carrying
-- the matching @tool_call_id@.
encodeRequest :: CompletionRequest -> Chat.CreateChatCompletion
encodeRequest cr = Chat._CreateChatCompletion
  { Chat.messages = V.fromList (systemMsgs <> concatMap msgOpenAi (crMessages cr))
  , Chat.model = OAM.Model (modelIdText (crModel cr))
  , Chat.max_completion_tokens = Just (fromIntegral (crMaxTokens cr))
  , Chat.tools = toolsVec
  , Chat.tool_choice = tc
  }
  where
    systemMsgs = case crSystem cr of
      Nothing -> []
      Just s  -> [ Chat.System { Chat.content = V.singleton (txt s), Chat.name = Nothing } ]
    toolsVec = case crTools cr of
      []  -> Nothing
      ts  -> Just (V.fromList (map toolDef ts))
    tc = case crToolChoice cr of
      ToolAuto  -> Just OAT.ToolChoiceAuto
      ToolNone  -> Just OAT.ToolChoiceNone

    toolDef (ToolDefinition (OpName n) d sch) =
      OAT.Tool_Function
        ( OAT.Function
            { OAT.description = Just d
            , OAT.name = n
            , OAT.parameters = Just sch
            , OAT.strict = Nothing
            }
        )

-- | Map a single Seal 'Message' to one or more OpenAI messages. A Seal
-- assistant message that mixes text + tool calls + tool results splits into a
-- single 'Chat.Assistant' message (text + tool_calls) plus one 'Chat.Tool'
-- message per 'CbToolResult'. (OpenAI has no per-tool-result container; each
-- result is its own @tool@-role message keyed by @tool_call_id@.)
msgOpenAi :: Message -> [Chat.Message (V.Vector Chat.Content)]
msgOpenAi (Message role blocks) =
  let textContents   = [ txt t     | CbText t <- blocks ]
      toolCallVec    = [ mkToolCall i n inp
                       | CbToolUse (ToolCallId i) (OpName n) inp <- blocks ]
      toolResultMsgs = [ Chat.Tool
                          { Chat.content = V.singleton (txt (joinParts parts))
                          , Chat.tool_call_id = i
                          }
                       | CbToolResult (ToolCallId i) parts _ <- blocks ]
      mainMsg = case role of
        User -> Chat.User
          { Chat.content = V.fromList textContents
          , Chat.name = Nothing
          }
        Assistant -> Chat.Assistant
          { Chat.assistant_content =
              if null textContents then Nothing else Just (V.fromList textContents)
          , Chat.tool_calls =
              if null toolCallVec then Nothing else Just (V.fromList toolCallVec)
          , Chat.refusal = Nothing
          , Chat.name = Nothing
          , Chat.assistant_audio = Nothing
          }
  in mainMsg : toolResultMsgs
  where
    mkToolCall i n inp =
      OATC.ToolCall_Function
        { OATC.id = i
        , OATC.function = OATC.Function
            { OATC.name = n
            , OATC.arguments = TE.decodeUtf8 (BL.toStrict (encode inp))
            }
        }
    joinParts []     = ""
    joinParts (p:ps) = T.intercalate "\n" (map partText (p:ps))
    partText (TrpText t) = t

-- Pure response mapping -----------------------------------------------------

-- | Map a finish-reason string to our 'StopReason'. OpenRouter follows the
-- OpenAI convention (@stop@ / @length@ / @tool_calls@); an unrecognized value
-- (including @content_filter@) maps to 'StopOther' rather than failing — the
-- caller can still use the partial response.
mapFinishReason :: Text -> StopReason
mapFinishReason r
  | r == "stop"        = StopEnd
  | r == "tool_calls"  = StopToolUse
  | r == "tool_use"     = StopToolUse
  | r == "length"      = StopMaxTokens
  | otherwise          = StopOther r

-- | Decode an OpenAI 'Chat.ChatCompletionObject' into our
-- 'CompletionResponse'. An empty @choices@ array is a graceful 'Left' (some
-- upstream error conditions return no choices). The first choice is taken;
-- its @message@ is an 'Chat.Assistant' carrying optional text + tool calls.
-- Tool-call ids are taken verbatim from OpenRouter (it returns ids); the
-- JSON-encoded @arguments@ text is parsed back to a 'Value'.
decodeResponse :: Chat.ChatCompletionObject -> Either Text CompletionResponse
decodeResponse obj =
  case V.toList (Chat.choices obj) of
    []     -> Left "OpenRouter returned no choices"
    (c:_)  ->
      let stop  = mapFinishReason (Chat.finish_reason c)
          blkss = assistantBlocks (Chat.message c)
          u     = Chat.usage obj
          usage = Usage
            { uInput  = fromIntegral (UAU.prompt_tokens u)
            , uOutput = fromIntegral (UAU.completion_tokens u)
            }
      in Right (CompletionResponse blkss stop usage)

-- | Extract our 'ContentBlock's from an OpenAI assistant message: the text
-- body becomes 'CbText' and each tool call becomes a 'CbToolUse' with the
-- upstream id + name, and the JSON-encoded @arguments@ parsed back to a
-- 'Value' (OpenRouter emits arguments as a JSON object encoded as a 'Text';
-- if it ever fails to parse, we fall back to a placeholder 'Value' so the
-- transcript still records the call).
assistantBlocks :: Chat.Message Text -> [ContentBlock]
assistantBlocks msg = case msg of
  Chat.Assistant mText _ _ _ mCalls ->
    let txts  = maybe [] (\t -> [CbText t]) mText
        calls = maybe [] (map toolCallBlock . V.toList) mCalls
    in txts <> calls
  _ -> []
  where
    toolCallBlock tc =
      let OATC.Function n args = OATC.function tc
          parsed = case eitherDecode (BL.fromStrict (TE.encodeUtf8 args)) :: Either String Value of
            Right v  -> v
            Left _e  -> Null
      in CbToolUse (ToolCallId (OATC.id tc)) (OpName n) parsed

-- Headers --------------------------------------------------------------------

-- | The headers for an OpenRouter chat-completion POST. The API key bytes
-- (@bytes@) live only here, inside the 'withApiKey' continuation. OpenRouter
-- recommends @HTTP-Referer@ / @X-Title@ for app attribution; neither carries a
-- secret.
bearerHeaders :: ByteString -> RequestHeaders
bearerHeaders bytes =
  [ ("content-type", "application/json")
  , ("authorization", "Bearer " <> bytes)
  , ("HTTP-Referer", "https://github.com/seal-harness")
  , ("X-Title", "seal-harness")
  ]

-- HTTP round-trip ------------------------------------------------------------

-- | POST @<baseUrl>/chat/completions@ with the given headers + request body,
-- then decode the response. Non-2xx -> 'httpErrorText'; a transport error
-- (connection / TLS) -> a 'Left' string. The body carries no secret. The
-- @baseUrl@ is the configured one ('orBaseUrl'), so a custom/proxy endpoint
-- is honored.
sendChatCompletion
  :: Manager -> Text -> RequestHeaders -> Chat.CreateChatCompletion
  -> IO (Either Text CompletionResponse)
sendChatCompletion mgr baseUrl hdrs req = do
  initReq <- parseRequest (T.unpack ("POST " <> baseUrl <> "/chat/completions"))
  let httpReq = initReq
        { requestBody = RequestBodyLBS (encode req)
        , requestHeaders = hdrs
        }
  result <- try (httpLbs httpReq mgr) :: IO (Either HttpException (Response BL.ByteString))
  case result of
    Left _e ->
      pure (Left "OpenRouter HTTP request failed (connection or transport error)")
    Right resp ->
      let code = statusCode (responseStatus resp)
      in if code >= 200 && code <= 299
           then case eitherDecode (responseBody resp) of
                  Left e    -> pure (Left (T.pack e))
                  Right obj -> pure (decodeResponse obj)
           else pure (Left (httpErrorText code
                             (TE.decodeUtf8With TEE.lenientDecode
                               (BL.toStrict (responseBody resp)))))

-- | Render a non-2xx OpenRouter response into a user-facing message. 429
-- (rate limit) and 401 (auth) get friendlier, actionable hints; other codes
-- keep the full response body (the body carries no secret).
httpErrorText :: Int -> Text -> Text
httpErrorText 429 _ =
  "OpenRouter rate limit (HTTP 429) — the account behind this credential is \
  \being throttled. Wait a moment and retry, or switch models with /model use."
httpErrorText 401 _ =
  "OpenRouter rejected the API key (HTTP 401) — run /provider remove openrouter \
  \then /provider add openrouter to re-enter the key."
httpErrorText code body =
  "OpenRouter API returned HTTP " <> T.pack (show code) <> ": " <> body

-- Provider instance ---------------------------------------------------------

instance Provider OpenRouter where
  listModels prov = pure (Right [orDefaultModel prov])
  complete prov cr = case orApiKey prov of
    Nothing ->
      pure (Left "OpenRouter needs an API key \x2014 run /vault setup then /provider add openrouter")
    Just key ->
      withApiKey key $ \bytes ->
        sendChatCompletion (orManager prov) (orBaseUrl prov) (bearerHeaders bytes) (encodeRequest cr)

-- Helpers --------------------------------------------------------------------

modelIdText :: ModelId -> Text
modelIdText (ModelId t) = t

-- | Build a text 'Chat.Content' from a 'Text'. The 'Content' type exports no
-- (public) constructors, so we go through its 'IsString' instance.
txt :: Text -> Chat.Content
txt = fromString . T.unpack