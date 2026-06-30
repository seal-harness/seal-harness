{-# LANGUAGE OverloadedStrings #-}
-- | Anthropic Messages-API provider. JSON mapping is pure ('encodeRequest' /
-- 'decodeResponse'); 'complete' adds the HTTP round-trip and supplies the API
-- key via 'withApiKey' (CPS) so the secret only ever lives on the request
-- header inside the continuation — never returned, never logged. Non-streaming.
module Seal.Providers.Anthropic
  ( Anthropic (..)
  , mkAnthropic
  , encodeRequest
  , decodeResponse
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client

import Seal.Core.Types
import Seal.Providers.Class
import Seal.Security.Secrets

data Anthropic = Anthropic
  { anModel :: ModelId
  , anManager :: Manager
  , anKey :: ApiKey
  }

mkAnthropic :: Manager -> ApiKey -> ModelId -> Anthropic
mkAnthropic mgr key model = Anthropic model mgr key

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
  object [ "type"       .= ("tool_result" :: Text)
         , "tool_use_id" .= i
         , "is_error"   .= isErr
         , "content"    .= [object ["type" .= ("text" :: Text), "text" .= t] | TrpText t <- parts]
         ]

encTool :: ToolDefinition -> Value
encTool (ToolDefinition (OpName n) d sch) =
  object ["name" .= n, "description" .= d, "input_schema" .= sch]

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

-- Provider instance --------------------------------------------------------

instance Provider Anthropic where
  listModels a = pure (Right [anModel a])
  complete a cr = withApiKey (anKey a) $ \keyBytes -> do
    let body = encode (encodeRequest cr)
    initReq <- parseRequest "POST https://api.anthropic.com/v1/messages"
    let req = initReq
          { requestBody    = RequestBodyLBS body
          , requestHeaders =
              [ ("content-type",       "application/json")
              , ("anthropic-version",  "2023-06-01")
              , ("x-api-key",          keyBytes)
              ]
          }
    resp <- httpLbs req (anManager a)
    pure $ case eitherDecode (responseBody resp) of
      Left e  -> Left (T.pack e)
      Right v -> decodeResponse v
