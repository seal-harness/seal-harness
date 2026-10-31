{-# LANGUAGE OverloadedStrings #-}
-- | The grant record, its codec, and the authority resolver (design §7.1–§7.2).
--
-- The resolver is the gate round 4 B-1 fix, so the regression is asserted by
-- name: a cookie-only client that omits the header must not be able to redeem a
-- live assertion grant. Rev 4 let an absent token fall through to the
-- session-held grant, which meant a stolen session cookie was enough.
module Seal.Security.EnrollmentGrantSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)

import Test.Hspec

import Seal.Security.EnrollmentGrant
  ( ChallengeId (..), Grant (..), GrantDenied (..)
  , GrantId (..), GrantPhase (..), GrantSource (..), findAuthority, grantBody
  , grantFromJson, grantSourceText, grantToJson, parseGrantSource, tokenDigest )

spec :: Spec
spec = describe "Seal.Security.EnrollmentGrant" $ do

  describe "grantSourceText / parseGrantSource" $ do
    it "round-trips every source" $
      map (parseGrantSource . grantSourceText) [CliToken, CliWindow, Assertion]
        `shouldBe` map Just [CliToken, CliWindow, Assertion]

    it "rejects an unknown spelling (the caller decides what that means)" $
      parseGrantSource "sneaky" `shouldBe` Nothing

  describe "grant JSON" $ do
    it "round-trips a token-backed grant" $
      grantFromJson (grantToJson tokenGrant) `shouldBe` Just tokenGrant

    it "round-trips a bound, window grant" $
      grantFromJson (grantToJson windowGrant) `shouldBe` Just windowGrant

    it "keeps the digest out of the body as anything but a digest" $ do
      -- The stored form must never contain the token itself.
      LBS.toStrict (grantBody tokenGrant)
        `shouldSatisfy` (not . BS.isInfixOf (encodeToken rawToken))

    it "treats an unknown minted_via as absent, not as a boot refusal" $
      grantFromJson (withField "minted_via" "sneaky" (grantToJson tokenGrant))
        `shouldBe` Nothing

    it "treats a missing expires_at as absent" $
      grantFromJson (dropField "expires_at" (grantToJson tokenGrant))
        `shouldBe` Nothing

    it "refuses a token-backed grant with no digest" $
      grantFromJson (dropField "token_sha256" (grantToJson tokenGrant))
        `shouldBe` Nothing

  describe "findAuthority" $ do
    it "accepts a presented token that matches the file grant" $
      findAuthority (Just rawToken) (Just tokenGrant) Nothing False
        `shouldBe` Right tokenGrant

    it "accepts a presented token that matches the session grant" $
      findAuthority (Just rawToken) Nothing (Just tokenGrant) True
        `shouldBe` Right tokenGrant

    it "refuses a token that matches nothing, and says so" $
      findAuthority (Just "not-the-token") (Just tokenGrant) (Just tokenGrant) True
        `shouldBe` Left GrantInvalid

    it "refuses a session grant when the session does not match" $
      findAuthority (Just rawToken) Nothing (Just tokenGrant) False
        `shouldBe` Left GrantInvalid

    -- Gate round 4, B-1. The exact scenario: an attacker holds the victim's
    -- session cookie (so the session grant is theirs to reach) but does not
    -- have the token, and simply omits the header.
    it "a cookie-only client with no header cannot redeem a live assertion grant" $ do
      let assertionGrant = tokenGrant { grSource = Assertion }
      findAuthority Nothing Nothing (Just assertionGrant) True
        `shouldBe` Left StepUpRequired

    it "tells an anonymous client to present a token rather than to step up" $
      findAuthority Nothing Nothing Nothing False `shouldBe` Left GrantRequired

    it "refuses Nothing when the only grant is token-backed" $
      findAuthority Nothing (Just tokenGrant) Nothing False
        `shouldBe` Left GrantRequired

    it "accepts Nothing for the loopback window grant" $
      findAuthority Nothing (Just windowGrant) Nothing False
        `shouldBe` Right windowGrant

    it "prefers a presented token over the window grant" $
      findAuthority (Just rawToken) (Just windowGrant) (Just tokenGrant) True
        `shouldBe` Right tokenGrant

    it "does not consume, rebind or extend anything on a mismatch" $ do
      -- A pure read: the mismatched call returns the same answers next time.
      let first = findAuthority (Just "wrong") (Just tokenGrant) Nothing False
      let second = findAuthority (Just "wrong") (Just tokenGrant) Nothing False
      first `shouldBe` second
      first `shouldBe` Left GrantInvalid

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

rawToken :: Text
rawToken = "0123456789abcdef0123456789abcdef"

-- | The digest of 'rawToken', as the store holds it.
rawDigest :: ByteString
rawDigest = tokenDigest rawToken

-- | Encode the token so 'BS.isInfixOf' can look for it in a serialised grant.
encodeToken :: Text -> ByteString
encodeToken = BS.pack . map (fromIntegral . fromEnum) . show

fixtureTime :: UTCTime
fixtureTime = posixSecondsToUTCTime 1767225600

tokenGrant :: Grant
tokenGrant = Grant
  { grId        = GrantId "grant-1"
  , grExpiresAt = addUTCTime 600 fixtureTime
  , grSource    = CliToken
  , grPhase     = GrantMinted
  , grTokenSha  = Just rawDigest
  }

windowGrant :: Grant
windowGrant = Grant
  { grId        = GrantId "grant-2"
  , grExpiresAt = addUTCTime 300 fixtureTime
  , grSource    = CliWindow
  , grPhase     = GrantBound (ChallengeId "challenge-abc")
  , grTokenSha  = Nothing
  }

-- | Rewrite one field of an encoded grant, to build the malformed cases.
withField :: Text -> Text -> Value -> Value
withField key value = rewrite (KeyMap.insert (Key.fromText key) (String value))

dropField :: Text -> Value -> Value
dropField key = rewrite (KeyMap.delete (Key.fromText key))

rewrite :: (KeyMap.KeyMap Value -> KeyMap.KeyMap Value) -> Value -> Value
rewrite f (Object o) = Object (f o)
rewrite _ other      = other
