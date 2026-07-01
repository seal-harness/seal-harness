{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.AnthropicSpec (spec) where

import Data.Aeson
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Anthropic
import Seal.Providers.Anthropic.OAuth (OAuthTokens (..))
import Seal.Providers.Class
import Seal.Security.Secrets (mkBearerToken, mkRefreshToken)

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

  describe "apiKeyHeaders" $
    it "sends x-api-key and no authorization" $ do
      let hs = apiKeyHeaders "sk-123"
      lookup "x-api-key" hs `shouldBe` Just "sk-123"
      lookup "authorization" hs `shouldBe` Nothing
      lookup "anthropic-version" hs `shouldBe` Just "2023-06-01"

  describe "oauthHeaders" $
    it "sends Bearer + oauth beta and no x-api-key" $ do
      let hs = oauthHeaders "tok-abc"
      lookup "authorization" hs `shouldBe` Just "Bearer tok-abc"
      lookup "anthropic-beta" hs `shouldBe` Just "oauth-2025-04-20"
      lookup "x-api-key" hs `shouldBe` Nothing

  describe "ensureFresh" $ do
    it "refreshes, updates the ref, and persists when the token is expired" $ do
      let stale = OAuthTokens (mkBearerToken "old") (mkRefreshToken "old-r")
                              (posixSecondsToUTCTime 0)          -- 1970: expired
          fresh = OAuthTokens (mkBearerToken "new") (mkRefreshToken "new-r")
                              (posixSecondsToUTCTime 4102444800) -- 2100: valid
      ref       <- newIORef stale
      persisted <- newIORef (Nothing :: Maybe OAuthTokens)
      let sess = OAuthSession
            { osTokens  = ref
            , osRefresh = \_ -> pure (Right fresh)
            , osPersist = \t -> writeIORef persisted (Just t)
            }
      r <- ensureFresh sess
      case r of
        Left e   -> expectationFailure (T.unpack e)
        Right ts -> otExpiresAt ts `shouldBe` posixSecondsToUTCTime 4102444800
      readIORef ref >>= \t -> otExpiresAt t `shouldBe` posixSecondsToUTCTime 4102444800
      readIORef persisted >>= \mp ->
        (otExpiresAt <$> mp) `shouldBe` Just (posixSecondsToUTCTime 4102444800)

    it "does NOT refresh when the token is still valid" $ do
      let valid = OAuthTokens (mkBearerToken "ok") (mkRefreshToken "ok-r")
                              (posixSecondsToUTCTime 4102444800) -- 2100
      ref    <- newIORef valid
      called <- newIORef (0 :: Int)
      let sess = OAuthSession
            { osTokens  = ref
            , osRefresh = \_ -> modifyThenFail called
            , osPersist = \_ -> pure ()
            }
      r <- ensureFresh sess
      case r of
        Left e  -> expectationFailure (T.unpack e)
        Right _ -> pure ()
      readIORef called `shouldReturn` 0
  where
    -- osRefresh must never run in the "still valid" case; if it does, record it.
    modifyThenFail ref = do
      modifyIORef' ref (+ 1)
      pure (Left "should not be called")
