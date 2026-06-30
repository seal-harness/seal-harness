{-# LANGUAGE OverloadedStrings #-}
-- | Top-level TUI entry: path resolution -> config -> vault -> registry -> loop.
module Seal.Tui (runTui) where

import Data.IORef (newIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Seal.Channel.Cli (runCliTui)
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
      registry = mkRegistry [vaultCommandSpec rt]
  runCliTui paths registry emptyChain
