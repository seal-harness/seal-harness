{-# LANGUAGE OverloadedStrings #-}
-- | The shared worker-builder for AGENT_START delegation. Each channel
-- (CLI, Signal, Telegram, web) has its own per-turn 'AgentEnv' closure but
-- the delegation-specific logic — open the child transcript under
-- @\<parent\>\/agents\/\<child-id\>@, build a narrowed child ISA registry with
-- the delegation blocklist applied, resolve the child provider (honoring
-- @delegation.provider/model/base_url@ overrides), run 'runTurn' with the
-- goal as the first user message, and capture the final text response as the
-- summary — is identical across channels. This module exposes one
-- 'mkDelegateWorker' that the wiring layers call.
module Seal.Agent.Runtime.Delegation.Worker
  ( mkDelegateWorker
  , delegationBlocklist
  , childBlocklist
  , effectiveRole
  , intersectAllowList
  , filterBlocklisted
  , filterBlocklistedWith
  , narrowAllowList
  , narrowAllowListWith
  , DelegationWorkerDeps (..)
  ) where

import Control.Exception (SomeException, catch)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)

import Seal.Agent.Def.Backend (AgentDefBackend)
import Seal.Agent.Def.Types (AgentDef (..))
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Delegation
  ( AgentWorkerBuilder
  , ChildExitReason (..)
  , ChildTask (..)
  , ChildWorkerOutcome (..)
  )
import Seal.Channel.Caps (ChannelCaps (..))
import Data.Default (def)
import Seal.Config.Paths (SealPaths, agentSessionDir)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId)
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Handles.Transcript (withTwoFileTranscript)
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)
import Seal.Security.Policy (AllowList (..), AutonomyLevel)
import Seal.Tools.Exec.Abort (AbortFlag)
import Seal.Tools.Exec.UIO.Internal (UIOEnv)
import Seal.Tools.Timeout (ToolTimeoutConfig)
import Seal.Types.App (runApp)
import Seal.Types.Env (Env)

-- | Opcodes that a child agent must NEVER have access to. Mirrors Hermes'
-- @DELEGATE_BLOCKED_TOOLS@. Stripping these means a child cannot:
--
--   * recursively spawn its own subagents (@AGENT_START@) — that would
--     bypass the depth cap;
--   * mutate agent definitions (@AGENT_DEF_WRITE@ / @AGENT_DEF_DELETE@) —
--     only the parent should evolve the def store;
--   * introspect or control live instances (@AGENT_INSTANCES@ /
--     @AGENT_STATUS@ / @AGENT_STOP@ / @AGENT_INTERRUPT@) — those are
--     parent/operator controls, not child tools.
delegationBlocklist :: Set.Set OpName
delegationBlocklist = Set.fromList
  [ OpName "AGENT_START"
  , OpName "AGENT_DEF_WRITE"
  , OpName "AGENT_DEF_DELETE"
  , OpName "AGENT_INSTANCES"
  , OpName "AGENT_STATUS"
  , OpName "AGENT_STOP"
  , OpName "AGENT_INTERRUPT"
  ]

