{-# LANGUAGE OverloadedStrings #-}
-- | The shared inbox-driven channel loop, used by both Signal and Telegram
-- channels (and any future inbox-driven channel). The loop pulls
-- @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route' (Layer-1 terse grammar + /tab commands BEFORE the
-- /-command registry), dispatches slash commands via a 'ChannelCaps'
-- adapter over the 'ChannelHandle', and routes plain messages to the
-- supplied 'plainHandler' (which runs 'runTurn' with 'aeMessageSource' =
-- @Just ms@). Terminates when 'chReceive' returns EOF.
-- Extracted from 'Seal.Channels.Signal.Run.runSignalLoop' so both channels
-- share the same routing logic.
--
-- The 'ChannelDeps' record bundles everything a channel turn needs to have
-- parity with the web and CLI paths: the full ISA registry (including
-- Untrusted execution opcodes, web fetch/search, harness ops, and
-- AGENT_START), the WS broker for live transcript updates, and the harness
-- + tmux + HTTP manager deps. This ensures every channel gets identical
-- transcript logging and tool-call infrastructure.
module Seal.Channels.Loop
  ( ChannelDeps (..)
  , runChannelLoop
  , handleTabCommand
  , plainTurn
  , buildIsaRegistry
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Data.Either (fromRight)
import Data.IORef (readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.IO (hPutStrLn, stderr)

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (adSystem, adModel, adProvider, AgentDef (..))
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), execBackendFromFile, mkSessionAgentEnv
  , resolveDefProvider, resolveSessionProvider, debugRequestsPath )
import Seal.Channels.Class (Channel (..))
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry, runCommandAction)
import Seal.Config.File
  ( FileConfig, defaultRetrievalMaxScanBytes, loadFileConfig, retrievalMaxScanBytes )
import Seal.Config.Paths (SealPaths (..), agentSessionDir, sessionDir)
import Seal.Core.MessageSource (MessageSource)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, askHuman, deliverNextAnswer )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (TabKind (..), tabIndexToChar)
import Seal.Handles.Transcript (withTwoFileTranscript, tfwSetSecretOps)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner, mkTmuxIdent)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import qualified Seal.ISA.Registry as ISA
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp
  , AgentWorkerBuilder )
import Seal.ISA.Ops.Code (codeExecOp)
import Seal.ISA.Ops.File (fileReadOp, fileWriteOp, filePatchOp)
import Seal.ISA.Ops.Harness (harnessListOp, harnessStartOp, harnessStopOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillReadOp, skillWriteOp )
import Seal.Routing.Route qualified as Route
import Seal.Security.Path (WorkspaceRoot (..))
import qualified Seal.Security.Policy as Policy
  ( AutonomyLevel (..), SecurityPolicy (..), AllowList (..) )
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), formatSessionId, saveSessionMeta)
import Seal.Tabs
  ( TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs )
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef (..), TabSlashCommand (..), ForceMode (..)
  , tabCount, tlTabs )
import Seal.Tools.Exec.Local (mkLocalExecHandle)
import Seal.Tools.Exec.Types (ExecBackend (..))
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Web.Fetch (webFetchOp, WebFetchConfig (..))
import Seal.Web.Search (webSearchOp, WebSearchConfig (..))

-- | The dependencies a channel turn needs to have full parity with the web
-- and CLI paths. Built once at startup (in 'Seal.Command.Serve' or the
-- standalone @seal signal@ / @seal telegram@ entry points) and shared
-- across all turns on that channel. Mirrors 'Seal.Gateway.Send.SendDeps'
-- but for inbox-driven channels.
data ChannelDeps = ChannelDeps
  { cdPaths      :: SealPaths
  , cdVault      :: VaultRuntime
  , cdProvider   :: ProviderRuntime
  , cdSession    :: SessionRuntime
  , cdBackends   :: Backends
  , cdAutonomy   :: Policy.AutonomyLevel
  , cdBroker     :: Maybe StreamBroker
    -- ^ The WS broker for pushing live transcript entries to the frontend.
    -- 'Nothing' in standalone modes (no web frontend); 'Just' under
    -- @seal serve@ so channel turns surface in the web UI in real time.
  , cdHarnessRegistry :: HarnessRegistry
    -- ^ The live harness registry (shared with the gateway). Backs
    -- HARNESS_LIST/START/STOP.
  , cdTmuxRunner  :: TmuxRunner
    -- ^ The tmux runner (real via 'mkRealTmuxRunner'; fail-closes when
    -- tmux is absent). Backs HARNESS_START/STOP.
  , cdHttpManager :: Maybe Manager
    -- ^ The shared HTTP manager (TLS-configured) for WEB_FETCH and
    -- WEB_SEARCH. 'Nothing' fail-closes those opcodes.
  , cdApprovals   :: ApprovalCache
    -- ^ The approval cache for Untrusted opcodes under 'Supervised'
    -- autonomy. Shared across all sessions.
  }

