{-# LANGUAGE OverloadedStrings #-}
-- | The @seal serve@ startup wiring: build the gateway + broker + API from
-- the existing startup (paths → config → vault → session → backends →
-- tabsHandle → broker → gateway). Parallel to @seal tui@ and @seal signal@.
module Seal.Command.Serve
  ( runServeMain
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (filterM)
import Data.Either (fromRight)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Network.HTTP.Client.TLS (newTlsManager)
import System.Directory (doesFileExist)

import Katip (Severity (..), ls)

import qualified Seal.Signal.Config
import qualified Seal.Telegram.Config
import qualified Data.Text.Encoding as TE
import qualified Seal.Channels.Telegram.Commands
import Seal.Channels.Telegram.Transport (mkRealTelegramTransport, tgSetCommands)

import Seal.Channel.Cli (Backends (..), newBackends, resolveSessionProvider)
import Seal.Channels.Loop (ChannelDeps (..), newChannelDeps, plainTurn, plainTurnWithCaps, runChannelLoop, mkTabCloseNotifier)
import Seal.Channels.Signal (withSignalChannel)
import Seal.Channels.Signal.Transport (mkRealSignalTransport)
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Channels.Telegram.Run (mkTelegramHandleCaps, onTelegramCallback)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Call (callCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.New (NewDeps (..), newCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Repo (RepoTestSeam (..), repoCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (mkRegistry, Registry)
import Seal.Gateway.Send (SendDeps (..), webCallDispatcher)
import Seal.Logging.Logger (SealLogger, logIO)
import Seal.Command.Tab (tabCommandSpec, terseGrammarSpec)
import Seal.Config.File (RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig)
import Seal.Config.Migrate (migrateSecurityConfig)
import Seal.Config.Security (SecurityConfig (..), UntrustedExecFileConfig (..), defaultSecurityConfig, loadSecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Tools.Exec.Untrusted (UntrustedExecConfig (..), UntrustedExecMode (..))
import Seal.Config.Paths (SealPaths (..), configFilePath, ensureSealDirs, getSealPaths, repoKeysDir, reposFilePath, securityFilePath, sessionMetaPath, sshAgentsDir, tabListPath, vaultFilePath)
import Seal.Gateway.API (ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Gateway.Server (runGateway)
import Seal.Gateway.Stream (StreamGuard (..), runStreamServer)
import Seal.Gateway.StreamBroker (newStreamBroker)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Tab (mkTabIndex)
import Seal.Ingest (emptyChain)
import Seal.Providers.Registry (configuredProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Policy (AutonomyLevel)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Security.Vault (VaultConfig (..), VaultHandle (..), openVault)
import qualified Seal.SourceControl.Clone as Clone
import Seal.SourceControl.Clone (lsRemoteRepo)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle, arProbeAndSweep)
import Seal.SourceControl.Registry (RepoRegistryHandle, mkRepoRegistryHandle)
import Seal.Tools.Ssh.Agent (mkRealSshAgentHandle)
import Seal.Session.Store (SessionRuntime (..), initSessionMeta)
import Seal.Signal.Config (resolveSignalConfig)
import Seal.Tabs (newPersistingTabsHandle, rebindTabH, seedTabsHandle, snapshotTabs)
import Seal.Tabs.Persist (loadTabList)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Telegram.Config (resolveTelegramConfig)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)
import Seal.Web.UiState (newUiStateHandle)

-- | Full @seal serve@ startup wiring. Mirrors 'Seal.Tui.runTui': paths →
-- config → vault → session → backends → tabsH → broker → gateway + WS
-- server.
runServeMain :: AutonomyLevel -> SealLogger -> IO ()
runServeMain autonomy logger = do
  paths <- getSealPaths
  ensureSealDirs paths
  -- Probe + sweep the persistent ssh-agent registry: GC dead agents from
  -- a crashed/killed seal process so their stale entries don't accumulate
  -- (#88). Live agents are reused (the key is still loaded).
  startupAgentRegH <- mkAgentRegistryHandle (sshAgentsDir paths)
  arProbeAndSweep startupAgentRegH
  migrateSecurityConfig paths
  let cfgPath = configFilePath paths
  cfg <- loadRuntimeConfig cfgPath >>= \case
    Left err -> do
      logIO logger WarningS ("could not load config: " <> ls err)
      pure defaultRuntimeConfig
    Right c  -> pure c
  secCfg <- loadSecurityConfig (securityFilePath paths) >>= \case
    Left err -> do
      logIO logger WarningS ("could not load security config: " <> ls err)
      pure defaultSecurityConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths secCfg logger
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
  -- W4: the source-control repo registry handle (closes over
  -- repos.toml). Built once at startup and threaded into ApiDeps for
  -- /api/repos CRUD. The handle's rrhList/rrhMutate re-read the file on
  -- each call so mutations from other processes are reflected.
  repoRegH <- mkRepoRegistryHandle (reposFilePath paths)
  -- W5: the /repo slash command's test seam. The ls-remote arm runs real
  -- git against repoCloneStateDir; the vault-list arm backs the /repo info
  -- non-blocking vault-key advisory. The vault handle (mHandle) may be
  -- 'Nothing' if the vault is not configured — in that case /repo test
  -- surfaces 'vault locked' (fail-closed) and /repo info skips the advisory.
  repoSeam <- mkRepoTestSeam rt repoRegH paths
  -- W5: persisting tab handle. Load the persisted tab list, drop tabs whose
  -- session.json is missing on disk (stale), and seed the TVar. Harness tabs
  -- (BoundHarness) are kept as-is; the periodic reconcile sweep (run later)
  -- re-resolves their liveness and marks missing windows 'orphaned'. No
  -- broadcast at boot (no WS client connected yet); the first subscriber's
  -- broadcast trigger refreshes the sidebar.
  let tabsPath = tabListPath paths
  tabsH <- newPersistingTabsHandle tabsPath
  mPersisted <- loadTabList tabsPath
  case mPersisted of
    Nothing -> pure ()
    Just tl -> do
      kept <- filterM (sessionTabExists paths) (tlTabs tl)
      seedTabsHandle tabsH (renumberTabs kept)
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
  let loadCfg = fromRight defaultRuntimeConfig <$> loadRuntimeConfig cfgPath
      isRemoteExec = case untrustedExecConfigFromSecurity secCfg of
        Just uec -> uecMode uec == UemRemote
        Nothing  -> False
  chanDeps <- newChannelDeps
        paths rt repoRegH pr backends autonomy (Just broker)
        reg tmuxR (Just mgr) approvals loadCfg isRemoteExec tabsH logger
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
        , ndOldMeta = readIORef activeRef
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
        , skillCommandSpec (bSkills backends) (webCallDispatcher sendDeps)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , tabCommandSpec paths tabsH (mkTabCloseNotifier (cdCursors chanDeps) (cdReplies chanDeps))
        , terseGrammarSpec
        , callCommandSpec (webCallDispatcher sendDeps)
        , newCommandSpec newDeps
        , repoCommandSpec repoRegH repoSeam
        ]
      sendDeps = SendDeps
        { sdPaths      = paths
        , sdVault      = rt
        , sdRepoReg    = repoRegH
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
        , sdTabsHandle  = tabsH
        , sdLogger      = logger
        , sdIsRemote    = isRemoteExec
        }
  -- Build the gateway config (from the [gateway] section or the default)
  let gwCfg = maybe defaultGatewayConfig withGatewayDefaults (rcGateway cfg)
      deps = ApiDeps
        { adSessionRuntime  = sr
        , adTabsHandle      = tabsH
        , adHarnessRegistry = reg
        , adAdoptConsent    = Just CcWeb
        , adAgentDefs       = bAgentDefs backends
        , adSkills          = bSkills backends
        , adProviders       = do
            -- The configured-provider list is computed on each request so
            -- newly-added credentials are reflected without a restart. The
            -- vault handle is read from the same ref the commands use.
            mh <- readIORef (vrHandleRef rt)
            configuredProviders mh cfg
        , adUiState         = uiState
        , adSend            = Just sendDeps
        , adDefaultAgent    = rcDefaultAgent <$> loadCfg
        , adBroker          = Just broker
        , adTabCloseNotifier = mkTabCloseNotifier (cdCursors chanDeps) (cdReplies chanDeps)
        , adRepoRegistry     = repoRegH
        , adConfigRepo       = repo
        , adVault            = rt
        , adPaths            = paths
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
      guard = StreamGuard { sgAllowedOrigins = origins, sgGlobalCap = 1024, sgTabsHandle = tabsH, sgPaths = paths }
  logIO logger InfoS ("WS stream server binding to " <> ls (gcHost gwCfg <> ":" <> T.pack (show (gcWsPort gwCfg))))
  _ <- forkIO (runStreamServer (gcHost gwCfg) (gcWsPort gwCfg) guard broker)
  -- Fork channel listeners for any configured channel. Each channel gets
  -- its own askReply store; the tab list is shared (passed by the
  -- listener). The listener runs the shared 'runChannelLoop' + 'plainTurn'
  -- so the agent loop is identical to the standalone modes.
  forkSignalListener chanDeps cfg registry
  forkTelegramListener chanDeps cfg registry
  -- Run the HTTP gateway (blocks). Fail-closed on non-loopback when
  -- mode=remote (design V6: prevents network access to the unauthenticated
  -- updateRuntimeConfig caller).
  let isRemote = case scUntrustedExec secCfg of
        Just uefc -> uefcMode uefc == "remote"
        Nothing   -> False
  runGateway gwCfg isRemote deps

-- | Build the /repo command's 'RepoTestSeam' from the live vault runtime +
-- paths. The 'VaultRuntime' holds the 'IORef' of the (maybe) live
-- 'VaultHandle'; when the vault is unconfigured/locked ('Nothing' in the
-- ref), @rtsLsRemote@ fails closed to 'CloneVaultError VaultLocked' (via
-- 'Clone.resolveVaultHandle') and @rtsVaultList@ returns 'Left VaultLocked'
-- (/repo info shows the locked advisory). Mirrors 'vaultGetByName' in
-- 'Seal.ISA.Ops.Secret'.
mkRepoTestSeam :: VaultRuntime -> RepoRegistryHandle -> SealPaths -> IO RepoTestSeam
mkRepoTestSeam rt repoRegH paths = do
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir paths)
  pure RepoTestSeam
    { rtsLsRemote  = \repo -> do
        let deps = Clone.CloneDeps
              { Clone.cdVault = rt
              , Clone.cdRepoReg = repoRegH
              , Clone.cdSshAgent = mkRealSshAgentHandle
              , Clone.cdAgentRegistry = agentRegH
              , Clone.cdPinnedKnownHosts = pinnedGithubKnownHosts
              , Clone.cdKeyfilesDir = repoKeysDir paths
              , Clone.cdIsRemote = False
              }
        lsRemoteRepo deps repo
  , rtsVaultList = do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just vh -> vhList vh
  }

-- | Open the vault if both recipient and identity are configured. Mirrors
-- 'Seal.Tui.tryOpenVault'; duplicated to keep this module standalone.
tryOpenVault :: SealPaths -> SecurityConfig -> SealLogger -> IO (Maybe VaultHandle)
tryOpenVault paths fcfg logger =
  case (scVaultRecipient fcfg, scVaultIdentity fcfg) of
    (Just _, Just _) ->
      resolveEncryptor fcfg >>= \case
        Left err -> do
          logIO logger WarningS ("vault not available: " <> ls (T.pack (show err)))
          pure Nothing
        Right enc -> do
          let vcfg = VaultConfig
                { vcPath    = maybe (vaultFilePath paths) T.unpack (scVaultPath fcfg)
                , vcKeyType = fromMaybe "x25519" (scVaultKeyType fcfg)
                , vcUnlock  = parseUnlockMode (scVaultUnlock fcfg)
                }
          Just <$> openVault vcfg enc
    _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- Channel listener forking
-- ---------------------------------------------------------------------------

-- | Does the session.json backing a 'BoundSession' tab exist on disk? Used
-- at boot to drop stale tabs (the session was deleted out-of-band). Harness
-- tabs (BoundHarness) are always kept (the reconcile sweep handles them).
sessionTabExists :: SealPaths -> Tab -> IO Bool
sessionTabExists paths t = case tRef t of
  BoundSession sid -> doesFileExist (sessionMetaPath paths sid)
  BoundHarness _  -> pure True

-- | Renumber a tab list so slots stay contiguous 0..n-1 after dropping stale
-- tabs (I1: the tab list invariant). The TVar's smart constructors would
-- do this via 'removeTab', but here we renumber in bulk after a boot-time
-- filter, so the indices are recomputed from position.
renumberTabs :: [Tab] -> TabList
renumberTabs ts = TabList (zipWith renumber [0..] ts)
  where
    renumber n t = t { tIndex = mkIdx n }
    mkIdx n = case mkTabIndex n of
      Right i -> i
      Left _  -> error ("renumberTabs: index out of range (unreachable, n=" <> show n <> ")")

-- | Fork the Signal channel listener if @[signal]@ is configured. Resolves
-- the config section, spawns the signal-cli transport, and runs the shared
-- inbox-driven loop in a background thread. A missing/unresolved section
-- is logged to stderr and skipped (not fatal — the gateway still starts).
forkSignalListener :: ChannelDeps -> RuntimeConfig -> Registry -> IO ()
forkSignalListener deps cfg registry =
  case resolveSignalConfig (rcSignal cfg) Nothing of
    Left _ -> pure ()  -- not configured; skip silently
    Right (account, chunkLimit, allow) -> do
      let accountLabel = Seal.Signal.Config.signalAccountText account
      eTransport <- mkRealSignalTransport accountLabel
      case eTransport of
        Left err -> logIO (cdLogger deps) WarningS ("seal serve: signal channel skipped: " <> ls err)
        Right transport -> do
          let tabsH = cdTabs deps
          askReply <- newAskReplyStore 0
          let withCh = withSignalChannel (allow, chunkLimit) account transport (cdLogger deps)
              plainHandler h = plainTurn deps h askReply
          _ <- forkIO (runChannelLoop deps withCh plainHandler registry emptyChain askReply tabsH Nothing Nothing)
          pure ()

-- | Fork the Telegram channel listener if @[telegram]@ is configured.
-- Resolves the config section, spawns the Bot API transport, registers the
-- bot's slash-command menu with BotFather for auto-completion, and runs the
-- shared inbox-driven loop in a background thread. A missing/unresolved
-- section is logged to stderr and skipped.
forkTelegramListener :: ChannelDeps -> RuntimeConfig -> Registry -> IO ()
forkTelegramListener deps cfg registry = do
  -- Read the bot token from the vault (the wizard stores it there).
  mh <- readIORef (vrHandleRef (cdVault deps))
  mVaultToken <- case mh of
    Nothing -> pure Nothing
    Just vh -> do
      r <- vhGet vh Seal.Telegram.Config.telegramVaultKey
      pure $ case r of
        Right bs -> Just (TE.decodeUtf8 bs)
        Left _   -> Nothing
  case resolveTelegramConfig (rcTelegram cfg) mVaultToken of
    Left err
      | isJust (rcTelegram cfg) ->
          -- The [telegram] section is present but unresolved (e.g. the vault
          -- is locked / missing the token). Surface it so the channel isn't
          -- silently dropped on startup.
          logIO (cdLogger deps) WarningS ("seal serve: telegram channel skipped: " <> ls err)
      | otherwise -> pure ()  -- not configured; skip silently
    Right (token, chunkLimit, allow) -> do
      mgr <- newTlsManager
      transport <- mkRealTelegramTransport (Seal.Telegram.Config.telegramTokenText token) mgr
      -- Register the bot's slash-command menu with BotFather.
      tgSetCommands transport (Seal.Channels.Telegram.Commands.telegramBotCommands registry)
      let tabsH = cdTabs deps
      askReply <- newAskReplyStore 0
      let withCh = withTelegramChannel (allow, chunkLimit) transport (cdLogger deps)
          plainHandler h = plainTurnWithCaps deps h askReply (Just (mkTelegramHandleCaps transport))
      _ <- forkIO (runChannelLoop deps withCh plainHandler registry emptyChain askReply tabsH
                     (Just (mkTelegramHandleCaps transport)) (Just (onTelegramCallback askReply)))
      pure ()
