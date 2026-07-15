{-# LANGUAGE OverloadedStrings #-}
-- | The shared inbox-driven channel loop, used by both Signal and Telegram
-- channels (and any future inbox-driven channel). The loop pulls
-- @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route' (Layer-1 terse grammar + /tab commands BEFORE the
-- /-command registry), dispatches slash commands via a 'ChannelCaps'
-- adapter over the 'ChannelHandle', and routes plain messages to the
-- supplied 'plainHandler' (which runs 'runTurn' with 'aeMessageSource' =
-- @Just ms@). Terminates when 'chReceive' returns EOF.
--
-- The 'ChannelDeps' record bundles everything a channel turn needs to have
-- parity with the web and CLI paths: the full ISA registry (including
-- Untrusted execution opcodes, web fetch/search, harness ops, and
-- AGENT_START), the WS broker for live transcript updates, and the harness
-- + tmux + HTTP manager deps. This ensures every channel gets identical
-- transcript logging and tool-call infrastructure.
--
-- == Tab-centric session model
--
-- Each conversation (a Telegram chat, a Signal conversation) has its own
-- cursor into the shared tab list ('CursorStore'). On first message from
-- a conversation, a new tab + session is created and the cursor is set.
-- Subsequent messages resolve the session via the cursor → tab → SessionId
-- path, NOT via a shared active-session ref. This means @/tab focus N@
-- on one Telegram conversation only affects that conversation — other
-- conversations keep their own cursor. The web frontend has no cursor; it
-- sends to a specific session by id (the tab the user clicked).
--
-- Replies fan out to all channels focused on the session via the
-- 'ReplyRegistry' — so a web-originated turn on a Telegram-session tab
-- also delivers the reply to Telegram. A per-session write lock
-- ('SessionLocks') serializes concurrent turns on the same session to
-- prevent transcript corruption.
module Seal.Channels.Loop
  ( ChannelDeps (..)
  , newChannelDeps
  , runChannelLoop
  , handleTabCommand
  , plainTurn
  , buildIsaRegistry
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))
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
import Seal.Channels.Cursor
  ( CursorStore, cursorLookup, cursorSet, newCursorStore )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry, runCommandAction)
import Seal.Config.File
  ( FileConfig, defaultRetrievalMaxScanBytes, loadFileConfig, retrievalMaxScanBytes )
import Seal.Config.Paths (SealPaths (..), agentSessionDir, sessionDir)
import Seal.Core.ChannelKind (ChannelKind (..), channelKindToText)
import Seal.Core.MessageSource
  ( MessageSource, conversationIdText, msChannelKind, msConversationId )
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, askHuman, deliverNextAnswer )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (TabKind (..), TabIndex, tabIndexToChar)
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
import Seal.Session.Lock
  ( ReplyRegistry, newReplyRegistry, replySubscribe
  , SessionLocks, newSessionLocks, withSessionLock )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, formatSessionId, newSessionMeta
  , resolveDefaultAgent, saveSessionMeta )
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
  , cdBackends   :: Backends
  , cdAutonomy   :: Policy.AutonomyLevel
  , cdBroker     :: Maybe StreamBroker
    -- ^ The WS broker for pushing live transcript entries to the frontend.
    -- 'Nothing' in standalone modes (no web frontend); 'Just' under
    -- @seal serve@ so channel turns surface in the web UI in real time.
  , cdHarnessRegistry :: HarnessRegistry
  , cdTmuxRunner  :: TmuxRunner
  , cdHttpManager :: Maybe Manager
  , cdApprovals   :: ApprovalCache
  , cdCursors     :: CursorStore
    -- ^ Per-conversation tab cursors. Each conversation (Telegram chat,
    -- Signal conversation) has its own cursor into the shared tab list.
  , cdReplies     :: ReplyRegistry
    -- ^ Per-session reply fan-out registry. Channels subscribe their
    -- 'ChannelHandle' when they focus a tab; replies are fanned out to
    -- all subscribed handles after each turn.
  , cdLocks       :: SessionLocks
    -- ^ Per-session write locks. Serializes concurrent turns on the same
    -- session to prevent transcript corruption.
  , cdConfig      :: IO FileConfig
    -- ^ Load the current config (re-read per turn so config changes take
    -- effect without a restart). Used for default provider/model/agent
    -- when creating a new session for a conversation.
  }

