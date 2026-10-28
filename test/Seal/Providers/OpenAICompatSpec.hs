{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the generic OpenAI API provider. Pure coverage for the
-- request/response mapping, base-URL validation and header construction, plus
-- wire-level coverage against a loopback @warp@ mock (no DNS, no egress).
--
-- The old @\"complete (no key) => Left\"@ test is gone: with the key guard
-- removed it would have performed real HTTPS to a public host and still
-- passed. The keyless path is now proven at the wire level instead.
module Seal.Providers.OpenAICompatSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson
  ( Value (Array, Object, String), encode, eitherDecode, object, (.=) )
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as S
import Data.ByteString.Lazy qualified as BL
import Data.Char (isControl, isSpace)
import Data.Either (isLeft, isRight)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
  ( hAuthorization, hContentType, hLocation, status200, status302, status400
  , status401 )
import Network.HTTP.Types.Header (RequestHeaders)
import Network.Wai
  ( Application, pathInfo, requestHeaders, requestMethod, responseLBS
  , strictRequestBody )
import Network.Wai.Handler.Warp (testWithApplication)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen, choose, elements, forAll, vectorOf )

import qualified OpenAI.V1.Chat.Completions as Chat (ChatCompletionObject)

import Seal.Agent.Loop (isTransientError)
import Seal.Core.Types (ModelId (ModelId), OpName (OpName), ToolCallId (ToolCallId))
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..), ContentBlock (..)
  , Message (..), Provider (..), Role (..), StopReason (..), ToolChoice (..)
  , ToolResultPart (..), Usage (..), textMsg )
import Seal.Providers.OpenAICompat
  ( ContentStyle (..), OpenAICompatSpec (..), WireFormat (..), chatHeaders
  , chatUrl, decodeResponse, effectiveWireFormat, encodeRequest
  , httpErrorText, mapFinishReason, mkOpenAICompat, parseContentStyle
  , sendChatCompletion, validateBaseUrl, wantsStringContent, wireBody )
import Seal.Security.Secrets (mkApiKey)

-- ── Fixtures ────────────────────────────────────────────────────────────────

-- | The shipped generic row (mirrors 'Seal.Providers.Registry.genericOpenAICompat').
genericSpec :: OpenAICompatSpec
genericSpec = OpenAICompatSpec
  { ocsId             = "openai"
  , ocsDisplayName    = "OpenAI API"
  , ocsVaultKey       = "OPENAI_API_KEY"
  , ocsBuiltinBaseUrl = Nothing
  , ocsDefaultModel   = Nothing
  , ocsKeyRequired    = False
  , ocsModels         = []
  , ocsExtraHeaders   = []
  }

-- | A preset-shaped row: built-in URL, key required, a model catalogue, and
-- vendor headers including two that must be dropped.
presetSpec :: OpenAICompatSpec
presetSpec = OpenAICompatSpec
  { ocsId             = "acme"
  , ocsDisplayName    = "Acme"
  , ocsVaultKey       = "ACME_API_KEY"
  , ocsBuiltinBaseUrl = Just "https://acme.example/v1"
  , ocsDefaultModel   = Just (ModelId "acme-large")
  , ocsKeyRequired    = True
  , ocsModels         = [ModelId "acme-large", ModelId "acme-small"]
  , ocsExtraHeaders   =
      [ ("x-acme-attribution", "seal")
      , (hAuthorization, "attacker-supplied")
      , (hContentType, "text/plain")
      ]
  }

-- | A minimal request: one user text message, no tools, ToolAuto, 256 tokens.
minimalReq :: CompletionRequest
minimalReq = CompletionRequest
  { crModel = ModelId "acme-large"
  , crSystem = Nothing
  , crMessages = [textMsg User "hello"]
  , crTools = []
  , crToolChoice = ToolAuto
  , crMaxTokens = 256
  }

-- ── JSON helpers ────────────────────────────────────────────────────────────

reqObject :: CompletionRequest -> KM.KeyMap Value
reqObject cr =
  case eitherDecode (wireBody WireString (encodeRequest cr)) :: Either String Value of
    Right (Object o) -> o
    other            -> error ("reqObject: not an object: " <> show other)

bodyObject :: BL.ByteString -> KM.KeyMap Value
bodyObject bs =
  case eitherDecode bs :: Either String Value of
    Right (Object o) -> o
    other            -> error ("bodyObject: not an object: " <> show other)

valAt :: Text -> Value -> Maybe Value
valAt k (Object o) = KM.lookup (fromString (T.unpack k)) o
valAt _ _          = Nothing

strAt :: Text -> KM.KeyMap Value -> Maybe Text
strAt k o = case KM.lookup (fromString (T.unpack k)) o of
  Just (String s) -> Just s
  _               -> Nothing

arrAt :: Text -> KM.KeyMap Value -> Maybe [Value]
arrAt k o = case KM.lookup (fromString (T.unpack k)) o of
  Just (Array a) -> Just (V.toList a)
  _              -> Nothing

