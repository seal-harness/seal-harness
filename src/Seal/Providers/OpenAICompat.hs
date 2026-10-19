{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | Generic OpenAI-compatible provider: uses the @openai@ package's *types*
-- (v2.5.4) with our own HTTP round-trip (mirroring 'Seal.Providers.Anthropic' /
-- 'Ollama'). We do NOT use 'OpenAI.V1.makeMethods' (the servant-client
-- convenience wrapper) — that would unwrap the 'ApiKey' to 'Text' and surface
-- 'servant-client' runtime exceptions. Instead the request is built as a
-- 'OpenAI.V1.Chat.Completions.CreateChatCompletion', @encode@d to JSON, and
-- POSTed with 'Network.HTTP.Client'; the response is @eitherDecode@d as a
-- 'OpenAI.V1.Chat.Completions.ChatCompletionObject'.
--
-- Everything that varies between OpenAI-compatible vendors (endpoint, display
-- name, vault key, whether a key is required, the advertised model catalogue,
-- static vendor headers) lives in an 'OpenAICompatSpec' supplied by the caller
-- (the catalog in 'Seal.Providers.Registry'). This module contains no
-- provider-specific branch, so a new compatible vendor is a catalog row, not a
-- code change here.
--
-- The API key bytes live only on the @Authorization: Bearer@ header built
-- inside the CPS 'withApiKey' accessor in 'chatHeaders' — never returned, never
-- logged. A provider with no key sends no @authorization@ header at all.
--
-- Security: capability-based — no opcode touches the agent-immutable home
-- state dir; this module imports only the openai types, the HTTP client
-- library, and the CPS secret accessor. It never spawns a process, never
-- touches the filesystem directly, and never imports the web-client library
-- whose types it borrows (see AGENTS.md §Security).
module Seal.Providers.OpenAICompat
  ( OpenAICompatSpec (..)
  , OpenAICompat (..)
  , mkOpenAICompat
  , defaultOpenRouterBaseUrl
  , encodeRequest
  , decodeResponse
  , mapFinishReason
  , chatUrl
  , validateBaseUrl
  , chatHeaders
  , sendChatCompletion
  , httpErrorText
  ) where

import Control.Exception (try)
import Control.Monad (when)
import Data.Aeson (Value (Null), eitherDecode, encode)
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.ByteString.Lazy qualified as BL
import Data.Char (isControl, isDigit, isSpace)
import Data.List (nub)
import Data.Maybe (listToMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Vector qualified as V
import Network.HTTP.Client
  ( HttpException (..), HttpExceptionContent (..), Manager
  , RequestBody (RequestBodyLBS)
  , httpLbs, parseRequest, redirectCount, requestBody, requestHeaders
  , responseBody, responseStatus, shouldStripHeaderOnRedirect )
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Header (HeaderName, RequestHeaders)
import Text.Read (readMaybe)

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

-- Configuration -------------------------------------------------------------

-- | Everything that varies between OpenAI-compatible providers. The generic
-- provider is a row with no built-in base URL; a vendor preset is a row with
-- one. The HTTP/JSON layer below is identical for every row.
data OpenAICompatSpec = OpenAICompatSpec
  { ocsId             :: !Text
    -- ^ the provider id typed at @\/provider@ (and used in error copy)
  , ocsDisplayName    :: !Text
    -- ^ human label used in prompts, errors and the API
  , ocsVaultKey       :: !Text
    -- ^ the vault key holding this provider's API key
  , ocsBuiltinBaseUrl :: !(Maybe Text)
    -- ^ 'Nothing' ⇒ the user must supply the base URL
  , ocsDefaultModel   :: !(Maybe ModelId)
    -- ^ 'Nothing' ⇒ the user must pick a model
  , ocsKeyRequired    :: !Bool
    -- ^ 'False' ⇒ keyless endpoints are usable (no key stored, none sent)
  , ocsModels         :: ![ModelId]
    -- ^ the advertised model catalogue (@[]@ = unknown)
  , ocsExtraHeaders   :: ![(HeaderName, ByteString)]
    -- ^ static vendor headers (e.g. attribution); secrets never belong here
  } deriving stock (Eq, Show)

-- Provider type -------------------------------------------------------------

-- | Strict fields; 'Text' not 'String'. The 'Manager' is shared with the
-- caller (mirrors 'Seal.Providers.Ollama.olManager' /
-- 'Seal.Providers.Anthropic.anManager') so the TLS context isn't rebuilt per
-- call.
data OpenAICompat = OpenAICompat
  { oacSpec    :: !OpenAICompatSpec
  , oacApiKey  :: !(Maybe ApiKey)
  , oacBaseUrl :: !Text
  , oacModel   :: !ModelId
  , oacManager :: !Manager
  }

-- | Build an 'OpenAICompat' with an externally-owned 'Manager'. 'Nothing' for
-- the key means the request carries no @authorization@ header (keyless
-- endpoints); whether a key is *required* is a resolution-time policy in
-- 'Seal.Providers.Registry'.
mkOpenAICompat :: Manager -> Maybe ApiKey -> Text -> ModelId -> OpenAICompatSpec -> OpenAICompat
mkOpenAICompat mgr key base model spec = OpenAICompat spec key base model mgr

-- | The OpenRouter endpoint, kept only for the config-migration unit (WU-2
-- moves provider defaults into the catalog and deletes this).
defaultOpenRouterBaseUrl :: Text
defaultOpenRouterBaseUrl = "https://openrouter.ai/api/v1"

-- Base URL handling ---------------------------------------------------------

-- | Validate and canonicalise an operator-supplied base URL. The 'Left' is a
-- short reason phrase (callers compose the user-facing sentence).
--
-- Contract: surrounding whitespace is stripped, the scheme is lowercased (the
-- rest is preserved verbatim), every trailing @\/@ is collapsed, and the
-- result is @<scheme>://<host>[:port][/path]@ with no userinfo, no query, no
-- fragment and no whitespace/control characters. IPv4, hostnames and bracketed
-- IPv6 literals are accepted (loopback is required by the local-endpoint use
-- case).
validateBaseUrl :: Text -> Either Text Text
validateBaseUrl raw
  | T.null t = Left "empty"
  | T.any (\c -> isSpace c || isControl c) t =
      Left "whitespace or control characters"
  | T.any (== '?') t || T.any (== '#') t =
      Left "query or fragment is not allowed"
  | otherwise = case T.breakOn "://" t of
      (_, rest) | T.null rest -> Left "scheme must be http or https"
      (schemeRaw, rest) -> do
        let scheme = T.toLower schemeRaw
            afterScheme = T.drop 3 rest
            authority = T.takeWhile (/= '/') afterScheme
        if scheme /= "http" && scheme /= "https"
          then Left "scheme must be http or https"
          else do
            when (T.any (== '@') authority) (Left "userinfo is not allowed")
            (host, mPort) <- splitAuthority authority
            when (T.null host) (Left "host required")
            case mPort of
              Nothing -> pure ()
              Just p
                | T.null p || not (T.all isDigit p) -> Left "port out of range"
                | otherwise -> case readMaybe (T.unpack p) :: Maybe Int of
                    Just n | n >= 1 && n <= 65535 -> pure ()
                    _ -> Left "port out of range"
            pure (stripTrailingSlashes (scheme <> T.drop (T.length schemeRaw) t))
  where
    t = T.strip raw

-- | Split an authority into (host, optional port). A bracketed IPv6 literal
-- keeps its brackets; an unbracketed host containing @:@ is rejected (the
-- port would be ambiguous).
splitAuthority :: Text -> Either Text (Text, Maybe Text)
splitAuthority a
  | "[" `T.isPrefixOf` a = case T.breakOn "]" a of
      (h, rest)
        | T.null rest -> Left "host required"
        | otherwise -> case T.drop 1 rest of
            "" -> Right (h <> "]", Nothing)
            sfx | ":" `T.isPrefixOf` sfx -> Right (h <> "]", Just (T.drop 1 sfx))
                | otherwise -> Left "port out of range"
  | otherwise = case T.breakOnEnd ":" a of
      ("", _) -> Right (a, Nothing)
      (pfx, sfx) ->
        let host = T.dropEnd 1 pfx
        in if T.any (== ':') host
             then Left "host required"
             else Right (host, Just sfx)

-- | Drop every trailing @\/@.
stripTrailingSlashes :: Text -> Text
stripTrailingSlashes = T.dropWhileEnd (== '/')

-- | The chat-completions URL for a canonical base URL. Expects the output of
-- 'validateBaseUrl' (or a built-in catalog URL); never yields
-- @\/\/chat\/completions@.
chatUrl :: Text -> Text
chatUrl base = stripTrailingSlashes base <> "/chat/completions"

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

-- | Map a finish-reason string to our 'StopReason'. OpenAI-compatible
-- endpoints follow the OpenAI convention (@stop@ / @length@ / @tool_calls@); an
-- unrecognized value (including @content_filter@) maps to 'StopOther' rather
-- than failing — the caller can still use the partial response.
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
-- Tool-call ids are taken verbatim; the JSON-encoded @arguments@ text is
-- parsed back to a 'Value'.
decodeResponse :: OpenAICompatSpec -> Chat.ChatCompletionObject -> Either Text CompletionResponse
decodeResponse spec obj =
  case V.toList (Chat.choices obj) of
    []     -> Left (ocsDisplayName spec <> " returned no choices")
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
-- 'Value' (if it ever fails to parse, we fall back to a placeholder 'Value' so
-- the transcript still records the call).
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

-- | The headers for a chat-completion POST. The API key (when present) is
-- unwrapped by 'withApiKey' **inside** this function, so the raw bytes never
-- cross a boundary; with no key there is no @authorization@ header at all
-- (never an empty @Bearer @). The spec's extra headers are appended, minus any
-- that could weaken key handling.
chatHeaders :: Maybe ApiKey -> OpenAICompatSpec -> RequestHeaders
chatHeaders mkey spec =
  ("content-type", "application/json")
    : maybe [] (\k -> withApiKey k (\b -> [("authorization", "Bearer " <> b)])) mkey
   <> [ (n, v) | (n, v) <- ocsExtraHeaders spec, not (reservedHeader n) ]
  where
    -- A vendor row must not be able to shadow the headers Seal owns.
    reservedHeader n =
      T.toLower (TE.decodeUtf8With TEE.lenientDecode (CI.original n))
        `elem` ["authorization", "host", "content-length", "content-type"]

-- HTTP round-trip ------------------------------------------------------------

-- | POST @<baseUrl>/chat/completions@ then decode the response.
--
-- * The URL and the body are both built inside the 'try', so a base URL the
--   request parser rejects yields a 'Left' instead of an escaping exception.
-- * Redirects are **refused** (@redirectCount = 0@): following one would
--   re-send the @authorization@ header to an attacker-chosen @Location@.
-- * Non-2xx -> 'httpErrorText'; a transport error -> a 'Left' string whose
--   wording stays compatible with 'Seal.Agent.Loop.isTransientError'.
sendChatCompletion
  :: Manager -> OpenAICompatSpec -> Text -> Maybe ApiKey
  -> Chat.CreateChatCompletion -> IO (Either Text CompletionResponse)
sendChatCompletion mgr spec baseUrl mkey req = do
  result <- try @HttpException $ do
    initReq <- parseRequest (T.unpack ("POST " <> chatUrl baseUrl))
    let httpReq = initReq
          { requestBody = RequestBodyLBS (encode req)
          , requestHeaders = chatHeaders mkey spec
          , redirectCount = 0
          , shouldStripHeaderOnRedirect = const True
          }
    httpLbs httpReq mgr
  case result of
    Left e -> pure (Left (exceptionText spec e))
    Right resp ->
      let code = statusCode (responseStatus resp)
      in if code >= 200 && code <= 299
           then case eitherDecode (responseBody resp) of
                  Left e    -> pure (Left (unreadableText spec (T.pack e)))
                  Right obj -> pure (decodeResponse spec obj)
           else pure (Left (httpErrorText spec code
                             (TE.decodeUtf8With TEE.lenientDecode
                               (BL.toStrict (responseBody resp)))))

-- | Render a transport-level 'HttpException': a refused redirect is its own,
-- non-transient message; everything else is the retry-compatible transport
-- wording.
exceptionText :: OpenAICompatSpec -> HttpException -> Text
exceptionText spec e = case e of
  HttpExceptionRequest _ content -> case content of
    TooManyRedirects rs -> redirectText spec (statusOf rs)
    _ -> ocsDisplayName spec <> " HTTP request failed (connection or transport error)"
  InvalidUrlException _ _ ->
    ocsDisplayName spec <> " base URL is not usable — it must be an http(s) URL like https://host/v1"
  where
    statusOf rs = statusCode . responseStatus <$> listToMaybe rs

-- | The refused-redirect message. Non-transient by construction:
-- 'Seal.Agent.Loop.isTransientError' matches neither "redirect" nor a 3xx code.
redirectText :: OpenAICompatSpec -> Maybe Int -> Text
redirectText spec mCode =
  ocsDisplayName spec <> " endpoint answered with a redirect"
    <> maybe "" (\c -> " (HTTP " <> T.pack (show c) <> ")") mCode
    <> ", refused for security — enter the final URL"
    <> case ocsBuiltinBaseUrl spec of
         Nothing -> "; run /provider add " <> ocsId spec
         Just _  -> " — this is a Seal bug, please report it"

-- | Render a non-2xx response into a user-facing message. 401/403 get
-- provider-aware, actionable hints (keyed vs keyless), 404 names the two likely
-- causes, 429 stays retry-compatible, and every body-bearing branch is
-- single-lined and truncated to 2000 chars: this text is persisted to the
-- transcript and re-sent to the model.
httpErrorText :: OpenAICompatSpec -> Int -> Text -> Text
httpErrorText spec code body
  | code == 401 || code == 403 =
      if ocsKeyRequired spec
        then n <> " rejected the API key (HTTP " <> codeTxt <> ")"
               <> " — run /provider add " <> i <> " to re-enter it"
        else n <> " rejected the request (HTTP " <> codeTxt <> ")"
               <> " — this endpoint requires an API key; set one in the"
               <> " Providers view or run /provider add " <> i
  | code == 404 =
      n <> " API returned HTTP 404 — check the base URL path (it may be missing"
        <> " /v1) or the model id: " <> clean
  | code == 429 =
      n <> " rate limit (HTTP 429) — wait a moment and retry, or switch models"
        <> " with /model use"
  | code >= 300 && code <= 399 = redirectText spec (Just code)
  | otherwise =
      n <> " API returned HTTP " <> codeTxt <> ": " <> clean
  where
    n = ocsDisplayName spec
    i = ocsId spec
    codeTxt = T.pack (show code)
    clean = T.take 2000 (T.unwords (T.lines body))

-- | The unreadable-response message (same cleaning rules as 'httpErrorText').
unreadableText :: OpenAICompatSpec -> Text -> Text
unreadableText spec msg =
  ocsDisplayName spec <> " returned an unreadable response: "
    <> T.take 2000 (T.unwords (T.lines msg))

-- Provider instance ---------------------------------------------------------

instance Provider OpenAICompat where
  -- The advertised catalogue: the row's known models, plus the model this
  -- instance was resolved with when it is set (so a configured model stays
  -- discoverable). Never yields an empty model id.
  listModels prov = pure (Right (nub (ocsModels spec <> [m | not (T.null (modelIdText m))])))
    where
      spec = oacSpec prov
      m = oacModel prov
  complete prov cr
    | T.null (modelIdText (crModel cr)) =
        pure (Left (oacDisplayName <> " has no model selected — set a model in the"
                     <> " Providers view, or run /model use " <> ocsId (oacSpec prov)
                     <> " <model-id>"))
    | otherwise =
        sendChatCompletion (oacManager prov) (oacSpec prov) (oacBaseUrl prov)
                           (oacApiKey prov) (encodeRequest cr)
    where
      oacDisplayName = ocsDisplayName (oacSpec prov)

-- Helpers --------------------------------------------------------------------

modelIdText :: ModelId -> Text
modelIdText (ModelId t) = t

-- | Build a text 'Chat.Content' from a 'Text'. The 'Content' type exports no
-- (public) constructors, so we go through its 'IsString' instance.
txt :: Text -> Chat.Content
txt = fromString . T.unpack