-- | Build a 'ChannelDeps' with fresh cursor/reply/lock stores and the
-- given config loader. Used by 'Seal.Command.Serve' and the standalone
-- entry points.
newChannelDeps
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> Backends
  -> Policy.AutonomyLevel -> Maybe StreamBroker
  -> HarnessRegistry -> TmuxRunner -> Maybe Manager
  -> ApprovalCache -> IO FileConfig
  -> IO ChannelDeps
newChannelDeps paths vault provider backends autonomy broker
               harnessReg tmux httpMgr approvals loadCfg = do
  cursors <- newCursorStore
  replies <- newReplyRegistry
  locks   <- newSessionLocks
  pure ChannelDeps
    { cdPaths      = paths
    , cdVault      = vault
    , cdProvider   = provider
    , cdBackends   = backends
    , cdAutonomy   = autonomy
    , cdBroker     = broker
    , cdHarnessRegistry = harnessReg
    , cdTmuxRunner  = tmux
    , cdHttpManager = httpMgr
    , cdApprovals   = approvals
    , cdCursors     = cursors
    , cdReplies     = replies
    , cdLocks       = locks
    , cdConfig      = loadCfg
    }

-- | The conversation key for the cursor store: (channel-kind-text,
-- conversation-id-text). Derived from the 'MessageSource' (both fields
-- are server-derived, never user-supplied, so a sender cannot forge a
-- cursor key).
convKey :: MessageSource -> (Text, Text)
convKey ms = (channelKindToText (msChannelKind ms), conversationIdText (msConversationId ms))

-- | The inbox-driven loop. Spawns the channel via the supplied bracket,
-- pulls @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route', and dispatches. Each conversation resolves its
-- session via the cursor store (not a shared active-session ref). On
-- first message from a conversation, a new tab + session is created.
runChannelLoop
  :: (Channel c)
  => ChannelDeps
  -> ((c -> IO ()) -> IO ())
  -> (ChannelHandle -> SessionMeta -> Maybe MessageSource -> Text -> IO ())
  -> Registry
  -> PreprocessChain
  -> AskReplyStore
  -> TabsHandle
  -> IO ()
runChannelLoop deps withChannel plainHandler registry chain askReply tabsH =
  withChannel $ \ch -> do
    let h = toHandle ch
    loop h
  where
    loop h = do
      (mSrc, body) <- chReceive h
      case mSrc of
        Nothing -> pure ()  -- EOF
        Just ms -> do
          let key = convKey ms
          -- Resolve the conversation's session (create if first message).
          mCursor <- cursorLookup (cdCursors deps) key
          meta <- case mCursor of
            Just tabRef -> do
              mMeta <- resolveTabSession deps tabRef
              case mMeta of
                Just m  -> pure m
                Nothing -> createConversationSession deps h key (msChannelKind ms) tabsH
            Nothing -> createConversationSession deps h key (msChannelKind ms) tabsH
          let sid = smId meta
          delivered <- deliverNextAnswer askReply sid body
          if delivered
            then loop h
            else do
              let handleCaps = mkHandleCaps h askReply sid
              case Route.route body of
                Right (Route.Focus idx) -> do
                  _ <- focusTabH tabsH idx
                  tl <- snapshotTabs tabsH
                  case lookupTabByIndex tl idx of
                    Just tab -> cursorSet (cdCursors deps) key (tRef tab)
                    Nothing -> pure ()
                  chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
                  loop h
                Right (Route.Inject idx payload) -> do
                  _ <- focusTabH tabsH idx
                  void (forkIO (plainHandler h meta (Just ms) payload))
                  loop h
                Right (Route.TabCommand tsc) -> do
                  _ <- handleTabCommand h tabsH tsc
                  loop h
                Right (Route.SlashCommand _) -> do
                  d <- ingest registry chain (RawInbound body)
                  case d of
                    DispatchAction a -> runCommandAction a handleCaps >> loop h
                    ShowText t       -> chSend h t >> loop h
                    PlainMessage t   -> void (forkIO (plainHandler h meta (Just ms) t)) >> loop h
                    Rejected msg     -> chSend h msg >> loop h
                Right (Route.Plain t) -> do
                  void (forkIO (plainHandler h meta (Just ms) t))
                  loop h
                Left (Route.ParseError e) -> do
                  chSend h e
                  loop h

