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
  , mkBgRunner
  , channelCallDispatcher
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (adSystem, adModel, adProvider, AgentDef (..))
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Delegation
  ( fromFileConfig, ChildTask (..), AgentWorkerBuilder )
import Seal.Agent.Runtime.Delegation.Worker
  ( mkDelegateWorker, filterBlocklisted, DelegationWorkerDeps (..) )
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), untrustedIOFromSecurity, mkSessionAgentEnv
  , resolveDefProvider, resolveSessionProvider, debugRequestsPath )
import Seal.Channels.Class (Channel (..))
import Seal.Channels.Cursor
  ( CursorStore, cursorLookup, cursorSet, cursorMigrateAll, newCursorStore )
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec)
import Seal.Command.Call (CallDispatcher, callCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (CommandAction (..), Registry, mkRegistry, registrySpecs, runCommandAction)
import Seal.Config.File
  ( RuntimeConfig, defaultRetrievalMaxScanBytes, loadRuntimeConfig, retrievalMaxScanBytes
  , onDemandSchemas, rcDelegation, WebConfig (..), rcWeb, resolvedAutoloadSkill )
import Seal.Config.Security (loadSecurityConfig)
import Seal.Config.Paths (SealPaths (..), securityFilePath, sessionDir)
import Seal.Core.ChannelKind (ChannelKind (..), channelKindToText)
import Seal.Core.MessageSource
  ( MessageSource, conversationIdText, msChannelKind, msConversationId )
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId, sessionIdText)
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
import Seal.ISA.Dispatch (dispatch, recordSkillLoadResult)
import qualified Seal.ISA.Registry as ISA
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp
  , agentInterruptOp, AgentStartWiring (..) )
import Seal.ISA.Opcode (localBackend, opName)
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.ISA.Ops.File (fileReadOp, fileWriteOp, filePatchOp)
import Seal.ISA.Ops.Harness (harnessListOp, harnessStartOp, harnessStopOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Registry (opcodeDescribeOp, opcodeListOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillLoadOp, skillWriteOp )
import Seal.Routing.Route qualified as Route
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.Workdir (ensureSessionWorkdir, mkSessionUntrustedIO)
import Seal.Skills.Autoload (injectAutoloadSkill)
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
  ( TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, rebindTabH
  , snapshotTabs )
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef (..), TabSlashCommand (..), ForceMode (..)
  , tabCount, tlTabs )
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub, UntrustedIO)
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
  , cdConfig      :: IO RuntimeConfig
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
  -> ApprovalCache -> IO RuntimeConfig
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
    -- A mutable cell holding the originating conversation's active session
    -- id, updated each turn before any slash command is dispatched. The
    -- /bg runner reads it to key the confirmation ask to the conversation
    -- (not the fresh bg session), so the loop's deliverNextAnswer
    -- short-circuit consumes the next inbound message as the answer. The
    -- initial bottom is never read: the loop writes the real sid before
    -- any /bg dispatch.
    bgConvSid <- newIORef (error "bgConvSid: set before first dispatch" :: SessionId)
    let bgRunner = mkBgRunner deps h askReply bgConvSid
        callDispatcher = channelCallDispatcher deps h askReply bgConvSid
        registryWithBg = mkRegistry (registrySpecs registry <>
          [ backgroundCommandSpec bgRunner
          , callCommandSpec callDispatcher
          , skillCommandSpec (bSkills (cdBackends deps)) callDispatcher
          ])
    loop h registryWithBg bgConvSid
  where
    loop h reg bgConvSid = do
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
          -- Record the conversation's active session so the /bg runner
          -- (dispatched below if this turn is a /bg) keys its
          -- confirmation ask to this sid. Updated every turn, before any
          -- slash-command dispatch.
          writeIORef bgConvSid sid
          delivered <- deliverNextAnswer askReply sid body
          if delivered
            then loop h reg bgConvSid
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
                  loop h reg bgConvSid
                Right (Route.Inject idx payload) -> do
                  _ <- focusTabH tabsH idx
                  void (forkIO (plainHandler h meta (Just ms) payload))
                  loop h reg bgConvSid
                Right (Route.TabCommand tsc) -> do
                  _ <- handleTabCommand h tabsH tsc
                  loop h reg bgConvSid
                Right Route.NewSession -> do
                  _ <- handleNewSession deps h tabsH (msChannelKind ms) meta
                  loop h reg bgConvSid
                Right (Route.SlashCommand _) -> do
                  d <- ingest reg chain (RawInbound body)
                  case d of
                    DispatchAction a -> runCommandAction a handleCaps >> loop h reg bgConvSid
                    ShowText t       -> chSend h t >> loop h reg bgConvSid
                    PlainMessage t   -> void (forkIO (plainHandler h meta (Just ms) t)) >> loop h reg bgConvSid
                    Rejected msg     -> chSend h msg >> loop h reg bgConvSid
                Right (Route.Plain t) -> do
                  void (forkIO (plainHandler h meta (Just ms) t))
                  loop h reg bgConvSid
                Left (Route.ParseError e) -> do
                  chSend h e
                  loop h reg bgConvSid

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

