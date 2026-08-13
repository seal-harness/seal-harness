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
  , mkHandleCaps
  , handleTabCommand
  , plainTurn
  , plainTurnWithCaps
  , buildIsaRegistry
  , buildChannelRegistry
  , mkBgRunner
  , channelCallDispatcher
  , mkTabCloseNotifier
  , shouldAutoTab
  , isBgSlash
  , createConversationSession
  , createConversationSessionHeadless
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (bracket)
import Control.Monad (void)
import Data.Either (fromRight)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

import Katip (Severity (..), ls)
import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (adSystem, adModel, adProvider, AgentDef (..))
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Delegation
  ( fromFileConfig, ChildTask (..), AgentWorkerBuilder )
import Seal.Agent.Runtime.Delegation.Worker
  ( mkDelegateWorker, filterBlocklisted, DelegationWorkerDeps (..) )
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)
import Seal.Channel.Cli
  ( Backends (..), untrustedIOFromSecurity, mkSessionAgentEnv
  , resolveDefProvider, resolveSessionProvider, debugRequestsPath )
import Seal.Channels.Class (Channel (..))
import Seal.Channels.Cursor
  ( CursorStore, cursorLookup, cursorSet, cursorMigrateAll, cursorClearAll, newCursorStore )
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec)
import Seal.Command.Call (CallDispatcher, callCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (CommandAction (..), CommandName (..), CommandSpec (..), Registry, mkRegistry, registrySpecs, runCommandAction)
import Seal.Command.Tab (TabCloseNotifier)
import Seal.Config.File
  ( RuntimeConfig, defaultRetrievalMaxScanBytes, defaultMaxTurns, loadRuntimeConfig, retrievalMaxScanBytes
  , onDemandSchemas, maxTurnsConfig, rcDelegation, WebConfig (..), rcWeb, resolvedAutoloadSkill, resolvedAvailableSkills, resolvedParallelToolGuidance, resolvedToolUseEnforcement, resolvedTaskCompletionGuidance )
import Seal.Config.Security (loadSecurityConfig)
import Seal.Config.Paths (SealPaths (..), repoKeysDir, securityFilePath, sessionDir, sessionLogPath, sshAgentsDir)
import Seal.Core.ChannelKind (ChannelKind (..), channelKindToText)
import Seal.Core.MessageSource
  ( MessageSource, conversationIdText, msChannelKind, msConversationId )
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSessionId, sessionIdText)
import Seal.Gateway.Broadcast (broadcastListsSnapshot, broadcastHarnessStatus, broadcastReplyDelivered)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, askHumanWithOptions, deliverNextAnswerResolved
  , formatQuestionWithOptions
  )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (TabKind (..), TabIndex, tabIndexToChar)
import Seal.Handles.Transcript (withTwoFileTranscript, tfwSetSecretOps)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner, mkTmuxIdent)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Dispatch (dispatch, recordGitPushResult, recordSkillLoadResult)
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
import Seal.ISA.Ops.Repo (setupRepoOp)
import Seal.ISA.Ops.Git (gitFetchOp, gitPullOp, gitPushOp)
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillLoadOp, skillWriteOp )
import Seal.Routing.Route qualified as Route
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.Tools.Ssh.Agent (mkRealSshAgentHandle)
import qualified Seal.SourceControl.Clone as Clone
import Seal.Session.Workdir (ensureSessionWorkdir, mkSessionUntrustedIO)
import Seal.Skills.Autoload (injectAutoloadSkill)
import Seal.Skills.Prompt (injectAvailableSkills)
import Seal.Agent.PromptParts (injectStaticGuidance)
import Seal.Skills.Backend (SkillBackend)
import Seal.Skills.Backend qualified as SkillBackend
import qualified Seal.Security.Policy as Policy
  ( AutonomyLevel (..), SecurityPolicy (..), AllowList (..) )
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Session.Lock
  ( ReplyRegistry, newReplyRegistry, replySubscribe, replyFanout
  , replyFanoutMessage, replyMigrateAll
  , SessionLocks, newSessionLocks, withSessionLock )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, formatSessionId, newSessionMeta
  , resolveDefaultAgent, saveSessionMeta )
import Seal.Tabs
  ( TabsHandle, ensureTabForSession, focusTabH, insertTabH, removeTabH
  , renameTabH, rebindTabH, snapshotTabs )
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef (..), TabSlashCommand (..), ForceMode (..)
  , tabCount, tlTabs, lookupByRef )
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub, UntrustedIO)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Logging.Logger (SealLogger, logIO)
import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Web.Fetch (webFetchOp, WebFetchConfig (..))
import Seal.Web.Search (webSearchOp, WebSearchConfig (..), parseProvider)
import Seal.Util.StrictIO (decodeFileStrict)

