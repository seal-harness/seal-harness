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
  , buildChannelRegistry
  , mkBgRunner
  , channelCallDispatcher
  , mkChannelTurnDeps
  , mkTabCloseNotifier
  , shouldAutoTab
  , isBgSlash
  , createConversationSession
  , createConversationSessionHeadless
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Data.Either (fromRight)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (Manager)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)
import Seal.Channel.Cli
  ( Backends (..), resolveSessionProvider )
import Seal.Channels.Class (Channel (..))
import Seal.Channels.Cursor
  ( CursorStore, cursorLookup, cursorSet, cursorMigrateAll, cursorClearAll )
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec)
import Seal.Command.Call (CallDispatcher, callCommandSpec)
import Seal.Command.Model (modelCommandSpecForSession, mkModelTranscriptWriter)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec (CommandAction (..), CommandName (..), CommandSpec (..), Registry, mkRegistry, registrySpecs, runCommandAction)
import Seal.Command.Tab (TabCloseNotifier)
import Seal.Config.File
  ( RuntimeConfig )
import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Core.ChannelKind (ChannelKind (..), channelKindToText)
import Seal.Core.MessageSource
  ( MessageSource, conversationIdText, msChannelKind, msConversationId )
import Seal.Core.TurnEngine
  (TurnDeps (..), TurnAdapter (..),
   runSessionTurn, shouldAutoTab)
import qualified Seal.Core.TurnEngine as TurnEngine
import Seal.Core.Types (SessionId, mkSessionId, sessionIdText)
import Seal.Gateway.Broadcast (broadcastListsSnapshot)
import Seal.Gateway.StreamBroker (StreamBroker)
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, askHumanWithOptions, deliverNextAnswerResolved
  , formatQuestionWithOptions )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (TabKind (..), TabIndex, tabIndexToChar)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.Routing.Route qualified as Route
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.Skills.Backend (SkillBackend)
import qualified Seal.Security.Policy as Policy (AutonomyLevel (..))
import Seal.Session.ExecCache (SessionExecCache, newSessionExecCache)
import Seal.Session.Lock
  ( ReplyRegistry, newReplyRegistry, replySubscribe, replyFanout
  , replyFanoutMessage, replyMigrateAll
  , SessionLocks, newSessionLocks )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, newSessionMeta
  , resolveDefaultAgent, saveSessionMeta )
import Seal.Tabs
  ( TabsHandle, focusTabH, insertTabH, removeTabH
  , renameTabH, rebindTabH, snapshotTabs )
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef (..), TabSlashCommand (..), ForceMode (..)
  , tabCount, tlTabs, lookupByRef )
import Seal.Tools.Exec.Abort (SessionAbortRegistry, newSessionAbortRegistry)
import Seal.Logging.Logger (SealLogger)
import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Vault.Commands (VaultRuntime (..))
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
  , cdAbortReg     :: SessionAbortRegistry
    -- ^ Per-session abort registry (design Blocker Resolution #2). The
    -- channel @\/stop@ command calls 'setSessionAbort' on this; the turn
    -- path looks up the per-session 'AbortFlag' via
    -- 'lookupOrCreateAbortFlag' and passes it into 'mkSessionAgentEnv' as
    -- 'aeAbortFlag'. Mirrors 'cdLocks'.
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
  , cdExecCache   :: SessionExecCache
    -- ^ The per-process session-exec + workdir-discovery cache (created by
    -- 'newChannelDeps'). Under @seal serve@ the SAME instance backs the
    -- web 'SendDeps'/'ApiDeps' so a scan runs once per session across all
    -- surfaces.
  }

-- | Build a 'TurnDeps' from a 'ChannelDeps'. The unified turn engine takes a
-- 'TurnDeps'; this adapter builder is the only place the channel's
-- 'ChannelDeps' shape meets the engine's 'TurnDeps' shape. After W4
-- collapses 'SendDeps' + 'ChannelDeps' + the CLI closures into one
-- 'TurnDeps', this builder is dropped.
mkChannelTurnDeps :: ChannelDeps -> TurnDeps
mkChannelTurnDeps deps = TurnDeps
  { tdPaths        = cdPaths deps
  , tdVault        = cdVault deps
  , tdProvider     = cdProvider deps
  , tdResolve      = resolveSessionProvider (cdProvider deps)
  , tdRepoReg      = cdRepoReg deps
  , tdAutonomy     = cdAutonomy deps
  , tdBroker       = cdBroker deps
  , tdHarnessReg   = cdHarnessRegistry deps
  , tdTmuxRunner   = cdTmuxRunner deps
  , tdHttpManager  = cdHttpManager deps
  , tdApprovals    = cdApprovals deps
  , tdReplies      = cdReplies deps
  , tdLocks        = cdLocks deps
  , tdAbortReg     = cdAbortReg deps
  , tdTabsHandle   = cdTabs deps
  , tdLogger       = cdLogger deps
  , tdIsRemote     = cdIsRemote deps
  , tdBaseBackends = cdBackends deps
  , tdExecCache    = cdExecCache deps
  }