-- | Handle @\/new@ on an inbox channel: mint a fresh session from config
-- defaults, rebind the conversation's current tab (if any) to the new sid,
-- migrate every OTHER conversation cursor pointing at the old ref to the
-- new ref (per the user's "a tab has one session at a time; all channels
-- focused on the tab follow the rebind" model), and send the confirmation
-- line. The old session is kept on disk (still in @/session list@).
--
-- Mirrors the CLI's @\/new@ path but lives at the loop level because the
-- conversation key + cursor aren't available to a registry CommandAction
-- (architect review issue C). The fresh @meta@ is NOT used to run a turn —
-- the next inbound message's cursor lookup resolves to the new session
-- automatically (the cursor migrate ensures that).
handleNewSession
  :: ChannelDeps -> ChannelHandle -> TabsHandle
  -> ChannelKind -> SessionMeta -> IO ()
handleNewSession deps h tabsH kind oldMeta = do
  -- Preserve the old session's provider/model/agent (so mid-session
  -- /model use changes survive /new). The new session gets a fresh id +
  -- timestamps; everything else is copied from the old meta.
  let channelLabel = channelKindToText kind
      oldSid = smId oldMeta
      oldRef = BoundSession oldSid
  newMeta <- newSessionMeta (cdPaths deps) (smProvider oldMeta) (smModel oldMeta)
                            channelLabel (smAgent oldMeta)
  saveSessionMeta (cdPaths deps) newMeta
  -- Rebind the tab (if any) bound to the old sid to the new sid.
  snap <- snapshotTabs tabsH
  case [ t | t <- tlTabs snap, tRef t == oldRef ] of
    []       -> pure ()  -- no tab bound to old sid; cursor-only swap below
    (tab : _) -> rebindTabH tabsH (tIndex tab) (BoundSession (smId newMeta)) >>= \case
      Left e  -> chSend h ("warning: /new tab rebind failed: " <> e)
      Right _ -> pure ()
  -- Migrate every conversation cursor pointing at the old ref to the new
  -- ref (includes THIS conversation's cursor). Per the user's model: a tab
  -- has one session at a time; all channels focused on it follow the
  -- rebind to the new session.
  _count <- cursorMigrateAll (cdCursors deps) oldRef (BoundSession (smId newMeta))
  chSend h
    ("new session " <> sessionIdText (smId newMeta)
       <> " (" <> smProvider newMeta <> "/" <> smModel newMeta <> ")"
       <> " — prior session " <> sessionIdText oldSid <> " kept in /session list")

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
plainTurn deps h askReply meta =
  runTurnOnSession deps h askReply (smId meta) meta

-- | The shared turn body. 'askSid' is the 'SessionId' used to key the
-- 'ccPrompt' ask/reply slot: for a normal turn it is the session's own sid
-- (the conversation's active session); for a @/bg@ turn it is the
-- /originating conversation's/ sid (NOT the fresh bg session's) so the
-- channel loop's per-session 'deliverNextAnswer' short-circuit consumes the
-- next inbound message as the confirmation answer — producing a modal
-- "answer the pending question before resuming normal turns" state scoped
-- to that conversation. The turn itself still runs on 'smId meta' (the bg
-- session): transcript, 'aeSession', and the approval cache stay scoped to
-- the bg session; only the ask-delivery key moves to the conversation.
runTurnOnSession
  :: ChannelDeps -> ChannelHandle -> AskReplyStore -> SessionId
  -> SessionMeta -> Maybe MessageSource -> Text -> IO ()
runTurnOnSession deps h askReply askSid meta mSrc t = do
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
          appEnv <- mkEnv defaultConfig
          eCfg <- loadRuntimeConfig (prConfigPath pr)
          eSecCfg <- loadSecurityConfig (securityFilePath (cdPaths deps))
          let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
          -- Per-session workdir: each session gets a fresh directory at
          -- ~/.seal/cache/workdirs/<sid> (local) or
          -- <scWorkspace>/workdirs/<sid> (remote). Handles both local
          -- and remote via mkSessionUntrustedIO.
          untrustedIO <- either (const (const (pure mkRemoteUntrustedIOStub))) (mkSessionUntrustedIO paths) eSecCfg sid
          eWd <- ensureSessionWorkdir paths sid
          let wsroot = case eWd of
                Right wd -> WorkspaceRoot wd
                Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
          mSystem <- case smAgent meta of
            Nothing  -> pure Nothing
            Just aid -> maybe Nothing adSystem <$> Def.adbRead (bAgentDefs backends) aid
          let autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
          mSystem' <- injectAutoloadSkill (bSkills backends) autoloadId mSystem
          let handleCaps = mkHandleCaps h askReply askSid
              onDemand = either (const False) onDemandSchemas eCfg
              startWiring = channelStartWiring
                deps paths sid handleCaps untrustedIO appEnv eCfg
                wsroot operatorCeiling isaReg
              isaReg = buildIsaRegistry
                rt backends wsroot sid operatorCeiling autonomy
                (either (const Nothing) rcWeb eCfg)
                startWiring
                (cdHarnessRegistry deps) (cdTmuxRunner deps)
                (cdHttpManager deps) handleCaps onDemand
          tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
          let env = (mkSessionAgentEnv
                       handleCaps prov (smProvider meta) model sid mSystem' isaReg tHandle untrustedIO
                       (debugRequestsPath paths sid eCfg) autonomy approvals
                       (broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta))
                       onDemand)
                      { aeMessageSource = mSrc }
          runApp appEnv (runTurn env t)
          broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta)