-- | The role-aware child blocklist (issue #154 §3.2): the delegation
-- blocklist a CHILD's registry must apply. AGENT_START is ALWAYS
-- present-but-rejecting in a child registry — the gate (its authorize)
-- is the enforcement, returning the dedicated leaf/kill-switch messages
-- (§3.2 item 6) instead of unknown-tool. So the blocklist drops only
-- AGENT_START; every other entry (def mutation, lifecycle control)
-- always applies — those stay parent/operator-only.
childBlocklist :: Maybe Text -> Bool -> Set.Set OpName
childBlocklist _ _ = Set.delete (OpName "AGENT_START") delegationBlocklist

-- | The effective role for a spawned child (issue #154 §3.1): the def's
-- role is AUTHORITATIVE; the per-task @role@ hint may only NARROW (an
-- orchestrator def downgraded to leaf). Any other task hint is ignored —
-- a leaf def can never be widened by task input. Returns @Nothing@ for
-- an unrole'd def (implicit leaf).
effectiveRole :: Maybe Text -> Maybe Text -> Maybe Text
effectiveRole defRole (Just "leaf") = case defRole of
  Just "orchestrator" -> Just "leaf"
  other               -> other
effectiveRole defRole _ = defRole

-- | Intersect a def's @tools@ allow-list with the set of opcodes the
-- harness's base child registry actually exposes ('AllowOnly' ⇒ keep only
-- members; 'AllowAll' passes through unchanged — the full base registry).
-- Unknown names silently drop (intersection semantics, not grants).
intersectAllowList :: AllowList OpName -> (OpName -> Bool) -> AllowList OpName
intersectAllowList AllowAll _         = AllowAll
intersectAllowList (AllowOnly xs) inBase = AllowOnly (Set.filter inBase xs)

-- | Apply a (role-aware) blocklist to a child's tool allow-list. Only
-- narrows 'AllowOnly' (set-difference with the blocklist); 'AllowAll' is
-- returned unchanged because the blocklist is enforced at registry-build
-- time by omitting blocklisted opcodes from the ops list (we can't enumerate
-- the universe of opcode names to form a complement here).
narrowAllowList :: AllowList OpName -> AllowList OpName
narrowAllowList = narrowAllowListWith delegationBlocklist

-- | 'narrowAllowList' over an explicit (role-aware) blocklist — W2's
-- second chokepoint: a def that explicitly lists @AGENT_START@ keeps it
-- only when the computed blocklist also omits it.
narrowAllowListWith :: Set.Set OpName -> AllowList OpName -> AllowList OpName
narrowAllowListWith _ AllowAll       = AllowAll
narrowAllowListWith bl (AllowOnly xs) = AllowOnly (Set.difference xs bl)

-- | Filter a list of opcodes to remove any whose name is in the
-- 'delegationBlocklist'. The wiring layer calls this on its base ops list
-- before passing to 'Seal.ISA.Registry.mkRegistry' to build the child's
-- narrowed registry. This is the primary blocklist enforcement — it works
-- regardless of whether the def's @adTools@ is 'AllowAll' or 'AllowOnly'.
filterBlocklisted :: [opcode] -> (opcode -> OpName) -> [opcode]
filterBlocklisted ops getName =
  [ o | o <- ops, not (getName o `Set.member` delegationBlocklist) ]

-- | Filter a list of opcodes to remove any whose name is in an explicit
-- (role-aware) blocklist. W2's generalized form — 'filterBlocklisted' is
-- the static-blocklist special case.
filterBlocklistedWith :: [opcode] -> Set.Set OpName -> (opcode -> OpName) -> [opcode]
filterBlocklistedWith ops bl getName =
  [ o | o <- ops, not (getName o `Set.member` bl) ]

-- | The per-channel deps the worker-builder closes over. The wiring layer
-- (Cli.hs, Channels.Loop.hs, Gateway.Send.hs) builds this from its own
-- per-turn closure and passes it to 'mkDelegateWorker'.
data DelegationWorkerDeps = DelegationWorkerDeps
  { dwdPaths        :: SealPaths
  , dwdParentSid    :: SessionId
    -- ^ The parent's session id — the child's transcript nests under it.
  , dwdAppEnv       :: Env
    -- ^ The top-level app env (katip logging, config) — re-used for the
    -- child's 'runApp'.
  , dwdMkUIOEnv :: SessionId -> IO UIOEnv
    -- ^ Construct the child's 'UIOEnv' (carrying the 'UntrustedIO'
    -- capability handle + Git 'CloneDeps') from the child's session id.
    -- The wiring layer creates the child's workdir (per-session isolation)
    -- and resolves the security config into the env. Called at child-start
    -- time (after the child's sid is minted).
  , dwdAutonomy     :: AutonomyLevel
  , dwdApprovals    :: ApprovalCache
  , dwdOnDemand     :: Bool
  , dwdParentDepth  :: Int
    -- ^ The parent's delegation depth; the child's depth is this + 1.
  , dwdResolveProvider :: AgentDef -> IO (Either Text (SomeProvider, ModelId))
    -- ^ Resolve the child's provider+model from the def, applying any
    -- delegation.provider/model/base_url override (the wiring layer reads
    -- the override from the RuntimeConfig and threads it here).
  , dwdResolveProviderOverride
      :: Maybe (AgentDef -> IO (Either Text (SomeProvider, ModelId)))
    -- ^ Test seam (issue #154): when 'Just', REPLACES 'dwdResolveProvider'
    -- for every child spawn. 'Nothing' in production. Gateway API
    -- integration tests inject a resolver returning the harness's
    -- 'ScriptProvider' so child turns pop the same scripted queue as the
    -- parent turn (no real provider call). Mirrors the 'tdMkWorker' seam
    -- pattern ('Nothing' = production behavior).
  , dwdUnionDefBackend :: AgentDefBackend
    -- ^ The per-turn workdir ⊕ user union agent-def backend (the SAME
    -- one the parent session's turn assembled). The nested wiring (§3.2)
    -- resolves grandchildren against it so repo-shipped orchestrators can
    -- spawn repo-shipped specialists. In mode=remote this reuses the
    -- parent's cachedWorkdirScan result — no new control-plane FS reads.
  , dwdChildRegistry
      :: AgentDef -> Int -> Maybe Text -> SessionId -> ChannelCaps -> IO Registry
    -- ^ Build the child's narrowed ISA registry. W2 signature (was
    -- @AgentDef -> SessionId -> ChannelCaps@): gains the CHILD's own
    -- delegation depth ('dwdParentDepth' + 1) and the child's effective
    -- role, both computed by 'mkDelegateWorker'. The wiring layer is
    -- responsible for applying the role-aware blocklist
    -- ('childBlocklist') to the ops list AND the def's @adTools@
    -- allow-list ('narrowAllowListWith' / 'intersectAllowList') and
    -- constructing the registry — including, for orchestrator children,
    -- the role-conditioned nested @AGENT_START@. The caps + sid are
    -- passed in so the registry can close over them (ASK_HUMAN etc.).
  , dwdChildSystemPrompt :: AgentDef -> ChildTask -> IO (Maybe Text)
    -- ^ Build the child's system prompt from the def's @adSystem@ + the
    -- task's @ctContext@. Runs in 'IO' so the wiring layer can load the
    -- auto-injected skill (default @seal-usage@) from the skill backend and
    -- append it. 'Nothing' means no system prompt.
  , dwdOnEntry :: IO ()
    -- ^ The on-entry hook for the child's transcript (live broadcast).
    -- 'pure ()' for the CLI; 'broadcastNewEntries' for web/channels.
  , dwdChannel :: Text
    -- ^ The parent session's channel label (e.g. @\"telegram\"@, @\"web\"@,
    -- @\"cli\"@), inherited by the child so the child's request entries are
    -- attributed to the same channel the parent turn ran on. Stamped into
    -- the child's 'aeChannel' so 'runTurn' attributes the child's user
    -- messages (the task goals) to the originating channel.
  , dwdAbortFlag :: SessionId -> IO AbortFlag
    -- ^ Construct the child's abort flag from the child's session id
    -- (looked up from the 'Seal.Tools.Exec.Abort.SessionAbortRegistry').
    -- The child's abort is independent of the parent's in v1 (a parent
    -- abort doesn't auto-abort the child, and vice versa).
  , dwdToolTimeout :: ToolTimeoutConfig
    -- ^ The per-call timeout/retry config, inherited from the parent
    -- (loaded once from @config.toml@ @[tool_timeout]@ at startup).
  }

-- | Build the 'AgentWorkerBuilder' the AGENT_START opcode closes over. This
-- is the shared delegation worker: open the child transcript, build the
-- child env, run 'runTurn' with the goal as the first user message, capture
-- the final text response as the summary, and report the outcome.
--
-- The summary is captured via a 'ChannelCaps' whose 'ccSend' writes to an
-- IORef; 'runTurn' calls 'ccSend' with the final text response, so we read
-- the IORef after the run. The child's @ccPrompt@ is a no-op (children don't
-- prompt the human — that would deadlock the parent).
mkDelegateWorker :: DelegationWorkerDeps -> AgentWorkerBuilder
mkDelegateWorker deps agentDef childSid task _hooks = do
  let childDir = agentSessionDir (dwdPaths deps) (dwdParentSid deps) childSid
      childDepth = dwdParentDepth deps + 1
  createDirectoryIfMissing True childDir
  let resolve = case dwdResolveProviderOverride deps of
        Just testResolve -> testResolve agentDef
        Nothing          -> dwdResolveProvider deps agentDef
  eProv <- resolve
  case eProv of
    Left err -> pure (ChildWorkerOutcome
                       (Just ("agent start failed: " <> err))
                       CerError 0 0 (Just childSid))
    Right (prov, model) ->
      withTwoFileTranscript childDir $ \childTHandle -> do
        summaryRef <- newIORef (Nothing :: Maybe Text)
        let capturingCaps = def
              { ccSend = \t -> atomicModifyIORef' summaryRef (const (Just t, ()))
              , ccStreaming    = False  -- children: capture final summary, no per-delta sends
              }
        childReg <- dwdChildRegistry deps agentDef childDepth
                                     (effectiveRole (adRole agentDef) (ctRole task))
                                     childSid capturingCaps
        childUioEnv <- dwdMkUIOEnv deps childSid
        childSystem <- dwdChildSystemPrompt deps agentDef task
        childAbortFlag <- dwdAbortFlag deps childSid
        -- Capture the final answer via 'aeOnStop': the loop's
        -- final-answer path calls 'notifyStop' (the replyFanout hook)
        -- rather than 'ccSend' — the double-delivery fix. The
        -- summaryRef-capture hooks BOTH, taking the last write.
        let childEnvOnStop = Just (\t -> atomicModifyIORef' summaryRef (const (Just t, ())))
        let env = AgentEnv
              { aeProvider   = prov
              , aeProviderLabel = providerLabel agentDef
              , aeModel      = model
              , aeSystem     = childSystem
              , aeRegistry   = childReg
              , aeTranscript = childTHandle
              , aeBackend    = localBackend
              , aeUIOEnv     = childUioEnv
              , aeCaps       = capturingCaps
              , aeSession    = childSid
              , aeMaxTurns   = 90
              , aeChannel    = dwdChannel deps
              , aeMessageSource = Nothing
              , aeAutonomy   = dwdAutonomy deps
              , aeApprovals  = dwdApprovals deps
              , aeDebugRequestsPath = Nothing
              , aeOnEntry    = dwdOnEntry deps
              , aeOnUserMessage = Nothing
              , aeOnStop     = childEnvOnStop
              , aeOnDemandSchemas = dwdOnDemand deps
              , aeLogPath    = Nothing
              , aeAbortFlag  = childAbortFlag
              , aeToolTimeout = dwdToolTimeout deps
              }
        runApp (dwdAppEnv deps) (runTurn env (ctGoal task))
          `catch` \e -> writeIORef summaryRef
                       (Just ("child runTurn raised: " <> T.pack (show (e :: SomeException))))
        summary <- readIORef summaryRef
        let exitReason = case summary of
              Just _  -> CerCompleted
              Nothing -> CerMaxIterations
        -- Token counts: the child's per-turn usage is recorded in the
        -- transcript entries; we don't aggregate them here (would require
        -- reading entries.jsonl). Report 0 for now — a follow-up can sum
        -- the child's EKResponse entries.
        pure (ChildWorkerOutcome summary exitReason 0 0 (Just childSid))
  where
    providerLabel d = if T.null (adProvider d) then "ollama" else adProvider d