roleOf :: Value -> Maybe Text
roleOf (Object mo) = case KM.lookup (fromString "role") mo of
  Just (String s) -> Just s
  _               -> Nothing
roleOf _ = Nothing

-- | A @ChatCompletionObject@ the way an OpenAI API endpoint emits it.
chatObj :: Maybe Text -> Text -> Maybe [Value] -> Value
chatObj mContent finishReason mToolCalls = object
  [ "id" .= ("chatcmpl-1" :: Text)
  , "object" .= ("chat.completion" :: Text)
  , "created" .= (0 :: Int)
  , "model" .= ("acme-large" :: Text)
  , "choices" .=
      [ object
          [ "finish_reason" .= finishReason
          , "index" .= (0 :: Int)
          , "message" .= object
              ( [ "role" .= ("assistant" :: Text)
                , "content" .= mContent
                ]
              <> [ "tool_calls" .= tcArray | Just tcArray <- [mToolCalls] ] )
          ]
      ]
  , "usage" .= object
      [ "prompt_tokens" .= (10 :: Int)
      , "completion_tokens" .= (5 :: Int)
      , "total_tokens" .= (15 :: Int)
      ]
  ]

decodeFromJson :: OpenAICompatSpec -> Value -> Either Text CompletionResponse
decodeFromJson sp v =
  case eitherDecode (encode v) :: Either String Chat.ChatCompletionObject of
    Left e  -> Left ("decode: " <> T.pack e)
    Right o -> decodeResponse sp o

-- ── Base-URL generator (bounded) ─────────────────────────────────────────────

-- | Does the URL carry userinfo (an @\@@ before the first path slash)?
userinfo :: Text -> Bool
userinfo out =
  let afterScheme = T.drop 3 (snd (T.breakOn "://" out))
  in T.any (== '@') (T.takeWhile (/= '/') afterScheme)

genUrl :: Gen Text
genUrl = do
  n <- choose (0, 60)
  T.pack <$> vectorOf n (elements "az09:/@.-[]?\r\n %#")

-- ── Spec ────────────────────────────────────────────────────────────────────

