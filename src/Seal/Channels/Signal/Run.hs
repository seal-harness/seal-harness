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

import Control.Concurrent (forkIO)
import Control.Monad (void)
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
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, askHuman, deliverNextAnswer, newApprovalCache
  , newAskReplyStore )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (tabIndexToChar, TabKind (..))
import Seal.Handles.Transcript (withTwoFileTranscript, tfwSetSecretOps)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), emptyChain, ingest)
import Seal.Routing.Route qualified
import Seal.Security.Policy (AutonomyLevel)
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
  -> AskReplyStore
  -> AutonomyLevel
  -> ApprovalCache
  -> IO ()
runSignal paths rt pr sr registry chain backends tabsH (account, chunkLimit, allow) askReply autonomy approvals = do
  let accountLabel = signalAccountText account
  eTransport <- mkRealSignalTransport accountLabel
  case eTransport of
    Left err -> hPutStrLn stderr ("seal signal: " <> T.unpack err)
    Right transport ->
      runSignalLoop registry chain (allow, chunkLimit) account transport tabsH askReply sr $
        \h -> plainTurn paths rt pr sr backends h askReply autonomy approvals

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
  -> AskReplyStore
  -> SessionRuntime
  -> (ChannelHandle -> Maybe MessageSource -> Text -> IO ())
  -> IO ()
runSignalLoop registry chain (allow, chunkLimit) account transport tabsH askReply sr plainHandler =
  withSignalChannel (allow, chunkLimit) account transport $ \ch -> do
    let h = toHandle ch
        handleCaps = ChannelCaps
          { ccSend         = chSend h
          , ccPrompt       = \q -> do
              -- Bind the pending question to the active session so the
              -- next inbound message from the peer (delivered via
              -- 'deliverNextAnswer' in the loop below) unblocks this thread.
              meta <- readIORef (srActive sr)
              let sid = smId meta
              outcome <- askHuman askReply sid q (\_qid -> chSend h q)
              pure (fromRight "" outcome)
          , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
          }
    loop h handleCaps
  where
    loop h handleCaps = do
      (mSrc, body) <- chReceive h
      case mSrc of
        Nothing -> pure ()  -- EOF: reader exited + inbox drained
        Just _ms -> do
          -- First, try to deliver the inbound message as the answer to the
          -- oldest pending ASK_HUMAN question for the active session. If it
          -- matches, the waiting agent-loop thread unblocks and the message
          -- is consumed as the answer (NOT routed as a plain turn). If no
          -- question is pending, the message is a normal inbound turn.
          meta <- readIORef (srActive sr)
          let sid = smId meta
          delivered <- deliverNextAnswer askReply sid body
          if delivered
            then loop h handleCaps
            else do
              -- Layer-1 routing: check the terse /N grammar + /tab commands
              -- BEFORE the /-command registry. Plain turns are forked so the
              -- main loop keeps receiving + delivering answers while the
              -- agent loop blocks on ASK_HUMAN.
              case Seal.Routing.Route.route body of
                Right (Seal.Routing.Route.Focus idx) -> do
                  _ <- focusTabH tabsH idx
                  chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
                  loop h handleCaps
                Right (Seal.Routing.Route.Inject idx payload) -> do
                  _ <- focusTabH tabsH idx
                  void (forkIO (plainHandler h mSrc payload))
                  loop h handleCaps
                Right (Seal.Routing.Route.TabCommand tsc) -> do
                  _ <- handleTabCommand' h tabsH tsc
                  loop h handleCaps
                Right (Seal.Routing.Route.SlashCommand _) -> do
                  d <- ingest registry chain (RawInbound body)
                  case d of
                    DispatchAction a -> runCommandAction a handleCaps >> loop h handleCaps
                    ShowText t       -> chSend h t >> loop h handleCaps
                    PlainMessage t   -> void (forkIO (plainHandler h mSrc t)) >> loop h handleCaps
                    Rejected msg     -> chSend h msg >> loop h handleCaps
                Right (Seal.Routing.Route.Plain t) -> do
                  void (forkIO (plainHandler h mSrc t))
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
-- replies go out via the Signal channel. The ask/reply store backs
-- ASK_HUMAN: 'ccPrompt' blocks the agent-loop thread on the store until the
-- next inbound message from the peer is delivered as the answer (by
-- 'deliverNextAnswer' in 'runSignalLoop'). The turn runs in a forked thread
-- so the main loop keeps receiving + delivering answers while the agent
-- blocks.
plainTurn
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime -> Backends
  -> ChannelHandle -> AskReplyStore -> AutonomyLevel -> ApprovalCache
  -> Maybe MessageSource -> Text -> IO ()