-- | Build the per-turn 'ChannelCaps' for a channel handle.
mkHandleCaps :: ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps
mkHandleCaps h askReply sid = ChannelCaps
  { ccSend         = chSend h
  , ccPrompt       = \q -> do
      outcome <- askHuman askReply sid q (\_qid -> chSend h q)
      pure (fromRight "" outcome)
  , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
  }

-- | Look up a tab by index in a 'TabList'.
lookupTabByIndex :: TabList -> Seal.Handles.Tab.TabIndex -> Maybe Tab
lookupTabByIndex tl idx = go (tlTabs tl)
  where
    go [] = Nothing
    go (t:rest) | tIndex t == idx = Just t
                | otherwise       = go rest

-- | Resolve a 'TabRef' to its session meta by loading from disk.
-- 'Nothing' if the tab was closed or the session.json is missing.
resolveTabSession :: ChannelDeps -> TabRef -> IO (Maybe SessionMeta)
resolveTabSession deps ref = case ref of
  BoundSession sid -> do
    let mp = sessionDir (cdPaths deps) sid </> "session.json"
    exists <- doesFileExist mp
    if not exists
      then pure Nothing
      else (A.decode <$> BL.readFile mp) :: IO (Maybe SessionMeta)
  BoundHarness _   -> pure Nothing

-- | Create a new session + tab for a conversation that has no cursor yet.
-- Mints a 'SessionMeta' from config defaults, persists it, inserts a tab
-- into the shared 'TabsHandle', and sets the conversation's cursor.
createConversationSession
  :: ChannelDeps -> ChannelHandle -> (Text, Text) -> ChannelKind
  -> TabsHandle -> IO SessionMeta
createConversationSession deps _h key kind tabsH = do
  cfg <- cdConfig deps
  (mAgent, mProv, mModel) <- resolveDefaultAgent (bAgentDefs (cdBackends deps)) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
      channelLabel = channelKindToText kind
  meta <- newSessionMeta (cdPaths deps) provider model channelLabel mAgent
  saveSessionMeta (cdPaths deps) meta
  r <- insertTabH tabsH (BoundSession (smId meta)) KindAi Nothing
  case r of
    Left _ -> pure ()  -- tab list full; session still works without a tab
    Right _ -> cursorSet (cdCursors deps) key (BoundSession (smId meta))
  pure meta

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
-- 'MessageSource' threaded into 'aeMessageSource'. Takes the resolved
-- 'SessionMeta' (from the cursor → tab → SessionId path) rather than
-- reading a shared active-session ref. Acquires the per-session write
-- lock to prevent concurrent transcript corruption. After the turn, the
-- reply is fanned out to all channels subscribed to this session.
plainTurn
  :: ChannelDeps -> ChannelHandle -> AskReplyStore
  -> SessionMeta -> Maybe MessageSource -> Text -> IO ()
