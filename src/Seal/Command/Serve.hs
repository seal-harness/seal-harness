{-# LANGUAGE OverloadedStrings #-}
-- | The @seal serve@ startup wiring: build the gateway + broker + API from
-- the existing startup (paths → config → vault → session → backends →
-- tabsHandle → broker → gateway). Parallel to @seal tui@ and @seal signal@.
module Seal.Command.Serve
  ( runServeMain
  ) where

import Control.Concurrent (forkIO)
import Data.Either (fromRight)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Network.HTTP.Client.TLS (newTlsManager)
import System.IO (hPutStrLn, stderr)

import qualified Seal.Signal.Config
import qualified Seal.Telegram.Config
import qualified Seal.Security.Vault
import qualified Data.Text.Encoding as TE
import qualified Seal.Channels.Telegram.Commands
import Seal.Channels.Telegram.Transport (mkRealTelegramTransport, tgSetCommands)

import Seal.Channel.Cli (Backends (..), newBackends, resolveSessionProvider)
import Seal.Channels.Loop (ChannelDeps (..), newChannelDeps, plainTurn, runChannelLoop)
import Seal.Channels.Signal (withSignalChannel)
import Seal.Channels.Signal.Transport (mkRealSignalTransport)
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Call (callCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.New (NewDeps (..), newCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (mkRegistry, Registry)
import Seal.Gateway.Send (SendDeps (..), webCallDispatcher)
import Seal.Command.Tab (tabCommandSpec, tabsCommandSpec, terseGrammarSpec)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths (SealPaths (..), configFilePath, ensureSealDirs, getSealPaths, vaultFilePath)
import Seal.Gateway.API (ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Gateway.Server (runGateway)
import Seal.Gateway.Stream (StreamGuard (..), runStreamServer)
import Seal.Gateway.StreamBroker (newStreamBroker)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Ingest (emptyChain)
import Seal.Providers.Registry (configuredProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Policy (AutonomyLevel)
import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
import Seal.Session.Store (SessionRuntime (..), initSessionMeta)
import Seal.Signal.Config (resolveSignalConfig)
import Seal.Tabs (newTabsHandle, rebindTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Telegram.Config (resolveTelegramConfig)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)
import Seal.Web.UiState (newUiStateHandle)

-- | Full @seal serve@ startup wiring. Mirrors 'Seal.Tui.runTui': paths →
-- config → vault → session → backends → tabsH → broker → gateway + WS
-- server.
runServeMain :: AutonomyLevel -> IO ()
runServeMain autonomy = do
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
  callCounter <- newIORef 0
  let pr = ProviderRuntime
            { prConfigPath  = cfgPath
            , prVault       = rt
            , prManager     = mgr
            , prCallCounter = callCounter
            }
      cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  backends <- newBackends cfgRoot repo
  tabsH   <- newTabsHandle
  reg     <- newHarnessRegistry
  tmuxR   <- mkRealTmuxRunner
  uiState <- newUiStateHandle paths
  askReply <- newAskReplyStore 0  -- 0 = block indefinitely (no timeout); a
                                 -- future phase may surface a configurable
                                 -- per-session timeout.
  approvals <- newApprovalCache
  -- Build an in-memory active session (NOT persisted to disk) so the
  -- active-session ref has valid provider/model fallbacks. The session
  -- only lands on disk when the user sends the first message (the web send
  -- handler writes the transcript to the session dir). This avoids
  -- polluting the sessions list with an empty session on every `seal serve`.
  sessionMeta <- initSessionMeta paths cfg (bAgentDefs backends)
  activeRef   <- newIORef sessionMeta
  broker <- newStreamBroker 1024
  -- Build the shared ChannelDeps early so the reply registry + write locks
  -- can be shared with the web send handler (SendDeps). The cursor store,
  -- reply registry, and write locks are created inside newChannelDeps.
  let loadCfg = fromRight defaultFileConfig <$> loadFileConfig cfgPath
  chanDeps <- newChannelDeps
        paths rt pr backends autonomy (Just broker)
        reg tmuxR (Just mgr) approvals loadCfg
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
      -- The /new command for the web: mints a fresh session, swaps srActive,
      -- rebinds the tab (if any) bound to the old sid to the new sid, and
      -- returns the old sid. Mirrors the CLI's ndRebind.
      newDeps = NewDeps
        { ndPaths = paths
        , ndCfg = loadCfg
        , ndAgentDefs = backends
        , ndChannelLabel = "web"
        , ndRebind = \_caps newMeta -> do
            oldMeta <- readIORef activeRef
            let oldSid = smId oldMeta
            snap <- snapshotTabs tabsH
            case [ t | t <- tlTabs snap, tRef t == BoundSession oldSid ] of
              []       -> pure ()
              (tab : _) -> rebindTabH tabsH (tIndex tab) (BoundSession (smId newMeta)) >>= \case
                Left _  -> pure ()  -- best-effort; the swap still happens
                Right _ -> pure ()
            writeIORef activeRef newMeta
            pure oldSid
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
        , callCommandSpec (webCallDispatcher sendDeps)
        , newCommandSpec newDeps
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
        , sdAutonomy   = autonomy
        , sdBroker     = Just broker
        , sdHarnessRegistry = reg
        , sdTmuxRunner  = tmuxR
        , sdHttpManager = Just mgr
        , sdAskReply    = askReply
        , sdApprovals   = approvals
        , sdReplies     = cdReplies chanDeps
        , sdLocks       = cdLocks chanDeps
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
        , adUiState         = uiState
        , adSend            = Just sendDeps
        , adDefaultAgent    = fcDefaultAgent cfg
        }
  -- Start the WS stream server on the WS port.
  -- The Origin allowlist is the configured list PLUS origins derived from
  -- the HTTP server's host + port. A wildcard host (0.0.0.0) means "bind all
  -- interfaces" — the browser may reach the server via any of them, so we
  -- can't enumerate the allowed origins ahead of time. In that case, pass an
  -- empty allowlist to the WS guard, which triggers wildcard mode (accept
  -- any Origin) — overriding even the default loopback origin. For a specific
  -- host, derive the origin + prepend it to the configured list.
  let isWildcard = gcHost gwCfg == "0.0.0.0" || gcHost gwCfg == "::"
      httpOrigins = [ "http://" <> gcHost gwCfg <> ":" <> T.pack (show (gcPort gwCfg))
                    | not isWildcard ]
      origins = if isWildcard
                  then []  -- wildcard host → empty allowlist → Stream.hs accepts any
                  else httpOrigins <> gcAllowedOrigins gwCfg
      guard = StreamGuard { sgAllowedOrigins = origins, sgGlobalCap = 1024 }
  _ <- forkIO (runStreamServer (gcHost gwCfg) (gcWsPort gwCfg) guard broker)
  -- Fork channel listeners for any configured channel. Each channel gets
  -- its own askReply store; the tab list is shared (passed by the
  -- listener). The listener runs the shared 'runChannelLoop' + 'plainTurn'
  -- so the agent loop is identical to the standalone modes.
  forkSignalListener chanDeps cfg registry
  forkTelegramListener chanDeps cfg registry
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
                { vcPath    = maybe (vaultFilePath paths) T.unpack (fcVaultPath fcfg)
                , vcKeyType = fromMaybe "x25519" (fcVaultKeyType fcfg)
                , vcUnlock  = parseUnlockMode (fcVaultUnlock fcfg)
                }
          Just <$> openVault vcfg enc
    _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- Channel listener forking
-- ---------------------------------------------------------------------------

-- | Fork the Signal channel listener if @[signal]@ is configured. Resolves
-- the config section, spawns the signal-cli transport, and runs the shared
-- inbox-driven loop in a background thread. A missing/unresolved section
-- is logged to stderr and skipped (not fatal — the gateway still starts).
forkSignalListener :: ChannelDeps -> FileConfig -> Registry -> IO ()
forkSignalListener deps cfg registry =
  case resolveSignalConfig (fcSignal cfg) Nothing of
    Left _ -> pure ()  -- not configured; skip silently
    Right (account, chunkLimit, allow) -> do
      let accountLabel = Seal.Signal.Config.signalAccountText account
      eTransport <- mkRealSignalTransport accountLabel
      case eTransport of
        Left err -> hPutStrLn stderr ("seal serve: signal channel skipped: " <> T.unpack err)
        Right transport -> do
          tabsH <- newTabsHandle
          askReply <- newAskReplyStore 0
          let withCh = withSignalChannel (allow, chunkLimit) account transport
              plainHandler h = plainTurn deps h askReply
          _ <- forkIO (runChannelLoop deps withCh plainHandler registry emptyChain askReply tabsH)
          pure ()

-- | Fork the Telegram channel listener if @[telegram]@ is configured.
-- Resolves the config section, spawns the Bot API transport, registers the
-- bot's slash-command menu with BotFather for auto-completion, and runs the
-- shared inbox-driven loop in a background thread. A missing/unresolved
-- section is logged to stderr and skipped.
forkTelegramListener :: ChannelDeps -> FileConfig -> Registry -> IO ()
forkTelegramListener deps cfg registry = do
  -- Read the bot token from the vault (the wizard stores it there).
  mh <- readIORef (vrHandleRef (cdVault deps))
  mVaultToken <- case mh of
    Nothing -> pure Nothing
    Just vh -> do
      r <- Seal.Security.Vault.vhGet vh Seal.Telegram.Config.telegramVaultKey
      pure $ case r of
        Right bs -> Just (TE.decodeUtf8 bs)
        Left _   -> Nothing
  case resolveTelegramConfig (fcTelegram cfg) mVaultToken of
    Left err
      | isJust (fcTelegram cfg) ->
          -- The [telegram] section is present but unresolved (e.g. the vault
          -- is locked / missing the token). Surface it so the channel isn't
          -- silently dropped on startup.
          hPutStrLn stderr ("seal serve: telegram channel skipped: " <> T.unpack err)
      | otherwise -> pure ()  -- not configured; skip silently
    Right (token, chunkLimit, allow) -> do
      mgr <- newTlsManager
      transport <- mkRealTelegramTransport (Seal.Telegram.Config.telegramTokenText token) mgr
      -- Register the bot's slash-command menu with BotFather.
      tgSetCommands transport (Seal.Channels.Telegram.Commands.telegramBotCommands registry)
      tabsH <- newTabsHandle
      askReply <- newAskReplyStore 0
      let withCh = withTelegramChannel (allow, chunkLimit) transport
          plainHandler h = plainTurn deps h askReply
      _ <- forkIO (runChannelLoop deps withCh plainHandler registry emptyChain askReply tabsH)
      pure ()