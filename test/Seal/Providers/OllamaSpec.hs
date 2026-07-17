{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.OllamaSpec (spec) where

import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text qualified as T
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class
import Seal.Providers.Ollama

spec :: Spec
spec = describe "Seal.Providers.Ollama" $ do

  describe "chatUrl / tagsUrl" $ do
    it "appends the path, stripping one trailing slash" $ do
      chatUrl "http://localhost:11434"  `shouldBe` "http://localhost:11434/api/chat"
      chatUrl "http://localhost:11434/" `shouldBe` "http://localhost:11434/api/chat"
      tagsUrl "https://ollama.com"      `shouldBe` "https://ollama.com/api/tags"

  describe "ollamaHeaders" $ do
    it "local: content-type only, no authorization" $ do
      let hs = ollamaHeaders Nothing
      lookup "content-type"  hs `shouldBe` Just "application/json"
      lookup "authorization" hs `shouldBe` Nothing
    it "cloud: adds a bearer authorization header" $ do
      let hs = ollamaHeaders (Just "k-123")
      lookup "authorization" hs `shouldBe` Just "Bearer k-123"

  describe "encodeRequest" $ do
    it "emits model, stream=false, num_predict, and a user message" $ do
      let req = CompletionRequest (ModelId "llama3.2") Nothing
                  [textMsg User "hi"] [] ToolAuto 4096
      encodeRequest req `shouldBe` object
        [ "model"    .= ("llama3.2" :: String)
        , "stream"   .= False
        , "messages" .= [object [ "role" .= ("user" :: String), "content" .= ("hi" :: String)]]
        , "options"  .= object ["num_predict" .= (4096 :: Int)]
        ]

    it "prepends a system message when crSystem is set" $ do
      let req = CompletionRequest (ModelId "m") (Just "be brief")
                  [textMsg User "hi"] [] ToolAuto 16
      case parseMaybe (withObject "req" (.: "messages")) (encodeRequest req) :: Maybe [Value] of
        Just (m0 : _) -> m0 `shouldBe`
          object ["role" .= ("system" :: String), "content" .= ("be brief" :: String)]
        _ -> expectationFailure "expected a system message first"

    it "encodes a CbToolUse in an assistant message as tool_calls" $ do
      let asst = Message Assistant
                   [CbToolUse (ToolCallId "call_0") (OpName "FILE_READ")
                              (object ["path" .= ("a.txt" :: String)])]
          req = CompletionRequest (ModelId "m") Nothing [asst] [] ToolAuto 16
      case parseMaybe (withObject "req" (.: "messages")) (encodeRequest req) :: Maybe [Value] of
        Just [m] -> m `shouldBe` object
          [ "role" .= ("assistant" :: String)
          , "content" .= ("" :: String)
          , "tool_calls" .=
              [object ["function" .= object
                 [ "name" .= ("FILE_READ" :: String)
                 , "arguments" .= object ["path" .= ("a.txt" :: String)]]]]
          ]
        _ -> expectationFailure "expected one assistant message"

    it "expands a User message of tool results into ordered tool messages" $ do
      let user = Message User
                   [ CbToolResult (ToolCallId "call_0") [TrpText "one"] False
                   , CbToolResult (ToolCallId "call_1") [TrpText "two"] True ]
          req = CompletionRequest (ModelId "m") Nothing [user] [] ToolAuto 16
      parseMaybe (withObject "req" (.: "messages")) (encodeRequest req) `shouldBe`
        Just [ object ["role" .= ("tool" :: String), "content" .= ("one" :: String)]
             , object ["role" .= ("tool" :: String), "content" .= ("[tool error] two" :: String)] ]

    it "includes a tools array only when tools are present" $ do
      let realSchema = object
            [ "type" .= ("object" :: String)
            , "properties" .= object ["path" .= object ["type" .= ("string" :: String)]]
            ]
          tool = ToolDefinition (OpName "FILE_READ") "read a file" realSchema
          req  = CompletionRequest (ModelId "m") Nothing [textMsg User "hi"]
                   [tool] ToolAuto 16
      case parseMaybe (withObject "req" (.: "tools")) (encodeRequest req) :: Maybe [Value] of
        Just [t] -> t `shouldBe` object
          [ "type" .= ("function" :: String)
          , "function" .= object
              [ "name" .= ("FILE_READ" :: String)
              , "description" .= ("read a file" :: String)
              , "parameters" .= realSchema ]
          ]
        _ -> expectationFailure "expected one tool"

    it "omits parameters when the tool input schema is the on-demand stub" $ do
      let tool = ToolDefinition (OpName "FILE_READ") "read a file" stubSchema
          req  = CompletionRequest (ModelId "m") Nothing [textMsg User "hi"]
                   [tool] ToolAuto 16
      case parseMaybe (withObject "req" (.: "tools")) (encodeRequest req) :: Maybe [Value] of
        Just [t] -> case parseMaybe (withObject "fn" (.: "function")) t of
          Just fn -> do
            fn `shouldBe` object
              [ "name" .= ("FILE_READ" :: String)
              , "description" .= ("read a file" :: String)
              ]
          Nothing -> expectationFailure "expected a function object"
        _ -> expectationFailure "expected one tool"

  describe "decodeResponse" $ do
    it "parses a text-only message with usage and stop=end" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("yo" :: String)]
            , "done_reason" .= ("stop" :: String)
            , "prompt_eval_count" .= (3 :: Int)
            , "eval_count" .= (1 :: Int)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [CbText "yo"] StopEnd (Usage 3 1))

    it "parses tool_calls into CbToolUse with synthesized ids and object args" $ do
      let body = object
            [ "message" .= object
                [ "role" .= ("assistant" :: String)
                , "content" .= ("" :: String)
                , "tool_calls" .=
                    [ object ["function" .= object
                        ["name" .= ("FILE_READ" :: String)
                        , "arguments" .= object ["path" .= ("a.txt" :: String)]]]
                    , object ["function" .= object
                        ["name" .= ("SECRET_GET" :: String)
                        , "arguments" .= object ["name" .= ("K" :: String)]]]
                    ]
                ]
            , "done_reason" .= ("stop" :: String)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse
                [ CbToolUse (ToolCallId "call_0") (OpName "FILE_READ")
                    (object ["path" .= ("a.txt" :: String)])
                , CbToolUse (ToolCallId "call_1") (OpName "SECRET_GET")
                    (object ["name" .= ("K" :: String)]) ]
                StopToolUse
                (Usage 0 0))

    it "maps done_reason=length to StopMaxTokens" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("x" :: String)]
            , "done_reason" .= ("length" :: String)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [CbText "x"] StopMaxTokens (Usage 0 0))

    it "defaults usage counts to zero when absent" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("x" :: String)] ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [CbText "x"] StopEnd (Usage 0 0))

    it "defaults arguments to an empty object when the function omits it" $ do
      let body = object
            [ "message" .= object
                [ "role" .= ("assistant" :: String)
                , "content" .= ("" :: String)
                , "tool_calls" .=
                    [ object ["function" .= object ["name" .= ("FILE_READ" :: String)]] ]
                ]
            , "done_reason" .= ("stop" :: String)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse
                [ CbToolUse (ToolCallId "call_0") (OpName "FILE_READ") (object []) ]
                StopToolUse
                (Usage 0 0))

    it "parses a fully-empty response with no text block, no tool calls, zero usage" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("" :: String)] ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [] StopEnd (Usage 0 0))

  describe "ollamaErrorText / unreachableMsg" $ do
    it "401 points the user at /provider add ollama" $ do
      let m = ollamaErrorText 401 "unauthorized"
      m `shouldSatisfy` T.isInfixOf "401"
      m `shouldSatisfy` T.isInfixOf "/provider add ollama"
    it "other statuses include the code and body" $ do
      let m = ollamaErrorText 400 "bad model"
      m `shouldSatisfy` T.isInfixOf "400"
      m `shouldSatisfy` T.isInfixOf "bad model"
    it "unreachable mentions the base url and how to start ollama" $ do
      let m = unreachableMsg "http://localhost:11434"
      m `shouldSatisfy` T.isInfixOf "http://localhost:11434"
      m `shouldSatisfy` T.isInfixOf "ollama serve"

  describe "Provider Ollama (live)" $
    it "chat + tags round-trip against a running ollama" $
      pendingWith "needs a local `ollama serve` at http://localhost:11434"

  describe "ollamaNeedsKey" $ do
    it "is False for a local daemon" $ do
      ollamaNeedsKey "http://localhost:11434" `shouldBe` False
    it "is False for a LAN host" $ do
      ollamaNeedsKey "http://192.168.1.10:11434" `shouldBe` False
    it "is True for the cloud host" $ do
      ollamaNeedsKey "https://ollama.com" `shouldBe` True
    it "is True for the cloud api host" $ do
      ollamaNeedsKey "https://api.ollama.com" `shouldBe` True
