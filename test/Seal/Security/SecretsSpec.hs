{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.SecretsSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Seal.Security.Secrets

spec :: Spec
spec = describe "Seal.Security.Secrets" $ do

  describe "ApiKey" $ do
    it "Show is redacted" $
      show (mkApiKey "sk-supersecret") `shouldBe` "ApiKey <redacted>"

    it "withApiKey provides access to the underlying value" $
      withApiKey (mkApiKey "sk-abc") id `shouldBe` ("sk-abc" :: ByteString)

  describe "BearerToken" $ do
    it "Show is redacted" $
      show (mkBearerToken "token-xyz") `shouldBe` "BearerToken <redacted>"

    it "withBearerToken provides access to the underlying value" $
      withBearerToken (mkBearerToken "token-xyz") id `shouldBe` ("token-xyz" :: ByteString)

  describe "RefreshToken" $ do
    it "Show is redacted" $
      show (mkRefreshToken "rt-supersecret") `shouldBe` "RefreshToken <redacted>"

    it "withRefreshToken provides access to the underlying value" $
      withRefreshToken (mkRefreshToken "rt-abc") id `shouldBe` ("rt-abc" :: ByteString)

  describe "SecretKey" $ do
    it "Show is redacted" $
      show (mkSecretKey "0123456789abcdef") `shouldBe` "SecretKey <redacted>"

    it "withSecretKey provides access to the underlying value" $
      withSecretKey (mkSecretKey "0123456789abcdef") id `shouldBe` ("0123456789abcdef" :: ByteString)

  describe "PairingCode" $ do
    it "Show is redacted" $
      show (mkPairingCode "123456") `shouldBe` "PairingCode <redacted>"

    it "withPairingCode provides access to the underlying value" $
      withPairingCode (mkPairingCode "123456") id `shouldBe` ("123456" :: Text)

  -- Show must equal the fixed redaction string for every input, so any leak
  -- of the payload into Show would diverge from it and fail the property.
  prop "Show never contains the secret bytes" $
    forAll (vectorOf 32 arbitrary) $ \(cs :: String) ->
      show (mkApiKey (BC.pack cs)) == "ApiKey <redacted>"
