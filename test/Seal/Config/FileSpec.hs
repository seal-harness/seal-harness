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
  ( RuntimeConfig (..), ProviderConfig (..), RetrievalConfig (..), WorkdirConfig (..)
  , defaultRuntimeConfig
  , defaultRetrievalMaxScanBytes, loadRuntimeConfig, onDemandSchemas, providerBaseUrl
  , providerDefaultModel, retrievalMaxScanBytes, saveRuntimeConfig
  , updateRuntimeConfig, upsertProvider )

spec :: Spec
spec = describe "Seal.Config.File" $ do

  describe "defaultRuntimeConfig" $ do
    it "has all Nothing fields" $
      defaultRuntimeConfig `shouldBe` RuntimeConfig
        { rcDefaultProvider = Nothing
        , rcDefaultModel    = Nothing
        , rcDefaultAgent    = Nothing
        , rcProviders       = Map.empty
        , rcRetrieval       = Nothing
        , rcSignal          = Nothing
        , rcTelegram        = Nothing
        , rcGateway         = Nothing
        , rcDebugSessionTranscript = Nothing
        , rcOnDemandSchemas = Nothing
        , rcDelegation      = Nothing
        , rcWeb             = Nothing
        , rcWorkdir          = Nothing
        }

  describe "loadRuntimeConfig" $ do
    it "returns defaultRuntimeConfig when the file is absent" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        result <- loadRuntimeConfig path
        result `shouldBe` Right defaultRuntimeConfig

    it "parses a valid TOML file with a subset of fields" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "default_provider = \"anthropic\""
          , "default_model = \"claude-opus-4-8\""
          ]
        result <- loadRuntimeConfig path
        case result of
          Left err -> expectationFailure ("parse failed: " <> T.unpack err)
          Right cfg -> do
            rcDefaultProvider cfg `shouldBe` Just "anthropic"
            rcDefaultModel    cfg `shouldBe` Just "claude-opus-4-8"

    it "returns Left on malformed TOML" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "default_provider = [not valid toml"
        result <- loadRuntimeConfig path
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed TOML but got Right"

  describe "saveRuntimeConfig / loadRuntimeConfig round-trip" $ do
    it "round-trips a fully-populated RuntimeConfig" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = RuntimeConfig
              { rcDefaultProvider = Just "anthropic"
              , rcDefaultModel    = Just "claude-opus-4-8"
              , rcDefaultAgent    = Nothing
              , rcProviders       = Map.empty
              , rcRetrieval       = Nothing
              , rcSignal          = Nothing
              , rcTelegram        = Nothing
              , rcGateway         = Nothing
              , rcDebugSessionTranscript = Nothing
              , rcOnDemandSchemas = Nothing
              , rcDelegation      = Nothing
              , rcWeb             = Nothing
              , rcWorkdir         = Nothing
              }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        result `shouldBe` Right cfg

    it "round-trips a [workdir] section" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = defaultRuntimeConfig
              { rcWorkdir = Just WorkdirConfig
                  { wdcCleanupOnExit = Just True
                  }
              }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        result `shouldBe` Right cfg

    it "round-trips defaultRuntimeConfig (all Nothing)" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        saveRuntimeConfig path defaultRuntimeConfig
        result <- loadRuntimeConfig path
        result `shouldBe` Right defaultRuntimeConfig

    it "leaves no leftover .tmp file after save" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        saveRuntimeConfig path defaultRuntimeConfig
        leftover <- doesFileExist (path <> ".tmp")
        leftover `shouldBe` False

  describe "updateRuntimeConfig" $ do
    it "patches one field and preserves all others" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let initial = defaultRuntimeConfig
              { rcDefaultProvider = Just "ollama"
              , rcDefaultModel    = Just "glm-5.2:cloud"
              }
        saveRuntimeConfig path initial
        result <- updateRuntimeConfig path (\c -> c { rcDefaultAgent = Just "worker" })
        result `shouldBe` Right ()
        loaded <- loadRuntimeConfig path
        case loaded of
          Left err -> expectationFailure ("reload failed: " <> T.unpack err)
          Right cfg -> do
            rcDefaultProvider cfg `shouldBe` Just "ollama"
            rcDefaultModel    cfg `shouldBe` Just "glm-5.2:cloud"
            rcDefaultAgent    cfg `shouldBe` Just "worker"

    it "returns Left when the config file is malformed" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "not = [valid"
        result <- updateRuntimeConfig path id
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed config"

  describe "provider defaults" $ do
    it "round-trips default_provider and default_model through TOML" $
      withSystemTempDirectory "seal-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultRuntimeConfig
              { rcDefaultProvider = Just "anthropic"
              , rcDefaultModel    = Just "claude-opus-4-8"
              }
        saveRuntimeConfig path cfg
        Right loaded <- loadRuntimeConfig path
        rcDefaultProvider loaded `shouldBe` Just "anthropic"
        rcDefaultModel    loaded `shouldBe` Just "claude-opus-4-8"

    it "defaults to Nothing when the keys are absent" $ do
      rcDefaultProvider defaultRuntimeConfig `shouldBe` Nothing
      rcDefaultModel    defaultRuntimeConfig `shouldBe` Nothing

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
        Right cfg <- loadRuntimeConfig path
        providerBaseUrl      cfg "ollama"    `shouldBe` Just "http://localhost:11434"
        providerDefaultModel cfg "ollama"    `shouldBe` Just "glm-5.2:cloud"
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
        providerBaseUrl      cfg "anthropic" `shouldBe` Nothing

    it "has an empty provider map when [providers] is absent" $
      providerDefaultModel defaultRuntimeConfig "ollama" `shouldBe` Nothing

    it "upsertProvider updates one field without clobbering the other" $ do
      let c1 = upsertProvider "ollama" (\p -> p { pcBaseUrl = Just "http://h:1" }) defaultRuntimeConfig
          c2 = upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "m" }) c1
      providerBaseUrl      c2 "ollama" `shouldBe` Just "http://h:1"
      providerDefaultModel c2 "ollama" `shouldBe` Just "m"

    it "round-trips provider sections through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = upsertProvider "ollama" (const (ProviderConfig (Just "glm-5.2:cloud") (Just "http://localhost:11434"))) defaultRuntimeConfig
        saveRuntimeConfig path cfg
        Right back <- loadRuntimeConfig path
        rcProviders back `shouldBe` rcProviders cfg

  describe "retrieval section" $ do
    it "parses a [retrieval] table with max_scan_bytes" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[retrieval]"
          , "max_scan_bytes = 262144"
          ]
        Right cfg <- loadRuntimeConfig path
        rcRetrieval cfg `shouldBe` Just (RetrievalConfig { rcMaxScanBytes = Just 262144 })

    it "round-trips a [retrieval] section through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultRuntimeConfig { rcRetrieval = Just (RetrievalConfig { rcMaxScanBytes = Just 65536 }) }
        saveRuntimeConfig path cfg
        Right back <- loadRuntimeConfig path
        rcRetrieval back `shouldBe` rcRetrieval cfg

    it "absent [retrieval] section decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "default_provider = \"ollama\"\n"
        Right cfg <- loadRuntimeConfig path
        rcRetrieval cfg `shouldBe` Nothing

    it "retrievalMaxScanBytes falls back to the default when [retrieval] is absent" $ do
      retrievalMaxScanBytes defaultRuntimeConfig `shouldBe` defaultRetrievalMaxScanBytes

    it "retrievalMaxScanBytes falls back to the default when max_scan_bytes is absent" $ do
      let cfg = defaultRuntimeConfig { rcRetrieval = Just (RetrievalConfig Nothing) }
      retrievalMaxScanBytes cfg `shouldBe` defaultRetrievalMaxScanBytes

    it "retrievalMaxScanBytes returns the configured value when present" $ do
      let cfg = defaultRuntimeConfig { rcRetrieval = Just (RetrievalConfig (Just 65536)) }
      retrievalMaxScanBytes cfg `shouldBe` 65536

  describe "debug_session_transcript flag" $ do
    it "absent key decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "default_provider = \"ollama\"\n"
        Right cfg <- loadRuntimeConfig path
        rcDebugSessionTranscript cfg `shouldBe` Nothing

    it "parses debug_session_transcript = true" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "debug_session_transcript = true\n"
        Right cfg <- loadRuntimeConfig path
        rcDebugSessionTranscript cfg `shouldBe` Just True

    it "parses debug_session_transcript = false" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "debug_session_transcript = false\n"
        Right cfg <- loadRuntimeConfig path
        rcDebugSessionTranscript cfg `shouldBe` Just False

    it "round-trips through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultRuntimeConfig { rcDebugSessionTranscript = Just True }
        saveRuntimeConfig path cfg
        Right back <- loadRuntimeConfig path
        rcDebugSessionTranscript back `shouldBe` Just True

  describe "on_demand_schemas flag" $ do
    it "absent key decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "default_provider = \"ollama\"\n"
        Right cfg <- loadRuntimeConfig path
        rcOnDemandSchemas cfg `shouldBe` Nothing

    it "parses on_demand_schemas = true" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "on_demand_schemas = true\n"
        Right cfg <- loadRuntimeConfig path
        rcOnDemandSchemas cfg `shouldBe` Just True

    it "parses on_demand_schemas = false" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "on_demand_schemas = false\n"
        Right cfg <- loadRuntimeConfig path
        rcOnDemandSchemas cfg `shouldBe` Just False

    it "round-trips through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultRuntimeConfig { rcOnDemandSchemas = Just True }
        saveRuntimeConfig path cfg
        Right back <- loadRuntimeConfig path
        rcOnDemandSchemas back `shouldBe` Just True

    it "onDemandSchemas defaults to False when the key is absent" $
      onDemandSchemas defaultRuntimeConfig `shouldBe` False

    it "onDemandSchemas returns True when the key is set" $
      onDemandSchemas (defaultRuntimeConfig { rcOnDemandSchemas = Just True }) `shouldBe` True