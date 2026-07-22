{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.MigrateSpec (spec) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.File (RuntimeConfig (..), loadRuntimeConfig)
import Seal.Config.Migrate (migrateSecurityConfig)
import Seal.Config.Paths (SealPaths (..), configFilePath, securityFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..), loadSecurityConfig )

spec :: Spec
spec = describe "Seal.Config.Migrate" $ do

  let makePaths tmp = SealPaths
        { spHome   = tmp
        , spConfig = tmp </> "config"
        , spState  = tmp </> "state"
        , spKeys   = tmp </> "keys"
        }

  describe "Case 1: security.toml absent, config.toml has legacy fields" $ do
    it "migrates [untrusted_execution] and vault_* from config.toml to security.toml" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "vault_path = \"/tmp/vault.age\""
          , "vault_recipient = \"age1abc\""
          , "vault_key_type = \"x25519\""
          , "default_provider = \"anthropic\""
          , "[untrusted_execution]"
          , "mode = \"remote\""
          ]
        migrateSecurityConfig paths
        secResult <- loadSecurityConfig secPath
        case secResult of
          Right sec -> do
            scVaultRecipient sec `shouldBe` Just "age1abc"
            scUntrustedExec sec `shouldSatisfy` isJustUexec
          Left _ -> expectationFailure "security.toml failed to load after migration"
        cfgResult <- loadRuntimeConfig cfgPath
        case cfgResult of
          Right cfg -> rcDefaultProvider cfg `shouldBe` Just "anthropic"
          Left _ -> expectationFailure "config.toml failed to load after migration"
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "vault_recipient"
        rawCfg `shouldSatisfy` not . T.isInfixOf "[untrusted_execution]"

  describe "Case 2: both present, config.toml has stale legacy fields" $ do
    it "security.toml wins; stale fields cleaned from config.toml" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "vault_recipient = \"age1fromsecurity\"\n"
        TIO.writeFile cfgPath $ T.unlines
          [ "vault_recipient = \"age1stale\""
          , "default_provider = \"ollama\""
          ]
        migrateSecurityConfig paths
        secResult <- loadSecurityConfig secPath
        case secResult of
          Right sec -> scVaultRecipient sec `shouldBe` Just "age1fromsecurity"
          Left _ -> expectationFailure "security.toml failed to load"
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "vault_recipient"
        rawCfg `shouldSatisfy` T.isInfixOf "default_provider"

  describe "Case 3: security.toml exists, config.toml clean" $ do
    it "is a no-op (idempotent)" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        let originalSec = "vault_recipient = \"age1abc\"\n"
            originalCfg = "default_provider = \"ollama\"\n"
        TIO.writeFile secPath originalSec
        TIO.writeFile cfgPath originalCfg
        migrateSecurityConfig paths
        secContents <- TIO.readFile secPath
        cfgContents <- TIO.readFile cfgPath
        secContents `shouldBe` originalSec
        cfgContents `shouldBe` originalCfg

  describe "Case 4: neither exists" $ do
    it "is a no-op" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
        migrateSecurityConfig paths
        secExists <- doesFileExist (securityFilePath paths)
        secExists `shouldBe` False

  describe "Idempotency" $ do
    it "running migration twice does not duplicate or error" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "vault_recipient = \"age1abc\""
          , "default_provider = \"ollama\""
          ]
        migrateSecurityConfig paths
        Right sec1 <- loadSecurityConfig secPath
        scVaultRecipient sec1 `shouldBe` Just "age1abc"
        migrateSecurityConfig paths
        Right sec2 <- loadSecurityConfig secPath
        scVaultRecipient sec2 `shouldBe` Just "age1abc"

  describe "Corrupted [untrusted_execution] input (migration is a move, not validation)" $ do
    it "preserves mode=local with no remote block as-is" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"local\""
          ]
        migrateSecurityConfig paths
        Right sec <- loadSecurityConfig secPath
        case scUntrustedExec sec of
          Just uefc -> uefcMode uefc `shouldBe` "local"
          Nothing -> expectationFailure "expected untrusted_execution to be migrated"

-- | Helper: check if a Maybe UntrustedExecFileConfig is Just.
isJustUexec :: Maybe UntrustedExecFileConfig -> Bool
isJustUexec = \case Just _ -> True; Nothing -> False