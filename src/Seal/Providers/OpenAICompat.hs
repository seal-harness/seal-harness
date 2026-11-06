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
  , ContentStyle (..)
  , WireFormat (..)
  , parseContentStyle
  , wantsStringContent
  , effectiveWireFormat
  , wireBody
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
import Data.Aeson
  ( Value (Array, Null, Object, String), eitherDecode, encode, object, toJSON
  , (.=) )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.ByteString.Lazy qualified as BL
import Data.Char (isControl, isDigit, isSpace)
import Data.IORef (IORef, atomicModifyIORef', readIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
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
  , stubSchema
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
  , oacContentStyle :: !ContentStyle
    -- ^ The instance's configured policy; 'StyleAuto' downgrades on the
    -- strict-server 400, the pinned styles never change format.
  , oacContentMemo :: !(IORef (Map Text WireFormat))
    -- ^ Process-lifetime memory of observed downgrades, keyed by canonical
    -- base URL. Lives above resolution (the provider value is rebuilt every
    -- turn), owned by the caller — 'Seal.Command.Provider.ProviderRuntime'.
  }

-- | Build an 'OpenAICompat' with an externally-owned 'Manager' and memo.
-- 'Nothing' for the key means the request carries no @authorization@ header
-- (keyless endpoints); whether a key is *required* is a resolution-time policy
-- in 'Seal.Providers.Registry'.
mkOpenAICompat
  :: Manager -> Maybe ApiKey -> Text -> ModelId -> OpenAICompatSpec
  -> ContentStyle -> IORef (Map Text WireFormat) -> OpenAICompat
