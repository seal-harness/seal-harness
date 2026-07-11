{-# LANGUAGE OverloadedStrings #-}
-- | The @seal serve@ startup wiring: build the gateway + broker + API from
-- the existing startup (paths → config → vault → session → backends →
-- tabsHandle → broker → gateway). Parallel to @seal tui@ and @seal signal@.
module Seal.Command.Serve
  ( runServeMain
  ) where

import Control.Concurrent (forkIO)
import Data.IORef (newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Network.HTTP.Client.TLS (newTlsManager)
import System.IO (hPutStrLn, stderr)

import Seal.Channel.Cli (Backends (..), newBackends, resolveSessionProvider)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (mkRegistry)
import Seal.Command.Tab (tabCommandSpec, tabsCommandSpec, terseGrammarSpec)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths (SealPaths (..), configFilePath, ensureSealDirs, getSealPaths)
import Seal.Gateway.API (ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Gateway.Send (SendDeps (..))
import Seal.Gateway.Server (runGateway)
import Seal.Gateway.Stream (StreamGuard (..), runStreamServer)
import Seal.Gateway.StreamBroker (newStreamBroker)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Ingest (emptyChain)
import Seal.Providers.Registry (configuredProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
import Seal.Session.Store (SessionRuntime (..), initSessionMeta)
import Seal.Tabs (newTabsHandle)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

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
  let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  mgr <- newTlsManager
  let pr = ProviderRuntime
            { prConfigPath = cfgPath
            , prVault      = rt
            , prManager    = mgr
            }
      cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  backends <- newBackends cfgRoot repo
  tabsH   <- newTabsHandle
  reg     <- newHarnessRegistry
  -- Build an in-memory active session (NOT persisted to disk) so the
  -- active-session ref has valid provider/model fallbacks. The session
  -- only lands on disk when the user sends the first message (the web send
  -- handler writes the transcript to the session dir). This avoids
  -- polluting the sessions list with an empty session on every `seal serve`.
  sessionMeta <- initSessionMeta paths cfg (bAgentDefs backends)
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
      -- The slash-command registry mirrors the TUI's. Web slash commands are
      -- best-effort: interactive-only specs (which prompt via ccPrompt) are
      -- included but the web caps return "" — a deferral story is a later phase.
      registry = mkRegistry
        [ vaultCommandSpec rt
        , providerCommandSpec pr
        , sessionCommandSpec sr
        , modelCommandSpec pr sr
        , skillCommandSpec (bSkills backends)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , tabCommandSpec tabsH
        , tabsCommandSpec tabsH
        , terseGrammarSpec
        ]
      sendDeps = SendDeps
        { sdPaths      = paths
        , sdVault      = rt
        , sdProvider   = pr
        , sdSession    = sr
        , sdBackends   = backends
        , sdConfigRepo = repo
        , sdPreprocess = emptyChain
        , sdRegistry   = registry
        , sdResolve    = resolveSessionProvider pr
        }
  -- Build the gateway config (from the [gateway] section or the default)
  let gwCfg = maybe defaultGatewayConfig withGatewayDefaults (fcGateway cfg)
      deps = ApiDeps
        { adSessionRuntime  = sr
        , adTabsHandle      = tabsH
        , adHarnessRegistry = reg
        , adAdoptConsent    = Just CcWeb
        , adAgentDefs       = bAgentDefs backends
        , adProviders       = do
            -- The configured-provider list is computed on each request so
            -- newly-added credentials are reflected without a restart. The
            -- vault handle is read from the same ref the commands use.
            mh <- readIORef (vrHandleRef rt)
            configuredProviders mh cfg
        , adSend            = Just sendDeps
        }
  -- Start the WS stream server on the WS port.
  -- The Origin allowlist is the configured list PLUS origins derived from
  -- the HTTP server's host + port. A wildcard host (0.0.0.0) means "bind all
  -- interfaces" — the browser may reach the server via any of them, so we
  -- can't enumerate the allowed origins ahead of time. In that case, pass an
  -- empty allowlist to the WS guard, which triggers wildcard mode (accept
  -- any Origin) — overriding even the default loopback origin. For a specific
  -- host, derive the origin + prepend it to the configured list.
  broker <- newStreamBroker 1024
  let isWildcard = gcHost gwCfg == "0.0.0.0" || gcHost gwCfg == "::"
      httpOrigins = [ "http://" <> gcHost gwCfg <> ":" <> T.pack (show (gcPort gwCfg))
                    | not isWildcard ]
      origins = if isWildcard
                  then []  -- wildcard host → empty allowlist → Stream.hs accepts any
                  else httpOrigins <> gcAllowedOrigins gwCfg
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