-- | Build the channel 'TurnAdapter' for a given 'ChannelHandle' +
-- 'ChannelCaps'. The channel adapter:
-- * @taPreTurn@ — 'replySubscribe's the channel handle to the session's
--   replies (so the post-turn fan-out delivers the assistant response to
--   this channel) + 'replyFanoutMessage' mirrors the user's message to
--   every OTHER subscribed channel (cross-channel mirroring, the handle's
--   label).
-- * @taChannelLabel@ — the session's 'smChannel' (an inbox session is
--   always created on the channel its messages arrive on).
-- * @taOnStop@ — 'Just' the reply fan-out so subscribed channels receive
--   the final reply.
-- * @taOnUserMessage@ — for /bg turns, 'Just' a 'broadcastTabs' refresh so
--   the sidebar shows the session name as soon as the user message is
--   durable; 'Nothing' for normal turns (the post-turn 'taPostTurn'
--   refresh covers them).
-- * @taPostTurn@ — 'broadcastTabs' so the sidebar reflects the new tab +
--   the first-message snippet. Runs for both auto-tab and /bg paths.
-- * @taStartWiring@ — the engine-owned 'TurnEngine.buildStartWiring' (W4
--   collapsed the per-surface builders into this single one).
mkChannelTurnAdapter :: ChannelDeps -> TurnDeps -> ChannelHandle -> ChannelCaps -> TurnAdapter
mkChannelTurnAdapter deps td h caps = TurnAdapter
  { taCaps          = caps
  , taPreTurn       = \sid _meta t -> do
      _ <- replySubscribe (cdReplies deps) h sid
      replyFanoutMessage (cdReplies deps) sid (chLabel h) t
  , taChannelLabel  = smChannel
  , taOnStop        = Just . replyFanout (cdReplies deps)
  , taOnUserMessage = \meta -> if shouldAutoTab meta
                                 then Nothing
                                 else Just (broadcastTabs deps (cdTabs deps))
  , taPostTurn      = \_ _ -> broadcastTabs deps (cdTabs deps)
  , taStartWiring   = \sessionBackends sid appEnv eCfg operatorCeiling meta ->
      TurnEngine.buildStartWiring td sessionBackends sid appEnv eCfg operatorCeiling (smChannel meta)
  }

-- | Build a 'ChannelDeps' with fresh reply/lock/abort stores and the given
-- config loader. Used by 'Seal.Command.Serve' and the standalone entry
-- points. The 'tabsH' is the shared/unified handle (W4). The 'cursors' is
-- supplied by the caller: a persisting store
-- ('Seal.Channels.Cursor.newPersistingCursorStore') under @seal serve@ /
-- standalone @seal telegram@ / @seal signal@ so the conversation→tab
-- bindings survive a restart, or a non-persisting 'newCursorStore' in
-- tests. The caller is responsible for loading + seeding the cursor store
-- at boot (see 'Seal.Channels.Cursor.Persist.loadCursorMap' +
-- 'seedCursorStore'); this function does NOT touch disk for cursors.
newChannelDeps
  :: SealPaths -> VaultRuntime -> RepoRegistryHandle -> ProviderRuntime -> Backends
  -> Policy.AutonomyLevel -> Maybe StreamBroker
  -> HarnessRegistry -> TmuxRunner -> Maybe Manager
  -> ApprovalCache -> IO RuntimeConfig
  -> Bool
  -> TabsHandle
  -> SealLogger
  -> CursorStore
  -> IO ChannelDeps
newChannelDeps paths vault repoReg provider backends autonomy broker
               harnessReg tmux httpMgr approvals loadCfg isRemote tabsH logger cursors = do
  replies <- newReplyRegistry
  locks   <- newSessionLocks
  abortReg <- newSessionAbortRegistry
  execCache <- newSessionExecCache
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
    , cdAbortReg    = abortReg
    , cdTabs        = tabsH
    , cdConfig      = loadCfg
    , cdIsRemote    = isRemote
    , cdLogger      = logger
    , cdExecCache   = execCache
    }

