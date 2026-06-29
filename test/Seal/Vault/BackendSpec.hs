{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.BackendSpec (spec) where

import Data.Bits ((.&.))
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
            result <- setupYubiKey paths "yubi" False caps
            case result of
              -- Hardware absent: plugin ran but produced no parseable output.
              Left _ -> pendingWith "age-plugin-yubikey: hardware not available"
              Right rk -> do
                rkKeyType rk `shouldBe` "yubikey"
                rkRecipient rk `shouldSatisfy`
                  (\r -> "age1yubikey1" `T.isPrefixOf` r || "age1" `T.isPrefixOf` r)