-- | The inbox-driven loop. Spawns the channel via the supplied bracket,
-- pulls @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route' (Layer-1 terse grammar + /tab commands BEFORE the
-- /-command registry), dispatches slash commands via a 'ChannelCaps'
-- adapter over the 'ChannelHandle', and routes plain messages to the
-- supplied 'plainHandler'. Terminates when 'chReceive' returns EOF.
-- The 'withChannel' bracket owns cleanup.
runChannelLoop
  :: (Channel c)
  => ((c -> IO ()) -> IO ())
  -> (ChannelHandle -> Maybe MessageSource -> Text -> IO ())
  -> Registry
  -> PreprocessChain
  -> AskReplyStore
  -> SessionRuntime
  -> TabsHandle
  -> IO ()
runChannelLoop withChannel plainHandler registry chain askReply sr tabsH =
  withChannel $ \ch -> do
    let h = toHandle ch
        handleCaps = ChannelCaps
          { ccSend         = chSend h
          , ccPrompt       = \q -> do
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
          meta <- readIORef (srActive sr)
          let sid = smId meta
          delivered <- deliverNextAnswer askReply sid body
          if delivered
            then loop h handleCaps
            else do
              case Route.route body of
                Right (Route.Focus idx) -> do
                  _ <- focusTabH tabsH idx
                  chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
                  loop h handleCaps
                Right (Route.Inject idx payload) -> do
                  _ <- focusTabH tabsH idx
                  void (forkIO (plainHandler h mSrc payload))
                  loop h handleCaps
                Right (Route.TabCommand tsc) -> do
                  _ <- handleTabCommand h tabsH tsc
                  loop h handleCaps
                Right (Route.SlashCommand _) -> do
                  d <- ingest registry chain (RawInbound body)
                  case d of
                    DispatchAction a -> runCommandAction a handleCaps >> loop h handleCaps
                    ShowText t       -> chSend h t >> loop h handleCaps
                    PlainMessage t   -> void (forkIO (plainHandler h mSrc t)) >> loop h handleCaps
                    Rejected msg     -> chSend h msg >> loop h handleCaps
                Right (Route.Plain t) -> do
                  void (forkIO (plainHandler h mSrc t))
                  loop h handleCaps
                Left (Route.ParseError e) -> do
                  chSend h e
                  loop h handleCaps

-- | Handle a parsed 'TabSlashCommand' over a channel (mutates the
-- TabsHandle, replies via chSend). Mirrors Seal.Channel.Cli.handleTabCommand.
handleTabCommand :: ChannelHandle -> TabsHandle -> TabSlashCommand -> IO ()
handleTabCommand h tabsH = \case
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
-- 'MessageSource' threaded into 'aeMessageSource'. Mirrors the web
-- 'plainTurn' ('Seal.Gateway.Send.plainTurn') and the CLI's plainHandler
-- so every channel gets identical transcript logging + tool-call
-- infrastructure:
--
--   * The full ISA registry (Untrusted execution opcodes, web fetch/search,
--     harness ops, AGENT_START) — not just the read-only subset.
--   * @session.json@ is persisted so the session appears in the web
--     frontend's sessions list.
--   * New transcript entries are broadcast to the WS broker (when present)
--     so the frontend updates live without a page refresh.
--
-- The 'ChannelHandle' supplies the 'ChannelCaps' (forwarded) so the
-- agent's replies go out via the channel. The ask/reply store backs
-- ASK_HUMAN. Generic — used by any inbox-driven channel.
plainTurn
  :: ChannelDeps -> ChannelHandle -> AskReplyStore
  -> Maybe MessageSource -> Text -> IO ()
plainTurn deps h askReply mSrc t = do
  let sr = cdSession deps
      pr = cdProvider deps
      paths = cdPaths deps
      backends = cdBackends deps
      rt = cdVault deps
      autonomy = cdAutonomy deps
      approvals = cdApprovals deps
  meta <- readIORef (srActive sr)
  eprov <- resolveSessionProvider pr meta
  case eprov of
    Left err -> hPutStrLn stderr (T.unpack err)
    Right (prov, model) -> do
      let sid = smId meta
          sessionDirPath = sessionDir paths sid
      createDirectoryIfMissing True sessionDirPath
      -- Persist session.json so the session appears in the web frontend's
      -- sessions list (listSessions scans for session.json). The standalone
      -- modes (seal signal/telegram) already persist via initSession; under
      -- seal serve the active session is an in-memory web meta that was
      -- never saved — this write lands it on disk so the frontend can see
      -- sessions created by channel activity. saveSessionMeta is atomic
      -- (tmp → chmod 0600 → rename) and idempotent, so re-saving an
      -- already-persisted session is a no-op.
      saveSessionMeta paths meta
      withTwoFileTranscript sessionDirPath $ \tHandle -> do
        wsroot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath pr)
        let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsroot) eCfg
            defaultExecBackend = EbLocal (mkLocalExecHandle wsroot)
        -- Resolve the bound agent's system prompt (re-read per turn; agent
        -- dirs are small). Nothing when no agent is bound or the def has no
        -- system prompt. Mirrors 'runCliTui's plainHandler.
        mSystem <- case smAgent meta of
          Nothing  -> pure Nothing
          Just aid -> maybe Nothing adSystem <$> Def.adbRead (bAgentDefs backends) aid
        let handleCaps = ChannelCaps
              { ccSend         = chSend h
              , ccPrompt       = \q -> do
                  outcome <- askHuman askReply sid q (\_qid -> chSend h q)
                  pure (fromRight "" outcome)
              , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
              }
            mintSession = channelMintSession sid
            isaReg = buildIsaRegistry
              rt backends wsroot sid operatorCeiling execBackend autonomy
              mintSession
              (channelMkWorker deps paths sid handleCaps execBackend appEnv eCfg isaReg)
              (cdHarnessRegistry deps) (cdTmuxRunner deps)
              (cdHttpManager deps) handleCaps
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        let env = (mkSessionAgentEnv
                     handleCaps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
                     (debugRequestsPath paths sid eCfg) autonomy approvals
                     (broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta)))
                    { aeMessageSource = mSrc }
        runApp appEnv (runTurn env t)
        -- Broadcast new entries after the turn so the frontend sees the
        -- final state (mirrors the web plainTurn).
        broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta)

