{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.OllamaSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Monad (replicateM, zipWithM_, (<=<))
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List (group, sort)
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

  -- Regression: the previous two-step read-then-advance counter raced under
  -- concurrency, so two overlapping responses could both synthesize "call_0"
  -- (observed in the wild in session 20260718-210934-264). The fix is a single
  -- atomic claim of the whole range. This test hammers 'claimToolCallIds' from
  -- many threads and asserts every claimed id is unique.
  describe "claimToolCallIds (concurrency)" $ do
    it "assigns disjoint id ranges under concurrent callers (no \"call_0\" collision)" $ do
      let threads = 64 :: Int
          perThread = 3 :: Int
      counter <- newIORef 0
      mvars <- replicateM threads newEmptyMVar
      zipWithM_ (\mv -> forkIO . (putMVar mv <=< claimToolCallIds counter)) mvars (repeat perThread)
      xs <- mapM readMVar mvars
      -- Every start index must be distinct (no two threads got the same slot).
      uniqLen xs `shouldBe` threads
      -- The union of all claimed ranges [s, s+perThread) must have no gaps
      -- and no overlaps: exactly threads*perThread distinct ids, covering 0..n-1.
      let allIds = concatMap (\s -> [s .. s + perThread - 1]) xs
      uniqLen allIds `shouldBe` threads * perThread
      (maximum allIds + 1) `shouldBe` threads * perThread

  -- Regression: each turn rebuilds a fresh 'Ollama' value (resolveProvider is
  -- called per-turn), but the tool-call-id counter must be shared across those
  -- instances — otherwise every turn restarts at "call_0" and the frontend's
  -- tool_result index (keyed by tool_use_id) clobbers earlier results. In the
  -- wild (session 20260718-230912-797) FILE_WRITE and FILE_PATCH both got
  -- "call_0", so the failed FILE_PATCH result overwrote the successful
  -- FILE_WRITE status in the web UI. This test asserts the counter is owned
  -- externally to the Ollama value: two mkOllama calls with the same IORef
  -- produce disjoint id ranges.
  describe "shared counter across Ollama instances (cross-turn uniqueness)" $ do
    it "two mkOllama calls with the same IORef advance the same counter (no call_0 repeat)" $ do
      counter <- newIORef 0
      o1 <- mkOllama' counter
      o2 <- mkOllama' counter
      -- Turn 1: claim 2 ids (a response with 2 tool calls).
      s1 <- claimToolCallIds (olCallCounter o1) 2
      -- Turn 2: a fresh Ollama built with the *same* counter.
      s2 <- claimToolCallIds (olCallCounter o2) 2
      -- Disjoint starts, no "call_0" repeat: turn 1 claims 0..1, turn 2 claims 2..3.
      s1 `shouldBe` 0
      s2 `shouldBe` 2
      final <- readIORef counter
      final `shouldBe` 4

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

-- | Number of distinct values (sorted + grouped). Used by the concurrency
-- test to assert that every claimed id is unique.
uniqLen :: [Int] -> Int
uniqLen = length . group . sort

-- | Build a trivial 'Ollama' sharing an externally-owned counter. The manager
-- is 'undefined' (never forced — we only exercise the counter); model/base are
-- placeholders. Used by the cross-turn-uniqueness test to prove the counter
-- lives outside any single 'Ollama' value.
mkOllama' :: IORef Int -> IO Ollama
mkOllama' = mkOllama undefined "" Nothing (ModelId "m")
