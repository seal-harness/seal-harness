{-# LANGUAGE OverloadedStrings #-}
-- | The @seal signal@ startup wiring: spawn the Signal channel + run the
-- agent loop against it, parallel to @seal tui@. Reuses the existing
-- 'Seal.Channel.Cli' session/provider-resolution machinery so the agent
-- loop is identical; the difference is the channel is inbox-driven
-- ('chReceive') not Haskeline-driven, and 'aeMessageSource' is @Just ms@
-- so the transcript records the channel + conversation id.
module Seal.Channels.Signal.Run
  ( runSignal
  , runSignalLoop
  , runSignalMain
  ) where

import Data.Either (fromRight)
import Data.IORef (newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client.TLS (newTlsManager)
import System.Directory (getCurrentDirectory)
import System.IO (hPutStrLn, stderr)

import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), mkSessionAgentEnv, newBackends, resolveSessionProvider
  , execBackendFromFile, debugRequestsPath )
import Seal.Tools.Exec.Local (mkLocalExecHandle)
import Seal.Tools.Exec.Types (ExecBackend (..))
import Seal.Channels.Class (Channel (..))
import Seal.Channels.Signal (withSignalChannel)
import Seal.Channels.Signal.Transport (SignalTransport, mkRealSignalTransport)
import Seal.Command.Channel (ChannelRuntime (..), channelCommandSpec, mkRealSignalCli)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry, mkRegistry)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Tab (tabCommandSpec, tabsCommandSpec, terseGrammarSpec)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths (SealPaths (..), configFilePath, ensureSealDirs, getSealPaths, sessionDir, vaultFilePath)
import Seal.Core.AllowList (AllowList)
import Seal.Core.MessageSource (MessageSource, UserId)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (tabIndexToChar, TabKind (..))
import Seal.Handles.Transcript (withTwoFileTranscript, tfwSetSecretOps)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), emptyChain, ingest)
import Seal.Routing.Route qualified
import Seal.Tabs (TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs, newTabsHandle)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..), TabSlashCommand (..), ForceMode (..), tabCount, tlTabs)
import Seal.ISA.Ops.File (fileReadOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillReadOp, skillWriteOp )
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStatusOp, agentStopOp )
import qualified Seal.ISA.Registry as ISA
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Vault qualified as Vault
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), initSession)
import Seal.Signal.Config (SignalAccount (..), resolveSignalConfig, signalAccountText)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..))

-- | Spawn the real signal-cli transport, resolve the account + chunk limit
-- + allow-list, and run the agent loop against the Signal channel. Fails
-- fast with a stderr diagnostic if signal-cli is absent or the account is
-- unresolved.
runSignal
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime
  -> Registry -> PreprocessChain -> Backends -> TabsHandle
  -> (SignalAccount, Int, AllowList UserId)
  -> IO ()
runSignal paths rt pr sr registry chain backends tabsH (account, chunkLimit, allow) = do
  let accountLabel = signalAccountText account
  eTransport <- mkRealSignalTransport accountLabel
  case eTransport of
    Left err -> hPutStrLn stderr ("seal signal: " <> T.unpack err)
    Right transport ->
      runSignalLoop registry chain (allow, chunkLimit) account transport tabsH $
        \h -> plainTurn paths rt pr sr backends h

-- | The inbox-driven loop. Spawns the Signal channel via 'withSignalChannel',
-- pulls @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route' (Layer-1 terse grammar + /tab commands BEFORE the
-- /-command registry), dispatches slash commands via a 'ChannelCaps' adapter
-- over the 'ChannelHandle', and routes plain messages to the supplied
-- 'plainHandler' (which runs 'runTurn' with 'aeMessageSource' = @Just ms@,
-- using the supplied 'ChannelHandle' for any sends).
-- Terminates when 'chReceive' returns EOF (@(Nothing, "")@ with the reader
-- exited). The 'withSignalChannel' bracket owns cleanup.
runSignalLoop
  :: Registry
  -> PreprocessChain
  -> (AllowList UserId, Int)
  -> SignalAccount
  -> SignalTransport
  -> TabsHandle
  -> (ChannelHandle -> Maybe MessageSource -> Text -> IO ())
  -> IO ()