-- | Build the ISA registry for a channel turn. Mirrors
-- 'Seal.Gateway.Send.buildWebRegistry' so channels have the SAME tool set
-- as the web and CLI paths: the full Untrusted execution opcodes (SHELL_EXEC,
-- CODE_EXEC, PROCESS_MANAGE, FILE_WRITE, FILE_PATCH, SEARCH_FILES), web
-- fetch/search, harness ops, and AGENT_START (sub-agents). The
-- human-interaction opcodes are wired to the ask/reply store via the
-- per-turn 'ChannelCaps' so ASK_HUMAN surfaces the question to the peer
-- and blocks until the next inbound message delivers the answer.
buildIsaRegistry
  :: VaultRuntime -> Backends -> WorkspaceRoot -> SessionId -> Int
  -> ExecBackend -> Policy.AutonomyLevel
  -> IO SessionId            -- ^ mint a fresh SessionId for a forked agent
  -> AgentWorkerBuilder       -- ^ the AGENT_START worker
  -> HarnessRegistry          -- ^ the live harness registry (shared)
  -> TmuxRunner               -- ^ the tmux runner
  -> Maybe Manager            -- ^ shared HTTP manager for WEB_FETCH / WEB_SEARCH
  -> ChannelCaps              -- ^ the per-turn caps (ASK_HUMAN/SHOW_HUMAN)
  -> ISA.Registry
