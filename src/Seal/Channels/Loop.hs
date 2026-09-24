{-# LANGUAGE OverloadedStrings #-}
-- | The shared 'ChannelDeps' record — the dependency bundle built once at
-- startup (in 'Seal.Command.Serve') and shared between the web send
-- handler ('Seal.Gateway.Send.SendDeps') and the tab-close notifier. The
-- old inbox-driven channel loop ('runChannelLoop', 'plainTurn', etc.) has
-- been replaced by the standalone 'seal-chat-channels' package
-- ('Seal.Channels.Chat.Loop'); this module retains only the shared deps
-- infrastructure that the web serve path still needs.
module Seal.Channels.Loop
  ( ChannelDeps (..)
  , newChannelDeps
  , mkTabCloseNotifier
  ) where

import Network.HTTP.Client (Manager)

import Seal.Channel.Cli (Backends)
import Seal.Channels.Cursor (CursorStore, cursorClearAll)
import Seal.Command.Provider (ProviderRuntime)
import Seal.Command.Tab (TabCloseNotifier)
import Seal.Config.File (RuntimeConfig)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (sessionIdText)
import Seal.Gateway.StreamBroker (StreamBroker)
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner)
import Seal.Logging.Logger (SealLogger)
import Seal.Session.ExecCache (SessionExecCache, newSessionExecCache)
import Seal.Session.Lock
  (ReplyRegistry, SessionLocks, newReplyRegistry, newSessionLocks, replyFanout)
import Seal.SourceControl.AgentRegistry (AgentRegistryHandle)
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.Tabs (TabsHandle)
import Seal.Tabs.Types (TabRef (..))
import Seal.Tools.Exec.Abort (SessionAbortRegistry, newSessionAbortRegistry)
import qualified Seal.Security.Policy as Policy (AutonomyLevel)
import Seal.Vault.Commands (VaultRuntime)

-- | The dependencies a channel turn needs to have full parity with the web
-- and CLI paths. Built once at startup (in 'Seal.Command.Serve') and shared
-- across all turns. The reply registry, write locks, abort registry, and
-- exec cache created inside 'newChannelDeps' are shared with the web send
-- handler ('Seal.Gateway.Send.SendDeps') so turns from all surfaces
-- (web, chat channels) hit the same stores.
data ChannelDeps = ChannelDeps
  { cdPaths      :: SealPaths
  , cdVault      :: VaultRuntime
  , cdRepoReg    :: RepoRegistryHandle
  , cdAgentReg   :: AgentRegistryHandle
    -- ^ The shared ssh-agent registry (one per process). Threaded through
    -- 'TurnDeps' so all git-op call sites share the same 'arhLive' set.
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
    -- ^ Per-session abort registry. The channel @\/stop@ command calls
    -- 'setSessionAbort' on this; the turn path looks up the per-session
    -- 'AbortFlag' via 'lookupOrCreateAbortFlag' and passes it into
    -- 'mkSessionAgentEnv' as 'aeAbortFlag'. Mirrors 'cdLocks'.
  , cdTabs        :: TabsHandle
    -- ^ The shared, unified tab handle. Under @seal serve@, this is the SAME
    -- handle as the web gateway's 'adTabsHandle', so a tab inserted by any
    -- channel is visible in the web sidebar.
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

-- | Build a 'ChannelDeps' with fresh reply/lock/abort stores and the given
-- config loader. Used by 'Seal.Command.Serve'. The 'tabsH' is the
-- shared/unified handle. The 'cursors' is supplied by the caller: a
-- persisting store ('Seal.Channels.Cursor.newPersistingCursorStore') under
-- @seal serve@ so the conversation→tab bindings survive a restart, or a
-- non-persisting 'newCursorStore' in tests. The caller is responsible for
-- loading + seeding the cursor store at boot (see
-- 'Seal.Channels.Cursor.Persist.loadCursorMap' + 'seedCursorStore'); this
-- function does NOT touch disk for cursors.
newChannelDeps
  :: SealPaths -> VaultRuntime -> RepoRegistryHandle -> AgentRegistryHandle -> ProviderRuntime -> Backends
  -> Policy.AutonomyLevel -> Maybe StreamBroker
  -> HarnessRegistry -> TmuxRunner -> Maybe Manager
  -> ApprovalCache -> IO RuntimeConfig
  -> Bool
  -> TabsHandle
  -> SealLogger
  -> CursorStore
  -> IO ChannelDeps
newChannelDeps paths vault repoReg agentReg provider backends autonomy broker
               harnessReg tmux httpMgr approvals loadCfg isRemote tabsH logger cursors = do
  replies <- newReplyRegistry
  locks   <- newSessionLocks
  abortReg <- newSessionAbortRegistry
  execCache <- newSessionExecCache
  pure ChannelDeps
    { cdPaths      = paths
    , cdVault      = vault
    , cdRepoReg    = repoReg
    , cdAgentReg   = agentReg
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

-- | Build a 'TabCloseNotifier' from the shared cursor store + reply
-- registry. When a tab is closed, every conversation whose cursor points
-- at the closed tab's session is notified (via 'replyFanout') and the
-- cursor is cleared (so the next message mints a fresh tab). For
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
