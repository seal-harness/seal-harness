{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.BackendSpec (spec) where

import Data.Bits ((.&.))
import Data.Either (isLeft)
import Data.List (sort)
import Data.Text qualified as T
import System.Directory (doesFileExist, findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec

import Seal.Config.File (FileConfig (..), defaultFileConfig)
import Seal.Config.Paths (SealPaths (..))
import Seal.Security.Vault (UnlockMode (..))
import Seal.Security.Vault.Age (VaultError (..))
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.Vault.Backend
  ( ResolvedKey (..)
  , detectAgePlugins
  , filterPluginNames
  , parsePluginRecipient
  , parseUnlockMode
  , resolveEncryptor
  , setupLocalAgeKey
  , setupUserSupplied
  , setupYubiKey
  )

spec :: Spec
spec = describe "Seal.Vault.Backend" $ do

  describe "parseUnlockMode" $ do
    it "Nothing defaults to UnlockOnDemand" $
      parseUnlockMode Nothing `shouldBe` UnlockOnDemand
    it "\"on_demand\" -> UnlockOnDemand" $
      parseUnlockMode (Just "on_demand") `shouldBe` UnlockOnDemand
    it "\"startup\" -> UnlockStartup" $
      parseUnlockMode (Just "startup") `shouldBe` UnlockStartup
    it "\"per_access\" -> UnlockPerAccess" $
      parseUnlockMode (Just "per_access") `shouldBe` UnlockPerAccess
    it "unrecognised value defaults to UnlockOnDemand" $
      parseUnlockMode (Just "bogus") `shouldBe` UnlockOnDemand

  describe "filterPluginNames" $ do
    it "returns suffixes for age-plugin-* entries" $ do
      let names = ["age-plugin-yubikey", "age-plugin-fido2", "ssh", "age"]
      sort (filterPluginNames names) `shouldBe` ["fido2", "yubikey"]
    it "ignores files that do not start with age-plugin-" $ do
      filterPluginNames ["age", "ssh", "gpg"] `shouldBe` []
    it "handles empty list" $ do
      filterPluginNames [] `shouldBe` []
    it "detectAgePlugins returns IO [Text] without error" $ do
      -- Smoke test: just ensure it runs without exception
      plugins <- detectAgePlugins
      plugins `shouldSatisfy` (not . any (null . show))

  describe "parsePluginRecipient" $ do
    it "parses a canonical Recipient line" $
      parsePluginRecipient "# Recipient: age1yubikey1abc123\n"
        `shouldBe` Just "age1yubikey1abc123"
    it "parses a lowercase recipient: line (case-insensitive)" $
      parsePluginRecipient "# recipient: age1yubikey1xyz\n"
        `shouldBe` Just "age1yubikey1xyz"
    it "returns Nothing when no recipient line is present" $
      parsePluginRecipient "# Identity: AGE-PLUGIN-YUBIKEY-1ABC\n"
        `shouldBe` Nothing
    -- Regression: age-plugin-yubikey right-aligns its comment labels, so the
    -- real Recipient line has several spaces after '#'. The label-stripping
    -- parser must handle that, not just a single space.
    it "parses the right-aligned Recipient label from real --generate output" $
      parsePluginRecipient (T.unlines
        [ "#       Serial: 27249638, Slot: 3"
        , "#         Name: age identity d170efd7"
        , "#      Created: Mon, 29 Jun 2026 16:13:09 +0000"
        , "#   PIN policy: Once   (A PIN is required once per session, if set)"
        , "# Touch policy: Never  (A physical touch is NOT required to decrypt)"
        , "#    Recipient: age1yubikey1qexampleexampleexampleexampleexampleex0"
        , "AGE-PLUGIN-YUBIKEY-1EXAMPLEEXAMPLEEXAMPLE"
        ])
        `shouldBe` Just "age1yubikey1qexampleexampleexampleexampleexampleex0"

  describe "resolveEncryptor" $ do
    it "returns Left VaultBackendError when recipient is missing" $ do
      result <- resolveEncryptor defaultFileConfig
      case result of
        Left (VaultBackendError _) -> pure ()
        Left other -> expectationFailure $ "expected VaultBackendError, got: " ++ show other
        Right _ -> expectationFailure "expected Left VaultBackendError but got Right"

    it "returns Left VaultBackendError when identity is missing" $ do
      let fc = defaultFileConfig { fcVaultRecipient = Just "age1abc" }
      result <- resolveEncryptor fc
      case result of
        Left (VaultBackendError _) -> pure ()
        Left other -> expectationFailure $ "expected VaultBackendError, got: " ++ show other
        Right _ -> expectationFailure "expected Left VaultBackendError but got Right"

    it "returns Left VaultBackendError when recipient is missing but identity is present" $ do
      let fc = defaultFileConfig { fcVaultIdentity = Just "/path/to/id" }
      result <- resolveEncryptor fc
      case result of
        Left (VaultBackendError _) -> pure ()
        _ -> expectationFailure "expected Left VaultBackendError"

    it "returns Right VaultEncryptor (or Left VaultBackendError if age absent) when both fields are set" $ do
      let fc = defaultFileConfig
            { fcVaultRecipient = Just "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqysq0"
            , fcVaultIdentity  = Just "/nonexistent/test.identity"
            }
      result <- resolveEncryptor fc
      case result of
        Right _                    -> pure ()  -- age binary present; encryptor built
        Left (VaultBackendError _) -> pure ()  -- age binary absent; acceptable
        Left other ->
          expectationFailure $ "unexpected error variant: " ++ show other

  describe "setupUserSupplied" $ do
    it "prompts for recipient then identity path; returns ResolvedKey with rkKeyType=user" $ do
      (_, caps) <- makeFakeCaps ["age1abc123", "/home/user/.seal/keys/mine.identity"]
      result <- setupUserSupplied caps
      result `shouldBe` Right ResolvedKey
        { rkRecipient = "age1abc123"
        , rkIdentity  = "/home/user/.seal/keys/mine.identity"
        , rkKeyType   = "user"
        }

    it "ccSend is not called (prompts only)" $ do
      (fc, caps) <- makeFakeCaps ["age1xyz", "/tmp/k.identity"]
      _ <- setupUserSupplied caps
      sent <- getSent fc
      sent `shouldBe` []

  describe "setupLocalAgeKey" $ do
    it "generates a local age identity and returns ResolvedKey with rkKeyType=x25519" $ do
      ageExe       <- findExecutable "age"
      ageKeygenExe <- findExecutable "age-keygen"
      case (ageExe, ageKeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _            ->
          withSystemTempDirectory "seal-backend-test" $ \tmpDir -> do
            let paths = SealPaths
                  { spHome   = tmpDir
                  , spConfig = tmpDir </> "config"
                  , spState  = tmpDir </> "state"
                  , spKeys   = tmpDir </> "keys"
                  }
            result <- setupLocalAgeKey paths "mykey"
            case result of
              Left err -> expectationFailure $ "setupLocalAgeKey failed: " ++ show err
              Right rk -> do
                rkKeyType rk `shouldBe` "x25519"
                rkRecipient rk `shouldSatisfy` ("age1" `T.isPrefixOf`)
                rkIdentity  rk `shouldSatisfy` (".identity" `T.isSuffixOf`)
                -- Identity file must exist and be mode 0600
                let identPath = T.unpack (rkIdentity rk)
                exists <- doesFileExist identPath
                exists `shouldBe` True
                st <- getFileStatus identPath
                let mode = fileMode st .&. 0o777
                mode `shouldBe` 0o600

    it "rejects a traversing name (\"../escape\") and creates no file outside keys dir" $ do
      ageKeygenExe <- findExecutable "age-keygen"
      case ageKeygenExe of
        Nothing -> pendingWith "age-keygen not installed"
        Just _  ->
          withSystemTempDirectory "seal-confine-test" $ \tmpDir -> do
            let paths = SealPaths
                  { spHome   = tmpDir
                  , spConfig = tmpDir </> "config"
                  , spState  = tmpDir </> "state"
                  , spKeys   = tmpDir </> "keys"
                  }
            result <- setupLocalAgeKey paths "../escape"
            result `shouldSatisfy` isLeft
            -- Verify no file was written outside the keys directory
            exists <- doesFileExist (tmpDir </> "escape.identity")
            exists `shouldBe` False

  describe "setupYubiKey" $ do
    it "generates a yubikey identity and returns ResolvedKey with rkKeyType=yubikey" $ do
      pluginExe <- findExecutable "age-plugin-yubikey"
      case pluginExe of
        Nothing -> pendingWith "age-plugin-yubikey not installed"
        Just _  ->
          withSystemTempDirectory "seal-yubikey-test" $ \tmpDir -> do
            let paths = SealPaths
                  { spHome   = tmpDir
                  , spConfig = tmpDir </> "config"
                  , spState  = tmpDir </> "state"
                  , spKeys   = tmpDir </> "keys"
                  }
            -- Provide scripted caps for the TTY-fallback path; the happy path
            -- (captured stdout) does not consume these, but if the plugin
            -- requires a TTY the fallback prompts exactly once.
            (_, caps) <- makeFakeCaps [""]
            -- touchRequired=False, pinRequired=True (the age-plugin default).
            result <- setupYubiKey paths "yubi" False True caps
            case result of
              -- Hardware absent: plugin ran but produced no parseable output.
              Left _ -> pendingWith "age-plugin-yubikey: hardware not available"
              Right rk -> do
                rkKeyType rk `shouldBe` "yubikey"
                rkRecipient rk `shouldSatisfy`
                  (\r -> "age1yubikey1" `T.isPrefixOf` r || "age1" `T.isPrefixOf` r)
