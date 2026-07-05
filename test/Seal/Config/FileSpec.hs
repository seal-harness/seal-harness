{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.FileSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Test.Hspec

import Seal.Config.File
  ( FileConfig (..), ProviderConfig (..), defaultFileConfig
  , loadFileConfig, providerBaseUrl, providerDefaultModel, saveFileConfig
  , updateFileConfig, upsertProvider )

spec :: Spec
spec = describe "Seal.Config.File" $ do

  describe "defaultFileConfig" $ do
    it "has all Nothing fields" $
      defaultFileConfig `shouldBe` FileConfig
        { fcVaultPath      = Nothing
        , fcVaultRecipient = Nothing
        , fcVaultIdentity  = Nothing
        , fcVaultUnlock    = Nothing
        , fcVaultKeyType   = Nothing
        , fcDefaultProvider = Nothing
        , fcDefaultModel    = Nothing
        , fcProviders       = Map.empty
        }

  describe "loadFileConfig" $ do
    it "returns defaultFileConfig when the file is absent" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        result <- loadFileConfig path
        result `shouldBe` Right defaultFileConfig

    it "parses a valid TOML file with a subset of fields" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "vault_path = \"/home/user/.seal/config/vault/vault.age\""
          , "vault_recipient = \"age1abc123\""
          , "vault_key_type = \"x25519\""
          ]
        result <- loadFileConfig path
        case result of
          Left err -> expectationFailure ("parse failed: " <> T.unpack err)
          Right cfg -> do
            fcVaultPath      cfg `shouldBe` Just "/home/user/.seal/config/vault/vault.age"
            fcVaultRecipient cfg `shouldBe` Just "age1abc123"
            fcVaultIdentity  cfg `shouldBe` Nothing
            fcVaultUnlock    cfg `shouldBe` Nothing
            fcVaultKeyType   cfg `shouldBe` Just "x25519"
            fcDefaultProvider cfg `shouldBe` Nothing
            fcDefaultModel    cfg `shouldBe` Nothing

    it "returns Left on malformed TOML" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = [not valid toml"
        result <- loadFileConfig path
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed TOML but got Right"

  describe "saveFileConfig / loadFileConfig round-trip" $ do
    it "round-trips a fully-populated FileConfig" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = FileConfig
              { fcVaultPath      = Just "/tmp/vault.age"
              , fcVaultRecipient = Just "age1abc"
              , fcVaultIdentity  = Just "/home/user/.seal/keys/default.identity"
              , fcVaultUnlock    = Just "on_demand"
              , fcVaultKeyType   = Just "x25519"
              , fcDefaultProvider = Nothing
              , fcDefaultModel    = Nothing
              , fcProviders       = Map.empty
              }
        saveFileConfig path cfg
        result <- loadFileConfig path
        result `shouldBe` Right cfg

    it "round-trips defaultFileConfig (all Nothing)" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        result <- loadFileConfig path
        result `shouldBe` Right defaultFileConfig

    it "leaves no leftover .tmp file after save" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        leftover <- doesFileExist (path <> ".tmp")
        leftover `shouldBe` False

  describe "updateFileConfig" $ do
    it "patches one field and preserves all others" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let initial = defaultFileConfig
              { fcVaultPath    = Just "/old/vault.age"
              , fcVaultKeyType = Just "x25519"
              , fcDefaultProvider = Nothing
              , fcDefaultModel    = Nothing
              }
        saveFileConfig path initial
        result <- updateFileConfig path (\c -> c { fcVaultRecipient = Just "age1new" })
        result `shouldBe` Right ()
        loaded <- loadFileConfig path
        case loaded of
          Left err -> expectationFailure ("reload failed: " <> T.unpack err)
          Right cfg -> do
            fcVaultPath      cfg `shouldBe` Just "/old/vault.age"
            fcVaultKeyType   cfg `shouldBe` Just "x25519"
            fcVaultRecipient cfg `shouldBe` Just "age1new"
            fcVaultIdentity  cfg `shouldBe` Nothing
            fcVaultUnlock    cfg `shouldBe` Nothing
            fcDefaultProvider cfg `shouldBe` Nothing
            fcDefaultModel    cfg `shouldBe` Nothing

    it "returns Left when the config file is malformed" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "not = [valid"
        result <- updateFileConfig path id
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed config"

  describe "provider defaults" $ do
    it "round-trips default_provider and default_model through TOML" $
      withSystemTempDirectory "seal-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultFileConfig
              { fcDefaultProvider = Just "anthropic"
              , fcDefaultModel    = Just "claude-opus-4-8"
              }
        saveFileConfig path cfg
        Right loaded <- loadFileConfig path
        fcDefaultProvider loaded `shouldBe` Just "anthropic"
        fcDefaultModel    loaded `shouldBe` Just "claude-opus-4-8"

    it "defaults to Nothing when the keys are absent" $ do
      fcDefaultProvider defaultFileConfig `shouldBe` Nothing
      fcDefaultModel    defaultFileConfig `shouldBe` Nothing

  describe "provider sections" $ do
    it "parses [providers.<label>] sections" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[providers.ollama]"
          , "base_url = \"http://localhost:11434\""
          , "default_model = \"glm-5.2:cloud\""
          , "[providers.anthropic]"
          , "default_model = \"claude-opus-4-8\""
          ]
        Right cfg <- loadFileConfig path
        providerBaseUrl      cfg "ollama"    `shouldBe` Just "http://localhost:11434"
        providerDefaultModel cfg "ollama"    `shouldBe` Just "glm-5.2:cloud"
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
        providerBaseUrl      cfg "anthropic" `shouldBe` Nothing

    it "has an empty provider map when [providers] is absent" $
      providerDefaultModel defaultFileConfig "ollama" `shouldBe` Nothing

    it "upsertProvider updates one field without clobbering the other" $ do
      let c1 = upsertProvider "ollama" (\p -> p { pcBaseUrl = Just "http://h:1" }) defaultFileConfig
          c2 = upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "m" }) c1
      providerBaseUrl      c2 "ollama" `shouldBe` Just "http://h:1"
      providerDefaultModel c2 "ollama" `shouldBe` Just "m"

    it "round-trips provider sections through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = upsertProvider "ollama" (const (ProviderConfig (Just "glm-5.2:cloud") (Just "http://localhost:11434"))) defaultFileConfig
        saveFileConfig path cfg
        Right back <- loadFileConfig path
        fcProviders back `shouldBe` fcProviders cfg
