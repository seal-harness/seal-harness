{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.Vault.AgeSpec (spec) where

import Data.ByteString (ByteString)
import Test.Hspec

import Seal.Security.Vault.Age

spec :: Spec
spec = describe "Seal.Security.Vault.Age" $ do
  it "mock encryptor round-trips" $ do
    enc <- veEncrypt mkMockEncryptor "hello"
    case enc of
      Left e   -> expectationFailure (show e)
      Right ct -> do
        ct `shouldNotBe` ("hello" :: ByteString)
        dec <- veDecrypt mkMockEncryptor ct
        dec `shouldBe` Right "hello"

  it "failing encryptor surfaces its error on encrypt" $ do
    enc <- veEncrypt (mkFailingEncryptor VaultLocked) "x"
    enc `shouldBe` Left VaultLocked

  it "XOR is its own inverse: double-encrypt returns original" $ do
    enc1 <- veEncrypt mkMockEncryptor "double xor test"
    case enc1 of
      Left e   -> expectationFailure (show e)
      Right ct -> do
        enc2 <- veEncrypt mkMockEncryptor ct
        enc2 `shouldBe` Right ("double xor test" :: ByteString)

  it "encrypts empty bytestring to empty bytestring" $ do
    result <- veEncrypt mkMockEncryptor ""
    result `shouldBe` Right ("" :: ByteString)

  it "failing encryptor surfaces its error on decrypt" $ do
    dec <- veDecrypt (mkFailingEncryptor (VaultBackendError "boom")) "anything"
    dec `shouldBe` Left (VaultBackendError "boom")
