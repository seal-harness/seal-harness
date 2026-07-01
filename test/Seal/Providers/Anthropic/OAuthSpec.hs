{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.Anthropic.OAuthSpec (spec) where

import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Seal.Providers.Anthropic.OAuth

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
