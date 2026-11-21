{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.Vault.AgeSpec (spec) where

import Data.ByteString (ByteString)
import Data.Text qualified as T
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

  -- Plan WU1 tests 23–25: the argv seam and the validation choke point.
  it "ageDecryptArgs uses the single-token identity form" $
    ageDecryptArgs (AgeIdentity "/home/u/.seal/keys/default.identity")
      `shouldBe` ["--decrypt", "--identity=/home/u/.seal/keys/default.identity"]

  it "ageEncryptArgs uses the single-token recipient form" $
    ageEncryptArgs (AgeRecipient "age1qqqq")
      `shouldBe` ["--encrypt", "--recipient=age1qqqq"]

  it "mkAgeEncryptor rejects a malformed recipient" $ do
    -- Validation happens BEFORE the `age --version` preflight, so this is a
    -- pure rejection: had a process been spawned with these arguments the
    -- error would be "age not installed" or age's own stderr, not this.
    result <- mkAgeEncryptor (AgeRecipient "not-a-recipient") (AgeIdentity "/tmp/x")
    case result of
      Left (VaultBackendError msg) ->
        msg `shouldSatisfy` T.isInfixOf "invalid recipient"
      Left other ->
        expectationFailure ("expected a recipient validation error, got " <> show other)
      Right _ ->
        expectationFailure "expected Left for a malformed recipient, got Right"