plainTurn paths rt pr sr backends h askReply autonomy approvals mSrc t = do
  meta <- readIORef (srActive sr)
  eprov <- resolveSessionProvider pr meta
  case eprov of
    Left err -> hPutStrLn stderr (T.unpack err)
    Right (prov, model) -> do
      let sid = smId meta
          sessionDirPath = sessionDir paths sid
      withTwoFileTranscript sessionDirPath $ \tHandle -> do
        wsroot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath pr)
        let isaReg = buildRegistry paths rt backends wsroot (smId meta) eCfg askReply h sid
            handleCaps = ChannelCaps
              { ccSend         = chSend h
              , ccPrompt       = \q -> do
                  outcome <- askHuman askReply sid q (\_qid -> chSend h q)
                  pure (fromRight "" outcome)
              , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
              }
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsroot) eCfg
            defaultExecBackend = EbLocal (mkLocalExecHandle wsroot)
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        let env = (mkSessionAgentEnv
                     handleCaps prov (smProvider meta) model sid Nothing isaReg tHandle execBackend
                     (debugRequestsPath paths sid eCfg) autonomy approvals (pure ()))
                    { aeMessageSource = mSrc }
        runApp appEnv (runTurn env t)

-- | Build the ISA registry for a Signal turn. Mirrors 'runCliTui's registry
-- assembly but without the AGENT_START worker (sub-agents over Signal is a
-- later phase). The human-interaction opcodes are wired to the ask/reply
-- store via the per-turn 'ChannelCaps' so ASK_HUMAN surfaces the question to
-- the peer and blocks until the next inbound message delivers the answer.
buildRegistry
  :: SealPaths -> VaultRuntime -> Backends -> WorkspaceRoot -> Seal.Core.Types.SessionId
  -> Either a Seal.Config.File.FileConfig -> AskReplyStore -> ChannelHandle
  -> Seal.Core.Types.SessionId
  -> ISA.Registry
buildRegistry _paths rt backends wsRoot sid _eCfg askReply h _activeSid =
  ISA.mkRegistry
    [ showHumanOp caps
    , askHumanOp caps
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
    -- The per-turn caps for the human-interaction opcodes. ASK_HUMAN mints
    -- a pending question in the store, sends the question to the peer via
    -- chSend, and blocks until the next inbound message is delivered as the
    -- answer (by 'deliverNextAnswer' in 'runSignalLoop').
    caps = ChannelCaps
      { ccSend         = chSend h
      , ccPrompt       = \q -> do
          outcome <- askHuman askReply sid q (\_qid -> chSend h q)
          pure (fromRight "" outcome)
      , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
      }

-- | Full @seal signal@ startup wiring: paths -> config -> vault -> session
-- -> backends -> registry -> spawn the Signal channel -> run the loop.
-- Mirrors 'Seal.Tui.runTui' but drives the Signal channel instead of the
-- Haskeline TUI. Resolves the @[signal]@ config section + an optional
-- vault-supplied account label; fails fast with a stderr diagnostic if
-- the account is unresolved or signal-cli is absent. The autonomy level
-- threads through to 'mkSessionAgentEnv' so 'Supervised' (the default)
-- prompts before running Untrusted opcodes (the next inbound message from
-- the peer delivers the answer via the ask/reply store).
runSignalMain :: Seal.Security.Policy.AutonomyLevel -> IO ()
runSignalMain autonomy = do
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
  let registry = mkRegistry
        [ sessionCommandSpec sr
        , modelCommandSpec pr sr
        , skillCommandSpec (bSkills backends)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , tabCommandSpec tabsH
        , tabsCommandSpec tabsH
        , terseGrammarSpec
        ]
  -- Resolve the [signal] section + an optional vault-supplied account.
  -- For now the vault-supplied account is Nothing (the account comes from
  -- config); a future phase may pull it from the vault via CPS.
  askReply <- newAskReplyStore 0  -- 0 = block indefinitely (no timeout)
  approvals <- newApprovalCache
  case resolveSignalConfig (fcSignal cfg) Nothing of
    Left err -> hPutStrLn stderr ("seal signal: " <> T.unpack err)
    Right resolved -> runSignal paths rt pr sr registry emptyChain backends tabsH resolved askReply autonomy approvals

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