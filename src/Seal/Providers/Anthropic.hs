{-# LANGUAGE OverloadedStrings #-}
-- | Anthropic Messages-API provider. JSON mapping is pure ('encodeRequest' /
-- 'decodeResponse'); 'complete' adds the HTTP round-trip and supplies
-- credentials via the CPS accessors ('withApiKey' / 'withBearerToken') so
-- secrets only ever live on the request header inside the continuation —
-- never returned, never logged. Non-streaming.
module Seal.Providers.Anthropic
  ( Anthropic (..)
  , AnthropicAuth (..)
  , OAuthSession (..)
  , mkAnthropic
  , mkAnthropicOAuth
  , ensureFresh
  , apiKeyHeaders
  , oauthHeaders
  , httpErrorText
  , encodeRequest
  , decodeResponse
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Time.Clock (NominalDiffTime, addUTCTime, getCurrentTime)
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Header (RequestHeaders)

import Seal.Core.Types
import Seal.Providers.Anthropic.OAuth (OAuthTokens (..), anthropicBeta, anthropicVersion)
import Seal.Providers.Class
import Seal.Security.Secrets

-- Auth types ---------------------------------------------------------------

-- | How the provider authenticates. OAuth carries a mutable token cell plus
-- injected refresh/persist actions so 'ensureFresh' can rotate tokens in place.
data AnthropicAuth
  = AuthApiKey ApiKey
  | AuthOAuth  OAuthSession

data OAuthSession = OAuthSession
  { osTokens :: IORef OAuthTokens
  , osRefresh :: OAuthTokens -> IO (Either Text OAuthTokens)
  , osPersist :: OAuthTokens -> IO ()
  }

data Anthropic = Anthropic
  { anModel :: ModelId
  , anManager :: Manager
  , anAuth :: AnthropicAuth
  }

mkAnthropic :: Manager -> ApiKey -> ModelId -> Anthropic
mkAnthropic mgr key model = Anthropic model mgr (AuthApiKey key)

mkAnthropicOAuth :: Manager -> OAuthSession -> ModelId -> Anthropic
mkAnthropicOAuth mgr sess model = Anthropic model mgr (AuthOAuth sess)

-- Header builders ----------------------------------------------------------

-- | Refresh this many seconds BEFORE the real expiry, so a token cannot lapse
-- mid-request.
refreshSkew :: NominalDiffTime
refreshSkew = 60

apiKeyHeaders :: ByteString -> RequestHeaders
apiKeyHeaders keyBytes =
  [ ("content-type",      "application/json")
  , ("anthropic-version", TE.encodeUtf8 anthropicVersion)
  , ("x-api-key",         keyBytes)
  ]

oauthHeaders :: ByteString -> RequestHeaders
oauthHeaders accessBytes =
  [ ("content-type",      "application/json")
  , ("anthropic-version", TE.encodeUtf8 anthropicVersion)
  , ("anthropic-beta",    TE.encodeUtf8 anthropicBeta)
  , ("authorization",     "Bearer " <> accessBytes)
  ]

-- | Return current tokens, refreshing first if within 'refreshSkew' of expiry.
-- On refresh success, update the in-memory ref AND persist.
ensureFresh :: OAuthSession -> IO (Either Text OAuthTokens)
ensureFresh sess = do
  toks <- readIORef (osTokens sess)
  now  <- getCurrentTime
  if otExpiresAt toks <= addUTCTime refreshSkew now
    then do
      r <- osRefresh sess toks
      case r of
        Left e    -> pure (Left e)
        Right new -> do
          writeIORef (osTokens sess) new
          osPersist sess new
          pure (Right new)
    else pure (Right toks)

-- Pure request mapping -----------------------------------------------------

encodeRequest :: CompletionRequest -> Value
encodeRequest cr = object $
  [ "model"      .= crModel cr
  , "max_tokens" .= crMaxTokens cr
  , "messages"   .= map encMsg (crMessages cr)
  ]
  <> maybe [] (\s -> ["system" .= s]) (crSystem cr)
  <> ["tools" .= map encTool (crTools cr) | not (null (crTools cr))]

encMsg :: Message -> Value
encMsg (Message r blocks) = object
  [ "role" .= roleText r, "content" .= map encBlock blocks ]

roleText :: Role -> Text
roleText User = "user"
roleText Assistant = "assistant"

encBlock :: ContentBlock -> Value
encBlock (CbText t) = object ["type" .= ("text" :: Text), "text" .= t]
encBlock (CbToolUse (ToolCallId i) (OpName n) inp) =
  object ["type" .= ("tool_use" :: Text), "id" .= i, "name" .= n, "input" .= inp]
encBlock (CbToolResult (ToolCallId i) parts isErr) =
  object [ "type"        .= ("tool_result" :: Text)
         , "tool_use_id" .= i
         , "is_error"    .= isErr
         , "content"     .= [object ["type" .= ("text" :: Text), "text" .= t] | TrpText t <- parts]
         ]

encTool :: ToolDefinition -> Value
encTool (ToolDefinition (OpName n) d sch) =
  -- Omit input_schema entirely when it's the on-demand stub. Anthropic
  -- normally requires input_schema on every tool; sending it only when the
  -- model has a real schema to follow keeps the stub tools (the common case
  -- under on-demand mode) at zero schema-token cost. The model retrieves a
  -- tool's real schema via OPCODE_DESCRIBE before calling it.
  if sch == stubSchema
    then object ["name" .= n, "description" .= d]
    else object ["name" .= n, "description" .= d, "input_schema" .= sch]

-- Pure response mapping ----------------------------------------------------

decodeResponse :: Value -> Either Text CompletionResponse
decodeResponse = mapLeft T.pack . parseEither parseResp
  where mapLeft f = either (Left . f) Right

parseResp :: Value -> Parser CompletionResponse
parseResp = withObject "response" $ \o -> do
  blocks <- o .: "content" >>= mapM parseBlock
  stop   <- parseStop <$> o .: "stop_reason"
  usageV <- o .: "usage"
  uin    <- usageV .: "input_tokens"
  uout   <- usageV .: "output_tokens"
  pure (CompletionResponse blocks stop (Usage uin uout))

parseBlock :: Value -> Parser ContentBlock
parseBlock = withObject "block" $ \o -> do
  ty <- o .: "type" :: Parser Text
  case ty of
    "text"     -> CbText <$> o .: "text"
    "tool_use" -> CbToolUse . ToolCallId <$> o .: "id"
                  <*> (OpName <$> o .: "name")
                  <*> o .: "input"
    other      -> fail ("unknown content block type: " <> T.unpack other)

parseStop :: Text -> StopReason
parseStop "end_turn"   = StopEnd
parseStop "tool_use"   = StopToolUse
parseStop "max_tokens" = StopMaxTokens
parseStop other        = StopOther other

-- HTTP round-trip ----------------------------------------------------------

-- | POST /v1/messages with the given auth headers; decode the response, or
-- return the HTTP status + response body (the body carries no secret).
sendMessages
  :: Manager -> RequestHeaders -> CompletionRequest
  -> IO (Either Text CompletionResponse)
sendMessages mgr hdrs cr = do
  let body = encode (encodeRequest cr)
  initReq <- parseRequest "POST https://api.anthropic.com/v1/messages"
  let req = initReq { requestBody = RequestBodyLBS body, requestHeaders = hdrs }
  result <- try (httpLbs req mgr)
  case result of
    Left (_ :: HttpException) ->
      pure (Left "HTTP request to Anthropic failed (connection or transport error)")
    Right resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then pure $ case eitherDecode (responseBody resp) of
          Left e  -> Left (T.pack e)
          Right v -> decodeResponse v
        else pure $ Left $ httpErrorText code
          (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict (responseBody resp)))

-- | Render a non-2xx Anthropic response into a user-facing message. HTTP 429
-- gets a friendlier hint: the subscription backend's rate-limit body is terse
-- and unhelpful (e.g. @{"error":{"type":"rate_limit_error","message":"Error"}}@),
-- so we explain the likely cause and next steps instead of echoing it. Every
-- other status keeps the full response body, which is diagnostic and key-safe.
httpErrorText :: Int -> Text -> Text
httpErrorText 429 _ =
  "Anthropic rate limit (HTTP 429) — the account behind this credential is being \
  \throttled; a subscription usage cap is the common cause. Wait a moment and \
  \retry, or switch models with /model use."
httpErrorText code body =
  "Anthropic API returned HTTP " <> T.pack (show code) <> ": " <> body

-- Provider instance --------------------------------------------------------

instance Provider Anthropic where
  listModels a = pure (Right [anModel a])
  complete a cr = case anAuth a of
    AuthApiKey key ->
      withApiKey key $ \keyBytes ->
        sendMessages (anManager a) (apiKeyHeaders keyBytes) cr
    AuthOAuth sess -> do
      ef <- ensureFresh sess
      case ef of
        Left e     -> pure (Left e)
        Right toks ->
          withBearerToken (otAccess toks) $ \accessBytes ->
            sendMessages (anManager a) (oauthHeaders accessBytes) cr