runSignalLoop registry chain (allow, chunkLimit) account transport tabsH plainHandler =
  withSignalChannel (allow, chunkLimit) account transport $ \ch -> do
    let h = toHandle ch
        handleCaps = ChannelCaps
          { ccSend         = chSend h
          , ccPrompt       = fmap (fromRight "") . chPrompt h
          , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
          }
    loop h handleCaps
  where
    loop h handleCaps = do
      (mSrc, body) <- chReceive h
      case mSrc of
        Nothing -> pure ()  -- EOF: reader exited + inbox drained
        Just _ms -> do
          -- Layer-1 routing: check the terse /N grammar + /tab commands
          -- BEFORE the /-command registry.
          case Seal.Routing.Route.route body of
            Right (Seal.Routing.Route.Focus idx) -> do
              _ <- focusTabH tabsH idx
              chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
              loop h handleCaps
            Right (Seal.Routing.Route.Inject idx payload) -> do
              _ <- focusTabH tabsH idx
              plainHandler h mSrc payload
              loop h handleCaps
            Right (Seal.Routing.Route.TabCommand tsc) -> do
              _ <- handleTabCommand' h tabsH tsc
              loop h handleCaps
            Right (Seal.Routing.Route.SlashCommand _) -> do
              d <- ingest registry chain (RawInbound body)
              case d of
                DispatchAction a -> runCommandAction a handleCaps >> loop h handleCaps
                ShowText t       -> chSend h t >> loop h handleCaps
                PlainMessage t   -> plainHandler h mSrc t >> loop h handleCaps
                Rejected msg     -> chSend h msg >> loop h handleCaps
            Right (Seal.Routing.Route.Plain t) -> do
              plainHandler h mSrc t
              loop h handleCaps
            Left (Seal.Routing.Route.ParseError e) -> do
              chSend h e
              loop h handleCaps

-- | Handle a parsed 'TabSlashCommand' over the Signal channel (mutates the
-- TabsHandle, replies via chSend). Mirrors Seal.Channel.Cli.handleTabCommand.
handleTabCommand' :: ChannelHandle -> TabsHandle -> TabSlashCommand -> IO ()
handleTabCommand' h tabsH = \case
  TabListCmd -> do
    tl <- snapshotTabs tabsH
    if tabCount tl == 0
      then chSend h "no tabs"
      else mapM_ (chSend h . renderTab) (tlTabs tl)
  TabNewCmd _mKind -> do
    r <- insertTabH tabsH (BoundSession placeholderSid) KindAi Nothing
    case r of
      Left e  -> chSend h ("tab new failed: " <> e)
      Right i -> chSend h ("tab " <> T.singleton (tabIndexToChar i) <> " created")
  TabCloseCmd idx force -> do
    r <- removeTabH tabsH idx
    case r of
      Left e  -> chSend h (if force == Force then "force close: " <> e else "close failed: " <> e)
      Right _ -> chSend h ("tab " <> T.singleton (tabIndexToChar idx) <> " closed")
  TabFocusCmd idx -> do
    r <- focusTabH tabsH idx
    case r of
      Left e  -> chSend h ("focus failed: " <> e)
      Right _ -> chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
  TabResumeCmd sid -> do
    r <- insertTabH tabsH (BoundSession sid) KindAi Nothing
    case r of
      Left e  -> chSend h ("resume failed: " <> e)
      Right i -> chSend h ("tab " <> T.singleton (tabIndexToChar i) <> " resumed")
  TabRenameCmd idx name -> do
    r <- renameTabH tabsH idx name
    case r of
      Left e  -> chSend h ("rename failed: " <> e)
      Right _ -> chSend h ("tab " <> T.singleton (tabIndexToChar idx) <> " renamed to " <> name)
  where
    placeholderSid = case mkSessionId "tab-session" of
      Right s -> s
      Left _  -> error "placeholder session id"
    renderTab t =
      T.singleton (tabIndexToChar (tIndex t)) <> "  " <> T.pack (show (tKind t))
        <> maybe "" ("  " <>) (tLabel t)

-- | Run one plain-text turn through the agent loop with the
-- 'MessageSource' threaded into 'aeMessageSource'. Mirrors 'runCliTui's
-- 'plainHandler' but pulls the active session's provider+model the same
-- way and builds the 'AgentEnv' with @aeMessageSource = Just ms@. The
-- 'ChannelHandle' supplies the 'ChannelCaps' (forwarded) so the agent's
-- replies go out via the Signal channel.
plainTurn
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime -> Backends
  -> ChannelHandle -> Maybe MessageSource -> Text -> IO ()
plainTurn paths rt pr sr backends h mSrc t = do
  meta <- readIORef (srActive sr)
  eprov <- resolveSessionProvider pr meta
  case eprov of
    Left err -> hPutStrLn stderr (T.unpack err)
    Right (prov, model) -> do
      let sid = smId meta
          sessionDirPath = sessionDir paths sid
      withTwoFileTranscript sessionDirPath $ \tHandle -> do
        wsRoot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath pr)
        let isaReg = buildRegistry paths rt backends wsRoot (smId meta) eCfg
            handleCaps = ChannelCaps
              { ccSend         = chSend h
              , ccPrompt       = fmap (fromRight "") . chPrompt h
              , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
              }
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsRoot) eCfg
            defaultExecBackend = EbLocal (mkLocalExecHandle wsRoot)
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        let env = (mkSessionAgentEnv
                     handleCaps prov (smProvider meta) model sid Nothing isaReg tHandle execBackend
                     (debugRequestsPath paths sid eCfg))
                    { aeMessageSource = mSrc }
        runApp appEnv (runTurn env t)