mkOpenAICompat mgr key base model spec =
  OpenAICompat spec key base model mgr

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
-- are dropped (no OpenAI equivalent); the conversation maps through
-- 'convoOpenAi' (which enforces OpenAI's tool-call ordering rules).
encodeRequest :: CompletionRequest -> Chat.CreateChatCompletion
encodeRequest cr = Chat._CreateChatCompletion
  { Chat.messages = V.fromList (systemMsgs <> convoOpenAi (crMessages cr))
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
      -- Strict OpenAI-compatible servers (Magnitude) REQUIRE the parameters
      -- field outright, so a stub tool cannot omit it the way
      -- 'Seal.Providers.Anthropic.encTool' and 'Seal.Providers.Ollama.encTool'
      -- do. Instead the stub travels inline with a discovery hint in its
      -- JSON Schema description: the field is always present, the schema
      -- stays tiny, and the model is pointed at OPCODE_DESCRIBE for the
      -- real arguments instead of being shown an empty object it may
      -- faithfully call with no arguments.
      OAT.Tool_Function
        ( OAT.Function
            { OAT.description = Just d
            , OAT.name = n
            , OAT.parameters = Just (if sch == stubSchema then onDemandHintSchema else sch)
            , OAT.strict = Nothing
            }
        )

-- | The wire form of a stub-schema tool for OpenAI-compatible servers: the
-- plain stub with the on-demand discovery instruction in the JSON Schema
-- @description@ keyword (see 'stubSchema').
onDemandHintSchema :: Value
onDemandHintSchema = object
  [ "type" .= ("object" :: Text)
  , "description" .= ("This tool's arguments are not shown here (on-demand"
      <> " schemas). Call OPCODE_DESCRIBE with this tool's name to fetch its"
      <> " real input schema before calling it." :: Text)
  ]

-- | Map the Seal conversation onto OpenAI's message rules. The agent loop
-- records an assistant's tool uses and their results in *separate* messages
-- (the results in a following user message, mirroring the Anthropic shape),
-- while OpenAI requires every assistant tool call to be followed immediately
-- by its @tool@-role result. So each assistant message emits its results
-- right after itself, pulled from the whole conversation and ordered to match
-- the assistant's @tool_calls@:
--
-- * a user message whose blocks are all results disappears (it was the
--   results container; a container that also carried text still emits that
--   text as a user message);
-- * a call with no recorded result anywhere (an interrupted or turn-capped
--   call) gets a placeholder result, so the conversation the server
--   validates is well-formed instead of a hard 400.
convoOpenAi :: [Message] -> [Chat.Message (V.Vector Chat.Content)]
convoOpenAi msgs = concatMap emitMsg msgs
  where
    -- First result recorded per call id wins; a duplicate is ignored.
    recorded = foldl' addMsgResults Map.empty msgs
    addMsgResults acc (Message _ blocks) =
      foldl' addResult acc [ b | b@CbToolResult{} <- blocks ]
    addResult acc (CbToolResult (ToolCallId i) parts _) =
      Map.insertWith (\_ old -> old) i parts acc
    addResult acc _ = acc
    emitMsg (Message role blocks) = case role of
      User
        | null textContents -> []
        | otherwise ->
            [ Chat.User { Chat.content = V.fromList textContents, Chat.name = Nothing } ]
      Assistant -> mainMsg : [ resultMsg i | CbToolUse (ToolCallId i) _ _ <- blocks ]
      where
        textContents = [ txt t | CbText t <- blocks ]
        mainMsg = Chat.Assistant
          { Chat.assistant_content =
              if null textContents then Nothing else Just (V.fromList textContents)
          , Chat.tool_calls = case toolCallVec of
              []  -> Nothing
              tcs -> Just (V.fromList tcs)
          , Chat.refusal = Nothing
          , Chat.name = Nothing
          , Chat.assistant_audio = Nothing
          }
        toolCallVec =
          [ mkToolCall i n inp | CbToolUse (ToolCallId i) (OpName n) inp <- blocks ]
    resultMsg i = Chat.Tool
      { Chat.content =
          V.singleton (txt (joinParts (Map.findWithDefault [TrpText noResultText] i recorded)))
      , Chat.tool_call_id = i
      }
    noResultText = "(no result was recorded for this tool call)"
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

-- Content wire format ---------------------------------------------------------

-- | The configured policy for how message content goes on the wire, per
-- provider instance. 'StyleAuto' sends the library-normal content-part
-- arrays and downgrades to plain strings only when the server proves it
-- requires them; 'StyleParts' and 'StyleString' pin one shape.
data ContentStyle
  = StyleAuto
  | StyleParts
  | StyleString
  deriving stock (Eq, Show)

-- | The shape a single request's message content actually takes.
data WireFormat
  = WireParts
    -- ^ the @openai@ package's default: @content@ as an array of
    -- @{\"type\":\"text\",...}@ parts
  | WireString
    -- ^ plain-string @content@, the maximally-compatible form
  deriving stock (Eq, Show)

-- | Parse a 'ContentStyle' from its TOML keyword. Case-sensitive on exactly
-- @auto@ / @parts@ / @string@; 'Nothing' for anything else.
parseContentStyle :: Text -> Maybe ContentStyle
parseContentStyle t
  | t == "auto"   = Just StyleAuto
  | t == "parts"  = Just StyleParts
  | t == "string" = Just StyleString
  | otherwise     = Nothing

-- | Does an HTTP 400 body indicate a server that deserializes @content@ as
-- a plain string and rejects our content-part arrays? Matches the distinctive
-- serde error (the phrasing Magnitude and other Rust servers emit), and
-- requires the pointer to mention @messages@ so a tools-shape error never
-- triggers the string downgrade. Deliberately narrow; the @content_style@
-- override covers servers with different phrasing.
wantsStringContent :: Text -> Bool
wantsStringContent body =
  ("invalid type: sequence, expected a string" `T.isInfixOf` body)
    && ("messages" `T.isInfixOf` body)

-- | The wire format for a call under a policy: fixed styles never consult the
-- memo; 'StyleAuto' starts at 'WireParts' and follows the memo entry for the
-- provider's canonical base URL once a downgrade has been observed.
effectiveWireFormat
  :: ContentStyle -> IORef (Map Text WireFormat) -> Text -> IO WireFormat
effectiveWireFormat style memo baseUrl = case style of
  StyleParts  -> pure WireParts
  StyleString -> pure WireString
  StyleAuto   -> fromMaybe WireParts . Map.lookup baseUrl <$> readIORef memo

-- | Remember that this base URL requires plain-string content, so later
-- requests skip the failed probe.
memoizeStringContent :: IORef (Map Text WireFormat) -> Text -> IO ()
memoizeStringContent memo baseUrl =
  atomicModifyIORef' memo (\m -> (Map.insert baseUrl WireString m, ()))

-- | Encode the request body in the given wire format: 'WireParts' is the
-- @openai@ package's own encoding; 'WireString' collapses text-only content
-- arrays into the plain strings strict servers require.
wireBody :: WireFormat -> Chat.CreateChatCompletion -> BL.ByteString
wireBody WireParts req  = encode req
wireBody WireString req = encode (compactMessages (toJSON req))

-- Wire encoding ---------------------------------------------------------------

-- | Collapse each message's text content-parts array into the plain string a
-- strict server requires (used by 'wireBody' 'WireString'). The @openai@
-- package's types force content into the array shape — fine for
-- api.openai.com, which accepts both, but many self-hosted servers
-- (llama.cpp, TGI, ...) only accept plain-string @content@.

-- | Rewrite each message of the request object with
-- 'compactMessageContent'. Anything without a @messages@ array passes through
-- unchanged.
compactMessages :: Value -> Value
compactMessages (Object o) =
  case KM.lookup "messages" o of
    Just (Array msgs) -> Object (KM.insert "messages" (Array (V.map compactMessageContent msgs)) o)
    _                 -> Object o
compactMessages v = v

-- | Collapse a message's @content@ array into a plain string when every part
-- is a text part (the only kind we emit). Multiple text blocks join with a
-- newline, mirroring 'joinParts'; an empty array becomes the empty string;
-- missing or non-array content is left untouched.
compactMessageContent :: Value -> Value
compactMessageContent (Object mo) =
  case KM.lookup "content" mo of
    Just (Array parts)
      | Just txts <- traverse textPart (V.toList parts) ->
          Object (KM.insert "content" (String (T.intercalate "\n" txts)) mo)
    _ -> Object mo
compactMessageContent v = v

-- | The text of a @{\"type\":\"text\"}@ content part; 'Nothing' for any other
-- shape.
textPart :: Value -> Maybe Text
textPart (Object po) =
  case (KM.lookup "type" po, KM.lookup "text" po) of
    (Just (String "text"), Just (String t)) -> Just t
    _                                       -> Nothing
textPart _ = Nothing

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
-- request parser rejects yields a 'Left' instead of an escaping exception.
-- * Redirects are **refused** (@redirectCount = 0@): following one would
-- re-send the @authorization@ header to an attacker-chosen @Location@.
-- * Under 'StyleAuto' the request goes out in the library-normal
-- content-parts format; if the server answers 400 with the strict-server
-- signature ('wantsStringContent'), the identical request is retried once
-- with plain-string content and the downgrade is memoized per base URL, so
-- later requests skip the failed probe. A failed retry surfaces its own
-- error. Pinned styles never change format.
-- * Non-2xx -> 'httpErrorText'; a transport error -> a 'Left' string whose
-- wording stays compatible with 'Seal.Agent.Loop.isTransientError'.
sendChatCompletion
  :: Manager -> OpenAICompatSpec -> Text -> Maybe ApiKey
  -> ContentStyle -> IORef (Map Text WireFormat)
  -> Chat.CreateChatCompletion -> IO (Either Text CompletionResponse)
sendChatCompletion mgr spec baseUrl mkey style memo req = do
  fmt <- effectiveWireFormat style memo baseUrl
  first' <- post fmt
  case first' of
    Left e -> pure (Left e)
    Right resp
      | ok resp        -> pure (decodeOk resp)
      | downgrade fmt resp -> do
          memoizeStringContent memo baseUrl
          second <- post WireString
          pure $ case second of
            Left e -> Left e
            Right resp2
              | ok resp2    -> decodeOk resp2
              | otherwise   -> Left (errorText resp2)
      | otherwise      -> pure (Left (errorText resp))
  where
    post fmt = do
      attempted <- try @HttpException $ do
        initReq <- parseRequest (T.unpack ("POST " <> chatUrl baseUrl))
        let httpReq = initReq
              { requestBody = RequestBodyLBS (wireBody fmt req)
              , requestHeaders = chatHeaders mkey spec
              , redirectCount = 0
              , shouldStripHeaderOnRedirect = const True
              }
        httpLbs httpReq mgr
      pure (either (Left . exceptionText spec) Right attempted)
    ok resp = let code = statusCode (responseStatus resp)
              in code >= 200 && code <= 299
    bodyText resp = TE.decodeUtf8With TEE.lenientDecode
                      (BL.toStrict (responseBody resp))
    errorText resp = httpErrorText spec (statusCode (responseStatus resp)) (bodyText resp)
    decodeOk resp = case eitherDecode (responseBody resp) of
      Left e    -> Left (unreadableText spec (T.pack e))
      Right obj -> decodeResponse spec obj
    downgrade fmt resp =
      style == StyleAuto
        && fmt == WireParts
        && statusCode (responseStatus resp) == 400
        && wantsStringContent (bodyText resp)

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
      n <> " returned HTTP 404 — check the base URL path (it may be missing"
        <> " /v1) or the model id: " <> clean
  | code == 429 =
      n <> " rate limit (HTTP 429) — wait a moment and retry, or switch models"
        <> " with /model use"
  | code >= 300 && code <= 399 = redirectText spec (Just code)
  | otherwise =
      n <> " returned HTTP " <> codeTxt <> ": " <> clean
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
                           (oacApiKey prov) (oacContentStyle prov) (oacContentMemo prov)
                           (encodeRequest cr)
    where
      oacDisplayName = ocsDisplayName (oacSpec prov)

-- Helpers --------------------------------------------------------------------

modelIdText :: ModelId -> Text
modelIdText (ModelId t) = t

-- | Build a text 'Chat.Content' from a 'Text'. The 'Content' type exports no
-- (public) constructors, so we go through its 'IsString' instance.
txt :: Text -> Chat.Content
txt = fromString . T.unpack
