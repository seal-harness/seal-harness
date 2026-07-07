{-# LANGUAGE OverloadedStrings #-}
-- | The @seal serve@ startup wiring: build the gateway + broker + API from
-- the existing startup (paths → config → vault → session → backends →
-- tabsHandle → broker → gateway). Parallel to @seal tui@ and @seal signal@.
module Seal.Command.Serve
  ( runServeMain
  ) where

import Control.Concurrent (forkIO)
import Data.IORef (newIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Network.HTTP.Client.TLS (newTlsManager)
import System.IO (hPutStrLn, stderr)

import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths (SealPaths (..), configFilePath, ensureSealDirs, getSealPaths)
import Seal.Gateway.API (ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Gateway.Server (runGateway)
import Seal.Gateway.Stream (StreamGuard (..), runStreamServer)
import Seal.Gateway.StreamBroker (newStreamBroker)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Providers.Registry (knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
import Seal.Session.Store (SessionRuntime (..), initSession)
import Seal.Tabs (newTabsHandle)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..))

-- | Full @seal serve@ startup wiring. Mirrors 'Seal.Tui.runTui': paths →
-- config → vault → session → backends → tabsH → broker → gateway + WS
-- server.
runServeMain :: IO ()
runServeMain = do
  paths <- getSealPaths
  ensureSealDirs paths
  let cfgPath = configFilePath paths
  cfg <- loadFileConfig cfgPath >>= \case
    Left err -> do
      hPutStrLn stderr ("Warning: could not load config: " <> T.unpack err)
      pure defaultFileConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths cfg
  ref     <- newIORef mHandle
  let _rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  _mgr <- newTlsManager
  let cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  backends <- newBackends cfgRoot repo
  tabsH   <- newTabsHandle
  reg     <- newHarnessRegistry
  sessionMeta <- initSession paths cfg (bAgentDefs backends)
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
  -- Build the gateway config (from the [gateway] section or the default)
  let gwCfg = maybe defaultGatewayConfig withGatewayDefaults (fcGateway cfg)
      deps = ApiDeps
        { adSessionRuntime  = sr
        , adTabsHandle      = tabsH
        , adHarnessRegistry = reg
        , adAdoptConsent    = Just CcWeb
        , adAgentDefs       = bAgentDefs backends
        , adProviders       = knownProviders
        }
  -- Start the WS stream server on the WS port.
  -- The Origin allowlist is the configured list PLUS the HTTP server's own
  -- origin (derived from host + port), so a non-loopback bind auto-admits
  -- browsers reaching it through that address without manual whitelisting.
  broker <- newStreamBroker 1024
  let httpOrigin = "http://" <> gcHost gwCfg <> ":" <> T.pack (show (gcPort gwCfg))
      origins = httpOrigin : gcAllowedOrigins gwCfg
      guard = StreamGuard { sgAllowedOrigins = origins, sgGlobalCap = 1024 }
  _ <- forkIO (runStreamServer (gcHost gwCfg) (gcWsPort gwCfg) guard broker)
  -- Run the HTTP gateway (blocks)
  runGateway gwCfg deps

-- | Open the vault if both recipient and identity are configured. Mirrors
-- 'Seal.Tui.tryOpenVault'; duplicated to keep this module standalone.
tryOpenVault :: SealPaths -> FileConfig -> IO (Maybe VaultHandle)
tryOpenVault paths fcfg =
  case (fcVaultRecipient fcfg, fcVaultIdentity fcfg) of
    (Just _, Just _) ->
      resolveEncryptor fcfg >>= \case
        Left err -> do
          hPutStrLn stderr ("Warning: vault not available: " <> show err)
          pure Nothing
        Right enc -> do
          let vcfg = VaultConfig
                { vcPath    = maybe (configFilePath paths) T.unpack (fcVaultPath fcfg)
                    -- the vault file is under config/
                , vcKeyType = fromMaybe "x25519" (fcVaultKeyType fcfg)
                , vcUnlock  = parseUnlockMode (fcVaultUnlock fcfg)
                }
          Just <$> openVault vcfg enc
    _ -> pure Nothing