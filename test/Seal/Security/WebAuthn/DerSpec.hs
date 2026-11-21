{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the DER @Ecdsa-Sig-Value@ decoder. The success case uses the
-- committed fixture signature produced by Node's OpenSSL-backed signer, and
-- the property re-encodes the decoded pair to prove the parse is exact.
module Seal.Security.WebAuthn.DerSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Word (Word8)
import Test.Hspec
import Test.QuickCheck
  ( Gen, chooseInt, counterexample, forAll, property, vectorOf )

import Seal.Security.WebAuthn.Der (decodeEcdsaSignature, maxInput)
import Seal.Security.WebAuthnSpecFixture (fixtureSignature)

spec :: Spec
spec = describe "Seal.Security.WebAuthn.Der" $ do
  describe "decodeEcdsaSignature" $ do
    it "parses the committed fixture signature exactly" $
      case decodeEcdsaSignature fixtureSignature of
        Left e -> expectationFailure ("fixture failed to parse: " <> show e)
        Right (r, s) -> do
          r `shouldSatisfy` (> 0)
          s `shouldSatisfy` (> 0)
          -- Re-encoding reproduces the input byte for byte, so the decoder
          -- cannot have skipped, reordered or reinterpreted anything.
          encodeDer r s `shouldBe` fixtureSignature

    it "parses a small hand-built signature" $
      decodeEcdsaSignature (BS.pack [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])
        `shouldBe` Right (1, 2)

    it "accepts the high-bit leading-zero form" $
      decodeEcdsaSignature (BS.pack [0x30, 0x07, 0x02, 0x02, 0x00, 0x80, 0x02, 0x01, 0x01])
        `shouldBe` Right (0x80, 1)

    it "rejects an empty input" $
      decodeEcdsaSignature BS.empty `shouldSatisfy` isLeft
    it "rejects a non-SEQUENCE tag" $
      rejects [0x31, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]
    it "rejects an indefinite length" $
      rejects [0x30, 0x80, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02, 0x00, 0x00]
    it "rejects a length exceeding the input" $
      rejects [0x30, 0x40, 0x02, 0x01, 0x01]
    it "rejects trailing bytes after the SEQUENCE" $
      rejects [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02, 0xff]
    it "rejects a truncated integer" $
      rejects [0x30, 0x04, 0x02, 0x01, 0x01]
    it "rejects a negative integer" $
      rejects [0x30, 0x06, 0x02, 0x01, 0x81, 0x02, 0x01, 0x02]
    it "rejects an empty integer" $
      rejects [0x30, 0x03, 0x02, 0x00, 0x02]
    it "rejects an input larger than the size cap" $
      decodeEcdsaSignature (BS.replicate (maxInput + 1) 0x30) `shouldSatisfy` isLeft
    it "rejects a non-integer member" $
      rejects [0x30, 0x06, 0x04, 0x01, 0x01, 0x02, 0x01, 0x02]

  describe "properties" $
    it "round-trips any pair of non-negative 256-bit integers" $
      property $ forAll genBytes $ \bytes -> do
        let (rb, sb) = BS.splitAt 32 bytes
            r = bytesToInteger rb
            s = bytesToInteger sb
        counterexample (show (r, s)) $
          decodeEcdsaSignature (encodeDer r s) == Right (r, s)

-- Helpers ------------------------------------------------------------------

rejects :: [Word8] -> Expectation
rejects bytes = decodeEcdsaSignature (BS.pack bytes) `shouldSatisfy` isLeft

genBytes :: Gen ByteString
genBytes = BS.pack . map fromIntegral <$> vectorOf 64 (chooseInt (0, 255))

bytesToInteger :: ByteString -> Integer
bytesToInteger = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) 0

-- | A minimal DER encoder, used only to check the decoder round-trips.
encodeDer :: Integer -> Integer -> ByteString
encodeDer r s =
  let body = encodeInteger r <> encodeInteger s
  in BS.pack [0x30] <> encodeLength (BS.length body) <> body

encodeInteger :: Integer -> ByteString
encodeInteger n =
  let raw = unsignedBytes n
      payload = case BS.uncons raw of
        Just (b, _) | b >= 0x80 -> BS.cons 0x00 raw
        _                       -> raw
  in BS.pack [0x02] <> encodeLength (BS.length payload) <> payload

unsignedBytes :: Integer -> ByteString
unsignedBytes n
  | n < 256 = BS.singleton (fromIntegral n)
  | otherwise = unsignedBytes (n `div` 256) <> BS.singleton (fromIntegral (n `mod` 256))

encodeLength :: Int -> ByteString
encodeLength n
  | n < 0x80 = BS.singleton (fromIntegral n)
  | otherwise =
      let bytes = unsignedBytes (toInteger n)
      in BS.singleton (0x80 + fromIntegral (BS.length bytes)) <> bytes