pureSpec :: Spec
pureSpec = describe "Seal.Providers.OpenAICompat" $ do

  describe "encodeRequest" $ do
    it "sets model + tool_choice and emits a user message" $ do
      let o = reqObject minimalReq
      strAt "model" o `shouldBe` Just "acme-large"
      strAt "tool_choice" o `shouldBe` Just "auto"
      case arrAt "messages" o of
        Just [msg] -> roleOf msg `shouldBe` Just "user"
        other      -> expectationFailure ("messages: " <> show other)

    it "emits a leading System message when crSystem is present" $ do
      let o = reqObject minimalReq { crSystem = Just "you are concise" }
      case arrAt "messages" o of
        Just (firstMsg : _) -> roleOf firstMsg `shouldBe` Just "system"
        other               -> expectationFailure ("messages: " <> show other)

    it "emits a tool-role message per CbToolResult, keyed by tool_call_id" $ do
      let cr = minimalReq
            { crMessages = [ Message Assistant
                                [ CbToolUse (ToolCallId "call_1") (OpName "search") (object [])
                                , CbToolResult (ToolCallId "call_1") [TrpText "found it"] False
                                ]
                            ]
            }
      case arrAt "messages" (reqObject cr) of
        Just msgs ->
          case [ m | m <- msgs, roleOf m == Just "tool" ] of
            (Object mo : _) ->
              case KM.lookup (fromString "tool_call_id") mo of
                Just (String "call_1") -> pure ()
                other                 -> expectationFailure ("tool_call_id: " <> show other)
            _ -> expectationFailure "no tool-role message emitted"
        Nothing -> expectationFailure "messages missing"

    it "places a later message's tool result immediately after the assistant tool call" $ do
      -- The agent loop's canonical shape: the assistant message carries the
      -- CbToolUse, a separate user message carries the CbToolResult.
      let cr = minimalReq
            { crMessages =
                [ Message User [CbText "hello"]
                , Message Assistant [CbToolUse (ToolCallId "call_1") (OpName "search") (object [])]
                , Message User [CbToolResult (ToolCallId "call_1") [TrpText "found it"] False]
                , Message Assistant [CbText "done"]
                ]
            }
      case arrAt "messages" (reqObject cr) of
        Just [u1, a1, t1, a2] -> do
          roleOf u1 `shouldBe` Just "user"
          valAt "content" u1 `shouldBe` Just (String "hello")
          roleOf a1 `shouldBe` Just "assistant"
          valAt "tool_calls" a1 `shouldSatisfy` isJust
          roleOf t1 `shouldBe` Just "tool"
          valAt "tool_call_id" t1 `shouldBe` Just (String "call_1")
          valAt "content" t1 `shouldBe` Just (String "found it")
          roleOf a2 `shouldBe` Just "assistant"
        other -> expectationFailure ("messages: " <> show other)

    it "synthesizes a result for a tool call with no recorded result" $ do
      let cr = minimalReq
            { crMessages =
                [ Message Assistant [CbToolUse (ToolCallId "call_9") (OpName "search") (object [])]
                , Message User [CbText "next"]
                ]
            }
      case arrAt "messages" (reqObject cr) of
        Just [a1, t1, u1] -> do
          roleOf a1 `shouldBe` Just "assistant"
          roleOf t1 `shouldBe` Just "tool"
          valAt "tool_call_id" t1 `shouldBe` Just (String "call_9")
          valAt "content" t1
            `shouldBe` Just (String "(no result was recorded for this tool call)")
          roleOf u1 `shouldBe` Just "user"
          valAt "content" u1 `shouldBe` Just (String "next")
        other -> expectationFailure ("messages: " <> show other)

  describe "wireBody WireString" $ do
    it "encodes system and user content as plain JSON strings, not part arrays" $ do
      let o = reqObject minimalReq { crSystem = Just "you are concise" }
      case arrAt "messages" o of
        Just [sysMsg, userMsg] -> do
          valAt "content" sysMsg  `shouldBe` Just (String "you are concise")
          valAt "content" userMsg `shouldBe` Just (String "hello")
        other -> expectationFailure ("messages: " <> show other)

    it "joins multiple text blocks of one message with newlines" $ do
      let cr = minimalReq { crMessages = [Message User [CbText "a", CbText "b"]] }
      case arrAt "messages" (reqObject cr) of
        Just [userMsg] -> valAt "content" userMsg `shouldBe` Just (String "a\nb")
        other         -> expectationFailure ("messages: " <> show other)

    it "emits string tool-result content keyed by tool_call_id" $ do
      let cr = minimalReq
            { crMessages = [ Message Assistant
                                [ CbToolUse (ToolCallId "call_1") (OpName "search") (object [])
                                , CbToolResult (ToolCallId "call_1") [TrpText "found it"] False
                                ]
                            ]
            }
      case arrAt "messages" (reqObject cr) of
        Just [assistantMsg, toolMsg] -> do
          valAt "content" assistantMsg `shouldBe` Nothing
          valAt "tool_calls" assistantMsg `shouldSatisfy` isJust
          valAt "content" toolMsg      `shouldBe` Just (String "found it")
          valAt "tool_call_id" toolMsg `shouldBe` Just (String "call_1")
        other -> expectationFailure ("messages: " <> show other)

    prop "system content round-trips any bounded text as a plain string" $
      forAll (T.pack <$> vectorOf 30 (elements "ab \"\n\\{}[]0")) $ \t ->
        case arrAt "messages" (reqObject minimalReq { crSystem = Just t }) of
          Just (sysMsg : _) -> valAt "content" sysMsg == Just (String t)
          _                 -> False

  describe "parseContentStyle" $ do
    it "accepts exactly auto / parts / string" $ do
      parseContentStyle "auto"   `shouldBe` Just StyleAuto
      parseContentStyle "parts"  `shouldBe` Just StyleParts
      parseContentStyle "string" `shouldBe` Just StyleString

    it "rejects case variants, padding and anything else" $ do
      parseContentStyle "AUTO"     `shouldBe` Nothing
      parseContentStyle "auto "    `shouldBe` Nothing
      parseContentStyle ""         `shouldBe` Nothing
      parseContentStyle "sometimes" `shouldBe` Nothing

  describe "wantsStringContent" $ do
    it "matches Magnitude's strict-server 400 body" $ do
      let body = "{\"error\":{\"message\":\"Failed to deserialize the JSON body"
                <> " into the target type: messages[0]: invalid type: sequence,"
                <> " expected a string at line 1 column 30706\",\"type\":"
                <> "\"invalid_request_error\",\"code\":\"invalid_request\"}}"
      wantsStringContent body `shouldBe` True

    it "rejects a tools-shape error and a body with no messages pointer" $ do
      wantsStringContent
        "tools[0]: invalid type: sequence, expected a string at line 1 column 4"
        `shouldBe` False
      wantsStringContent
        "invalid type: sequence, expected a string but the reason is elsewhere"
        `shouldBe` False

  describe "effectiveWireFormat" $ do
    it "fixed styles bypass the memo" $ do
      memo <- newIORef Map.empty
      effectiveWireFormat StyleParts memo "https://h/v1" >>= (`shouldBe` WireParts)
      effectiveWireFormat StyleString memo "https://h/v1" >>= (`shouldBe` WireString)

    it "auto defaults to parts with an untouched memo" $ do
      memo <- newIORef Map.empty
      effectiveWireFormat StyleAuto memo "https://h/v1" >>= (`shouldBe` WireParts)

    it "auto follows a memo hit for the base URL only" $ do
      memo <- newIORef (Map.fromList [("https://h/v1", WireString)])
      effectiveWireFormat StyleAuto memo "https://h/v1" >>= (`shouldBe` WireString)
      effectiveWireFormat StyleAuto memo "https://other/v1" >>= (`shouldBe` WireParts)

  describe "wireBody" $ do
    it "parts emits the openai-package content-part arrays" $ do
      let o = bodyObject (wireBody WireParts (encodeRequest minimalReq { crSystem = Just "s" }))
      case arrAt "messages" o of
        Just [sysMsg, _userMsg] ->
          valAt "content" sysMsg `shouldBe` Just (Array (V.fromList [object ["type" .= ("text" :: Text), "text" .= ("s" :: Text)]]))
        other -> expectationFailure ("messages: " <> show other)

    it "string emits plain-string content, matching encodeRequestBody" $ do
      let o = bodyObject (wireBody WireString (encodeRequest minimalReq { crSystem = Just "s" }))
      case arrAt "messages" o of
        Just [sysMsg, userMsg] -> do
          valAt "content" sysMsg  `shouldBe` Just (String "s")
          valAt "content" userMsg `shouldBe` Just (String "hello")
        other -> expectationFailure ("messages: " <> show other)

  describe "mapFinishReason" $
    it "maps stop / tool_calls / tool_use / length / unknown" $ do
      mapFinishReason "stop"           `shouldBe` StopEnd
      mapFinishReason "tool_calls"     `shouldBe` StopToolUse
      mapFinishReason "tool_use"       `shouldBe` StopToolUse
      mapFinishReason "length"         `shouldBe` StopMaxTokens
      mapFinishReason "content_filter" `shouldBe` StopOther "content_filter"

  describe "decodeResponse" $ do
    it "decodes a plain assistant text choice with stop + usage" $
      case decodeFromJson genericSpec (chatObj (Just "hi") "stop" Nothing) of
        Left e -> expectationFailure ("Left: " <> T.unpack e)
        Right (CompletionResponse blocks stop (Usage i o)) -> do
          blocks `shouldBe` [CbText "hi"]
          stop   `shouldBe` StopEnd
          (i, o) `shouldBe` (10, 5)

    it "decodes tool_calls into CbToolUse with the upstream id + name" $ do
      let tc = object
            [ "id" .= ("call_9" :: Text)
            , "type" .= ("function" :: Text)
            , "function" .= object
                [ "name" .= ("search" :: Text)
                , "arguments" .= ("{\"q\":\"rust\"}" :: Text)
                ]
            ]
      case decodeFromJson genericSpec (chatObj Nothing "tool_calls" (Just [tc])) of
        Left e -> expectationFailure ("Left: " <> T.unpack e)
        Right (CompletionResponse blocks stop _) -> do
          stop `shouldBe` StopToolUse
          case blocks of
            [CbToolUse tcid (OpName n) _] -> do
              tcid `shouldBe` ToolCallId "call_9"
              n    `shouldBe` "search"
            other -> expectationFailure ("blocks: " <> show other)

    it "names the provider when there are no choices" $ do
      let emptyObj = object
            [ "id" .= ("chatcmpl-2" :: Text)
            , "object" .= ("chat.completion" :: Text)
            , "created" .= (0 :: Int)
            , "model" .= ("acme-large" :: Text)
            , "choices" .= ([] :: [Value])
            , "usage" .= object
                [ "prompt_tokens" .= (0 :: Int)
                , "completion_tokens" .= (0 :: Int)
                , "total_tokens" .= (0 :: Int)
                ]
            ]
      case decodeFromJson presetSpec emptyObj of
        Left e  -> e `shouldSatisfy` ("Acme returned no choices" ==)
        Right _ -> expectationFailure "expected Left"

  describe "chatHeaders" $ do
    it "sends no authorization header when there is no key" $ do
      let hdrs = chatHeaders Nothing genericSpec
      lookup hAuthorization hdrs `shouldBe` Nothing
      lookup hContentType hdrs `shouldBe` Just "application/json"

    it "puts the key bytes only in the Bearer header" $ do
      let hdrs = chatHeaders (Just (mkApiKey "sk-test-key")) genericSpec
      lookup hAuthorization hdrs `shouldBe` Just "Bearer sk-test-key"
      [ () | (_, v) <- hdrs, v == ("sk-test-key" :: ByteString) ] `shouldBe` []

    it "appends vendor headers but drops the ones Seal owns" $ do
      let hdrs = chatHeaders (Just (mkApiKey "sk-test-key")) presetSpec
      lookup "x-acme-attribution" hdrs `shouldBe` Just "seal"
      lookup hAuthorization hdrs `shouldBe` Just "Bearer sk-test-key"
      lookup hContentType hdrs `shouldBe` Just "application/json"

  describe "validateBaseUrl" $ do
    it "accepts http(s) URLs, IPv4, hostnames and bracketed IPv6" $ do
      validateBaseUrl "https://h/v1"                 `shouldBe` Right "https://h/v1"
      validateBaseUrl "http://localhost:8000/v1"     `shouldBe` Right "http://localhost:8000/v1"
      validateBaseUrl "http://192.168.1.10:11434"    `shouldBe` Right "http://192.168.1.10:11434"
      validateBaseUrl "http://[::1]:8000/v1"         `shouldBe` Right "http://[::1]:8000/v1"
      validateBaseUrl "https://h"                    `shouldBe` Right "https://h"

    it "lowercases only the scheme" $
      validateBaseUrl "HTTPS://Host/v1" `shouldBe` Right "https://Host/v1"

    it "strips surrounding whitespace and every trailing slash" $ do
      validateBaseUrl "  https://h/v1//  " `shouldBe` Right "https://h/v1"
      validateBaseUrl "https://h/"         `shouldBe` Right "https://h"

    it "rejects empty and whitespace-only input" $ do
      validateBaseUrl ""    `shouldBe` Left "empty"
      validateBaseUrl "   " `shouldBe` Left "empty"
      validateBaseUrl "\t"  `shouldBe` Left "empty"

    it "requires an http(s) scheme" $
      map validateBaseUrl ["h/v1", "//h/v1", "http:/h", "ftp://h/v1", "file:///v1", "ws://h"]
        `shouldBe` replicate 6 (Left "scheme must be http or https")

    it "requires a host" $ do
      validateBaseUrl "https://"       `shouldBe` Left "host required"
      validateBaseUrl "http://:8000/v1" `shouldBe` Left "host required"

    it "rejects userinfo" $ do
      validateBaseUrl "https://user:pw@h/v1" `shouldBe` Left "userinfo is not allowed"
      validateBaseUrl "https://user@h/v1"    `shouldBe` Left "userinfo is not allowed"

    it "rejects whitespace and control characters (header injection)" $ do
      validateBaseUrl "https://h/v1\r\nHost: evil"
        `shouldBe` Left "whitespace or control characters"
      validateBaseUrl "https://h/v1 x"
        `shouldBe` Left "whitespace or control characters"

    it "rejects an out-of-range port" $ do
      validateBaseUrl "https://h:99999/v1" `shouldBe` Left "port out of range"
      validateBaseUrl "https://h:abc/v1"   `shouldBe` Left "port out of range"

    it "rejects a query or fragment" $ do
      validateBaseUrl "https://h/v1?x=1" `shouldBe` Left "query or fragment is not allowed"
      validateBaseUrl "https://h/v1#f"   `shouldBe` Left "query or fragment is not allowed"

    prop "never accepts whitespace/control chars or userinfo" $
      forAll genUrl $ \u ->
        case validateBaseUrl u of
          Left _    -> True
          Right out -> not (T.any (\c -> isSpace c || isControl c) out)
                         && not (userinfo out)

    prop "is idempotent on its own output" $
      forAll genUrl $ \u ->
        case validateBaseUrl u of
          Left _     -> True
          Right out  -> validateBaseUrl out == Right out

  describe "chatUrl" $ do
    it "joins exactly one slash" $ do
      chatUrl "https://h/v1"  `shouldBe` "https://h/v1/chat/completions"
      chatUrl "https://h/v1/" `shouldBe` "https://h/v1/chat/completions"

    prop "never yields a doubled slash" $
      forAll genUrl $ \u ->
        case validateBaseUrl u of
          Left _    -> True
          Right out -> let url = chatUrl out
                       in T.isSuffixOf "/chat/completions" url
                            && not ("//chat/completions" `T.isInfixOf` url)

  describe "httpErrorText" $ do
    it "gives keyed and keyless 401s different, actionable copy" $ do
      let keyed = httpErrorText presetSpec 401 "denied"
          keyless = httpErrorText genericSpec 401 "denied"
      keyed `shouldSatisfy` ("re-enter it" `T.isInfixOf`)
      keyed `shouldSatisfy` ("/provider add acme" `T.isInfixOf`)
      keyless `shouldSatisfy` ("requires an API key" `T.isInfixOf`)
      keyless `shouldSatisfy` ("Providers view" `T.isInfixOf`)

    it "treats 403 like 401" $
      httpErrorText genericSpec 403 "no" `shouldSatisfy` ("requires an API key" `T.isInfixOf`)

    it "names the missing API path and the model on 404" $ do
      let msg = httpErrorText genericSpec 404 "not found"
      msg `shouldSatisfy` ("/v1" `T.isInfixOf`)
      msg `shouldSatisfy` ("model id" `T.isInfixOf`)

    it "keeps the retry-compatible 429 wording" $
      httpErrorText genericSpec 429 "" `shouldSatisfy` ("HTTP 429" `T.isInfixOf`)

    it "single-lines and truncates a long body" $ do
      let body = T.unlines (replicate 400 "x")
          msg  = httpErrorText genericSpec 500 body
      T.length msg `shouldSatisfy` (<= 2200)
      T.count "\n" msg `shouldBe` 0

    it "renders a 3xx as a refused redirect" $ do
      let msg = httpErrorText genericSpec 302 ""
      msg `shouldSatisfy` ("redirect" `T.isInfixOf`)
      msg `shouldSatisfy` ("refused for security" `T.isInfixOf`)
      isTransientError msg `shouldBe` False

  describe "sendChatCompletion" $
    it "returns Left (never an exception) for an unparseable base URL" $ do
      mgr <- newTlsManager
      memo <- newIORef Map.empty
      r <- sendChatCompletion mgr genericSpec "http://" Nothing StyleAuto memo (encodeRequest minimalReq)
      r `shouldSatisfy` isLeft

  describe "complete (no model)" $
    it "reports the missing model without touching the network" $ do
      mgr <- newTlsManager
      memo <- newIORef Map.empty
      let prov = mkOpenAICompat mgr Nothing "http://127.0.0.1:1" (ModelId "") genericSpec StyleAuto memo
      r <- complete prov minimalReq { crModel = ModelId "" }
      case r of
        Left e -> do
          e `shouldSatisfy` ("has no model selected" `T.isInfixOf`)
          e `shouldSatisfy` ("/model use openai" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "listModels" $ do
    it "advertises the catalogue plus the configured model, deduped" $ do
      mgr <- newTlsManager
      memo <- newIORef Map.empty
      let prov = mkOpenAICompat mgr Nothing "http://127.0.0.1:1" (ModelId "acme-large") presetSpec StyleAuto memo
      r <- listModels prov
      r `shouldBe` Right [ModelId "acme-large", ModelId "acme-small"]

    it "never reports an empty model id" $ do
      mgr <- newTlsManager
      memo <- newIORef Map.empty
      let prov = mkOpenAICompat mgr Nothing "http://127.0.0.1:1" (ModelId "") genericSpec StyleAuto memo
      r <- listModels prov
      r `shouldBe` Right []

-- ── Wire-level (loopback only) ───────────────────────────────────────────────

data Seen = Seen
  { seenMethod  :: !ByteString
  , seenPath    :: ![Text]
  , seenHeaders :: !RequestHeaders
  , seenBody    :: !BL.ByteString
  }

cannedBody :: BL.ByteString
cannedBody = encode (chatObj (Just "hi") "stop" Nothing)

-- | Magnitude's verbatim strict-server 400 body: serde rejects the
-- content-part array.
serde400 :: BL.ByteString
serde400 = encode (object
  [ "error" .= object
    [ "message" .= ("Failed to deserialize the JSON body into the target type: messages[0]: invalid type: sequence, expected a string at line 1 column 30706" :: Text)
    , "type" .= ("invalid_request_error" :: Text)
    , "code" .= ("invalid_request" :: Text)
    ]
  ])

-- | The strict-server 400 for a tool call whose result does not immediately
-- follow the assistant message (Magnitude's verbatim wording).
ordering400 :: Text -> BL.ByteString
ordering400 badId = encode (object
  [ "error" .= object
    [ "message" .= ("assistant tool call " <> badId <> " has no immediately following result" :: Text)
    , "type" .= ("invalid_request_error" :: Text)
    , "code" .= ("invalid_request" :: Text)
    ]
  ])

-- | The first assistant tool-call id in the message list whose result does
-- not immediately follow its assistant message ('Nothing' when the
-- conversation satisfies the strict-server ordering rule).
firstUncoveredCall :: [Value] -> Maybe Text
firstUncoveredCall [] = Nothing
firstUncoveredCall (m : rest) = case roleOf m of
  Just "assistant" -> case valAt "tool_calls" m of
    Just (Array calls) ->
      let ids = mapMaybe callIdOf (V.toList calls)
      in case cover ids rest of
           (Nothing, rest') -> firstUncoveredCall rest'
           (Just bad, _)    -> Just bad
    _ -> firstUncoveredCall rest
  _ -> firstUncoveredCall rest
  where
    callIdOf (Object o) = case KM.lookup (fromString "id") o of
      Just (String s) -> Just s
      _               -> Nothing
    callIdOf _ = Nothing
    cover [] ms = (Nothing, ms)
    cover (i : is) ms = case ms of
      (n : ms')
        | roleOf n == Just "tool"
        , valAt "tool_call_id" n == Just (String i) -> cover is ms'
      _ -> (Just i, ms)

-- | A strict OpenAI-compatible server: content-part arrays are rejected with
-- the serde 400, plain-string content gets the canned 200. Counts POSTs and
-- records each request body in order.
strictApp :: IORef Int -> IORef [BL.ByteString] -> Application
strictApp posts bodies req respond = do
  body <- strictRequestBody req
  modifyIORef' posts (+ 1)
  modifyIORef' bodies (++ [body])
  let bs = S.toStrict body
  if S.isInfixOf "\"content\":[" bs
    then respond (responseLBS status400 [] serde400)
    else case eitherDecode body :: Either String Value of
      Right (Object o) -> case arrAt "messages" o >>= firstUncoveredCall of
        Just badId -> respond (responseLBS status400 [] (ordering400 badId))
        Nothing    -> respond (responseLBS status200 [] cannedBody)
      _ -> respond (responseLBS status200 [] cannedBody)

-- | Run a warp mock on an ephemeral loopback port, recording the last request.
withRecording :: IORef (Maybe Seen) -> Application -> (Int -> IO a) -> IO a
withRecording ref app = testWithApplication (pure inner)
  where
    inner req respond = do
      body <- strictRequestBody req
      writeIORef ref (Just (Seen (requestMethod req) (pathInfo req) (requestHeaders req) body))
      app req respond

loopbackBase :: Int -> Text -> Text
loopbackBase port suffix = "http://127.0.0.1:" <> T.pack (show port) <> suffix

-- | The recorded request, or a test failure.
seenOrFail :: IORef (Maybe Seen) -> IO Seen
seenOrFail ref = do
  m <- readIORef ref
  maybe (expectationFailure "the mock server received no request" >> pure emptySeen) pure m
  where
    emptySeen = Seen "" [] [] ""

-- ── Wire-level (loopback only) ───────────────────────────────────────────────

wireSpec :: Spec
wireSpec = describe "wire behaviour (loopback warp mock)" $ do

  it "posts to <base>/chat/completions without an authorization header when keyless" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    withRecording ref (\_ respond -> respond (responseLBS status200 [] cannedBody)) $ \port -> do
      let base = loopbackBase port "/openai/v1/"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleAuto memo
      r <- complete prov minimalReq
      r `shouldSatisfy` isRight
      seen <- seenOrFail ref
      seenMethod seen `shouldBe` "POST"
      seenPath seen `shouldBe` ["openai", "v1", "chat", "completions"]
      lookup hAuthorization (seenHeaders seen) `shouldBe` Nothing

  it "sends plain-string message content on the wire when style is string" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    withRecording ref (\_ respond -> respond (responseLBS status200 [] cannedBody)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleString memo
      r <- complete prov minimalReq { crSystem = Just "you are concise" }
      r `shouldSatisfy` isRight
      seen <- seenOrFail ref
      case eitherDecode (seenBody seen) :: Either String Value of
        Left e    -> expectationFailure ("wire body undecodable: " <> e)
        Right (Object o) -> case arrAt "messages" o of
          Just [sysMsg, userMsg] -> do
            valAt "content" sysMsg  `shouldBe` Just (String "you are concise")
            valAt "content" userMsg `shouldBe` Just (String "hello")
          other -> expectationFailure ("wire messages: " <> show other)
        Right v -> expectationFailure ("wire body is not an object: " <> show v)

  it "sends the stored key as a Bearer header" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    withRecording ref (\_ respond -> respond (responseLBS status200 [] cannedBody)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr (Just (mkApiKey "sk-wire")) base (ModelId "acme-large") genericSpec StyleAuto memo
      r <- complete prov minimalReq
      r `shouldSatisfy` isRight
      seen <- seenOrFail ref
      lookup hAuthorization (seenHeaders seen) `shouldBe` Just "Bearer sk-wire"

  it "refuses a redirect instead of following it, and does not retry it" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    let app _req respond =
          respond (responseLBS status302 [(hLocation, "/elsewhere")] "")
    withRecording ref app $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleAuto memo
      r <- complete prov minimalReq
      case r of
        Left e -> do
          e `shouldSatisfy` ("refused for security" `T.isInfixOf`)
          e `shouldSatisfy` ("HTTP 302" `T.isInfixOf`)
          isTransientError e `shouldBe` False
        Right _ -> expectationFailure "expected Left"
      seen <- seenOrFail ref
      -- The redirect target was never requested: only the original path is seen.
      seenPath seen `shouldBe` ["v1", "chat", "completions"]

  it "reports a keyless 401 with the store-a-key guidance" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    withRecording ref (\_ respond -> respond (responseLBS status401 [] "denied")) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleAuto memo
      r <- complete prov minimalReq
      case r of
        Left e -> do
          e `shouldSatisfy` ("requires an API key" `T.isInfixOf`)
          e `shouldSatisfy` ("Providers view" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  it "downgrades to string content after a strict 400 and remembers it" $ do
    posts <- newIORef (0 :: Int)
    bodies <- newIORef []
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    testWithApplication (pure (strictApp posts bodies)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleAuto memo
      r1 <- complete prov minimalReq { crSystem = Just "you are concise" }
      r1 `shouldSatisfy` isRight
      n1 <- readIORef posts
      n1 `shouldBe` 2
      bs1 <- readIORef bodies
      case bs1 of
        [first, second] -> do
          first  `shouldSatisfy` (S.isInfixOf "\"content\":[" . S.toStrict)
          second `shouldSatisfy` (S.isInfixOf "\"content\":\"you are concise\"" . S.toStrict)
        _ -> expectationFailure ("expected exactly 2 POSTs, saw " <> show n1)
      -- The memo held: the next turn (a fresh provider value, same memo)
      -- sends exactly one string POST.
      r2 <- complete prov minimalReq
      r2 `shouldSatisfy` isRight
      readIORef posts >>= (`shouldBe` 3)
      readIORef memo >>= (`shouldBe` Map.fromList [(base, WireString)])

  it "parts style surfaces the 400 and never downgrades" $ do
    posts <- newIORef (0 :: Int)
    bodies <- newIORef []
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    testWithApplication (pure (strictApp posts bodies)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleParts memo
      r <- complete prov minimalReq
      case r of
        Left e -> e `shouldSatisfy` ("invalid type: sequence" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"
      readIORef posts >>= (`shouldBe` 1)
      readIORef memo >>= (`shouldBe` Map.empty)

  it "string style posts strings first try on a strict server" $ do
    posts <- newIORef (0 :: Int)
    bodies <- newIORef []
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    testWithApplication (pure (strictApp posts bodies)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleString memo
      r <- complete prov minimalReq { crSystem = Just "s" }
      r `shouldSatisfy` isRight
      readIORef posts >>= (`shouldBe` 1)
      readIORef memo >>= (`shouldBe` Map.empty)
      readIORef bodies >>= \case
        [b] -> b `shouldSatisfy` (S.isInfixOf "\"content\":\"s\"" . S.toStrict)
        _   -> expectationFailure "expected exactly 1 POST"

  it "concurrent probes converge on the downgrade without losing updates" $ do
    posts <- newIORef (0 :: Int)
    bodies <- newIORef []
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    testWithApplication (pure (strictApp posts bodies)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleAuto memo
          go m = putMVar m =<< complete prov minimalReq
      m1 <- newEmptyMVar
      m2 <- newEmptyMVar
      _ <- forkIO (go m1)
      _ <- forkIO (go m2)
      r1 <- takeMVar m1
      r2 <- takeMVar m2
      r1 `shouldSatisfy` isRight
      r2 `shouldSatisfy` isRight
      readIORef posts >>= \n -> do
        -- Each thread probes parts first unless the memo is already flipped:
        -- 3 when the loser sees the winner's memo, 4 when both probe.
        n `shouldSatisfy` (\c -> c >= 3 && c <= 4)
      readIORef memo >>= (`shouldBe` Map.fromList [(base, WireString)])

  it "sends each tool result immediately after its tool call (strict servers enforce order)" $ do
    posts <- newIORef (0 :: Int)
    bodies <- newIORef []
    mgr <- newTlsManager
    memo <- newIORef Map.empty
    testWithApplication (pure (strictApp posts bodies)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec StyleAuto memo
          conv =
            [ Message User [CbText "hello"]
            , Message Assistant
                [ CbToolUse (ToolCallId "call_1") (OpName "search") (object [])
                , CbToolUse (ToolCallId "call_2") (OpName "search") (object [])
                ]
            , Message User
                [ CbToolResult (ToolCallId "call_2") [TrpText "second"] False
                , CbToolResult (ToolCallId "call_1") [TrpText "first"] False
                ]
            , Message Assistant [CbText "done"]
            ]
      r <- complete prov minimalReq { crMessages = conv }
      r `shouldSatisfy` isRight
      readIORef posts >>= (`shouldBe` 2)  -- parts probe + string retry, both ordered
      bs <- readIORef bodies
      case reverse bs of
        (final : _) -> case eitherDecode final :: Either String Value of
          Right (Object o) -> case arrAt "messages" o of
            Just msgs -> case msgs of
              [u1, a1, t1, t2, a2] -> do
                roleOf u1 `shouldBe` Just "user"
                roleOf a1 `shouldBe` Just "assistant"
                roleOf t1 `shouldBe` Just "tool"
                roleOf t2 `shouldBe` Just "tool"
                roleOf a2 `shouldBe` Just "assistant"
                -- results follow the assistant's tool-call ORDER, not arrival order
                valAt "tool_call_id" t1 `shouldBe` Just (String "call_1")
                valAt "content" t1      `shouldBe` Just (String "first")
                valAt "tool_call_id" t2 `shouldBe` Just (String "call_2")
                valAt "content" t2      `shouldBe` Just (String "second")
              other -> expectationFailure ("messages shape: " <> show other)
            other -> expectationFailure ("messages: " <> show other)
          other -> expectationFailure ("undecodable body: " <> show other)
        [] -> expectationFailure "no request bodies recorded"

-- ── Suite ───────────────────────────────────────────────────────────────────

spec :: Spec
spec = pureSpec >> wireSpec
