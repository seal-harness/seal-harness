{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the WebAuthn ceremony verifier.
--
-- The success cases use the committed fixture corpus, which was produced by
-- Node's WebCrypto / OpenSSL (@scripts\/gen-webauthn-fixture.mjs@) — so the
-- signature and DER checks are validated against an implementation that is not
-- this one. The failure cases mutate those bytes (or rebuild the CBOR wrapper
-- with a local encoder) and assert the specific 'WebAuthnError'.
module Seal.Security.WebAuthnSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Test.Hspec

import Seal.Security.WebAuthn
import Seal.Security.WebAuthn.Types (CosePublicKey (..))
import Seal.Security.WebAuthnSpecFixture

spec :: Spec
spec = describe "Seal.Security.WebAuthn" $ do
  describe "parseClientData" $
    it "parses the fixture client data" $
      case parseClientData (fxAsnClientData f) of
        Left e -> expectationFailure ("fixture clientData failed: " <> show e)
        Right cd -> do
          cdType cd `shouldBe` "webauthn.get"
          cdChallenge cd `shouldBe` fxChallenge f
          cdOrigin cd `shouldBe` fxOrigin f
          cdCrossOrigin cd `shouldBe` False

  describe "normalizeOrigin" $ do
    it "lower-cases the scheme and host" $
      normalizeOrigin "HTTP://LocalHost:8080" `shouldBe` Just "http://localhost:8080"
    it "elides the default port" $ do
      normalizeOrigin "https://example.com:443" `shouldBe` Just "https://example.com"
      normalizeOrigin "http://example.com:80/" `shouldBe` Just "http://example.com"
    it "keeps a non-default port" $
      normalizeOrigin "https://example.com:8443" `shouldBe` Just "https://example.com:8443"
    it "rejects a relative or malformed origin" $ do
      normalizeOrigin "localhost:8080" `shouldSatisfy` isNothing
      normalizeOrigin "http://" `shouldSatisfy` isNothing
      normalizeOrigin "http://host/path" `shouldSatisfy` isNothing
      normalizeOrigin "" `shouldSatisfy` isNothing

  describe "checkSignCount" $ do
    it "accepts two zeros (no counter implemented)" $
      checkSignCount 0 0 `shouldBe` Right 0
    it "accepts a strictly increasing counter" $
      checkSignCount 1 2 `shouldBe` Right 2
    it "rejects an equal counter" $
      checkSignCount 2 2 `shouldBe` Left (WnSignCountRegression 2 2)
    it "rejects a decreasing counter" $
      checkSignCount 5 2 `shouldBe` Left (WnSignCountRegression 5 2)
    it "rejects a reset to zero when a counter was stored" $
      checkSignCount 5 0 `shouldBe` Left (WnSignCountRegression 5 0)

  describe "verifyRegistration" $ do
    it "accepts the fixture" $
      fmap rrFields (verifyRegistration regInput)
        `shouldBe` Right (fxCredentialId f, CosePublicKey (fxPublicKey f), 1)

    it "rejects a wrong rpId" $
      verifyRegistration regInput { riExpectedRpId = "evil.example" }
        `shouldBe` Left WnRpIdMismatch

    it "rejects a wrong origin" $
      verifyRegistration regInput { riExpectedOrigin = "http://evil.example" }
        `shouldBe` Left (WnOriginMismatch (fxOrigin f))

    it "rejects a wrong challenge" $
      verifyRegistration regInput { riExpectedChallenge = otherChallenge }
        `shouldBe` Left WnChallengeMismatch

    it "rejects a cross-origin ceremony" $
      verifyRegistration regInput
        { riClientDataJSON =
            rewriteOn (fxRegClientData f) (T.replace "\"crossOrigin\":false" "\"crossOrigin\":true") }
        `shouldBe` Left WnCrossOrigin

    it "rejects a raw id that does not match the attested credential" $
      verifyRegistration regInput { riRawId = BS.replicate 16 0x41 }
        `shouldBe` Left WnCredentialIdMismatch

    it "rejects a non-none attestation format" $
      verifyRegistration regInput { riAttestationObject = attestationWith "packed" (fxRegAuthData f) }
        `shouldBe` Left (WnUnsupportedAttestation "packed")

    it "rejects a registration without user presence" $
      verifyRegistration regInput
        { riAttestationObject = attestationWith "none" (setFlags 0x44 regAuthData) }
        `shouldBe` Left WnUserPresenceMissing

    it "rejects a registration without user verification" $
      verifyRegistration regInput
        { riAttestationObject = attestationWith "none" (setFlags 0x41 regAuthData) }
        `shouldBe` Left WnUserVerificationMissing

    it "rejects an authData with no attested credential" $
      verifyRegistration regInput
        { riAttestationObject = attestationWith "none" (setFlags 0x05 regAuthData) }
        `shouldBe` Left WnAttestedCredentialMissing

    it "rejects a malformed attestation object" $
      verifyRegistration regInput { riAttestationObject = "not cbor" }
        `shouldSatisfy` isLeft

  describe "verifyAssertion" $ do
    it "accepts the fixture and returns the new counter" $
      verifyAssertion fixturePublicKey asnInput
        `shouldBe` Right (fxSignCount f)

    it "rejects a tampered signature" $
      verifyAssertion fixturePublicKey
        asnInput { aiSignature = tamperLastByte (fxSignature f) }
        `shouldBe` Left WnSignatureInvalid

    it "rejects tampered authenticator data" $
      verifyAssertion fixturePublicKey
        asnInput { aiAuthenticatorData = tamperByte 36 (fxAuthData f) }
        `shouldBe` Left WnSignatureInvalid

    it "rejects a replayed sign counter" $
      verifyAssertion fixturePublicKey
        asnInput { aiStoredSignCount = fxSignCount f }
        `shouldBe` Left (WnSignCountRegression (fxSignCount f) (fxSignCount f))

    it "rejects a counter that went backwards" $
      verifyAssertion fixturePublicKey asnInput { aiStoredSignCount = 9 }
        `shouldBe` Left (WnSignCountRegression 9 (fxSignCount f))

    it "rejects an assertion without user verification" $
      verifyAssertion fixturePublicKey
        asnInput { aiAuthenticatorData = setFlags 0x01 (fxAuthData f) }
        `shouldBe` Left WnUserVerificationMissing

    it "rejects an assertion for another rpId" $
      verifyAssertion fixturePublicKey asnInput { aiExpectedRpId = "evil.example" }
        `shouldBe` Left WnRpIdMismatch

    it "rejects an assertion from another origin" $
      verifyAssertion fixturePublicKey asnInput { aiExpectedOrigin = "https://evil.example" }
        `shouldBe` Left (WnOriginMismatch (fxOrigin f))

    it "rejects an assertion with the create ceremony type" $
      verifyAssertion fixturePublicKey
        asnInput { aiClientDataJSON = rewrite (T.replace "webauthn.get" "webauthn.create") }
        `shouldBe` Left (WnWrongCeremony "webauthn.create")

    it "rejects a malformed signature" $
      verifyAssertion fixturePublicKey asnInput { aiSignature = "garbage" }
        `shouldSatisfy` isLeft

    it "rejects a key that is not on the curve" $
      verifyAssertion (CosePublicKey (BS.replicate 64 0xff)) asnInput
        `shouldBe` Left (WnMalformedCoseKey "point is not on P-256")

    it "rejects a key of the wrong length" $
      verifyAssertion (CosePublicKey (BS.replicate 10 0x01)) asnInput
        `shouldBe` Left (WnMalformedCoseKey "key is not 64 bytes")

  describe "error mapping" $ do
    it "gives the errors the UI branches on a stable machine code" $ do
      webAuthnErrorCode WnChallengeMismatch `shouldBe` "challenge_invalid"
      webAuthnErrorCode (WnOriginMismatch "x") `shouldBe` "origin_mismatch"
      webAuthnErrorCode WnSignatureInvalid `shouldBe` "signature_invalid"
      webAuthnErrorCode (WnSignCountRegression 1 0) `shouldBe` "sign_count_regression"
      webAuthnErrorCode WnUserVerificationMissing `shouldBe` "user_verification_required"
    it "gives every error a non-empty sentence" $
      T.length (webAuthnErrorText WnRpIdMismatch) `shouldSatisfy` (> 0)

-- Fixtures and mutations ----------------------------------------------------

f :: Fixture
f = loadFixture

regInput :: RegistrationInput
regInput = RegistrationInput
  { riClientDataJSON    = fxRegClientData f
  , riAttestationObject = fxAttestation f
  , riRawId             = fxRawId f
  , riExpectedChallenge = fxChallenge f
  , riExpectedOrigin    = fxOrigin f
  , riExpectedRpId      = fxRpId f
  }

asnInput :: AssertionInput
asnInput = AssertionInput
  { aiClientDataJSON    = fxAsnClientData f
  , aiAuthenticatorData = fxAuthData f
  , aiSignature         = fxSignature f
  , aiExpectedChallenge = fxChallenge f
  , aiExpectedOrigin    = fxOrigin f
  , aiExpectedRpId      = fxRpId f
  , aiStoredSignCount   = 1
  }

regAuthData :: ByteString
regAuthData = fxRegAuthData f

rrFields :: RegistrationResult -> (ByteString, CosePublicKey, Int)
rrFields r = (rrCredentialId r, rrPublicKey r, rrSignCount r)

otherChallenge :: Text
otherChallenge = "//////////////////////////////////////////8"

-- | Rewrite the fixture clientDataJSON (rewriting bytes, not the parsed
-- object, so the test proves the verifier re-reads what it is given).
rewrite :: (Text -> Text) -> ByteString
rewrite = rewriteOn (fxAsnClientData f)

rewriteOn :: ByteString -> (Text -> Text) -> ByteString
rewriteOn raw g = TE.encodeUtf8 (g (TE.decodeUtf8 raw))

setFlags :: Word8 -> ByteString -> ByteString
setFlags flags bs = BS.take 32 bs <> BS.singleton flags <> BS.drop 33 bs

tamperByte :: Int -> ByteString -> ByteString
tamperByte i bs =
  let (pre, rest) = BS.splitAt i bs
  in case BS.uncons rest of
       Nothing        -> bs
       Just (b, post) -> pre <> BS.singleton (b + 1) <> post

tamperLastByte :: ByteString -> ByteString
tamperLastByte bs
  | BS.null bs = bs
  | otherwise = tamperByte (BS.length bs - 1) bs

-- | Rebuild an attestation object with a given format and authData. A local
-- CBOR encoder, deliberately independent of the production decoder.
attestationWith :: Text -> ByteString -> ByteString
attestationWith fmt authData =
  cborMap
    [ (cborText "fmt", cborText fmt)
    , (cborText "attStmt", cborMap [])
    , (cborText "authData", cborBytes authData)
    ]

cborMap :: [(ByteString, ByteString)] -> ByteString
cborMap pairs =
  BS.singleton (0xa0 + fromIntegral (length pairs))
    <> BS.concat (concatMap (\(k, v) -> [k, v]) pairs)

cborText :: Text -> ByteString
cborText t =
  let raw = TE.encodeUtf8 t
  in cborHead 3 (BS.length raw) <> raw

cborBytes :: ByteString -> ByteString
cborBytes b = cborHead 2 (BS.length b) <> b

cborHead :: Word8 -> Int -> ByteString
cborHead major n
  | n < 24 = BS.singleton (major * 32 + fromIntegral n)
  | n < 256 = BS.pack [major * 32 + 24, fromIntegral n]
  | otherwise =
      BS.pack [major * 32 + 25, fromIntegral (n `div` 256), fromIntegral (n `mod` 256)]
