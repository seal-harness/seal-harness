{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.CryptoSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (ioProperty)
import Seal.Security.Secrets (mkSecretKey)
import Seal.Security.Crypto

key32 :: ByteString
key32 = BS.replicate 32 7

spec :: Spec
spec = describe "Seal.Security.Crypto" $ do

  describe "sha256Hash" $ do
    it "known-answer vector for empty input" $
      sha256Hash "" `shouldBe`
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    it "is stable (same output for same input)" $
      sha256Hash "test" `shouldBe` sha256Hash "test"
    it "differs for different inputs" $
      sha256Hash "a" `shouldNotBe` sha256Hash "b"
    it "returns a 64-byte hex string" $
      BS.length (sha256Hash "test") `shouldBe` 64

  describe "constantTimeEq" $ do
    it "returns True for equal bytestrings" $
      constantTimeEq "abc" "abc" `shouldBe` True
    it "returns False for different bytestrings" $
      constantTimeEq "abc" "abd" `shouldBe` False
    it "returns False for different-length inputs" $
      constantTimeEq "short" "longer" `shouldBe` False

  describe "getRandomBytes" $ do
    it "returns the requested number of bytes" $ do
      bytes <- getRandomBytes 32
      BS.length bytes `shouldBe` 32
    it "returns different bytes on successive calls" $ do
      a <- getRandomBytes 16
      b <- getRandomBytes 16
      a `shouldNotBe` b

  describe "generateToken" $ do
    it "hex length equals 2 * requested byte count" $ do
      token <- generateToken 16
      T.length token `shouldBe` 32
    it "returns different tokens on successive calls" $ do
      a <- generateToken 16
      b <- generateToken 16
      a `shouldNotBe` b

  describe "encrypt / decrypt" $ do
    prop "roundtrip arbitrary plaintext" $ \s -> ioProperty $ do
      let plain = BC.pack s
      enc <- encrypt (mkSecretKey key32) plain
      pure $ (enc >>= decrypt (mkSecretKey key32)) == Right plain

    it "produces different ciphertext for same plaintext (random IV)" $ do
      let key = mkSecretKey (BS.replicate 32 0xAA)
          plain = "same message"
      ct1 <- encrypt key plain
      ct2 <- encrypt key plain
      case (ct1, ct2) of
        (Right a, Right b) -> a `shouldNotBe` b
        _ -> expectationFailure "encryption failed"

    it "encrypt rejects a non-32-byte key" $ do
      enc <- encrypt (mkSecretKey "short") "data"
      enc `shouldSatisfy` isLeft

    it "decrypt rejects a non-32-byte key" $ do
      let fakeCt = BS.replicate 32 0x00
      decrypt (mkSecretKey (BS.replicate 16 0x00)) fakeCt `shouldSatisfy` isLeft

    it "decrypt rejects ciphertext shorter than the 16-byte IV" $
      decrypt (mkSecretKey key32) "tiny" `shouldSatisfy` isLeft

    it "handles empty plaintext (ciphertext is IV-only, decrypts to empty)" $ do
      let key = mkSecretKey key32
      enc <- encrypt key ""
      case enc of
        Left err -> expectationFailure $ "encrypt failed: " ++ show err
        Right ct -> do
          BS.length ct `shouldBe` 16
          decrypt key ct `shouldBe` Right ""
