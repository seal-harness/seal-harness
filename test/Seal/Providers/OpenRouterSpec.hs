{-# LANGUAGE OverloadedStrings #-}
-- | WU-C — real tests for the OpenRouter provider. Exercises the pure
-- request/response mapping + the no-key branch + the static listModels +
-- the bearer header builder, WITHOUT a network round-trip. A live
-- @\/api\/v1\/chat\/completions@ round-trip would need a real key + endpoint;
-- that is out of scope here (guard with 'pendingWith' if added later).
module Seal.Providers.OpenRouterSpec (spec) where

import Data.Aeson
  ( Value (Array, Object, String), encode, eitherDecode, object, (.=) )
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Header (hAuthorization, hContentType)
import Test.Hspec

import qualified OpenAI.V1.Chat.Completions as Chat (ChatCompletionObject)

import Seal.Core.Types (ModelId (ModelId), OpName (OpName), ToolCallId (ToolCallId))
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..), ContentBlock (..)
  , Message (..), Provider (..), Role (..), StopReason (..), ToolChoice (..)
  , ToolResultPart (..), Usage (..), textMsg )
import Seal.Providers.OpenRouter
  ( bearerHeaders, decodeResponse, encodeRequest, mapFinishReason, mkOpenRouter
  , defaultOpenRouterBaseUrl )

-- | A minimal request: one user text message, no tools, ToolAuto, 256 tokens.
minimalReq :: CompletionRequest
minimalReq = CompletionRequest
  { crModel = ModelId "openrouter/default"
  , crSystem = Nothing
  , crMessages = [textMsg User "hello"]
  , crTools = []
  , crToolChoice = ToolAuto
  , crMaxTokens = 256
  }

-- ── JSON traversal helpers (for inspecting the encoded request) ──────────────

-- | Encode a request and decode the JSON back to an Aeson object.
reqObject :: CompletionRequest -> KM.KeyMap Value
reqObject cr =
  case eitherDecode (encode (encodeRequest cr)) :: Either String Value of
    Right (Object o) -> o
    other            -> error ("reqObject: not an object: " <> show other)

-- | Look up a string field.
strAt :: Text -> KM.KeyMap Value -> Maybe Text
strAt k o = case KM.lookup (fromString (T.unpack k)) o of
  Just (String s) -> Just s
  _               -> Nothing

-- | Look up an array field.
arrAt :: Text -> KM.KeyMap Value -> Maybe [Value]
arrAt k o = case KM.lookup (fromString (T.unpack k)) o of
  Just (Array a) -> Just (V.toList a)
  _              -> Nothing

-- | The role string of a message Value (Nothing if not an object).
roleOf :: Value -> Maybe Text
roleOf (Object mo) = case KM.lookup (fromString "role") mo of
  Just (String s) -> Just s
  _               -> Nothing
roleOf _ = Nothing

-- ── Response fixtures ──────────────────────────────────────────────────────

-- | The JSON 'Value' for a @ChatCompletionObject@ the way OpenRouter emits it.
-- @mContent@ drives the assistant message's @content@ (Nothing => null); @finishReason@
-- drives the single choice's @finish_reason@; @mToolCalls@, when present, adds a
-- @tool_calls@ array to the assistant message.
chatObj :: Maybe Text -> Text -> Maybe [Value] -> Value
chatObj mContent finishReason mToolCalls = object
  [ "id" .= ("chatcmpl-1" :: Text)
  , "object" .= ("chat.completion" :: Text)
  , "created" .= (0 :: Int)
  , "model" .= ("openrouter/default" :: Text)
  , "choices" .=
      [ object
          [ "finish_reason" .= finishReason
          , "index" .= (0 :: Int)
          , "message" .= object
              ( [ "role" .= ("assistant" :: Text)
                , "content" .= mContent
                ]
              <> [ "tool_calls" .= tcArray | Just tcArray <- [mToolCalls] ]
              )
          ]
      ]
  , "usage" .= object
      [ "prompt_tokens" .= (10 :: Int)
      , "completion_tokens" .= (5 :: Int)
      , "total_tokens" .= (15 :: Int)
      ]
  ]

-- | Decode a JSON 'Value' as a 'Chat.ChatCompletionObject' and run
-- 'decodeResponse'. Fails the test (Left) if the JSON doesn't parse.
decodeFromJson :: Value -> Either Text CompletionResponse
decodeFromJson v =
  case eitherDecode (encode v) :: Either String Chat.ChatCompletionObject of
    Left e  -> Left ("decode: " <> T.pack e)
    Right o -> decodeResponse o

-- ── Spec ────────────────────────────────────────────────────────────────────