plainTurn deps h askReply meta mSrc t = do
  let pr = cdProvider deps
      paths = cdPaths deps
      backends = cdBackends deps
      rt = cdVault deps
      autonomy = cdAutonomy deps
      approvals = cdApprovals deps
      sid = smId meta
  eprov <- resolveSessionProvider pr meta
  case eprov of
    Left err -> hPutStrLn stderr (T.unpack err)
    Right (prov, model) -> do
      let sessionDirPath = sessionDir paths sid
      createDirectoryIfMissing True sessionDirPath
      saveSessionMeta paths meta
      -- Subscribe this channel handle to the session's replies (so the
      -- reply fan-out after the turn delivers the assistant response to
      -- this channel). The guard is stored so we can unsubscribe later
      -- (e.g. when the conversation focuses a different tab).
      _guard <- replySubscribe (cdReplies deps) h sid
      withSessionLock (cdLocks deps) sid $ do
        withTwoFileTranscript sessionDirPath $ \tHandle -> do
          wsroot <- WorkspaceRoot <$> getCurrentDirectory
          appEnv <- mkEnv defaultConfig
          eCfg <- loadFileConfig (prConfigPath pr)
          let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
              execBackend = either (const defaultExecBackend) (execBackendFromFile wsroot) eCfg
              defaultExecBackend = EbLocal (mkLocalExecHandle wsroot)
          mSystem <- case smAgent meta of
            Nothing  -> pure Nothing
            Just aid -> maybe Nothing adSystem <$> Def.adbRead (bAgentDefs backends) aid
          let handleCaps = mkHandleCaps h askReply sid
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
          broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta)

-- | Build the ISA registry for a channel turn. Mirrors
-- 'Seal.Gateway.Send.buildWebRegistry' so channels have the SAME tool set
-- as the web and CLI paths.
buildIsaRegistry
  :: VaultRuntime -> Backends -> WorkspaceRoot -> SessionId -> Int
  -> ExecBackend -> Policy.AutonomyLevel
  -> IO SessionId
  -> AgentWorkerBuilder
  -> HarnessRegistry
  -> TmuxRunner
  -> Maybe Manager
  -> ChannelCaps
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

-- | Mint a fresh 'SessionId' for a forked agent instance.
channelMintSession :: SessionId -> IO SessionId
channelMintSession fallback = do
  now <- getCurrentTime
  case mkSessionId (formatSessionId now) of
    Right s  -> pure s
    Left _e  -> pure fallback

-- | The AGENT_START worker-builder for inbox-driven channels.
channelMkWorker
  :: ChannelDeps -> SealPaths -> SessionId -> ChannelCaps -> ExecBackend -> Env
  -> Either a FileConfig -> ISA.Registry -> AgentWorkerBuilder
channelMkWorker deps paths parentSid caps execBackend appEnv eCfg isaReg def childSid = do
  let childDir = agentSessionDir paths parentSid childSid
  createDirectoryIfMissing True childDir
  -- Load the parent session meta from disk for fallback provider/model.
  mParentMeta <- loadMeta paths parentSid
  now <- getCurrentTime
  let parent = fromMaybe (fallbackMeta now) mParentMeta
      fallBackProvider = if T.null (adProvider def) then smProvider parent else adProvider def
      fallBackModel = case adModel def of
        ModelId m | T.null m -> smModel parent
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
              (broadcastNewEntries (cdBroker deps) paths childSid (modelText childModel) (smCreatedAt parent))
        runApp appEnv (runTurn childEnv "")
  where
    fallbackMeta t = SessionMeta
      { smId = parentSid, smProvider = "ollama", smModel = "glm-5.2:cloud"
      , smChannel = "cli", smAgent = Nothing
      , smCreatedAt = t, smLastActive = t }
    loadMeta p sid = do
      let mp = sessionDir p sid </> "session.json"
      exists <- doesFileExist mp
      if not exists
        then pure Nothing
        else (A.decode <$> BL.readFile mp) :: IO (Maybe SessionMeta)

-- | Extract the 'Text' from a 'ModelId'.
modelText :: ModelId -> Text
modelText (ModelId t) = t

-- | Broadcast new transcript entries over the WS broker.
broadcastNewEntries
  :: Maybe StreamBroker -> SealPaths -> SessionId -> Text -> UTCTime -> IO ()
broadcastNewEntries mBroker paths sid model createdAt =
  case mBroker of
    Nothing -> pure ()
    Just broker -> do
      entries <- readTranscriptEntries paths model (showIso createdAt) sid
      mapM_ (broadcast broker . BeEntryRecorded sid) entries