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
  ( FileConfig (..), ProviderConfig (..), RetrievalConfig (..), defaultFileConfig
  , defaultRetrievalMaxScanBytes, loadFileConfig, onDemandSchemas, providerBaseUrl
  , providerDefaultModel, retrievalMaxScanBytes, saveFileConfig
  , updateFileConfig, upsertProvider, UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..), untrustedExecConfigFromFile )

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
        , fcDefaultAgent    = Nothing
        , fcProviders       = Map.empty
        , fcRetrieval       = Nothing
        , fcSignal          = Nothing
        , fcTelegram        = Nothing
        , fcGateway          = Nothing
        , fcUntrustedExec   = Nothing
        , fcDebugSessionTranscript = Nothing
        , fcOnDemandSchemas = Nothing
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
              , fcDefaultAgent    = Nothing
              , fcProviders       = Map.empty
              , fcRetrieval       = Nothing
              , fcSignal          = Nothing
              , fcTelegram        = Nothing
              , fcGateway          = Nothing
        , fcUntrustedExec   = Nothing
        , fcDebugSessionTranscript = Nothing
        , fcOnDemandSchemas = Nothing
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

  describe "retrieval section" $ do
    it "parses a [retrieval] table with max_scan_bytes" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[retrieval]"
          , "max_scan_bytes = 262144"
          ]
        Right cfg <- loadFileConfig path
        fcRetrieval cfg `shouldBe` Just (RetrievalConfig { rcMaxScanBytes = Just 262144 })

    it "round-trips a [retrieval] section through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultFileConfig { fcRetrieval = Just (RetrievalConfig { rcMaxScanBytes = Just 65536 }) }
        saveFileConfig path cfg
        Right back <- loadFileConfig path
        fcRetrieval back `shouldBe` fcRetrieval cfg

    it "absent [retrieval] section decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = \"/tmp/vault.age\"\n"
        Right cfg <- loadFileConfig path
        fcRetrieval cfg `shouldBe` Nothing

    it "retrievalMaxScanBytes falls back to the default when [retrieval] is absent" $ do
      retrievalMaxScanBytes defaultFileConfig `shouldBe` defaultRetrievalMaxScanBytes

    it "retrievalMaxScanBytes falls back to the default when max_scan_bytes is absent" $ do
      let cfg = defaultFileConfig { fcRetrieval = Just (RetrievalConfig Nothing) }
      retrievalMaxScanBytes cfg `shouldBe` defaultRetrievalMaxScanBytes

    it "retrievalMaxScanBytes returns the configured value when present" $ do
      let cfg = defaultFileConfig { fcRetrieval = Just (RetrievalConfig (Just 65536)) }
      retrievalMaxScanBytes cfg `shouldBe` 65536

  describe "untrusted_execution section" $ do

    it "absent [untrusted_execution] section decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = \"/tmp/vault.age\"\n"
        Right cfg <- loadFileConfig path
        fcUntrustedExec cfg `shouldBe` Nothing

    it "parses [untrusted_execution] with mode = local (default)" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"local\""
          ]
        Right cfg <- loadFileConfig path
        fcUntrustedExec cfg `shouldBe` Just (UntrustedExecFileConfig
          { uefcMode = "local"
          , uefcRemote = Nothing
          })

    it "parses [untrusted_execution] with mode = remote and a [remote] sub-table" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"remote\""
          , "[untrusted_execution.remote]"
          , "host = \"exec.internal\""
          , "user = \"agent\""
          , "port = 22"
          , "known_hosts = \"/home/agent/.ssh/known_hosts\""
          , "workspace = \"/srv/agent-workspace\""
          ]
        Right cfg <- loadFileConfig path
        fcUntrustedExec cfg `shouldBe` Just (UntrustedExecFileConfig
          { uefcMode = "remote"
          , uefcRemote = Just (UntrustedExecRemoteFileConfig
              { uerfcHost = Just "exec.internal"
              , uerfcUser = Just "agent"
              , uerfcPort = Just 22
              , uerfcIdentity = Nothing
              , uerfcKnownHosts = Just "/home/agent/.ssh/known_hosts"
              , uerfcWorkspace = Just "/srv/agent-workspace"
              })
          })

    it "parses mode=remote with no [remote] block (fail-closed is at call time, not parse time)" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"remote\""
          ]
        Right cfg <- loadFileConfig path
        fcUntrustedExec cfg `shouldBe` Just (UntrustedExecFileConfig
          { uefcMode = "remote"
          , uefcRemote = Nothing
          })

    it "round-trips an untrusted_execution section through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultFileConfig
              { fcUntrustedExec = Just (UntrustedExecFileConfig
                  { uefcMode = "remote"
                  , uefcRemote = Just (UntrustedExecRemoteFileConfig
                      { uerfcHost = Just "h"
                      , uerfcUser = Just "u"
                      , uerfcPort = Just 2222
                      , uerfcIdentity = Just "/key"
                      , uerfcKnownHosts = Just "/kh"
                      , uerfcWorkspace = Just "/ws"
                      })
                  })
              }
        saveFileConfig path cfg
        Right back <- loadFileConfig path
        fcUntrustedExec back `shouldBe` fcUntrustedExec cfg

    it "untrustedExecConfigFromFile returns Nothing when the section is absent" $ do
      untrustedExecConfigFromFile defaultFileConfig `shouldBe` Nothing

    it "untrustedExecConfigFromFile returns Nothing when mode=local (no remote needed)" $ do
      let cfg = defaultFileConfig
            { fcUntrustedExec = Just (UntrustedExecFileConfig "local" Nothing) }
      untrustedExecConfigFromFile cfg `shouldBe` Nothing

  describe "debug_session_transcript flag" $ do
    it "absent key decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = \"/tmp/vault.age\"\n"
        Right cfg <- loadFileConfig path
        fcDebugSessionTranscript cfg `shouldBe` Nothing

    it "parses debug_session_transcript = true" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "debug_session_transcript = true\n"
        Right cfg <- loadFileConfig path
        fcDebugSessionTranscript cfg `shouldBe` Just True

    it "parses debug_session_transcript = false" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "debug_session_transcript = false\n"
        Right cfg <- loadFileConfig path
        fcDebugSessionTranscript cfg `shouldBe` Just False

    it "round-trips through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultFileConfig { fcDebugSessionTranscript = Just True }
        saveFileConfig path cfg
        Right back <- loadFileConfig path
        fcDebugSessionTranscript back `shouldBe` Just True

  describe "on_demand_schemas flag" $ do
    it "absent key decodes to Nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = \"/tmp/vault.age\"\n"
        Right cfg <- loadFileConfig path
        fcOnDemandSchemas cfg `shouldBe` Nothing

    it "parses on_demand_schemas = true" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "on_demand_schemas = true\n"
        Right cfg <- loadFileConfig path
        fcOnDemandSchemas cfg `shouldBe` Just True

    it "parses on_demand_schemas = false" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "on_demand_schemas = false\n"
        Right cfg <- loadFileConfig path
        fcOnDemandSchemas cfg `shouldBe` Just False

    it "round-trips through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultFileConfig { fcOnDemandSchemas = Just True }
        saveFileConfig path cfg
        Right back <- loadFileConfig path
        fcOnDemandSchemas back `shouldBe` Just True

    it "onDemandSchemas defaults to False when the key is absent" $
      onDemandSchemas defaultFileConfig `shouldBe` False

    it "onDemandSchemas returns True when the key is set" $
      onDemandSchemas (defaultFileConfig { fcOnDemandSchemas = Just True }) `shouldBe` True