-- | The dependencies a channel turn needs to have full parity with the web
-- and CLI paths. Built once at startup (in 'Seal.Command.Serve' or the
-- standalone @seal signal@ / @seal telegram@ entry points) and shared
-- across all turns on that channel. Mirrors 'Seal.Gateway.Send.SendDeps'
-- but for inbox-driven channels.
data ChannelDeps = ChannelDeps
  { cdPaths      :: SealPaths
  , cdVault      :: VaultRuntime
  , cdRepoReg    :: RepoRegistryHandle
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
  , cdTabs        :: TabsHandle
    -- ^ The shared, unified tab handle. Under @seal serve@, this is the SAME
    -- handle as the web gateway's 'adTabsHandle', so a tab inserted by any
    -- channel (Signal, Telegram) is visible in the web sidebar (W4
    -- invariant 3). The standalone @seal signal@ / @seal telegram@ entry
    -- points pass their own 'newTabsHandle' (no web surface to unify with).
  , cdConfig      :: IO RuntimeConfig
    -- ^ Load the current config (re-read per turn so config changes take
    -- effect without a restart). Used for default provider/model/agent
    -- when creating a new session for a conversation.
  , cdIsRemote    :: Bool
    -- ^ Whether the untrusted executor runs commands over SSH (remote
    -- mode from the security config). Set once at startup from
    -- @isJust (untrustedExecConfigFromSecurity secCfg)@. Threaded into
    -- 'CloneDeps' so the deploy-key clone path knows to use agent
    -- forwarding (@ssh -A@) + a remote @known_hosts@ temp file.
  , cdLogger      :: SealLogger
    -- ^ The shared logger for structured katip logging. Built once at
    -- startup via 'withSealLogger', threaded through all channel turns.
  }

-- | Build 'Clone.CloneDeps' from a 'ChannelDeps' (the in-scope vault runtime
-- + repo registry handle + paths). Used by the 2 'buildIsaRegistry' call
-- sites + the 1 'buildChildRegistry' site in this module. The ssh-agent is
-- real (production: 'mkRealSshAgentHandle'); the pinned host
-- keys are compile-time-embedded.
mkCloneDepsFromChannel :: ChannelDeps -> IO Clone.CloneDeps
mkCloneDepsFromChannel deps = do
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir (cdPaths deps))
  pure Clone.CloneDeps
    { Clone.cdVault = cdVault deps
    , Clone.cdRepoReg = cdRepoReg deps
    , Clone.cdSshAgent = mkRealSshAgentHandle
    , Clone.cdAgentRegistry = agentRegH
    , Clone.cdPinnedKnownHosts = pinnedGithubKnownHosts
    , Clone.cdKeyfilesDir = repoKeysDir (cdPaths deps)
    , Clone.cdIsRemote = cdIsRemote deps
    }

-- | Build a 'ChannelDeps' with fresh cursor/reply/lock stores and the
-- given config loader. Used by 'Seal.Command.Serve' and the standalone
-- entry points. The 'tabsH' is the shared/unified handle (W4).
newChannelDeps
  :: SealPaths -> VaultRuntime -> RepoRegistryHandle -> ProviderRuntime -> Backends
  -> Policy.AutonomyLevel -> Maybe StreamBroker
  -> HarnessRegistry -> TmuxRunner -> Maybe Manager
  -> ApprovalCache -> IO RuntimeConfig
  -> Bool
  -> TabsHandle
  -> SealLogger
  -> IO ChannelDeps
newChannelDeps paths vault repoReg provider backends autonomy broker
               harnessReg tmux httpMgr approvals loadCfg isRemote tabsH logger = do
  cursors <- newCursorStore
  replies <- newReplyRegistry
  locks   <- newSessionLocks
  pure ChannelDeps
    { cdPaths      = paths
    , cdVault      = vault
    , cdRepoReg    = repoReg
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
    , cdTabs        = tabsH
    , cdConfig      = loadCfg
    , cdIsRemote    = isRemote
    , cdLogger      = logger
    }

-- | The conversation key for the cursor store: (channel-kind-text,
-- conversation-id-text). Derived from the 'MessageSource' (both fields
-- are server-derived, never user-supplied, so a sender cannot forge a
-- cursor key).
convKey :: MessageSource -> (Text, Text)
convKey ms = (channelKindToText (msChannelKind ms), conversationIdText (msConversationId ms))

-- | Build the channel's slash-command registry from a supplied base
-- 'Registry' plus the channel-specific @bg@, @call@, and @skill@ specs.
--
-- The channel-appended specs bind to the channel's per-session
-- 'channelCallDispatcher' (which reads the conversation's cursor-resolved
-- sid). Under @seal serve@, the supplied @registry@ is the WEB gateway's
-- registry, whose @skill@ and @call@ specs bind to 'webCallDispatcher'
-- (which reads the process-global @srActive@ ref). Without shadowing those
-- out, a @/skill load@ issued from Telegram dispatches via the FIRST
-- matching spec — the web one — and records the SKILL_LOAD entry on
-- whatever session @srActive@ points at, NOT the Telegram conversation's
-- session. The channel-dispatcher versions must win, so drop any incoming
-- spec whose primary name collides with a channel-appended spec before
-- appending them. 'lookupSpec' returns the first match, so the appended
-- channel specs then resolve correctly.
buildChannelRegistry
  :: SkillBackend -> BgRunner -> CallDispatcher -> Registry -> Registry
buildChannelRegistry skillBackend bgRunner callDispatcher registry =
  mkRegistry (baseSpecs <> channelSpecs)
  where
    channelSpecNames = ["bg", "call", "skill"] :: [Text]
    baseSpecs = filter
      (\s -> let CommandName n = csName s in n `notElem` channelSpecNames)
      (registrySpecs registry)
    channelSpecs =
      [ backgroundCommandSpec bgRunner
      , callCommandSpec callDispatcher
      , skillCommandSpec skillBackend callDispatcher
      ]