-- | Build the ISA registry for a Signal turn. Mirrors 'runCliTui's registry
-- assembly but without the AGENT_START worker (sub-agents over Signal is a
-- later phase). Kept minimal: the human-interaction, file-read, secret,
-- memory, skills, and agent-def opcodes.
buildRegistry
  :: SealPaths -> VaultRuntime -> Backends -> WorkspaceRoot -> Seal.Core.Types.SessionId
  -> Either a Seal.Config.File.FileConfig -> ISA.Registry
buildRegistry _paths rt backends wsRoot sid _eCfg =
  ISA.mkRegistry
    [ showHumanOp simpleCaps
    , askHumanOp simpleCaps
    , fileReadOp wsRoot 131072
    , secretGetOp rt
    , memoryWriteOp (bMemory backends) sid
    , memoryRecallOp defaultPageParams (bMemory backends)
    , memoryDeleteOp (bMemory backends)
    , skillWriteOp (bSkills backends) sid
    , skillReadOp (bSkills backends)
    , skillListOp (bSkills backends)
    , skillDeleteOp (bSkills backends)
    , agentDefWriteOp (bAgentDefs backends) sid
    , agentDefReadOp (bAgentDefs backends)
    , agentDefListOp (bAgentDefs backends)
    , agentDefDeleteOp (bAgentDefs backends)
    , agentInstancesOp (bRuntime backends)
    , agentStatusOp (bRuntime backends)
    , agentStopOp (bRuntime backends)
    ]
  where
    -- A minimal ChannelCaps for the human-interaction opcodes (Signal can't
    -- answer inline, so askHuman returns a deferral; this is a placeholder
    -- until the opcode is widened to ChannelHandle).
    simpleCaps = ChannelCaps
      { ccSend = \_ -> pure ()
      , ccPrompt = \_ -> pure ""
      , ccPromptSecret = \_ -> pure ""
      }

-- | Full @seal signal@ startup wiring: paths -> config -> vault -> session
-- -> backends -> registry -> spawn the Signal channel -> run the loop.
-- Mirrors 'Seal.Tui.runTui' but drives the Signal channel instead of the
-- Haskeline TUI. Resolves the @[signal]@ config section + an optional
-- vault-supplied account label; fails fast with a stderr diagnostic if
-- the account is unresolved or signal-cli is absent.
runSignalMain :: IO ()
runSignalMain = do
  paths <- getSealPaths
  ensureSealDirs paths
  let cfgPath = configFilePath paths
  cfg <- loadFileConfig cfgPath >>= \case
    Left err -> do
      hPutStrLn stderr ("Warning: could not load config: " <> T.unpack err)
      pure defaultFileConfig
    Right c  -> pure c
  -- Vault (mirrors Tui.tryOpenVault but inlined to keep this module standalone)
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
  -- The config directory is a git repo (versioning for the evolutionary stores)
  let cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  backends <- newBackends cfgRoot repo
  sessionMeta <- initSession paths cfg (bAgentDefs backends)
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
  tabsH <- newTabsHandle
  cli <- mkRealSignalCli
  let channelRt = ChannelRuntime { crConfigPath = cfgPath, crSignalCli = cli }
  let registry = mkRegistry
        [ sessionCommandSpec sr
        , modelCommandSpec pr sr
        , skillCommandSpec (bSkills backends)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , channelCommandSpec channelRt
        , tabCommandSpec tabsH
        , tabsCommandSpec tabsH
        , terseGrammarSpec
        ]
  -- Resolve the [signal] section + an optional vault-supplied account.
  -- For now the vault-supplied account is Nothing (the account comes from
  -- config); a future phase may pull it from the vault via CPS.
  case resolveSignalConfig (fcSignal cfg) Nothing of
    Left err -> hPutStrLn stderr ("seal signal: " <> T.unpack err)
    Right resolved -> runSignal paths rt pr sr registry emptyChain backends tabsH resolved

-- | Open the vault if both recipient and identity are configured. Mirrors
-- 'Seal.Tui.tryOpenVault'; duplicated here to keep this module standalone
-- (a later refactor can extract the shared startup).
tryOpenVault :: SealPaths -> FileConfig -> IO (Maybe Vault.VaultHandle)
tryOpenVault paths cfg =
  case (fcVaultRecipient cfg, fcVaultIdentity cfg) of
    (Just _, Just _) ->
      resolveEncryptor cfg >>= \case
        Left err -> do
          hPutStrLn stderr ("Warning: vault not available: " <> show err)
          pure Nothing
        Right enc -> do
          let vcfg = Vault.VaultConfig
                { Vault.vcPath    = maybe (vaultFilePath paths) T.unpack (fcVaultPath cfg)
                , Vault.vcKeyType = fromMaybe "x25519" (fcVaultKeyType cfg)
                , Vault.vcUnlock  = parseUnlockMode (fcVaultUnlock cfg)
                }
          Just <$> Vault.openVault vcfg enc
    _ -> pure Nothing