-- | Build the @/bg@ 'BgRunner' for an inbox-driven channel. The runner mints
-- a fresh persisted session from the config defaults (channel label
-- @"bg"@), then forks a turn against the invoking 'ChannelHandle'. The
-- confirmation ask is keyed to the /originating conversation's/ active
-- session id (read from 'bgConvSid', which the loop updates each turn) —
-- NOT the fresh bg session's sid — so the channel loop's per-session
-- 'deliverNextAnswer' short-circuit consumes the next inbound message as
-- the confirmation answer (a modal "answer the pending question before
-- resuming normal turns" state scoped to that conversation). The turn
-- itself runs on the fresh bg session (transcript + 'aeSession' + approval
-- cache stay scoped to it); only the ask-delivery key moves to the
-- conversation. The assistant reply is delivered via the handle's
-- @chSend@. No tab or cursor state is mutated.
mkBgRunner :: ChannelDeps -> ChannelHandle -> AskReplyStore -> IORef SessionId -> BgRunner
mkBgRunner deps h askReply bgConvSid = BgRunner $ \prompt -> do
  convSid <- readIORef bgConvSid
  cfg <- cdConfig deps
  (mAgent, mProv, mModel) <- resolveDefaultAgent (bAgentDefs (cdBackends deps)) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
  meta <- newSessionMeta (cdPaths deps) provider model "bg" mAgent
  saveSessionMeta (cdPaths deps) meta
  void (forkIO (runTurnOnSession deps h askReply convSid meta Nothing prompt))

-- | The inbox-channel analogue of 'Seal.Gateway.Send.webCallDispatcher'.
-- Dispatches an opcode against the active session's ISA registry + transcript
-- under 'Full' autonomy semantics (the operator is the approver by typing the
-- command). Reads the session id from the supplied 'IORef' fresh on each
-- invocation — the 'runChannelLoop' body writes the cursor-resolved 'sid' to
-- this IORef every turn at Loop.hs:266, so the dispatcher always sees the
-- active session.
--
-- Constructed inside 'runChannelLoop' at Loop.hs:243 in the @let@-block
-- where 'bgConvSid' (the IORef) and 'askReply' (the 'AskReplyStore' param)
-- are in scope, and baked into 'registryWithBg' alongside
-- 'backgroundCommandSpec', 'callCommandSpec', and 'skillCommandSpec' so
-- @/call@ and @/skill load@ dispatch against the same per-session registry
-- + transcript. Mirrors 'webCallDispatcher' at
-- 'Seal.Gateway.Send.hs:516-541'.
channelCallDispatcher
  :: ChannelDeps -> ChannelHandle -> AskReplyStore -> IORef SessionId -> CallDispatcher
channelCallDispatcher deps h askReply sidRef callOpName val = do
  sid <- readIORef sidRef
  let paths = cdPaths deps
      sessionDirPath = sessionDir paths sid
  createDirectoryIfMissing True sessionDirPath
  withTwoFileTranscript sessionDirPath $ \tHandle -> do
    appEnv <- mkEnv defaultConfig
    eCfg <- loadRuntimeConfig (prConfigPath (cdProvider deps))
    eSecCfg <- loadSecurityConfig (securityFilePath (cdPaths deps))
    let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
    untrustedIO <- either (const (const (pure mkRemoteUntrustedIOStub))) (mkSessionUntrustedIO paths) eSecCfg sid
    eWd <- ensureSessionWorkdir paths sid
    let wsRoot = case eWd of
          Right wd -> WorkspaceRoot wd
          Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
        caps = mkHandleCaps h askReply sid
        onDemand = either (const False) onDemandSchemas eCfg
        startWiring = channelStartWiring
          deps paths sid caps untrustedIO appEnv eCfg
          wsRoot operatorCeiling isaReg
        isaReg = buildIsaRegistry
          (cdVault deps) (cdBackends deps) wsRoot sid operatorCeiling
          (cdAutonomy deps) (either (const Nothing) rcWeb eCfg) startWiring
          (cdHarnessRegistry deps) (cdTmuxRunner deps) (cdHttpManager deps)
          caps onDemand
    tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
    res <- runApp appEnv (dispatch isaReg tHandle localBackend untrustedIO callOpName val)
    case res of
      Right r -> recordSkillLoadResult tHandle callOpName val r
      Left _  -> pure ()
    pure res

-- | Build the ISA registry for a channel turn. Mirrors
-- 'Seal.Gateway.Send.buildWebRegistry' so channels have the SAME tool set
-- as the web and CLI paths.
buildIsaRegistry
  :: VaultRuntime -> Backends -> WorkspaceRoot -> SessionId -> Int
  -> Policy.AutonomyLevel
  -> Maybe WebConfig
  -> AgentStartWiring
  -> HarnessRegistry
  -> TmuxRunner
  -> Maybe Manager
  -> ChannelCaps
  -> Bool                     -- ^ on-demand schemas: register OPCODE_DESCRIBE/OPCODE_LIST
  -> ISA.Registry
buildIsaRegistry rt backends wsRoot sid operatorCeiling autonomy webCfg
                 startWiring harnessReg tmuxRunner httpManager caps onDemand =
  reg
  where
    baseOps =
      [ showHumanOp caps
      , askHumanOp caps
      , secretGetOp rt
      , memoryWriteOp (bMemory backends) sid
      , memoryRecallOp defaultPageParams (bMemory backends)
      , memoryDeleteOp (bMemory backends)
      , skillWriteOp (bSkills backends) sid
      , skillLoadOp (bSkills backends)
      , skillListOp (bSkills backends)
      , skillDeleteOp (bSkills backends)
      , agentDefWriteOp (bAgentDefs backends) sid
      , agentDefReadOp (bAgentDefs backends)
      , agentDefListOp (bAgentDefs backends)
      , agentDefDeleteOp (bAgentDefs backends)
      , agentInstancesOp (bRuntime backends)
      , agentStartOp startWiring
      , agentStatusOp (bRuntime backends)
      , agentStopOp (bRuntime backends)
      , agentInterruptOp (bRuntime backends)
      , searchFilesOp wsRoot securityPolicy operatorCeiling
      , fileReadOp wsRoot operatorCeiling
      , fileWriteOp wsRoot operatorCeiling
      , filePatchOp wsRoot
      , shellExecOp wsRoot securityPolicy
      , binExecOp wsRoot securityPolicy binAllowList
      , processManageOp wsRoot securityPolicy
      , webFetchOp webFetchCfg
      , webSearchOp webSearchCfg
      , harnessListOp harnessReg
      , harnessStartOp harnessReg tmuxRunner harnessSession harnessWindow
          HfGeneric newHarnessId
      , harnessStopOp harnessReg tmuxRunner
      ]
    introspectionOps = [ opcodeDescribeOp reg, opcodeListOp reg ]
    reg = ISA.mkRegistry (baseOps ++ if onDemand then introspectionOps else [])
    securityPolicy = Policy.SecurityPolicy Policy.AllowAll autonomy
    binAllowList = Nothing
    webSearchCfg = WebSearchConfig
      { wscManager   = httpManager
      , wscEndpoint  = unwrapOpt wcSearchEndpoint webCfg ""
      , wscAllowList = unwrapOpt wcSearchAllowList webCfg []
      , wscAuthKey   = Nothing
      }
    webFetchCfg = WebFetchConfig
      { wfcManager   = httpManager
      , wfcAllowList = unwrapOpt wcFetchAllowList webCfg []
      , wfcMaxBytes  = unwrapOpt wcMaxFetchBytes webCfg operatorCeiling
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

-- | Build the 'AgentStartWiring' for a channel turn. The wiring closes over
-- the per-turn 'ChannelDeps' + parent session id + 'ChannelCaps' +
-- | Unwrap a nested 'Maybe' field from an optional 'WebConfig'. Returns
-- the default when the config section or the field is absent.
unwrapOpt :: (WebConfig -> Maybe a) -> Maybe WebConfig -> a -> a
unwrapOpt field webCfg def =
  case webCfg of
    Nothing   -> def
    Just cfg  -> fromMaybe def (field cfg)

-- 'UntrustedIO' + 'Env' + loaded config + wsRoot + operatorCeiling (for the
-- child's narrowed registry). The worker-builder is 'channelMkWorker'
-- (below), which runs 'runTurn' with the goal as the first user message and
-- captures the final text response as the summary.
channelStartWiring
  :: ChannelDeps -> SealPaths -> SessionId -> ChannelCaps -> UntrustedIO -> Env
  -> Either a RuntimeConfig -> WorkspaceRoot -> Int -> ISA.Registry -> AgentStartWiring
channelStartWiring deps paths parentSid caps untrustedIO appEnv eCfg wsRoot operatorCeiling _isaReg =
  AgentStartWiring
    { aswDefBackend = bAgentDefs (cdBackends deps)
    , aswRuntime = bRuntime (cdBackends deps)
    , aswConfig = do
        eCfg' <- loadRuntimeConfig (prConfigPath (cdProvider deps))
        pure (fromFileConfig (either (const Nothing) rcDelegation eCfg'))
    , aswPauseFlag = bSpawnPauseFlag (cdBackends deps)
    , aswParentActivity = Just (bParentActivity (cdBackends deps))
    , aswMintSession = channelMintSession parentSid
    , aswParentDepth = 0
    , aswWorker = channelMkWorker deps paths parentSid caps untrustedIO appEnv eCfg wsRoot operatorCeiling
    }

-- | The AGENT_START worker-builder for inbox-driven channels. Resolves the
-- def's provider+model (falling back to the parent session meta when the def
-- fields are empty), opens a fresh two-file transcript under
-- @\<parent-session\>\/agents\/\<child-id\>@, builds a narrowed child ISA
-- registry (blocklist strips AGENT_START/AGENT_DEF_*/lifecycle opcodes), and
-- runs 'runTurn' with the goal as the first user message. The final text
-- response is captured via a 'ChannelCaps' whose 'ccSend' writes to an
-- IORef; the worker reads it after the run and returns it as the summary.
channelMkWorker
  :: ChannelDeps -> SealPaths -> SessionId -> ChannelCaps -> UntrustedIO -> Env
  -> Either a RuntimeConfig -> WorkspaceRoot -> Int
  -> AgentWorkerBuilder
channelMkWorker deps paths parentSid _caps _untrustedIO appEnv eCfg _wsRoot operatorCeiling =
  mkDelegateWorker DelegationWorkerDeps
    { dwdPaths = paths
    , dwdParentSid = parentSid
    , dwdAppEnv = appEnv
    , dwdMkUntrustedIO = \childSid -> do
        eChildWd <- ensureSessionWorkdir paths childSid
        let childWsRoot = case eChildWd of
              Right wd -> WorkspaceRoot wd
              Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
        eSecCfg <- loadSecurityConfig (securityFilePath paths)
        pure (either (const mkRemoteUntrustedIOStub) (untrustedIOFromSecurity childWsRoot) eSecCfg)
    , dwdAutonomy = cdAutonomy deps
    , dwdApprovals = cdApprovals deps
    , dwdOnDemand = either (const False) onDemandSchemas eCfg
    , dwdParentDepth = 0
    , dwdResolveProvider = resolveChild
    , dwdChildRegistry = buildChildRegistry
    , dwdChildSystemPrompt = childSystemPrompt
    , dwdOnEntry = pure ()  -- child onEntry: no live broadcast (would need the broker + child sid)
    }
  where
    resolveChild def = do
      mParentMeta <- loadMeta paths parentSid
      now <- getCurrentTime
      let parent = fromMaybe (fallbackMeta now) mParentMeta
          fallBackProvider = if T.null (adProvider def) then smProvider parent else adProvider def
          fallBackModel = case adModel def of
            ModelId m | T.null m -> smModel parent
                      | otherwise -> m
      resolveDefProvider (cdProvider deps) fallBackProvider (ModelId fallBackModel)
    childSystemPrompt def task = do
      let base = adSystem def
          ctx  = ctContext task
          basePrompt = case (base, ctx) of
            (Just b, Just c) | not (T.null c) -> Just (b <> "\n\nCONTEXT:\n" <> c)
            (Just b, _)                       -> Just b
            (Nothing, Just c)                 -> Just ("CONTEXT:\n" <> c)
            (Nothing, Nothing)                -> Nothing
          autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
      injectAutoloadSkill (bSkills (cdBackends deps)) autoloadId basePrompt
    buildChildRegistry _def childSid childCaps = do
      eChildWd <- ensureSessionWorkdir paths childSid
      let childWsRoot = case eChildWd of
            Right wd -> WorkspaceRoot wd
            Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
      let childBaseOps =
            [ showHumanOp childCaps
            , askHumanOp childCaps
            , secretGetOp (cdVault deps)
            , memoryWriteOp (bMemory (cdBackends deps)) childSid
            , memoryRecallOp defaultPageParams (bMemory (cdBackends deps))
            , memoryDeleteOp (bMemory (cdBackends deps))
            , skillWriteOp (bSkills (cdBackends deps)) childSid
            , skillLoadOp (bSkills (cdBackends deps))
            , skillListOp (bSkills (cdBackends deps))
            , skillDeleteOp (bSkills (cdBackends deps))
            , agentDefReadOp (bAgentDefs (cdBackends deps))
            , agentDefListOp (bAgentDefs (cdBackends deps))
            -- blocklisted: AGENT_DEF_WRITE, AGENT_DEF_DELETE,
            -- AGENT_INSTANCES, AGENT_START, AGENT_STATUS, AGENT_STOP,
            -- AGENT_INTERRUPT
            , searchFilesOp childWsRoot securityPolicy operatorCeiling
            , fileReadOp childWsRoot operatorCeiling
            , fileWriteOp childWsRoot operatorCeiling
            , filePatchOp childWsRoot
            , shellExecOp childWsRoot securityPolicy
            , binExecOp childWsRoot securityPolicy binAllowList
            , processManageOp childWsRoot securityPolicy
            , webFetchOp webFetchCfg
            , webSearchOp webSearchCfg
            ]
      pure (ISA.mkRegistry (filterBlocklisted childBaseOps opName))
      where
        securityPolicy = Policy.SecurityPolicy Policy.AllowAll (cdAutonomy deps)
        binAllowList = Nothing
        childWebCfg = either (const Nothing) rcWeb eCfg
        webFetchCfg = WebFetchConfig
          { wfcManager = cdHttpManager deps
          , wfcAllowList = unwrapOpt wcFetchAllowList childWebCfg []
          , wfcMaxBytes = unwrapOpt wcMaxFetchBytes childWebCfg operatorCeiling
          , wfcAuthKey = Nothing }
        webSearchCfg = WebSearchConfig
          { wscManager = cdHttpManager deps
          , wscEndpoint = unwrapOpt wcSearchEndpoint childWebCfg ""
          , wscAllowList = unwrapOpt wcSearchAllowList childWebCfg []
          , wscAuthKey = Nothing }
    fallbackMeta t = SessionMeta
      { smId = parentSid, smProvider = "ollama", smModel = "glm-5.2:cloud"
      , smChannel = "cli", smAgent = Nothing, smSystemOverride = Nothing, smAgentName = Nothing
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