{-# LANGUAGE OverloadedStrings #-}
-- | The @seal serve@ startup wiring: build the gateway + broker + API from
-- the existing startup (paths → config → vault → session → backends →
-- tabsHandle → broker → gateway). Parallel to @seal tui@ and @seal signal@.
module Seal.Command.Serve
  ( runServeMain
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (filterM)
import Data.Foldable (for_)
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
import Seal.Channels.Cursor
  ( newPersistingCursorStore, seedCursorStore )
import Seal.Channels.Cursor.Persist (loadCursorMap)
import Seal.Channels.Loop (ChannelDeps (..), newChannelDeps, plainTurn, plainTurnWithCaps, runChannelLoop, mkTabCloseNotifier)
import Seal.Channels.Signal (withSignalChannel)
import Seal.Channels.Signal.Transport (mkRealSignalTransport)
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Channels.Telegram.Run (mkTelegramHandleCaps, onTelegramCallback)
import Seal.Command.Call (callCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Core.Types (OpName (..))
import Seal.ISA.Dispatch (DispatchError (OpNotFound))
import Seal.Command.New (NewDeps (..), newCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Model (mkModelTranscriptWriter)
import Seal.Command.Registry (CoreCommandDeps (..), coreCommandSpecs)
import Seal.Command.Repo (RepoTestSeam (..))
import Seal.Command.Stop (mkStopTranscriptWriter)
import Seal.Command.Spec (mkRegistry, Registry)
import Seal.Gateway.Send (SendDeps (..), handleSetupRepo)
import Seal.Logging.Logger (SealLogger, logIO)
import Seal.Config.File (RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig)
import Seal.Config.Migrate (migrateSecurityConfig)
import Seal.Config.Security (SecurityConfig (..), UntrustedExecFileConfig (..), defaultSecurityConfig, loadSecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Tools.Exec.Untrusted (UntrustedExecConfig (..), UntrustedExecMode (..))
import Seal.Config.Paths (SealPaths (..), configFilePath, cursorMapPath, ensureSealDirs, getSealPaths, repoKeysDir, reposFilePath, securityFilePath, sessionMetaPath, sshAgentsDir, tabListPath, vaultFilePath)
import Seal.Gateway.API (ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Gateway.Server (runGateway)
import Seal.Gateway.Stream (StreamGuard (..), runStreamServer)
import Seal.Gateway.StreamBroker (newStreamBroker)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Tab (mkTabIndex, TabKind(..))
import Seal.Ingest (emptyChain)
import Seal.Providers.Registry (configuredProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Policy (AutonomyLevel)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Security.Vault (VaultConfig (..), VaultHandle (..), openVault)
import qualified Seal.SourceControl.Clone as Clone
import Seal.SourceControl.Clone (lsRemoteRepo)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.Session.AgentMetaCache
  ( agentMetaCacheDir, gcAgentMetaCache, agentMetaCacheKeepN )
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle, arProbeAndSweep)
import Seal.SourceControl.Registry (RepoRegistryHandle, mkRepoRegistryHandle)
import Seal.Tools.Ssh.Agent (mkRealSshAgentHandle)
import Seal.Session.Store (SessionRuntime (..), initSessionMeta)
import Seal.Signal.Config (resolveSignalConfig)
import Seal.Tabs (newPersistingTabsHandle, insertTabH, seedTabsHandle)
import Seal.Tabs.Persist (loadTabList)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Telegram.Config (resolveTelegramConfig)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..))
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
  -- GC the content-addressed agent-metadata snapshot cache: keep the
  -- newest N entries, drop the rest. Best-effort — failures are ignored.
  gcAgentMetaCache (agentMetaCacheDir paths) agentMetaCacheKeepN
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
  -- Persisting cursor store: load + seed so existing Telegram/Signal
  -- conversations re-resolve to their prior sessions (carrying the user's
  -- /model use choice) after a seal serve restart. A cursor pointing at a
  -- session whose session.json is missing degrades gracefully —
  -- resolveTabSession returns Nothing and the loop mints a fresh session
  -- on the next message (exactly as if the cursor were absent). No
  -- boot-time stale sweep is needed.
  cursorsH <- newPersistingCursorStore (cursorMapPath paths)
  mCursors <- loadCursorMap (cursorMapPath paths)
  for_ mCursors (seedCursorStore cursorsH)
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
        reg tmuxR (Just mgr) approvals loadCfg isRemoteExec tabsH logger cursorsH
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
      -- The /new command for the web: mints a fresh session, swaps srActive,
      -- inserts a new tab into the TabsHandle, swaps srActive to the new
      -- session, and returns the old sid. When -r/--repo is given, the
      -- repo is cloned via SETUP_REPO (same as the web "Set up repo").
      newDeps = NewDeps
        { ndPaths = paths
        , ndCfg = loadCfg
        , ndAgentDefs = backends
        , ndChannelLabel = "web"
        , ndOldMeta = readIORef activeRef
        , ndInsertTab = \_caps newMeta -> do
            oldMeta <- readIORef activeRef
            let oldSid = smId oldMeta
            _ <- insertTabH tabsH (BoundSession (smId newMeta)) KindProvider Nothing
            writeIORef activeRef newMeta
            pure oldSid
        , ndSetupRepo = Just (handleSetupRepo sendDeps)
        , ndRepoReg = Just repoRegH
        }
      -- The slash-command registry is built from the shared
      -- 'coreCommandSpecs' (the channel-agnostic core: vault, provider,
      -- session, model, agent, tab, stop, terseGrammar, new, repo) plus
      -- the web's call/skill placeholders. 'runSlash' rebuilds call/skill
      -- AND stop per-request via 'replaceCallSkillSpecs' so those commands
      -- target the request's explicit 'SessionId' (the web is
      -- multi-session; srActive is not authoritative). The placeholders
      -- here never run.
      placeholderDispatcher _ _ = pure (Left (OpNotFound (OpName "placeholder")))
      coreDeps = CoreCommandDeps
        { ccdVault       = rt
        , ccdProvider    = pr
        , ccdSession     = sr
        , ccdAgentDefs   = bAgentDefs backends
        , ccdCfgPath     = cfgPath
        , ccdPaths       = paths
        , ccdTabs        = tabsH
        , ccdTabCloseNotifier = mkTabCloseNotifier (cdCursors chanDeps) (cdReplies chanDeps)
        , ccdAbortReg    = cdAbortReg chanDeps
        , ccdStopWriter  = mkStopTranscriptWriter paths (Just broker)
        , ccdModelWriter = mkModelTranscriptWriter paths (Just broker)
        , ccdRepoReg     = repoRegH
        , ccdRepoSeam    = Just repoSeam
        }
      registry = mkRegistry
        ( coreCommandSpecs coreDeps
          <> [ skillCommandSpec (bSkills backends) placeholderDispatcher
             , callCommandSpec placeholderDispatcher
             , newCommandSpec newDeps
             ]
        )
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
        , sdAbortReg    = cdAbortReg chanDeps
        , sdTabsHandle  = tabsH
        , sdLogger      = logger
        , sdIsRemote    = isRemoteExec
        , sdExecCache   = cdExecCache chanDeps
        , sdRemoteRunner = Nothing
          -- ^ ONE shared instance: turns (web + channels), /call dispatches,
          -- and GET /api/sessions/:id/agents all hit the same cache.
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
        , adWsPort           = gcWsPort gwCfg
        , adSecurityConfig   = secCfg
        , adMkSessionExec    = Nothing
        , adAbortReg         = cdAbortReg chanDeps
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
  , rtsVaultPut = \k v -> do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just vh -> vhPut vh k v
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