-- | The conversation key for the cursor store: (channel-kind-text,
-- conversation-id-text). Derived from the 'MessageSource' (both fields
-- are server-derived, never user-supplied, so a sender cannot forge a
-- cursor key).
convKey :: MessageSource -> (Text, Text)
convKey ms = (channelKindToText (msChannelKind ms), conversationIdText (msConversationId ms))

-- | Build the channel's slash-command registry from a supplied base
-- 'Registry' plus the channel-specific @bg@, @call@, @skill@, and @model@
-- specs.
--
-- The channel-appended specs bind to the channel's per-session
-- 'channelCallDispatcher' (which reads the conversation's cursor-resolved
-- sid). Under @seal serve@, the supplied @registry@ is the WEB gateway's
-- registry, whose @skill@ and @call@ specs bind to 'webCallDispatcher'
-- (which reads the process-global @srActive@ ref). Without shadowing those
-- out, a @/skill load@ issued from Telegram dispatches via the FIRST
-- matching spec — the web one — and records the SKILL_LOAD entry on
-- whatever session @srActive@ points at, NOT the Telegram conversation's
-- session. The same hazard applies to @/model use@ (the core spec writes
-- @srActive@'s session.json, not the conversation's). The channel-dispatcher
--   versions must win, so drop any incoming spec whose primary name collides
--   with a channel-appended spec before appending them. 'lookupSpec' returns
--   the first match, so the appended channel specs then resolve correctly.
--
-- The @model@ spec is built from the channel's 'ProviderRuntime' + 'SealPaths'
-- + broker (passed explicitly rather than reading the whole 'ChannelDeps' so
-- the registry builder stays decoupled from the full deps record — the
-- pure-registry tests don't need to construct a full 'ChannelDeps').
buildChannelRegistry
  :: ProviderRuntime -> SealPaths -> Maybe StreamBroker
  -> SkillBackend -> BgRunner -> CallDispatcher
  -> IORef SessionId -> Registry -> Registry
buildChannelRegistry pr paths mBroker skillBackend bgRunner callDispatcher sidRef registry =
  mkRegistry (baseSpecs <> channelSpecs)
  where
    channelSpecNames = ["bg", "call", "skill", "model"] :: [Text]
    baseSpecs = filter
      (\s -> let CommandName n = csName s in n `notElem` channelSpecNames)
      (registrySpecs registry)
    channelSpecs =
      [ backgroundCommandSpec bgRunner
      , callCommandSpec callDispatcher
      , skillCommandSpec skillBackend callDispatcher
      , modelCommandSpecForSession
          pr paths (readIORef sidRef)
          (mkModelTranscriptWriter paths mBroker)
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
    let td = mkChannelTurnDeps deps
        bgRunner = mkBgRunner deps h askReply bgConvSid tabsH
        callDispatcher = channelCallDispatcher deps td h askReply bgConvSid
        registryWithBg = buildChannelRegistry
          (cdProvider deps) (cdPaths deps) (cdBroker deps)
          (bSkills (cdBackends deps)) bgRunner callDispatcher bgConvSid registry
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
                Right (Route.NewSession _args) -> do
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
  let td = mkChannelTurnDeps deps
      handleCaps = case mkCaps of
        Nothing  -> mkHandleCaps h askReply askSid
        Just f   -> f h askReply askSid
      adapter = mkChannelTurnAdapter deps td h handleCaps
  _ <- runSessionTurn td adapter meta mSrc t
  pure ()

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
-- | The inbox-channel analogue of 'Seal.Gateway.Send.webCallDispatcher'.
-- Delegates to the unified 'TurnEngine.callDispatcher'. Reads the session
-- id from the supplied 'IORef' fresh on each invocation — the
-- 'runChannelLoop' body writes the cursor-resolved 'sid' to this IORef
-- every turn, so the dispatcher always sees the active session.
channelCallDispatcher
  :: ChannelDeps -> TurnDeps -> ChannelHandle -> AskReplyStore -> IORef SessionId -> CallDispatcher
channelCallDispatcher deps td h askReply sidRef callOpName val = do
  sid <- readIORef sidRef
  mChannel <- TurnEngine.loadChannelLabel (cdPaths deps) sid
  let channelLabel = fromMaybe "cli" mChannel
      caps = mkHandleCaps h askReply sid
  TurnEngine.callDispatcher td caps sid channelLabel callOpName val

-- | Mint a fresh 'SessionId' for a forked agent instance.
-- IORef; the worker reads it after the run and returns it as the summary.
