{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the bounded CBOR decoder. The interesting cases are the hostile
-- ones: an attestation object arrives from a browser (or from anything that
-- claims to be one), so every length prefix is attacker-controlled.
module Seal.Security.WebAuthn.CborSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Word (Word8)
import Test.Hspec
import Test.QuickCheck
  ( Gen, Property, chooseInt, counterexample, forAll, property, vectorOf )

import Seal.Security.WebAuthn.Cbor
  ( Cbor (..), decodeCbor, decodeCborPrefix, maxInput )

spec :: Spec
spec = describe "Seal.Security.WebAuthn.Cbor" $ do
  describe "decodeCbor" $ do
    it "decodes small integers inline" $ do
      decodeCbor (BS.pack [0x00]) `shouldBe` Right (CborInt 0)
      decodeCbor (BS.pack [0x17]) `shouldBe` Right (CborInt 23)
      decodeCbor (BS.pack [0x18, 0x18]) `shouldBe` Right (CborInt 24)
      decodeCbor (BS.pack [0x19, 0x01, 0x00]) `shouldBe` Right (CborInt 256)
      decodeCbor (BS.pack [0x1a, 0x00, 0x01, 0x00, 0x00]) `shouldBe` Right (CborInt 65536)

    it "decodes negative integers as -1 - n" $ do
      decodeCbor (BS.pack [0x20]) `shouldBe` Right (CborInt (-1))
      decodeCbor (BS.pack [0x22]) `shouldBe` Right (CborInt (-3))

    it "decodes byte strings and text strings" $ do
      decodeCbor (BS.pack [0x43, 0x61, 0x62, 0x63]) `shouldBe` Right (CborBytes "abc")
      decodeCbor (BS.pack [0x63, 0x61, 0x62, 0x63]) `shouldBe` Right (CborText "abc")

    it "decodes arrays, maps, booleans and null" $ do
      decodeCbor (BS.pack [0x82, 0x01, 0x02])
        `shouldBe` Right (CborArray [CborInt 1, CborInt 2])
      decodeCbor (BS.pack [0xa1, 0x01, 0x02])
        `shouldBe` Right (CborMap [(CborInt 1, CborInt 2)])
      decodeCbor (BS.pack [0xa0]) `shouldBe` Right (CborMap [])
      decodeCbor (BS.pack [0xf5]) `shouldBe` Right (CborBool True)
      decodeCbor (BS.pack [0xf4]) `shouldBe` Right (CborBool False)
      decodeCbor (BS.pack [0xf6]) `shouldBe` Right CborNull

  describe "decodeCbor rejects hostile input" $ do
    it "rejects indefinite-length byte strings" $
      rejects [0x5f, 0x41, 0x61, 0xff]
    it "rejects indefinite-length arrays" $
      rejects [0x9f, 0x01, 0xff]
    it "rejects tags" $ rejects [0xc0, 0x01]
    it "rejects floats" $ rejects [0xf9, 0x3c, 0x00]
    it "rejects a reserved additional-info nibble" $ rejects [0x1c]
    it "rejects trailing bytes" $ rejects [0x01, 0x02]
    it "rejects a byte string longer than the remaining input" $
      rejects [0x45, 0x61]
    it "rejects an array arity the remaining input cannot satisfy" $
      -- An 8-byte length of 2^32-1 elements with one byte of payload: the
      -- decoder must reject instead of iterating.
      rejects [0x9b, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x01]
    it "rejects a map arity larger than the item cap" $
      rejects [0xb9, 0x04, 0x01]
    it "rejects an empty input" $
      decodeCbor BS.empty `shouldSatisfy` isLeft
    it "rejects a truncated length prefix" $ rejects [0x19, 0x01]
    it "rejects nesting deeper than the depth cap" $
      decodeCbor (BS.replicate 64 0x81 <> BS.pack [0x00]) `shouldSatisfy` isLeft
    it "rejects invalid UTF-8 in a text string" $ rejects [0x62, 0xff, 0xfe]
    it "rejects an input larger than the size cap" $
      decodeCbor (BS.replicate (maxInput + 1) 0x00) `shouldSatisfy` isLeft

  describe "decodeCborPrefix" $
    it "returns the unconsumed remainder" $
      decodeCborPrefix (BS.pack [0x01, 0x02, 0x03])
        `shouldBe` Right (CborInt 1, BS.pack [0x02, 0x03])

  describe "properties" $ do
    it "round-trips any 32-bit integer" $
      property $ forAll (chooseInt (0, 2 ^ (32 :: Int) - 1)) $ \n ->
        decodeCbor (encodeInt (toInteger n)) == Right (CborInt (toInteger n))

    it "rejects every strict prefix of a minimal integer encoding" $
      property (truncationProp <$> chooseInt (0, 2 ^ (32 :: Int) - 1))

    it "decodes a byte string to exactly its declared payload" $
      property $ forAll genShortBytes $ \payload ->
        decodeCbor (encodeBytes payload) == Right (CborBytes payload)

    it "decodeCborPrefix consumes exactly one item" $
      property $ forAll genShortBytes $ \payload ->
        decodeCborPrefix (encodeBytes payload <> "TRAILING")
          == Right (CborBytes payload, "TRAILING")

-- Helpers ------------------------------------------------------------------

rejects :: [Word8] -> Expectation
rejects bytes = decodeCbor (BS.pack bytes) `shouldSatisfy` isLeft

truncationProp :: Int -> Property
truncationProp n =
  let encoded = encodeInt (toInteger n)
      prefixes = [BS.take k encoded | k <- [0 .. BS.length encoded - 1]]
      bad = [p | p <- prefixes, not (isLeft (decodeCbor p))]
  in counterexample ("encoding: " <> show encoded <> " accepted prefixes: " <> show bad) $
       null bad

genShortBytes :: Gen ByteString
genShortBytes = do
  n <- chooseInt (0, 23)
  BS.pack . map fromIntegral <$> vectorOf n (chooseInt (0, 255))

-- | A minimal definite-length unsigned-integer encoding.
encodeInt :: Integer -> ByteString
encodeInt n
  | n < 24        = BS.singleton (fromIntegral n)
  | n < 0x100     = BS.pack [0x18] <> beN 1 n
  | n < 0x10000   = BS.pack [0x19] <> beN 2 n
  | n < 0x1000000 = BS.pack [0x1a] <> beN 4 n
  | otherwise     = BS.pack [0x1b] <> beN 8 n

beN :: Int -> Integer -> ByteString
beN k n = BS.pack [fromIntegral ((n `div` (256 ^ i)) `mod` 256) | i <- [k - 1, k - 2 .. 0]]

-- | Inline-length byte string (payloads are shorter than 24 bytes here).
encodeBytes :: ByteString -> ByteString
encodeBytes payload = BS.pack [0x40 + fromIntegral (BS.length payload)] <> payload
