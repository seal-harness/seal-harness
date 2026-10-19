{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.MigrateSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), loadRuntimeConfig
  , providerBaseUrl, providerDefaultModel )
import Seal.Config.Migrate (migrateSecurityConfig, providerRenameMigration)
import Seal.Config.Paths (SealPaths (..), configFilePath, securityFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..), loadSecurityConfig )

spec_main :: Spec
spec_main = describe "Seal.Config.Migrate" $ do

  let makePaths tmp = SealPaths
        { spHome   = tmp
        , spConfig = tmp </> "config"
        , spState  = tmp </> "state"
        , spKeys   = tmp </> "keys"
        , spCache  = tmp </> "cache"
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
-- ---------------------------------------------------------------------------
-- Provider rename migration (issue #271: openrouter -> openai-compat)
-- ---------------------------------------------------------------------------

providerRenameSpec :: Spec
providerRenameSpec = describe "providerRenameMigration" $ do

  let makePaths tmp = SealPaths
        { spHome = tmp, spConfig = tmp </> "config"
        , spState = tmp </> "state", spKeys = tmp </> "keys"
        , spCache = tmp </> "cache" }
      writeCfg tmp = do
        createDirectoryIfMissing True (tmp </> "config")
        pure (configFilePath (makePaths tmp))

  it "rewrites default_provider and copies the provider section" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath $ T.unlines
        [ "default_provider = \"openrouter\""
        , "[providers.openrouter]"
        , "base_url = \"https://proxy.example/v1\""
        , "default_model = \"some/model\""
        ]
      msg <- providerRenameMigration paths
      msg `shouldSatisfy` maybe False (T.isInfixOf "renamed to openai-compat")
      msg `shouldSatisfy` maybe False (T.isInfixOf "Run /provider add openai-compat")
      Right cfg <- loadRuntimeConfig cfgPath
      rcDefaultProvider cfg `shouldBe` Just "openai-compat"
      providerBaseUrl cfg "openai-compat" `shouldBe` Just "https://proxy.example/v1"
      providerDefaultModel cfg "openai-compat" `shouldBe` Just "some/model"
      providerBaseUrl cfg "openrouter" `shouldBe` Nothing
      rcProviders cfg `shouldSatisfy` not . Map.member "openrouter"

  it "fills the OpenRouter URL and the old implicit model when absent" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath "[providers.openrouter]\ndefault_model = \"m1\"\n"
      msg <- providerRenameMigration paths
      msg `shouldSatisfy` maybe False (T.isInfixOf "openai-compat")
      Right cfg <- loadRuntimeConfig cfgPath
      providerBaseUrl cfg "openai-compat" `shouldBe` Just "https://openrouter.ai/api/v1"
      providerDefaultModel cfg "openai-compat" `shouldBe` Just "m1"

  it "synthesizes the section when only default_provider was set" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath "default_provider = \"openrouter\"\n"
      _ <- providerRenameMigration paths
      Right cfg <- loadRuntimeConfig cfgPath
      providerBaseUrl cfg "openai-compat" `shouldBe` Just "https://openrouter.ai/api/v1"
      providerDefaultModel cfg "openai-compat"
        `shouldBe` Just "deepseek/deepseek-v4.1-flash-1017"

  it "lets an existing [providers.openai-compat] win" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath $ T.unlines
        [ "[providers.openai-compat]"
        , "base_url = \"http://localhost:8000/v1\""
        , "default_model = \"mine\""
        , "[providers.openrouter]"
        , "base_url = \"https://old.example/v1\""
        ]
      _ <- providerRenameMigration paths
      Right cfg <- loadRuntimeConfig cfgPath
      providerBaseUrl cfg "openai-compat" `shouldBe` Just "http://localhost:8000/v1"
      providerDefaultModel cfg "openai-compat" `shouldBe` Just "mine"
      rcProviders cfg `shouldSatisfy` not . Map.member "openrouter"

  it "leaves a typed [providers.openrouter] section (an ordinary instance) alone" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath $ T.unlines
        [ "default_provider = \"openrouter\""
        , "[providers.openrouter]"
        , "type = \"openai-compat\""
        , "base_url = \"https://my-proxy.example/v1\""
        ]
      bytesBefore <- TIO.readFile cfgPath
      msg <- providerRenameMigration paths
      msg `shouldBe` Nothing
      bytesAfter <- TIO.readFile cfgPath
      bytesAfter `shouldBe` bytesBefore
      Right cfg <- loadRuntimeConfig cfgPath
      rcDefaultProvider cfg `shouldBe` Just "openrouter"
      providerBaseUrl cfg "openrouter" `shouldBe` Just "https://my-proxy.example/v1"
      providerBaseUrl cfg "openai-compat" `shouldBe` Nothing

  it "merges into a typed destination, preserving its type and settings" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath $ T.unlines
        [ "[providers.openai-compat]"
        , "type = \"openai-compat\""
        , "base_url = \"http://localhost:8000/v1\""
        , "[providers.openrouter]"
        , "default_model = \"old/model\""
        ]
      _ <- providerRenameMigration paths
      Right cfg <- loadRuntimeConfig cfgPath
      providerBaseUrl cfg "openai-compat" `shouldBe` Just "http://localhost:8000/v1"
      providerDefaultModel cfg "openai-compat" `shouldBe` Just "old/model"
      rcProviders cfg `shouldSatisfy` not . Map.member "openrouter"
      -- the destination keeps its explicit type
      fmap pcType (Map.lookup "openai-compat" (rcProviders cfg))
        `shouldBe` Just (Just "openai-compat")

  it "is idempotent" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath "default_provider = \"openrouter\"\n"
      _ <- providerRenameMigration paths
      Right once <- loadRuntimeConfig cfgPath
      again <- providerRenameMigration paths
      again `shouldBe` Nothing
      Right twice <- loadRuntimeConfig cfgPath
      twice `shouldBe` once

  it "leaves malformed TOML untouched and does not throw" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath "this is not toml [[["
      _ <- providerRenameMigration paths
      raw <- TIO.readFile cfgPath
      raw `shouldBe` "this is not toml [[["

  it "runs after the security migration, so remote-exec settings survive" $
    withSystemTempDirectory "seal-rename" $ \tmp -> do
      let paths = makePaths tmp
          secPath = securityFilePath paths
      cfgPath <- writeCfg tmp
      TIO.writeFile cfgPath $ T.unlines
        [ "vault_path = \"/tmp/vault.age\""
        , "vault_recipient = \"age1abc\""
        , "default_provider = \"openrouter\""
        , "[providers.openrouter]"
        , "base_url = \"https://proxy.example/v1\""
        , "[untrusted_execution]"
        , "mode = \"remote\""
        ]
      migrateSecurityConfig paths
      _ <- providerRenameMigration paths
      secExists <- doesFileExist secPath
      secExists `shouldBe` True
      Right cfg <- loadRuntimeConfig cfgPath
      providerBaseUrl cfg "openai-compat" `shouldBe` Just "https://proxy.example/v1"
      raw <- TIO.readFile cfgPath
      raw `shouldSatisfy` not . T.isInfixOf "[untrusted_execution]"

-- | Both suites behind the module's single exported @spec@.

spec :: Spec
spec = spec_main >> providerRenameSpec