buildIsaRegistry rt backends wsRoot sid operatorCeiling execBackend autonomy
                 mintSession mkWorker harnessReg tmuxRunner httpManager caps =
  ISA.mkRegistry
    [ showHumanOp caps
    , askHumanOp caps
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
    , agentStartOp (bAgentDefs backends) (bRuntime backends) mintSession mkWorker
    , agentStatusOp (bRuntime backends)
    , agentStopOp (bRuntime backends)
    , searchFilesOp wsRoot securityPolicy operatorCeiling execBackend
    , fileReadOp wsRoot operatorCeiling
    , fileWriteOp wsRoot operatorCeiling
    , filePatchOp wsRoot
    , shellExecOp wsRoot securityPolicy execBackend
    , codeExecOp wsRoot securityPolicy codeAllowList execBackend
    , processManageOp wsRoot securityPolicy execBackend
    , webFetchOp webFetchCfg
    , webSearchOp webSearchCfg
    , harnessListOp harnessReg
    , harnessStartOp harnessReg tmuxRunner harnessSession harnessWindow
        HfGeneric newHarnessId
    , harnessStopOp harnessReg tmuxRunner
    ]
  where
    securityPolicy = Policy.SecurityPolicy Policy.AllowAll autonomy
    codeAllowList = Set.fromList ["python3", "node", "bash", "sh"]
    webSearchCfg = WebSearchConfig
      { wscManager   = httpManager
      , wscEndpoint  = ""
      , wscAllowList = []
      , wscAuthKey   = Nothing
      }
    webFetchCfg = WebFetchConfig
      { wfcManager   = httpManager
      , wfcAllowList = []
      , wfcMaxBytes  = operatorCeiling
      , wfcAuthKey   = Nothing
      }
    harnessSession = either (error "unreachable: seal is a valid TmuxIdent") id (mkTmuxIdent "seal")
    harnessWindow  = either (error "unreachable: harness is a valid TmuxIdent") id (mkTmuxIdent "harness")

-- | Mint a fresh 'SessionId' for a forked agent instance (mirrors the CLI's
-- 'mintAgentSession' and the web's 'webMintSession'). Each start gets its
-- own timestamped id.
channelMintSession :: SessionId -> IO SessionId
channelMintSession fallback = do
  now <- getCurrentTime
  case mkSessionId (formatSessionId now) of
    Right s  -> pure s
    Left _e  -> pure fallback

-- | The AGENT_START worker-builder for inbox-driven channels. Mirrors the
-- CLI's 'mkWorker' and the web's 'webMkWorker': resolve the def's
-- provider+model, open a fresh two-file transcript under the parent
-- session's agents dir, build a fresh 'AgentEnv' bound to the child
-- session + child transcript, and run the turn. The child shares the
-- parent's 'isaReg' (same tool set) but gets its OWN 'TwoFileHandle' so
-- its conversation/entries stay separate.
channelMkWorker
  :: ChannelDeps -> SealPaths -> SessionId -> ChannelCaps -> ExecBackend -> Env
  -> Either a Seal.Config.File.FileConfig -> ISA.Registry -> AgentWorkerBuilder
channelMkWorker deps paths parentSid caps execBackend appEnv eCfg isaReg def childSid = do
  let childDir = agentSessionDir paths parentSid childSid
  createDirectoryIfMissing True childDir
  active <- readIORef (srActive (cdSession deps))
  let fallBackProvider = if T.null (adProvider def) then smProvider active else adProvider def
      fallBackModel = case adModel def of
        ModelId m | T.null m -> smModel active
                  | otherwise -> m
  eChildProv <- resolveDefProvider (cdProvider deps) fallBackProvider (ModelId fallBackModel)
  case eChildProv of
    Left err -> ccSend caps ("agent start failed: " <> err)
    Right (childProv, childModel) ->
      withTwoFileTranscript childDir $ \childTHandle -> do
        let childEnv = mkSessionAgentEnv
              caps childProv fallBackProvider childModel childSid
              (adSystem def) isaReg childTHandle execBackend
              (debugRequestsPath paths childSid eCfg) (cdAutonomy deps) (cdApprovals deps)
              (broadcastNewEntries (cdBroker deps) paths childSid (modelText childModel) (smCreatedAt active))
        runApp appEnv (runTurn childEnv "")

-- | Extract the 'Text' from a 'ModelId'.
modelText :: ModelId -> Text
modelText (ModelId t) = t

-- | Broadcast new transcript entries over the WS broker so the frontend
-- updates live without a page refresh. Reads the full transcript from disk
-- and broadcasts every entry — the frontend dedupes by id, so already-seen
-- entries are no-ops. 'Nothing' broker (standalone modes, tests) is a no-op.
-- Mirrors 'Seal.Gateway.Send.broadcastNewEntries'.
broadcastNewEntries
  :: Maybe StreamBroker -> SealPaths -> SessionId -> Text -> UTCTime -> IO ()
broadcastNewEntries mBroker paths sid model createdAt =
  case mBroker of
    Nothing -> pure ()
    Just broker -> do
      entries <- readTranscriptEntries paths model (showIso createdAt) sid
      mapM_ (broadcast broker . BeEntryRecorded sid) entries