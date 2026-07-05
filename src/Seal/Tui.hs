{-# LANGUAGE OverloadedStrings #-}
-- | Top-level TUI entry: path resolution -> config -> vault -> registry -> loop.
module Seal.Tui (runTui) where

import Data.IORef (newIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Network.HTTP.Client.TLS (newTlsManager)

import Seal.Channel.Cli (Backends (..), newBackends, runCliTui)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (mkRegistry)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths
  ( SealPaths
  , configFilePath
  , ensureSealDirs
  , getSealPaths
  , vaultFilePath
  )
import Seal.Ingest (emptyChain)
import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
import Seal.Session.Store (SessionRuntime (..), initSession)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

-- | Open the vault if both recipient and identity are configured.
-- Failures print a warning and return 'Nothing' so the TUI still starts;
-- vault commands will direct the user to run @\/vault setup@.
tryOpenVault :: SealPaths -> FileConfig -> IO (Maybe VaultHandle)
tryOpenVault paths cfg =
  case (fcVaultRecipient cfg, fcVaultIdentity cfg) of
    (Just _, Just _) ->
      resolveEncryptor cfg >>= \case
        Left err -> do
          putStrLn ("Warning: vault not available: " <> show err)
          pure Nothing
        Right enc -> do
          -- Honor vault_path from config if set; fall back to the default.
          -- setupCmd and rekeyExisting in Seal.Vault.Commands replicate this
          -- same expression so all three stay in sync.
          let vcfg = VaultConfig
                { vcPath    = maybe (vaultFilePath paths) T.unpack
                                    (fcVaultPath cfg)
                , vcKeyType = fromMaybe "x25519" (fcVaultKeyType cfg)
                , vcUnlock  = parseUnlockMode (fcVaultUnlock cfg)
                }
          Just <$> openVault vcfg enc
    _ -> pure Nothing

-- | Full TUI wiring.
runTui :: IO ()
runTui = do
  paths <- getSealPaths
  ensureSealDirs paths
  let cfgPath = configFilePath paths
  cfg <- loadFileConfig cfgPath >>= \case
    Left err -> do
      putStrLn ("Warning: could not load config: " <> T.unpack err)
      pure defaultFileConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths cfg
  ref     <- newIORef mHandle
  let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  -- A dedicated manager for the /provider test round-trip. (M2 consolidates
  -- this with the chat provider's manager when the startup hardcode is removed.)
  mgr <- newTlsManager
  let pr = ProviderRuntime
            { prConfigPath = cfgPath
            , prVault      = rt
            , prManager    = mgr
            }
  -- Every launch starts a fresh session (resume is a follow-on milestone).
  sessionMeta <- initSession paths cfg
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
  -- The evolutionary-store backends are created once and shared between the
  -- @\/skill@ \/ @\/agent@ command specs (read-only) and the ISA opcodes
  -- (mutate). They materialize from the Audited log inside runCliTui.
  backends <- newBackends
  let registry = mkRegistry
        [ vaultCommandSpec rt
        , providerCommandSpec pr
        , sessionCommandSpec sr
        , modelCommandSpec pr sr
        , skillCommandSpec (bSkills backends)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        ]
  runCliTui paths rt pr sr registry emptyChain backends
