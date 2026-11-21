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
  , providerModels
  , SkillsConfig (..)
  , AgentConfig (..)
  , defaultRuntimeConfig
  , defaultRetrievalMaxScanBytes, loadRuntimeConfig, onDemandSchemas, providerBaseUrl
  , providerDefaultModel, retrievalMaxScanBytes, saveRuntimeConfig
  , updateRuntimeConfig, upsertProvider, migrateLegacyChannels, upsertChannel, deleteChannel
  , defaultAutoloadSkill, resolvedAutoloadSkill, resolvedAvailableSkills
  , resolvedParallelToolGuidance, resolvedToolUseEnforcement, resolvedTaskCompletionGuidance
  , resolvedCredentialToolGuidance
  , maxTurnsConfig )
import Seal.Channels.Config (ChannelId (..), ChannelConfig (..))
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Signal.Config (SignalConfig (..), defaultSignalConfig)
import Seal.Telegram.Config (TelegramConfig (..), defaultTelegramConfig)
import Data.Set qualified as Set
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
        , rcDebugSessionTranscript = Nothing
        , rcDebugModelResponses = Nothing
        , rcMaxModelRetries = Nothing
        , rcRetryBaseDelayMs = Nothing
        , rcOnDemandSchemas = Nothing
        , rcDelegation      = Nothing
        , rcWeb             = Nothing
        , rcWorkdir          = Nothing
        , rcSkills           = Nothing
        , rcAgent            = Nothing
        , rcMaxTurns         = Nothing
        , rcToolTimeout      = Nothing
        , rcEmbedding        = Nothing
        , rcChannels         = Map.empty
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
              , rcDebugSessionTranscript = Nothing
              , rcDebugModelResponses = Nothing
              , rcMaxModelRetries = Nothing
              , rcRetryBaseDelayMs = Nothing
              , rcOnDemandSchemas = Nothing
              , rcDelegation      = Nothing
              , rcWeb             = Nothing
              , rcWorkdir         = Nothing
              , rcSkills          = Nothing
              , rcAgent           = Nothing
              , rcMaxTurns        = Nothing
              , rcToolTimeout     = Nothing
             , rcEmbedding       = Nothing
              , rcChannels       = Map.fromList
                  [ (ChannelId "test-signal", ChannelConfig
                      { ccKind = Signal
                      , ccLabel = Just "Test Signal"
                      , ccAccount = Just "+15555550100"
                      , ccToken = Nothing
                      , ccTextChunkLimit = Just 1998
                      , ccAllowFrom = AllowAll
                      } ) ]
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

    it "round-trips a [skills] section" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = defaultRuntimeConfig
              { rcSkills = Just SkillsConfig
                  { scAutoload = Just "custom-skill"
                  , scAvailableSkills = Nothing
                  }
              }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        result `shouldBe` Right cfg

    it "round-trips [skills] autoload = \"\" (disabled)" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = defaultRuntimeConfig
              { rcSkills = Just SkillsConfig
                  { scAutoload = Just ""
                  , scAvailableSkills = Nothing
                  }
              }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        result `shouldBe` Right cfg

    it "round-trips max_turns" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = defaultRuntimeConfig { rcMaxTurns = Just 120 }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        result `shouldBe` Right cfg

  describe "maxTurnsConfig" $ do
    it "defaults to 200 when max_turns is absent" $
      maxTurnsConfig defaultRuntimeConfig `shouldBe` 200

    it "returns the configured value when set" $
      maxTurnsConfig (defaultRuntimeConfig { rcMaxTurns = Just 30 }) `shouldBe` 30

    it "clamps values below 1 to 1" $
      maxTurnsConfig (defaultRuntimeConfig { rcMaxTurns = Just 0 }) `shouldBe` 1

    it "clamps negative values to 1" $
      maxTurnsConfig (defaultRuntimeConfig { rcMaxTurns = Just (-5) }) `shouldBe` 1

    describe "resolvedAutoloadSkill" $ do
      it "defaults to seal-usage when [skills] is absent" $
        resolvedAutoloadSkill defaultRuntimeConfig `shouldBe` Just defaultAutoloadSkill

      it "defaults to seal-usage when autoload key is absent" $
        resolvedAutoloadSkill (defaultRuntimeConfig { rcSkills = Just SkillsConfig { scAutoload = Nothing, scAvailableSkills = Nothing } })
          `shouldBe` Just defaultAutoloadSkill

      it "returns the custom id when autoload is set" $
        resolvedAutoloadSkill (defaultRuntimeConfig { rcSkills = Just SkillsConfig { scAutoload = Just "custom", scAvailableSkills = Nothing } })
          `shouldBe` Just "custom"

      it "returns Nothing when autoload is explicitly empty (disabled)" $
        resolvedAutoloadSkill (defaultRuntimeConfig { rcSkills = Just SkillsConfig { scAutoload = Just "", scAvailableSkills = Nothing } })
          `shouldBe` (Nothing :: Maybe T.Text)

    describe "resolvedAvailableSkills" $ do
      it "defaults to True when [skills] is absent" $
        resolvedAvailableSkills defaultRuntimeConfig `shouldBe` True

      it "defaults to True when available_skills key is absent" $
        resolvedAvailableSkills (defaultRuntimeConfig { rcSkills = Just SkillsConfig { scAutoload = Nothing, scAvailableSkills = Nothing } })
          `shouldBe` True

      it "returns False when available_skills = False" $
        resolvedAvailableSkills (defaultRuntimeConfig { rcSkills = Just SkillsConfig { scAutoload = Nothing, scAvailableSkills = Just False } })
          `shouldBe` False

      it "returns True when available_skills = True" $
        resolvedAvailableSkills (defaultRuntimeConfig { rcSkills = Just SkillsConfig { scAutoload = Nothing, scAvailableSkills = Just True } })
          `shouldBe` True

    describe "resolvedParallelToolGuidance / resolvedToolUseEnforcement / resolvedTaskCompletionGuidance" $ do
      let allNothing = AgentConfig { acParallelToolGuidance = Nothing
                                    , acToolUseEnforcement = Nothing
                                    , acTaskCompletionGuidance = Nothing
                                    , acCredentialToolGuidance = Nothing
                                    , acAvailableAgents = Nothing
                                    }

      it "default to True when [agent] is absent" $ do
        resolvedParallelToolGuidance defaultRuntimeConfig `shouldBe` True
        resolvedToolUseEnforcement defaultRuntimeConfig `shouldBe` True
        resolvedTaskCompletionGuidance defaultRuntimeConfig `shouldBe` True
        resolvedCredentialToolGuidance defaultRuntimeConfig `shouldBe` True

      it "default to True when the keys are absent" $ do
        let cfg = defaultRuntimeConfig { rcAgent = Just allNothing }
        resolvedParallelToolGuidance cfg `shouldBe` True
        resolvedToolUseEnforcement cfg `shouldBe` True
        resolvedTaskCompletionGuidance cfg `shouldBe` True
        resolvedCredentialToolGuidance cfg `shouldBe` True

      it "return False when a flag is explicitly False" $ do
        let cfg = defaultRuntimeConfig { rcAgent = Just allNothing { acParallelToolGuidance = Just False } }
        resolvedParallelToolGuidance cfg `shouldBe` False
        let cfg2 = defaultRuntimeConfig { rcAgent = Just allNothing { acToolUseEnforcement = Just False } }
        resolvedToolUseEnforcement cfg2 `shouldBe` False
        let cfg3 = defaultRuntimeConfig { rcAgent = Just allNothing { acTaskCompletionGuidance = Just False } }
        resolvedTaskCompletionGuidance cfg3 `shouldBe` False
        let cfg4 = defaultRuntimeConfig { rcAgent = Just allNothing { acCredentialToolGuidance = Just False } }
        resolvedCredentialToolGuidance cfg4 `shouldBe` False

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

    -- Re-encoding through runtimeConfigCodec cannot carry a section the codec
    -- no longer knows, so an un-migrated file must be refused, not rewritten:
    -- the write would delete the operator's gateway bind address and the
    -- migration could never recover it.
    it "refuses while the file still carries a [gateway] table, and changes nothing" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            initial = "default_provider = \"ollama\"\n\n[gateway]\nhost = \"0.0.0.0\"\nport = 8443\n"
        TIO.writeFile path initial
        result <- updateRuntimeConfig path (\c -> c { rcDefaultAgent = Just "worker" })
        case result of
          Left err -> err `shouldSatisfy` T.isInfixOf "seal serve"
          Right _  -> expectationFailure "expected the legacy [gateway] write to be refused"
        TIO.readFile path `shouldReturn` initial

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
          , "models = [\"glm-5.2:cloud\", \"llama3.2\"]"
          , "[providers.anthropic]"
          , "default_model = \"claude-opus-4-8\""
          ]
        Right cfg <- loadRuntimeConfig path
        providerBaseUrl      cfg "ollama"    `shouldBe` Just "http://localhost:11434"
        providerDefaultModel cfg "ollama"    `shouldBe` Just "glm-5.2:cloud"
        providerModels       cfg "ollama"    `shouldBe` ["glm-5.2:cloud", "llama3.2"]
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
        providerModels       cfg "anthropic" `shouldBe` []
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
            cfg  = upsertProvider "ollama" (const (ProviderConfig (Just "glm-5.2:cloud") (Just "http://localhost:11434") Nothing)) defaultRuntimeConfig
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

  describe "rcChannels" $ do
    it "defaultRuntimeConfig has empty rcChannels" $
      rcChannels defaultRuntimeConfig `shouldBe` Map.empty

  describe "migrateLegacyChannels" $ do
    let sigCfg = defaultSignalConfig { scAccount = Just "+15555550123"
                                     , scTextChunkLimit = Just 1998
                                     , scAllowFrom = AllowOnly (Set.fromList ["+15555550123"])
                                     }
        tgCfg = defaultTelegramConfig { tcToken = Just "123:ABCdef"
                                      , tcTextChunkLimit = Just 3900
                                      , tcAllowFrom = AllowOnly (Set.fromList ["111"])
                                      }

    it "migrates legacy [signal] to channel id 'signal'" $ do
      let cfg = defaultRuntimeConfig { rcSignal = Just sigCfg }
          migrated = migrateLegacyChannels cfg
      Map.lookup (ChannelId "signal") (rcChannels migrated)
        `shouldBe` Just (ChannelConfig { ccKind = Signal
                                       , ccLabel = Nothing
                                       , ccAccount = Just "+15555550123"
                                       , ccToken = Nothing
                                       , ccTextChunkLimit = Just 1998
                                       , ccAllowFrom = AllowOnly (Set.fromList ["+15555550123"])
                                       })

    it "migrates legacy [telegram] to channel id 'telegram'" $ do
      let cfg = defaultRuntimeConfig { rcTelegram = Just tgCfg }
          migrated = migrateLegacyChannels cfg
      Map.lookup (ChannelId "telegram") (rcChannels migrated)
        `shouldBe` Just (ChannelConfig { ccKind = Telegram
                                       , ccLabel = Nothing
                                       , ccAccount = Nothing
                                       , ccToken = Just "123:ABCdef"
                                       , ccTextChunkLimit = Just 3900
                                       , ccAllowFrom = AllowOnly (Set.fromList ["111"])
                                       })

    it "migrates both signal + telegram legacy sections" $ do
      let cfg = defaultRuntimeConfig { rcSignal = Just sigCfg, rcTelegram = Just tgCfg }
          migrated = migrateLegacyChannels cfg
      Map.member (ChannelId "signal") (rcChannels migrated) `shouldBe` True
      Map.member (ChannelId "telegram") (rcChannels migrated) `shouldBe` True

    it "preserves tcToken in ccToken on telegram migration" $ do
      let cfg = defaultRuntimeConfig { rcTelegram = Just tgCfg }
          migrated = migrateLegacyChannels cfg
      (ccToken =<< Map.lookup (ChannelId "telegram") (rcChannels migrated))
        `shouldBe` Just "123:ABCdef"

    it "does NOT overwrite when the channel id already exists" $ do
      let existing = ChannelConfig { ccKind = Signal
                                   , ccLabel = Just "Existing"
                                   , ccAccount = Just "+19999990000"
                                   , ccToken = Nothing
                                   , ccTextChunkLimit = Just 1000
                                   , ccAllowFrom = AllowAll
                                   }
          cfg = defaultRuntimeConfig { rcSignal = Just sigCfg
                                     , rcChannels = Map.fromList [(ChannelId "signal", existing)]
                                     }
          migrated = migrateLegacyChannels cfg
      Map.lookup (ChannelId "signal") (rcChannels migrated) `shouldBe` Just existing

    it "migrates a legacy section even when rcChannels is non-empty (coexistence)" $ do
      let prodTg = ChannelConfig { ccKind = Telegram
                                 , ccLabel = Just "Prod Telegram"
                                 , ccAccount = Nothing
                                 , ccToken = Nothing
                                 , ccTextChunkLimit = Nothing
                                 , ccAllowFrom = AllowAll
                                 }
          cfg = defaultRuntimeConfig { rcSignal = Just sigCfg
                                     , rcChannels = Map.fromList [(ChannelId "prod-telegram", prodTg)]
                                     }
          migrated = migrateLegacyChannels cfg
      Map.member (ChannelId "prod-telegram") (rcChannels migrated) `shouldBe` True
      Map.member (ChannelId "signal") (rcChannels migrated) `shouldBe` True

    it "does not migrate when the legacy section is absent" $ do
      let migrated = migrateLegacyChannels defaultRuntimeConfig
      rcChannels migrated `shouldBe` Map.empty

  describe "channel config TOML round-trip" $ do
    it "parses [channels.work-signal] with kind=signal" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[channels.work-signal]"
          , "kind = \"signal\""
          , "label = \"Work Signal\""
          , "account = \"+15555550123\""
          , "text_chunk_limit = 1998"
          , "allow_from = [\"+15555550123\"]"
          ]
        Right cfg <- loadRuntimeConfig path
        Map.lookup (ChannelId "work-signal") (rcChannels cfg)
          `shouldBe` Just (ChannelConfig { ccKind = Signal
                                         , ccLabel = Just "Work Signal"
                                         , ccAccount = Just "+15555550123"
                                         , ccToken = Nothing
                                         , ccTextChunkLimit = Just 1998
                                         , ccAllowFrom = AllowOnly (Set.fromList ["+15555550123"])
                                         })

    it "parses [channels.dev-telegram] with kind=telegram and token" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[channels.dev-telegram]"
          , "kind = \"telegram\""
          , "label = \"Dev Bot\""
          , "token = \"123:ABCdef\""
          , "text_chunk_limit = 3900"
          , "allow_from = [\"123456789\"]"
          ]
        Right cfg <- loadRuntimeConfig path
        Map.lookup (ChannelId "dev-telegram") (rcChannels cfg)
          `shouldBe` Just (ChannelConfig { ccKind = Telegram
                                         , ccLabel = Just "Dev Bot"
                                         , ccAccount = Nothing
                                         , ccToken = Just "123:ABCdef"
                                         , ccTextChunkLimit = Just 3900
                                         , ccAllowFrom = AllowOnly (Set.fromList ["123456789"])
                                         })

    it "round-trips save -> load for a populated channels map" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg = defaultRuntimeConfig
              { rcChannels = Map.fromList
                  [ (ChannelId "work-signal", ChannelConfig
                      { ccKind = Signal
                      , ccLabel = Just "Work Signal"
                      , ccAccount = Just "+15555550123"
                      , ccToken = Nothing
                      , ccTextChunkLimit = Just 1998
                      , ccAllowFrom = AllowOnly (Set.fromList ["+15555550123"])
                      } )
                  ]
              }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        result `shouldBe` Right cfg

    it "normalizes hand-written [channels.<id>] without a bare [channels] header" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[channels.a-signal]"
          , "kind = \"signal\""
          , "account = \"+15555550100\""
          , "[channels.b-telegram]"
          , "kind = \"telegram\""
          ]
        Right cfg <- loadRuntimeConfig path
        Map.member (ChannelId "a-signal") (rcChannels cfg) `shouldBe` True
        Map.member (ChannelId "b-telegram") (rcChannels cfg) `shouldBe` True

    it "migrates a legacy [telegram] section into rcChannels on load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[telegram]"
          , "token = \"999:legacy\""
          ]
        Right cfg <- loadRuntimeConfig path
        Map.lookup (ChannelId "telegram") (rcChannels cfg)
          `shouldBe` Just (ChannelConfig { ccKind = Telegram
                                         , ccLabel = Nothing
                                         , ccAccount = Nothing
                                         , ccToken = Just "999:legacy"
                                         , ccTextChunkLimit = Nothing
                                         , ccAllowFrom = AllowAll
                                         })

  describe "upsertChannel" $ do
    it "inserts a new channel" $ do
      let cfg = upsertChannel (ChannelId "new-signal")
                  (\c -> c { ccKind = Signal, ccAccount = Just "+15555550100" })
                  defaultRuntimeConfig
      Map.member (ChannelId "new-signal") (rcChannels cfg) `shouldBe` True

    it "updates an existing channel without clobbering other fields" $ do
      let existing = ChannelConfig { ccKind = Telegram
                                   , ccLabel = Just "Old"
                                   , ccAccount = Nothing
                                   , ccToken = Just "tok"
                                   , ccTextChunkLimit = Just 3900
                                   , ccAllowFrom = AllowAll
                                   }
          cfg0 = defaultRuntimeConfig
                   { rcChannels = Map.fromList [(ChannelId "tg", existing)] }
          cfg1 = upsertChannel (ChannelId "tg")
                   (\c -> c { ccLabel = Just "New" }) cfg0
      (ccLabel =<< Map.lookup (ChannelId "tg") (rcChannels cfg1)) `shouldBe` Just "New"
      (ccToken =<< Map.lookup (ChannelId "tg") (rcChannels cfg1)) `shouldBe` Just "tok"

  describe "deleteChannel" $ do
    it "removes a channel" $ do
      let chan = ChannelConfig { ccKind = Signal
                               , ccLabel = Nothing
                               , ccAccount = Just "+1"
                               , ccToken = Nothing
                               , ccTextChunkLimit = Nothing
                               , ccAllowFrom = AllowAll
                               }
          cfg0 = defaultRuntimeConfig
                   { rcChannels = Map.fromList [(ChannelId "sig", chan)] }
          cfg1 = deleteChannel (ChannelId "sig") cfg0
      Map.member (ChannelId "sig") (rcChannels cfg1) `shouldBe` False

    it "is a no-op when the channel is absent" $ do
      deleteChannel (ChannelId "missing") defaultRuntimeConfig
        `shouldBe` defaultRuntimeConfig
