{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.AnthropicSpec (spec) where

import Data.Aeson
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class
import Seal.Providers.Anthropic

spec :: Spec
spec = describe "Seal.Providers.Anthropic" $ do
  it "encodeRequest emits model + max_tokens + tagged content" $ do
    let req = CompletionRequest (ModelId "claude-opus-4-8") Nothing
                [textMsg User "hi"] [] ToolAuto 1024
        v = encodeRequest req
    v `shouldBe` object
      [ "model"      .= ("claude-opus-4-8" :: String)
      , "max_tokens" .= (1024 :: Int)
      , "messages"   .= [object [ "role"    .= ("user" :: String)
                                 , "content" .= [object [ "type" .= ("text" :: String)
                                                         , "text" .= ("hi" :: String)]]]]
      ]

  it "decodeResponse parses text + stop_reason + usage" $ do
    let body = object
          [ "content"     .= [object ["type" .= ("text" :: String), "text" .= ("yo" :: String)]]
          , "stop_reason" .= ("end_turn" :: String)
          , "usage"       .= object ["input_tokens" .= (3 :: Int), "output_tokens" .= (1 :: Int)]
          ]
    decodeResponse body `shouldBe`
      Right (CompletionResponse [CbText "yo"] StopEnd (Usage 3 1))

  it "decodeResponse parses a tool_use block" $ do
    let body = object
          [ "content"     .= [object [ "type"  .= ("tool_use" :: String)
                                      , "id"    .= ("tc-1" :: String)
                                      , "name"  .= ("FILE_READ" :: String)
                                      , "input" .= object ["path" .= ("a.txt" :: String)]]]
          , "stop_reason" .= ("tool_use" :: String)
          , "usage"       .= object ["input_tokens" .= (5 :: Int), "output_tokens" .= (2 :: Int)]
          ]
    decodeResponse body `shouldBe`
      Right (CompletionResponse
              [CbToolUse (ToolCallId "tc-1") (OpName "FILE_READ")
                         (object ["path" .= ("a.txt" :: String)])]
              StopToolUse (Usage 5 2))

  it "live completion (opt-in)" $ pendingWith "needs ANTHROPIC_API_KEY"
