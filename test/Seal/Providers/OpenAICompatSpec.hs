{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the generic OpenAI-compatible provider. Pure coverage for the
-- request/response mapping, base-URL validation and header construction, plus
-- wire-level coverage against a loopback @warp@ mock (no DNS, no egress).
--
-- The old @\"complete (no key) => Left\"@ test is gone: with the key guard
-- removed it would have performed real HTTPS to a public host and still
-- passed. The keyless path is now proven at the wire level instead.
module Seal.Providers.OpenAICompatSpec (spec) where

import Data.Aeson
  ( Value (Array, Object, String), encode, eitherDecode, object, (.=) )
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isControl, isSpace)
import Data.Either (isLeft, isRight)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
  ( hAuthorization, hContentType, hLocation, status200, status302, status401 )
import Network.HTTP.Types.Header (RequestHeaders)
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod, responseLBS)
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
  ( OpenAICompatSpec (..), chatHeaders, chatUrl, decodeResponse
  , encodeRequest, httpErrorText, mapFinishReason, mkOpenAICompat
  , sendChatCompletion, validateBaseUrl )
import Seal.Security.Secrets (mkApiKey)

-- ── Fixtures ────────────────────────────────────────────────────────────────

-- | The shipped generic row (mirrors 'Seal.Providers.Registry.genericOpenAICompat').
genericSpec :: OpenAICompatSpec
genericSpec = OpenAICompatSpec
  { ocsId             = "openai-compat"
  , ocsDisplayName    = "OpenAI-compatible"
  , ocsVaultKey       = "OPENAI_COMPAT_API_KEY"
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
  case eitherDecode (encode (encodeRequest cr)) :: Either String Value of
    Right (Object o) -> o
    other            -> error ("reqObject: not an object: " <> show other)

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

-- | A @ChatCompletionObject@ the way an OpenAI-compatible endpoint emits it.
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
      r <- sendChatCompletion mgr genericSpec "http://" Nothing (encodeRequest minimalReq)
      r `shouldSatisfy` isLeft

  describe "complete (no model)" $
    it "reports the missing model without touching the network" $ do
      mgr <- newTlsManager
      let prov = mkOpenAICompat mgr Nothing "http://127.0.0.1:1" (ModelId "") genericSpec
      r <- complete prov minimalReq { crModel = ModelId "" }
      case r of
        Left e -> do
          e `shouldSatisfy` ("has no model selected" `T.isInfixOf`)
          e `shouldSatisfy` ("/model use openai-compat" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "listModels" $ do
    it "advertises the catalogue plus the configured model, deduped" $ do
      mgr <- newTlsManager
      let prov = mkOpenAICompat mgr Nothing "http://127.0.0.1:1" (ModelId "acme-large") presetSpec
      r <- listModels prov
      r `shouldBe` Right [ModelId "acme-large", ModelId "acme-small"]

    it "never reports an empty model id" $ do
      mgr <- newTlsManager
      let prov = mkOpenAICompat mgr Nothing "http://127.0.0.1:1" (ModelId "") genericSpec
      r <- listModels prov
      r `shouldBe` Right []

-- ── Wire-level (loopback only) ───────────────────────────────────────────────

data Seen = Seen
  { seenMethod  :: !ByteString
  , seenPath    :: ![Text]
  , seenHeaders :: !RequestHeaders
  }

cannedBody :: BL.ByteString
cannedBody = encode (chatObj (Just "hi") "stop" Nothing)

-- | Run a warp mock on an ephemeral loopback port, recording the last request.
withRecording :: IORef (Maybe Seen) -> Application -> (Int -> IO a) -> IO a
withRecording ref app = testWithApplication (pure inner)
  where
    inner req respond = do
      writeIORef ref (Just (Seen (requestMethod req) (pathInfo req) (requestHeaders req)))
      app req respond

loopbackBase :: Int -> Text -> Text
loopbackBase port suffix = "http://127.0.0.1:" <> T.pack (show port) <> suffix

-- | The recorded request, or a test failure.
seenOrFail :: IORef (Maybe Seen) -> IO Seen
seenOrFail ref = do
  m <- readIORef ref
  maybe (expectationFailure "the mock server received no request" >> pure emptySeen) pure m
  where
    emptySeen = Seen "" [] []

-- ── Wire-level (loopback only) ───────────────────────────────────────────────

wireSpec :: Spec
wireSpec = describe "wire behaviour (loopback warp mock)" $ do

  it "posts to <base>/chat/completions without an authorization header when keyless" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    withRecording ref (\_ respond -> respond (responseLBS status200 [] cannedBody)) $ \port -> do
      let base = loopbackBase port "/openai/v1/"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec
      r <- complete prov minimalReq
      r `shouldSatisfy` isRight
      seen <- seenOrFail ref
      seenMethod seen `shouldBe` "POST"
      seenPath seen `shouldBe` ["openai", "v1", "chat", "completions"]
      lookup hAuthorization (seenHeaders seen) `shouldBe` Nothing

  it "sends the stored key as a Bearer header" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    withRecording ref (\_ respond -> respond (responseLBS status200 [] cannedBody)) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr (Just (mkApiKey "sk-wire")) base (ModelId "acme-large") genericSpec
      r <- complete prov minimalReq
      r `shouldSatisfy` isRight
      seen <- seenOrFail ref
      lookup hAuthorization (seenHeaders seen) `shouldBe` Just "Bearer sk-wire"

  it "refuses a redirect instead of following it, and does not retry it" $ do
    ref <- newIORef Nothing
    mgr <- newTlsManager
    let app _req respond =
          respond (responseLBS status302 [(hLocation, "/elsewhere")] "")
    withRecording ref app $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec
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
    withRecording ref (\_ respond -> respond (responseLBS status401 [] "denied")) $ \port -> do
      let base = loopbackBase port "/v1"
          prov = mkOpenAICompat mgr Nothing base (ModelId "acme-large") genericSpec
      r <- complete prov minimalReq
      case r of
        Left e -> do
          e `shouldSatisfy` ("requires an API key" `T.isInfixOf`)
          e `shouldSatisfy` ("Providers view" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

-- ── Suite ───────────────────────────────────────────────────────────────────

spec :: Spec
spec = pureSpec >> wireSpec
