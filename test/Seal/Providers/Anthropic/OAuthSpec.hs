{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.Anthropic.OAuthSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Test.Hspec

import Seal.Providers.Anthropic.OAuth
import Seal.Security.Secrets (mkBearerToken, mkRefreshToken, withBearerToken, withRefreshToken)


spec :: Spec
spec = describe "Seal.Providers.Anthropic.OAuth" $ do

  describe "codeChallenge" $
    -- RFC 7636 Appendix B known-answer vector.
    it "matches the RFC 7636 S256 vector" $
      codeChallenge "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        `shouldBe` "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  describe "buildAuthorizeUrl" $
    it "renders params in the required order with percent-encoding" $
      buildAuthorizeUrl (Pkce "test-verifier" "test-challenge")
        `shouldBe`
        "https://claude.ai/oauth/authorize\
        \?response_type=code\
        \&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e\
        \&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback\
        \&scope=org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference\
        \&state=test-verifier\
        \&code_challenge=test-challenge\
        \&code_challenge_method=S256"

  describe "parsePastedCode" $ do
    it "splits CODE#STATE on the first '#'" $
      parsePastedCode "the-code#the-state" `shouldBe` ("the-code", "the-state")

    it "returns an empty state when no '#' is present" $
      parsePastedCode "just-a-code" `shouldBe` ("just-a-code", "")

    it "splits on the FIRST '#' only" $
      parsePastedCode "code#state#extra" `shouldBe` ("code", "state#extra")

  describe "newPkce" $
    it "produces a 43-char verifier whose challenge matches codeChallenge" $ do
      p <- newPkce
      T.length (pkceVerifier p) `shouldBe` 43
      pkceChallenge p `shouldBe` codeChallenge (TE.encodeUtf8 (pkceVerifier p))

  describe "parseTokenResponse" $ do
    it "parses access/refresh and computes expiresAt = now + expires_in" $ do
      let now = posixSecondsToUTCTime 1000
          v   = object
            [ "access_token"  .= ("acc-1" :: T.Text)
            , "refresh_token" .= ("ref-1" :: T.Text)
            , "expires_in"    .= (3600 :: Int)
            ]
      case parseTokenResponse now v of
        Left e   -> expectationFailure (T.unpack e)
        Right ts -> do
          withBearerToken  (otAccess ts)  id `shouldBe` "acc-1"
          withRefreshToken (otRefresh ts) id `shouldBe` "ref-1"
          otExpiresAt ts `shouldBe` addUTCTime 3600 now

    it "fails clearly when a field is missing" $ do
      let now = posixSecondsToUTCTime 0
          v   = object ["access_token" .= ("only" :: T.Text)]
      case parseTokenResponse now v of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected Left for a malformed token response"

  describe "serializeTokens / deserializeTokens" $
    it "round-trips through the vault blob" $ do
      let ts = OAuthTokens (mkBearerToken "acc-9") (mkRefreshToken "ref-9")
                           (posixSecondsToUTCTime 1700000000)
      case deserializeTokens (serializeTokens ts) of
        Left e    -> expectationFailure (T.unpack e)
        Right ts' -> do
          withBearerToken  (otAccess ts')  id `shouldBe` "acc-9"
          withRefreshToken (otRefresh ts') id `shouldBe` "ref-9"
          otExpiresAt ts' `shouldBe` posixSecondsToUTCTime 1700000000

  describe "authorizationCodeBody" $
    it "builds the authorization_code grant body with the verifier" $
      authorizationCodeBody (Pkce "vrfy" "chal") "the-code" "the-state"
        `shouldBe` object
          [ "grant_type"    .= ("authorization_code" :: T.Text)
          , "client_id"     .= ("9d1c250a-e61b-44d9-88ed-5944d1962f5e" :: T.Text)
          , "code"          .= ("the-code" :: T.Text)
          , "state"         .= ("the-state" :: T.Text)
          , "redirect_uri"  .= ("https://console.anthropic.com/oauth/code/callback" :: T.Text)
          , "code_verifier" .= ("vrfy" :: T.Text)
          ]

  describe "refreshTokenBody" $
    it "builds the refresh_token grant body carrying the refresh token" $ do
      let ts = OAuthTokens (mkBearerToken "acc") (mkRefreshToken "the-refresh")
                           (posixSecondsToUTCTime 0)
      refreshTokenBody ts `shouldBe` object
        [ "grant_type"    .= ("refresh_token" :: T.Text)
        , "client_id"     .= ("9d1c250a-e61b-44d9-88ed-5944d1962f5e" :: T.Text)
        , "refresh_token" .= ("the-refresh" :: T.Text)
        ]

  describe "exchangeCode / refreshTokens (live)" $
    it "needs a real OAuth endpoint" $
      pendingWith "live OAuth flow — exercised manually with a Claude subscription"