spec :: Spec
spec = describe "Seal.Providers.OpenRouter — WU-C" $ do

  describe "encodeRequest" $ do
    it "sets model + tool_choice and emits a user message" $ do
      let o = reqObject minimalReq
      strAt "model" o `shouldBe` Just "openrouter/default"
      strAt "tool_choice" o `shouldBe` Just "auto"
      case arrAt "messages" o of
        Just [msg] -> roleOf msg `shouldBe` Just "user"
        other      -> expectationFailure ("messages: " <> show other)

    it "emits a leading System message when crSystem is present" $ do
      let cr = minimalReq { crSystem = Just "you are concise" }
          o  = reqObject cr
      case arrAt "messages" o of
        Just (firstMsg : _) -> roleOf firstMsg `shouldBe` Just "system"
        other               -> expectationFailure ("messages: " <> show other)

    it "emits a tool-role message for each CbToolResult, keyed by tool_call_id" $ do
      let cr = minimalReq
            { crMessages = [ Message Assistant
                               [ CbToolUse (ToolCallId "call_1") (OpName "search") (object [])
                               , CbToolResult (ToolCallId "call_1") [TrpText "found it"] False
                               ]
                            ]
            }
          o = reqObject cr
      case arrAt "messages" o of
        Just msgs ->
          case [ m | m <- msgs, roleOf m == Just "tool" ] of
            (Object mo : _) ->
              case KM.lookup (fromString "tool_call_id") mo of
                Just (String "call_1") -> pure ()
                other                 -> expectationFailure ("tool_call_id: " <> show other)
            _ -> expectationFailure "no tool-role message emitted (or not an object)"
        Nothing -> expectationFailure "messages missing"

  describe "mapFinishReason" $ do
    it "maps stop / tool_calls / tool_use / length / content_filter / unknown" $ do
      mapFinishReason "stop"            `shouldBe` StopEnd
      mapFinishReason "tool_calls"      `shouldBe` StopToolUse
      mapFinishReason "tool_use"        `shouldBe` StopToolUse
      mapFinishReason "length"          `shouldBe` StopMaxTokens
      mapFinishReason "content_filter" `shouldBe` StopOther "content_filter"
      mapFinishReason "anything-else"  `shouldBe` StopOther "anything-else"

  describe "decodeResponse" $ do
    it "decodes a plain assistant text choice with stop + usage" $ do
      case decodeFromJson (chatObj (Just "hi") "stop" Nothing) of
        Left e  -> expectationFailure ("Left: " <> T.unpack e)
        Right (CompletionResponse blocks stop (Usage i o)) -> do
          blocks `shouldBe` [CbText "hi"]
          stop   `shouldBe` StopEnd
          (i, o) `shouldBe` (10, 5)

    it "decodes tool_calls into CbToolUse with the upstream id + name" $ do
      let toolCallVal = object
            [ "id" .= ("call_9" :: Text)
            , "type" .= ("function" :: Text)
            , "function" .= object
                [ "name" .= ("search" :: Text)
                , "arguments" .= ("{\"q\":\"rust\"}" :: Text)
                ]
            ]
      case decodeFromJson (chatObj Nothing "tool_calls" (Just [toolCallVal])) of
        Left e -> expectationFailure ("Left: " <> T.unpack e)
        Right (CompletionResponse blocks stop _) -> do
          stop `shouldBe` StopToolUse
          case blocks of
            [CbToolUse tcid (OpName n) _inp] -> do
              tcid `shouldBe` ToolCallId "call_9"
              n    `shouldBe` "search"
            other -> expectationFailure ("blocks: " <> show other)

    it "returns Left when choices is empty" $ do
      let emptyObj = object
            [ "id" .= ("chatcmpl-2" :: Text)
            , "object" .= ("chat.completion" :: Text)
            , "created" .= (0 :: Int)
            , "model" .= ("openrouter/default" :: Text)
            , "choices" .= ([] :: [Value])
            , "usage" .= object
                [ "prompt_tokens" .= (0 :: Int)
                , "completion_tokens" .= (0 :: Int)
                , "total_tokens" .= (0 :: Int)
                ]
            ]
      decodeFromJson emptyObj `shouldSatisfy` isLeft

  describe "complete (no key)" $ do
    it "returns Left when the API key is absent" $ do
      mgr <- newTlsManager
      let prov = mkOpenRouter mgr Nothing defaultOpenRouterBaseUrl (ModelId "openrouter/default")
      r <- complete prov minimalReq
      r `shouldSatisfy` isLeft

  describe "listModels" $ do
    it "returns Right with the default model" $ do
      mgr <- newTlsManager
      let prov = mkOpenRouter mgr Nothing defaultOpenRouterBaseUrl (ModelId "openrouter/default")
      r <- listModels prov
      r `shouldBe` Right [ModelId "openrouter/default"]

  describe "bearerHeaders" $ do
    it "puts the raw key bytes only in Authorization: Bearer + json content-type" $ do
      let hdrs = bearerHeaders ("sk-test-key" :: ByteString)
      lookup hAuthorization hdrs `shouldBe` Just "Bearer sk-test-key"
      lookup hContentType hdrs `shouldBe` Just "application/json"
      -- No header's VALUE is the bare key (the key only appears inside the
      -- Bearer prefix in authorization).
      [ () | (_, v) <- hdrs, v == ("sk-test-key" :: ByteString) ] `shouldBe` []