-- | The inbox-driven loop. Spawns the channel via the supplied bracket,
-- pulls @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route', and dispatches. Each conversation resolves its
-- session via the cursor store (not a shared active-session ref). On
-- first message from a conversation, a new tab + session is created.
--
-- The optional 'mkCaps' factory overrides the default 'mkHandleCaps'
-- (e.g. Telegram's inline-keyboard 'ccPrompt'). 'Nothing' = use
-- 'mkHandleCaps' (Signal + the generic numbered list).
--
-- The optional 'onCallback' hook is called before
-- 'deliverNextAnswerResolved' — Telegram uses it to route callback_query
-- button taps by 'AskId' (by-id delivery, NOT FIFO). 'Nothing' = no
-- callback support (the body goes straight to 'deliverNextAnswerResolved').
runChannelLoop
  :: (Channel c)
  => ChannelDeps
  -> ((c -> IO ()) -> IO ())
  -> (ChannelHandle -> SessionMeta -> Maybe MessageSource -> Text -> IO ())
  -> Registry
  -> PreprocessChain
  -> AskReplyStore
  -> TabsHandle
  -> Maybe (ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps)
  -> Maybe (ChannelHandle -> SessionId -> Text -> IO Bool)
  -> IO ()
runChannelLoop deps withChannel plainHandler registry chain askReply tabsH mkCaps onCallback =
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
    let bgRunner = mkBgRunner deps h askReply bgConvSid tabsH
        callDispatcher = channelCallDispatcher deps h askReply bgConvSid
        registryWithBg = buildChannelRegistry
          (bSkills (cdBackends deps)) bgRunner callDispatcher registry
    loop h registryWithBg bgConvSid
  where
    loop h reg bgConvSid = do
      (mSrc, body) <- chReceive h
      case mSrc of
        Nothing -> pure ()  -- EOF
        Just ms -> do
          let key = convKey ms
              bgRoute = isBgSlash body
          -- Resolve the conversation's session (create if first message).
          -- For a /bg command, take the headless path: the conversation needs
          -- an anchor session (its sid keys the bg runner's confirmation ask
          -- via bgConvSid below) but must NOT get a tab, since no turn ever
          -- runs on this session — a tab would surface as an empty
          -- conversation in the web sidebar. The bg turn itself runs on a
          -- separate, fresh bg session minted by mkBgRunner.
          mCursor <- cursorLookup (cdCursors deps) key
          meta <- case mCursor of
            Just tabRef -> do
              mMeta <- resolveTabSession deps tabRef
              case mMeta of
                Just m  -> pure m
                Nothing
                  | bgRoute  -> createConversationSessionHeadless deps key (msChannelKind ms)
                  | otherwise -> createConversationSession deps h key (msChannelKind ms) tabsH
            Nothing
              | bgRoute  -> createConversationSessionHeadless deps key (msChannelKind ms)
              | otherwise -> createConversationSession deps h key (msChannelKind ms) tabsH
          let sid = smId meta
          -- Record the conversation's active session so the /bg runner
          -- (dispatched below if this turn is a /bg) keys its confirmation
          -- ask to this sid. Updated every turn, before any slash-command
          -- dispatch.
          writeIORef bgConvSid sid
          -- For channels with callback support (Telegram), try the
          -- onCallback hook first (by-id delivery for button taps). If it
          -- returns True, the body was a callback + delivered; continue
          -- the loop. Otherwise, fall through to deliverNextAnswerResolved.
          mCallbackHandled <- case onCallback of
            Nothing -> pure False
            Just cb -> cb h sid body
          delivered <-
            if mCallbackHandled
              then pure True
              else snd <$> deliverNextAnswerResolved askReply sid body
          if delivered
            then loop h reg bgConvSid
            else do
              let handleCaps = case mkCaps of
                    Nothing -> mkHandleCaps h askReply sid
                    Just f  -> f h askReply sid
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
                Right Route.CurrentTab -> do
                  tl <- snapshotTabs tabsH
                  case mCursor >>= lookupByRef tl of
                    Just t  -> chSend h (renderCurrentTab t)
                    Nothing -> chSend h "no current tab"
                  loop h reg bgConvSid
                Right Route.NewSession -> do
                  _ <- handleNewSession deps h tabsH (msChannelKind ms) meta
                  loop h reg bgConvSid
                Right (Route.SlashCommand _) -> do
                  d <- ingest reg chain (RawInbound body)
                  case d of
                    DispatchAction a -> do
                      eResult <- withExceptionLogging (cdLogger deps) Nothing "slash command" $
                        runCommandAction a handleCaps
                      case eResult of
                        Left errMsg -> chSend h errMsg
                        Right _     -> pure ()
                      loop h reg bgConvSid
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
mkHandleCaps h askReply sid = def
  { ccSend         = chSend h
  , ccPrompt       = \(AskPrompt q opts) -> do
      chSend h (formatQuestionWithOptions q opts)
      outcome <- askHumanWithOptions askReply sid q opts (const (pure ()))
      pure (fromRight "" outcome)
  , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
  , ccStreaming    = chStreaming h
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
      else decodeFileStrict mp :: IO (Maybe SessionMeta)
  BoundHarness _   -> pure Nothing

-- | Load a session's channel provenance label (e.g. @"telegram"@, @"web"@,
-- @"cli"@) from its @session.json@. Returns 'Nothing' when the session
-- directory or file is missing or undecodable. Used by
-- 'channelCallDispatcher' to stamp channel origin into the SKILL_LOAD
-- transcript entry so the frontend can surface it in the skill-load row's
-- source label.
loadChannelLabel :: SealPaths -> SessionId -> IO (Maybe Text)
loadChannelLabel paths sid = do
  let mp = sessionDir paths sid </> "session.json"
  exists <- doesFileExist mp
  if not exists
    then pure Nothing
    else do
      mMeta <- decodeFileStrict mp :: IO (Maybe SessionMeta)
      pure (smChannel <$> mMeta)

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
      Right _ -> broadcastTabs deps tabsH
  -- Migrate every conversation cursor pointing at the old ref to the new
  -- ref (includes THIS conversation's cursor). Per the user's model: a tab
  -- has one session at a time; all channels focused on it follow the
  -- rebind to the new session.
  _count <- cursorMigrateAll (cdCursors deps) oldRef (BoundSession (smId newMeta))
  -- Migrate reply subscriptions from the old session to the new one so
  -- future fan-outs (including tab-close notifications) reach attached
  -- channels under the new session id.
  _n <- replyMigrateAll (cdReplies deps) oldSid (smId newMeta)
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
  -- Bind the conversation's cursor to this session unconditionally. The
  -- cursor is what the loop's next-turn lookup (Loop.hs:278) uses to
  -- resolve the conversation's session; if it isn't set, the next message
  -- mints a brand-new session and orphans this one. Earlier this lived
  -- inside the 'Right _' branch below, so a full tab list (Left _) silently
  -- skipped cursor-binding — every subsequent turn from the conversation
  -- would mint a fresh session, never reusing this one.
  cursorSet (cdCursors deps) key (BoundSession (smId meta))
  r <- insertTabH tabsH (BoundSession (smId meta)) KindAi Nothing
  case r of
    Left _ -> pure ()  -- tab list full; session still works without a tab
    Right _ ->
      -- Push the new tab to any WS subscribers (the web frontend sidebar)
      -- so a channel-created tab surfaces immediately. No-op when cdBroker
      -- is Nothing (standalone signal/telegram without serve).
      broadcastTabs deps tabsH
  pure meta

-- | Create a new session for a conversation WITHOUT inserting a tab or
-- broadcasting to the sidebar. Used by the @/bg@ path (see 'isBgSlash')
-- where the conversation needs an anchor session (its sid keys the bg
-- runner's confirmation ask via 'bgConvSid') but must NOT surface an empty
-- tab in the web sidebar — the @/bg@ turn runs headless on a fresh bg
-- session, so a tab bound to this conversation session would never receive
-- a turn and would appear dead. The cursor is always set (unlike
-- 'createConversationSession', there is no tab-list-full failure mode to
-- skip it on), so subsequent non-bg messages resolve to this session.
createConversationSessionHeadless
  :: ChannelDeps -> (Text, Text) -> ChannelKind -> IO SessionMeta
createConversationSessionHeadless deps key kind = do
  cfg <- cdConfig deps
  (mAgent, mProv, mModel) <- resolveDefaultAgent (bAgentDefs (cdBackends deps)) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
      channelLabel = channelKindToText kind
  meta <- newSessionMeta (cdPaths deps) provider model channelLabel mAgent
  saveSessionMeta (cdPaths deps) meta
  cursorSet (cdCursors deps) key (BoundSession (smId meta))
  pure meta

-- | Does an inbound body route to a @/bg@ slash command? Layer-1 routing
-- ('Seal.Routing.Route.route') sends any @\/<other>…@ to 'SlashCommand'; this
-- checks the command name is @"bg"@ (case-insensitive, matching the terse
-- grammar's single-token form @\/bg@ or @\/bg <prompt>@). Used by the loop to
-- pick the headless session-creation path, so @/bg@ does not mint a spurious
-- empty tab for the conversation while still anchoring the bg runner's
-- confirmation-ask key on the conversation's sid.
isBgSlash :: Text -> Bool
isBgSlash body =
  case Route.route body of
    Right (Route.SlashCommand rest) ->
      let cmd = T.toCaseFold (T.takeWhile (/= ' ') rest)
      in cmd == "bg"
    _ -> False

-- | Push the current tab-list snapshot to WS subscribers (the web frontend
-- sidebar). No-op when 'cdBroker' is 'Nothing' (standalone channels without
-- @seal serve@). Call after any channel-side tab mutation so the frontend
-- reflects the change without waiting for a web-originated turn.
broadcastTabs :: ChannelDeps -> TabsHandle -> IO ()
broadcastTabs deps tabsH =
  case cdBroker deps of
    Nothing     -> pure ()
    Just broker -> broadcastListsSnapshot broker tabsH (cdPaths deps)

-- | Build a 'TabCloseNotifier' from the shared cursor store + reply
-- registry. When a tab is closed, every conversation whose cursor points
-- at the closed tab's 'TabRef' is notified via the reply fan-out (so the
-- message lands on the channel handle the conversation last used), and the
-- cursor is cleared so the next message creates a fresh tab. For
-- 'BoundHarness' tabs there are no channel subscriptions, so this is a
-- no-op. Used by the slash-command registry's @\/tab close@ and the REST
-- @POST \/api\/tabs\/:index\/close@ path.
mkTabCloseNotifier :: CursorStore -> ReplyRegistry -> TabCloseNotifier
mkTabCloseNotifier cursors replies ref = case ref of
  BoundSession sid -> do
    replyFanout replies sid (msg sid)
    cursorClearAll cursors ref
  BoundHarness _ -> pure ()
  where
    msg sid = "tab closed (session " <> sessionIdText sid <> "); a new tab will be created on your next message"

-- | Handle a parsed 'TabSlashCommand' over a channel (mutates the
-- TabsHandle, replies via chSend). Mirrors Seal.Channel.Cli.handleTabCommand.
handleTabCommand :: ChannelHandle -> TabsHandle -> TabSlashCommand -> IO ()
handleTabCommand h tabsH = \case
  TabListCmd -> do
    tl <- snapshotTabs tabsH
    if tabCount tl == 0
      then chSend h "no tabs"
      else mapM_ (chSend h . renderCurrentTab) (tlTabs tl)
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

-- | Render one tab as a single line: @<index>  <kind>  [label]@.
renderCurrentTab :: Tab -> Text
renderCurrentTab t =
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
  runTurnOnSession deps h askReply Nothing (smId meta) meta

-- | Like 'plainTurn' but with an optional 'ChannelCaps' factory override
-- (e.g. Telegram's 'mkTelegramHandleCaps' for inline-keyboard @ASK_HUMAN@).
-- 'Nothing' uses the generic 'mkHandleCaps' (numbered-list rendering).
plainTurnWithCaps
  :: ChannelDeps -> ChannelHandle -> AskReplyStore
  -> Maybe (ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps)
  -> SessionMeta -> Maybe MessageSource -> Text -> IO ()
plainTurnWithCaps deps h askReply mkCaps meta =
  runTurnOnSession deps h askReply mkCaps (smId meta) meta

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
  :: ChannelDeps -> ChannelHandle -> AskReplyStore
  -> Maybe (ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps)
  -> SessionId -> SessionMeta -> Maybe MessageSource -> Text -> IO ()
runTurnOnSession deps h askReply mkCaps askSid meta mSrc t = do
  let pr = cdProvider deps
      paths = cdPaths deps
      backends = cdBackends deps
      rt = cdVault deps
      autonomy = cdAutonomy deps
      approvals = cdApprovals deps
      sid = smId meta
  eprov <- resolveSessionProvider pr meta
  case eprov of
    Left err -> logIO (cdLogger deps) ErrorS (ls err)
    Right (prov, model) -> do
      let sessionDirPath = sessionDir paths sid
      createDirectoryIfMissing True sessionDirPath
      saveSessionMeta paths meta
      -- Subscribe this channel handle to the session's replies (so the
      -- reply fan-out after the turn delivers the assistant response to
      -- this channel). The guard is stored so we can unsubscribe later
      -- (e.g. when the conversation focuses a different tab).
      _guard <- replySubscribe (cdReplies deps) h sid
      -- Cross-channel message mirroring: fan out the user's message to
      -- every OTHER append-only channel subscribed to this session,
      -- prefixed with the sender's channel label (e.g. "[telegram] hi").
      -- The sender is excluded (it already has the message); the web
      -- frontend sees the message via the transcript, not this registry.
      replyFanoutMessage (cdReplies deps) sid (chLabel h) t
      -- Signal the turn start so the web sidebar transitions the tab to
      -- Thinking. Paired with the idle signal in the 'bracket' cleanup
      -- below, which runs on EVERY exit path (success, synchronous
      -- exceptions, AND async exceptions like ThreadKilled) so a turn
      -- that dies mid-way cannot leave the tab stuck in Thinking.
      broadcastHarnessStatus (cdBroker deps) sid "thinking"
      bracket
        (pure ())
        (\_ -> do
          -- Guaranteed cleanup: signal idle + reply-delivered so the
          -- web sidebar transitions the tab back to Idle regardless of
          -- how the turn exited.
          broadcastHarnessStatus (cdBroker deps) sid "idle"
          broadcastReplyDelivered (cdBroker deps) sid)
        (\_ ->
        withSessionLock (cdLocks deps) sid $ do
        withTwoFileTranscript sessionDirPath $ \tHandle -> do
          appEnv <- mkEnv (cdLogger deps) defaultConfig
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
          -- Workdir-aware skill backend: repo-local (SETUP_REPO) ⊕ user ⊕
          -- builtin, workdir-wins. Fail-closed on a workdir error.
          workdirSkills <- case eWd of
            Right wd -> SkillBackend.workdirSkillBackend wd
            Left _err -> SkillBackend.workdirSkillBackend "/nonexistent-workdir-fail-closed"
          let sessionSkills = SkillBackend.tripleUnionSkillBackend workdirSkills (bSkills backends)
          -- Workdir-aware agent def backend: repo-local (.agents/) + user,
          -- workdir-wins. Fail-closed on a workdir error.
          workdirAgentDefs <- case eWd of
            Right wd -> Def.workdirAgentDefBackend wd
            Left _err -> Def.workdirAgentDefBackend "/nonexistent-workdir-fail-closed"
          let sessionBackends = backends { bAgentDefs = Def.unionAgentDefBackend workdirAgentDefs (bAgentDefs backends) }
          mSystem <- case smAgent meta of
            Nothing  -> pure Nothing
            Just aid -> maybe Nothing adSystem <$> Def.adbRead (bAgentDefs sessionBackends) aid
          let autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
              injectCatalog = either (const True) resolvedAvailableSkills eCfg
              parallel = either (const True) resolvedParallelToolGuidance eCfg
              toolUse = either (const True) resolvedToolUseEnforcement eCfg
              taskCompletion = either (const True) resolvedTaskCompletionGuidance eCfg
              withGuidance = injectStaticGuidance parallel toolUse taskCompletion mSystem
          mSystem' <- injectAutoloadSkill sessionSkills autoloadId withGuidance
          mSystem'' <- if injectCatalog
                         then injectAvailableSkills sessionSkills mSystem'
                         else pure mSystem'
          cloneDeps <- mkCloneDepsFromChannel deps
          let handleCaps = case mkCaps of
                Nothing  -> mkHandleCaps h askReply askSid
                Just f   -> f h askReply askSid
              onDemand = either (const False) onDemandSchemas eCfg
              startWiring = channelStartWiring
                deps paths sid handleCaps untrustedIO appEnv eCfg
                wsroot operatorCeiling (smChannel meta) isaReg sessionBackends
              isaReg = buildIsaRegistry
                rt cloneDeps sessionBackends wsroot sid operatorCeiling autonomy
                (either (const Nothing) rcWeb eCfg)
                startWiring
                (cdHarnessRegistry deps) (cdTmuxRunner deps)
                (cdHttpManager deps) handleCaps onDemand
          tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
          -- For a /bg turn, broadcast a lists snapshot as soon as the user
          -- message is durable on disk: the snapshot's first-user-message
          -- snippet is now populated, so the web sidebar shows the session
          -- name immediately (the pre-turn broadcast in mkBgRunner fired
          -- before the transcript write, so its snippet was empty and only
          -- the agent name showed). The hook runs inside runTurn right after
          -- a synchronous (fsync'd) tfwRecordAndAck of the user message,
          -- eliminating the race an async write + immediate read would have.
          -- Normal channel turns pass Nothing (no fsync latency at turn
          -- start); they get their snippet refresh from the post-turn
          -- broadcastTabs below.
          let onUserMessage =
                if shouldAutoTab meta
                  then Nothing
                  else Just (broadcastTabs deps (cdTabs deps))
          let env = (mkSessionAgentEnv
                       handleCaps prov (smProvider meta) model sid mSystem'' isaReg tHandle untrustedIO
                       (debugRequestsPath paths sid eCfg) autonomy approvals
                       (broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta))
                       onDemand
                       (Just (sessionLogPath paths sid))
                       (either (const defaultMaxTurns) maxTurnsConfig eCfg)
                       onUserMessage
                       (smChannel meta)
                       (Just (replyFanout (cdReplies deps) sid)))
                      { aeMessageSource = mSrc }
          eResult <- withExceptionLogging (cdLogger deps) (Just (sessionLogPath paths sid)) "turn" $
            runApp appEnv (runTurn env t)
          case eResult of
            Left errMsg -> logIO (cdLogger deps) ErrorS ("[channel] turn failed: " <> ls errMsg)
            Right _     -> pure ()
        broadcastNewEntries (cdBroker deps) paths sid (modelText model) (smCreatedAt meta))
      -- W3 invariant 2: auto-tab the session after a channel turn. Idempotent
      -- (no-op if a tab already binds sid — e.g. createConversationSession
      -- already inserted one on first message). Uses KindAi (channel/CLI
      -- tab kind, wire "session:ai"). Sources sid from smId meta only.
      --
      -- Gated on 'shouldAutoTab' to honor the @mkBgRunner@ contract
      -- (Loop.hs:624-636): a @/bg@ turn runs on a fresh, headless session
      -- that must NOT get a tab — the tab would be bound to the bg
      -- session's sid while the reply/ask-key is wired to the originating
      -- conversation's sid, producing a dead-looking tab. But a @/bg@
      -- session DOES legitimately surface in the sidebar's
      -- @recentSessions@ (it's a real, persisted, one-shot session), so
      -- we still broadcast a @lists@ snapshot after the turn — now that
      -- the transcript holds the user prompt, the snapshot's snippet
      -- populates the session name. Without this refresh the sidebar
      -- keeps the pre-turn snapshot (snippet null → only the agent name
      -- shows) until a hard refresh.
      if shouldAutoTab meta
        then do
          ensureTabForSession (cdTabs deps) KindAi sid
          -- Refresh the sidebar lists so the tab label updates with the
          -- first-message snippet now that the transcript has content. Without
          -- this, a freshly-created tab shows the agent name (snippet was null
          -- at creation time) and never refreshes until a web-originated action.
          broadcastTabs deps (cdTabs deps)
        else
          -- /bg path: no tab, but still push a lists snapshot so the
          -- session's recentSessions row picks up the now-populated
          -- first-user-message snippet as its name.
          broadcastTabs deps (cdTabs deps)

-- | Should 'runTurnOnSession' auto-tab the session after a turn? 'True' for
-- normal channel turns (W3 invariant 2: every channel-originated session is
-- visible in the sidebar). 'False' for @/bg@ sessions, whose 'smChannel' is
-- @"bg"@ (set at Loop.hs:645 and Cli.hs:551): a @/bg@ turn runs headless on a
-- fresh session that must NOT surface in the web sidebar (see the
-- 'mkBgRunner' contract at Loop.hs:636-656). The label @"bg"@ is the
-- established convention shared by both bg runner sites; 'channelKindToText'
-- never produces it (the 'Background' kind maps to @"background"@), so there
-- is no collision with any real channel kind.
shouldAutoTab :: SessionMeta -> Bool
shouldAutoTab meta = smChannel meta /= "bg"

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
--
-- After persisting the session, a @lists@ snapshot is broadcast (via
-- 'broadcastTabs') so the web frontend's 'useListsStream' learns about the
-- new session immediately — it surfaces in @recentSessions@ (it's a real,
-- persisted, one-shot session, just not tabbed). At this point the
-- transcript is empty so the row shows the agent name as a placeholder;
-- the @runTurnOnSession@ path's @aeOnUserMessage@ hook (wired in
-- 'runTurnOnSession' when @shouldAutoTab@ is False) re-broadcasts a
-- @lists@ snapshot as soon as the user message is durable on disk, so
-- the snippet (the first user message) populates the session name
-- before the LLM responds. Without the pre-turn push the frontend only
-- discovers the session on a hard refresh. No-op when 'cdBroker' is
-- 'Nothing' (standalone Telegram/Signal without @seal serve@).
mkBgRunner :: ChannelDeps -> ChannelHandle -> AskReplyStore -> IORef SessionId -> TabsHandle -> BgRunner
mkBgRunner deps h askReply bgConvSid tabsH = BgRunner $ \prompt -> do
  convSid <- readIORef bgConvSid
  cfg <- cdConfig deps
  (mAgent, mProv, mModel) <- resolveDefaultAgent (bAgentDefs (cdBackends deps)) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
  meta <- newSessionMeta (cdPaths deps) provider model "bg" mAgent
  saveSessionMeta (cdPaths deps) meta
  broadcastTabs deps tabsH
  void (forkIO (runTurnOnSession deps h askReply Nothing convSid meta Nothing prompt))

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
  -- Load the session's channel provenance (smChannel, e.g. "telegram") so
  -- recordSkillLoadResult can stamp it into the SKILL_LOAD entry's erMeta,
  -- surfacing channel origin in the frontend's skill-load row.
  mChannel <- loadChannelLabel paths sid
  withTwoFileTranscript sessionDirPath $ \tHandle -> do
    appEnv <- mkEnv (cdLogger deps) defaultConfig
    eCfg <- loadRuntimeConfig (prConfigPath (cdProvider deps))
    eSecCfg <- loadSecurityConfig (securityFilePath (cdPaths deps))
    let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
    untrustedIO <- either (const (const (pure mkRemoteUntrustedIOStub))) (mkSessionUntrustedIO paths) eSecCfg sid
    eWd <- ensureSessionWorkdir paths sid
    cloneDeps <- mkCloneDepsFromChannel deps
    workdirAgentDefs <- case eWd of
          Right wd -> Def.workdirAgentDefBackend wd
          Left _err -> Def.workdirAgentDefBackend "/nonexistent-workdir-fail-closed"
    let wsRoot = case eWd of
          Right wd -> WorkspaceRoot wd
          Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
        caps = mkHandleCaps h askReply sid
        onDemand = either (const False) onDemandSchemas eCfg
        sessionBackends = (cdBackends deps) { bAgentDefs = Def.unionAgentDefBackend workdirAgentDefs (bAgentDefs (cdBackends deps)) }
        startWiring = channelStartWiring
          deps paths sid caps untrustedIO appEnv eCfg
          wsRoot operatorCeiling (fromMaybe "cli" mChannel) isaReg sessionBackends
        isaReg = buildIsaRegistry
          (cdVault deps) cloneDeps sessionBackends wsRoot sid operatorCeiling
          (cdAutonomy deps) (either (const Nothing) rcWeb eCfg) startWiring
          (cdHarnessRegistry deps) (cdTmuxRunner deps) (cdHttpManager deps)
          caps onDemand
    tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
    res <- runApp appEnv (dispatch isaReg tHandle localBackend untrustedIO callOpName val)
    case res of
      Right r -> do
        let opNm = case callOpName of OpName n -> n
        if opNm == "GIT_PUSH"
          then recordGitPushResult tHandle callOpName val r mChannel
          else recordSkillLoadResult tHandle callOpName val r mChannel
      Left _  -> pure ()
    pure res

-- | Build the ISA registry for a channel turn. Mirrors
-- 'Seal.Gateway.Send.buildWebRegistry' so channels have the SAME tool set
-- as the web and CLI paths.
buildIsaRegistry
  :: VaultRuntime -> Clone.CloneDeps -> Backends -> WorkspaceRoot -> SessionId -> Int
  -> Policy.AutonomyLevel
  -> Maybe WebConfig
  -> AgentStartWiring
  -> HarnessRegistry
  -> TmuxRunner
  -> Maybe Manager
  -> ChannelCaps
  -> Bool                     -- ^ on-demand schemas: register OPCODE_DESCRIBE/OPCODE_LIST
  -> ISA.Registry
buildIsaRegistry rt cloneDeps backends wsRoot sid operatorCeiling autonomy webCfg
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
      , setupRepoOp cloneDeps wsRoot autonomy
      , gitFetchOp cloneDeps wsRoot autonomy
      , gitPullOp cloneDeps wsRoot autonomy
      , gitPushOp cloneDeps wsRoot autonomy
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
      { wscManager     = httpManager
      , wscProvider    = parseProvider (unwrapOpt wcSearchProvider webCfg "parallel")
      , wscEndpoint    = unwrapOpt wcSearchEndpoint webCfg ""
      , wscAllowList   = unwrapOpt wcSearchAllowList webCfg []
      , wscAuthKey     = unwrapOptMaybe wcSearchAuthKey webCfg
      , wscMaxResults  = unwrapOpt wcSearchMaxResults webCfg 10
      , wscVault       = Just rt
      , wscSearXngUrl  = unwrapOptMaybe wcSearXngUrl webCfg
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
unwrapOpt field webCfg agentDef =
  case webCfg of
    Nothing   -> agentDef
    Just cfg  -> fromMaybe agentDef (field cfg)

-- | Like 'unwrapOpt' but for fields that are already 'Maybe a'. The
-- section-absent case yields 'Nothing'; the section-present case yields the
-- field's value (which may itself be 'Nothing').
unwrapOptMaybe :: (WebConfig -> Maybe a) -> Maybe WebConfig -> Maybe a
unwrapOptMaybe = maybe Nothing

-- 'UntrustedIO' + 'Env' + loaded config + wsRoot + operatorCeiling (for the
-- child's narrowed registry). The worker-builder is 'channelMkWorker'
-- (below), which runs 'runTurn' with the goal as the first user message and
-- captures the final text response as the summary.
channelStartWiring
  :: ChannelDeps -> SealPaths -> SessionId -> ChannelCaps -> UntrustedIO -> Env
  -> Either a RuntimeConfig -> WorkspaceRoot -> Int -> Text -> ISA.Registry -> Backends -> AgentStartWiring
channelStartWiring deps paths parentSid caps untrustedIO appEnv eCfg wsRoot operatorCeiling channel _isaReg sessionBackends =
  AgentStartWiring
    { aswDefBackend = bAgentDefs sessionBackends
    , aswRuntime = bRuntime (cdBackends deps)
    , aswConfig = do
        eCfg' <- loadRuntimeConfig (prConfigPath (cdProvider deps))
        pure (fromFileConfig (either (const Nothing) rcDelegation eCfg'))
    , aswPauseFlag = bSpawnPauseFlag (cdBackends deps)
    , aswParentActivity = Just (bParentActivity (cdBackends deps))
    , aswMintSession = channelMintSession parentSid
    , aswParentDepth = 0
    , aswWorker = channelMkWorker deps paths parentSid caps untrustedIO appEnv eCfg wsRoot operatorCeiling channel
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
  -> Either a RuntimeConfig -> WorkspaceRoot -> Int -> Text
  -> AgentWorkerBuilder
channelMkWorker deps paths parentSid _caps _untrustedIO appEnv eCfg _wsRoot operatorCeiling channel =
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
    , dwdChannel = channel
    }
  where
    resolveChild agentDef = do
      mParentMeta <- loadMeta paths parentSid
      now <- getCurrentTime
      let parent = fromMaybe (fallbackMeta now) mParentMeta
          fallBackProvider = if T.null (adProvider agentDef) then smProvider parent else adProvider agentDef
          fallBackModel = case adModel agentDef of
            ModelId m | T.null m -> smModel parent
                      | otherwise -> m
      resolveDefProvider (cdProvider deps) fallBackProvider (ModelId fallBackModel)
    childSystemPrompt agentDef task = do
      let base = adSystem agentDef
          ctx  = ctContext task
          basePrompt = case (base, ctx) of
            (Just b, Just c) | not (T.null c) -> Just (b <> "\n\nCONTEXT:\n" <> c)
            (Just b, _)                       -> Just b
            (Nothing, Just c)                 -> Just ("CONTEXT:\n" <> c)
            (Nothing, Nothing)                -> Nothing
          autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
          injectCatalog = either (const True) resolvedAvailableSkills eCfg
          parallel = either (const True) resolvedParallelToolGuidance eCfg
          toolUse = either (const True) resolvedToolUseEnforcement eCfg
          taskCompletion = either (const True) resolvedTaskCompletionGuidance eCfg
          withGuidance = injectStaticGuidance parallel toolUse taskCompletion basePrompt
      withAutoload <- injectAutoloadSkill (bSkills (cdBackends deps)) autoloadId withGuidance
      if injectCatalog
        then injectAvailableSkills (bSkills (cdBackends deps)) withAutoload
        else pure withAutoload
    buildChildRegistry _def childSid childCaps = do
      eChildWd <- ensureSessionWorkdir paths childSid
      childCloneDeps <- mkCloneDepsFromChannel deps
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
            , setupRepoOp childCloneDeps childWsRoot (cdAutonomy deps)
            , gitFetchOp childCloneDeps childWsRoot (cdAutonomy deps)
            , gitPullOp childCloneDeps childWsRoot (cdAutonomy deps)
            , gitPushOp childCloneDeps childWsRoot (cdAutonomy deps)
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
          , wscProvider = parseProvider (unwrapOpt wcSearchProvider childWebCfg "parallel")
          , wscEndpoint = unwrapOpt wcSearchEndpoint childWebCfg ""
          , wscAllowList = unwrapOpt wcSearchAllowList childWebCfg []
          , wscAuthKey = unwrapOptMaybe wcSearchAuthKey childWebCfg
          , wscMaxResults = unwrapOpt wcSearchMaxResults childWebCfg 10
          , wscVault = Just (cdVault deps)
          , wscSearXngUrl = unwrapOptMaybe wcSearXngUrl childWebCfg
          }
    fallbackMeta t = SessionMeta
      { smId = parentSid, smProvider = "ollama", smModel = "glm-5.2:cloud"
      , smChannel = "cli", smAgent = Nothing, smSystemOverride = Nothing, smAgentName = Nothing
      , smDescription = Nothing
      , smCreatedAt = t, smLastActive = t }
    loadMeta p sid = do
      let mp = sessionDir p sid </> "session.json"
      exists <- doesFileExist mp
      if not exists
        then pure Nothing
        else decodeFileStrict mp :: IO (Maybe SessionMeta)

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
