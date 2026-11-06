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
  , handoffRepo
  , handoffRepoRegistry
  , dispatchHandoffRepo
  , DelegationWorkerDeps (..)
  ) where

import Control.Exception (SomeException, catch)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Katip (Severity (..), ls)
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
  , RepoSpec (..)
  )
import Seal.Channel.Caps (ChannelCaps (..))
import Data.Default (def)
import Seal.Config.Paths (SealPaths, agentSessionDir, sessionDir)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId)
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Handles.Transcript (IndexedTranscriptHandle, withIndexedTranscript)
import Seal.ISA.Dispatch (dispatch, recordSetupRepoResult)
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Ops.Repo (setupRepoOp)
import Seal.ISA.Registry (Registry, mkRegistry)
import Seal.ISA.RepeatDetect (RepeatTrack)
import Seal.Logging.Global (globalLogIO)
import Seal.Providers.Class (SomeProvider)
import Seal.Security.Policy (AllowList (..), AutonomyLevel)
import Seal.Session.Meta (SessionMeta (..), readSessionMeta)
import Seal.Session.Store (saveChildSessionMeta, saveSessionMeta)
import Seal.SourceControl.Clone (CloneDeps)
import Seal.Tools.Args (branchNameText, mkBranchName)
import Seal.Tools.Exec.Abort (AbortFlag)
import Seal.Tools.Exec.UIO.Internal (UIOEnv, runUIOWithEnv)
import Seal.Tools.Exec.UIOGit (uioCdCloneDeps)
import Seal.Tools.Timeout (ToolTimeoutConfig)
import Seal.Types.App (App, runApp)
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
  , dwdParentLineage :: [SessionId]
    -- ^ The parent's FULL lineage, self first (threaded from
    -- @buildWorker@'s @parentLineage@ parameter in "Seal.Core.TurnEngine").
    -- The worker prepends each spawned child's own id and passes
    -- @childSid : dwdParentLineage@ to 'dwdChildRegistry' so the child's
    -- session ops get the whole chain baked in — no per-call meta reads,
    -- no directory scans on the guard path. Empty in test deps that
    -- don't exercise lineage.
  , dwdAppEnv       :: Env
    -- ^ The top-level app env (katip logging, config) — re-used for the
    -- child's 'runApp'.
  , dwdMkUIOEnv :: Maybe FilePath -> SessionId -> IO UIOEnv
    -- ^ Construct the child's 'UIOEnv' (carrying the 'UntrustedIO'
    -- capability handle + Git 'CloneDeps') from an optional anchor
    -- workdir + the child's session id. When the anchor is 'Just path'
    -- (WU-4: the parent's workdir, @ctIsolateWorkdir = False@), the
    -- child reuses that workdir so repo clones and plan files are
    -- visible without re-cloning. When 'Nothing' (WU-4:
    -- @ctIsolateWorkdir = True@), the child gets a fresh empty workdir
    -- at @cache/workdirs/<child-session>@. The wiring layer resolves
    -- the security config into the env. Called at child-start time
    -- (after the child's sid is minted).
  , dwdParentWorkdir :: Maybe FilePath
    -- ^ The parent's workdir (WU-4). 'Just' the parent's
    -- @sessionWorkdir paths parentSid@ in production wiring; 'Nothing'
    -- in tests that don't exercise anchoring. Used by
    -- 'mkDelegateWorker' to compute the anchor: when the task's
    -- 'ctIsolateWorkdir' is 'False', the child inherits this workdir;
    -- when 'True', the child is isolated (anchor = 'Nothing').
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
      :: [SessionId] -> AgentDef -> Int -> Maybe Text -> SessionId -> ChannelCaps -> IO Registry
    -- ^ Build the child's narrowed ISA registry. The first argument is
    -- the CHILD's full lineage (self first), computed by
    -- 'mkDelegateWorker' as @childSid : dwdParentLineage@ — the
    -- registry bakes it into the child's session ops so the
    -- self/ancestor read guards never need a per-call lookup. W2
    -- signature (was @AgentDef -> SessionId -> ChannelCaps@): gains the
    -- CHILD's own delegation depth ('dwdParentDepth' + 1) and the
    -- child's effective role, both computed by 'mkDelegateWorker'. The
    -- wiring layer is responsible for applying the role-aware blocklist
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
  , dwdRepeatTrack :: SessionId -> IO RepeatTrack
    -- ^ Construct the child's no-progress repeat window from the child's
    -- session id (looked up from the process-lifetime
    -- 'Seal.ISA.RepeatDetect.SessionRepeatRegistry'; session-read hardening
    -- WU4). Mirrors 'dwdAbortFlag': the wiring layer passes the partially
    -- applied 'Seal.ISA.RepeatDetect.lookupOrCreateRepeatTrack' and the
    -- worker resolves it with the minted child sid at spawn time, so the
    -- child's window is independent of the parent's and survives across
    -- the child's turns.
  , dwdToolTimeout :: ToolTimeoutConfig
    -- ^ The per-call timeout/retry config, inherited from the parent
    -- (loaded once from @config.toml@ @[tool_timeout]@ at startup).
  , dwdTopLevel :: !Bool
    -- ^ When 'True', the worker creates a **top-level** session (used by
    -- @AGENT_MANAGE action=handoff@) instead of a child session nested
    -- under the parent's @agents\/@ directory. The session directory
    -- becomes @sessions\/\<sid\>@ (visible to @SESSION_LIST@), the
    -- metadata has @smParent = Nothing@, the lineage is @[sid]@ only,
    -- and the delegation depth is 0.
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
  let topLevel = dwdTopLevel deps
      childDir = if topLevel
                   then sessionDir (dwdPaths deps) childSid
                   else agentSessionDir (dwdPaths deps) (dwdParentSid deps) childSid
      childDepth = if topLevel then 0 else dwdParentDepth deps + 1
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
      withIndexedTranscript childDir $ \childTHandle -> do
        -- Top-level (handoff): write the session's own meta and resolve the
        -- repo it carries (explicit @ctRepoUrl@ else the caller's).
        mRepo <- if topLevel
                   then writeHandoffMeta deps childSid agentDef (ctRepo task)
                   else writeChildMeta deps childSid >> pure Nothing
        summaryRef <- newIORef (Nothing :: Maybe Text)
        stopFanoutDoneRef <- newIORef False
        let capturingCaps = def
              { ccSend = \t -> atomicModifyIORef' summaryRef (const (Just t, ()))
              , ccStreaming    = False  -- children: capture final summary, no per-delta sends
              }
        -- The child's full lineage, self first: the child's own id
        -- prepended to the parent's baked chain. Passed into the
        -- registry seam so the child's session ops get the whole chain.
        -- For top-level (handoff): lineage is just [childSid] — no parent chain.
        let childLineage = if topLevel
                             then [childSid]
                             else childSid : dwdParentLineage deps
        childReg <- dwdChildRegistry deps childLineage agentDef childDepth
                                      (effectiveRole (adRole agentDef) (ctRole task))
                                      childSid capturingCaps
        let anchor = if ctIsolateWorkdir task then Nothing else dwdParentWorkdir deps
        childUioEnv <- dwdMkUIOEnv deps anchor childSid
        childSystem <- dwdChildSystemPrompt deps agentDef task
        childAbortFlag <- dwdAbortFlag deps childSid
        childRepeatTrack <- dwdRepeatTrack deps childSid
        -- Handoff: materialize the session's repo in its OWN workdir (the
        -- task set @ctIsolateWorkdir@, so @dwdMkUIOEnv@ above built a fresh
        -- per-session workdir) through the audited SETUP_REPO opcode — the
        -- same op the gateway's setup-repo endpoint and @/new -r@ dispatch.
        -- It gets the same arguments the creating session used (url +
        -- branch). Runs BEFORE the first turn so the goal sees a checkout.
        case mRepo of
          Nothing -> pure ()
          Just repo -> do
            cloneDeps <- runUIOWithEnv childUioEnv uioCdCloneDeps
            runApp (dwdAppEnv deps) $
              dispatchHandoffRepo childTHandle
                (handoffRepoRegistry cloneDeps (dwdAutonomy deps))
                childUioEnv (dwdToolTimeout deps) childAbortFlag
                repo (Just (dwdChannel deps))
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
                  , aeDebugResponsePath = Nothing
                  , aeMaxModelRetries = 3
                  , aeRetryBaseDelayMs = 1000
              , aeOnEntry    = dwdOnEntry deps
              , aeOnUserMessage = Nothing
              , aeOnStop     = childEnvOnStop
              , aeStopFanoutDone = stopFanoutDoneRef
              , aeOnToolCall = \_ _ -> pure ()
              , aeOnTextDelta = Nothing
              , aeOnDemandSchemas = dwdOnDemand deps
              , aeLogPath    = Nothing
               , aeAbortFlag  = childAbortFlag
               , aeRepeatTrack = childRepeatTrack
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

-- | Write a minimal 'SessionMeta' for a spawned child session into its
-- child dir (@\<parent\>\/agents\/\<child\>\/session.json@): the child's
-- own id, the parent's provider/model (the audit trail records what the
-- parent session ran on), channel @"agent"@, and 'smParent' = the
-- spawning parent. Unreadable parent meta falls back to @\"unknown\"@.
-- Idempotent — overwrites harmlessly. The child meta never appears in
-- 'Seal.Session.Store.listSessions' (which scans only top-level dirs).
writeChildMeta :: DelegationWorkerDeps -> SessionId -> IO ()
writeChildMeta deps childSid = do
  mParent <- loadParentMeta deps
  now <- getCurrentTime
  let (provider, model) = case mParent of
        Just pm -> (smProvider pm, smModel pm)
        Nothing -> ("unknown", "unknown")
  saveChildSessionMeta (dwdPaths deps) (dwdParentSid deps) childSid SessionMeta
    { smId = childSid
    , smProvider = provider
    , smModel = model
    , smChannel = "agent"
    , smParent = Just (dwdParentSid deps)
    , smAgent = Nothing
    , smSystemOverride = Nothing
    , smAgentName = Nothing
    , smDescription = Nothing
    , smSealFrontMatter = True
    , smRepoUrl = Nothing
    , smRepoBranch = Nothing
    , smCreatedAt = now
    , smLastActive = now
    }

-- | Load the calling session's 'SessionMeta' through the shared leaf reader
-- ("Seal.Session.Meta"), if readable.
loadParentMeta :: DelegationWorkerDeps -> IO (Maybe SessionMeta)
loadParentMeta deps = readSessionMeta (dwdPaths deps) (dwdParentSid deps)

-- | The repo checkout a handoff session carries, from the caller's optional
-- overrides and the calling session's own record. Pure, and used by BOTH the
-- opcode (to name it in the result text) and the worker (to write the meta
-- and dispatch the clone) -- one rule, applied twice, so the two never
-- disagree.
--
-- * With no explicit repo, the caller's 'smRepoUrl' *and* 'smRepoBranch' are
--   inherited: the handoff session gets the same repo and the same branch as
--   the session that handed off.
-- * An explicit branch overrides the inherited one (same repo, different
--   branch).
-- * An explicit repo stands alone: its branch is whatever the caller passed
--   (or the remote default). A branch belonging to a different repo is never
--   carried across.
-- * A blank value on either side counts as absent; an inherited branch that
--   no longer validates (a hand-edited @session.json@) is dropped rather
--   than failing the handoff.
handoffRepo :: Maybe Text -> Maybe Text -> Maybe SessionMeta -> Maybe RepoSpec
handoffRepo explicitUrl explicitBranch mParent = case nonBlank explicitUrl of
  Just url -> Just (RepoSpec url (validBranch (nonBlank explicitBranch)))
  Nothing  -> do
    url <- mParent >>= nonBlank . smRepoUrl
    let inherited = mParent >>= validBranch . smRepoBranch
        branch = validBranch (nonBlank explicitBranch)
    pure (RepoSpec url (pick branch inherited))
  where
    nonBlank :: Maybe Text -> Maybe Text
    nonBlank Nothing  = Nothing
    nonBlank (Just t)
      | T.null (T.strip t) = Nothing
      | otherwise          = Just (T.strip t)
    -- A branch is only carried when it still parses as one.
    validBranch :: Maybe Text -> Maybe Text
    validBranch Nothing  = Nothing
    validBranch (Just b) = case mkBranchName b of
      Right bn -> Just (branchNameText bn)
      Left _   -> Nothing
    pick (Just x) _ = Just x
    pick Nothing y  = y

-- | The registry the handoff session's pre-turn repo checkout dispatches
-- through: exactly one opcode, the real 'SETUP_REPO', with the child's own
-- 'CloneDeps' and the caller's autonomy level.
--
-- Deliberately NOT the session's own (def-narrowed) registry: a definition's
-- @tools@ allow-list is intersected into that one, so a def that does not
-- list 'SETUP_REPO' would silently skip the checkout. Only that allow-list
-- is bypassed — no blocklist control is skipped ('SETUP_REPO' is not in
-- 'delegationBlocklist').
handoffRepoRegistry :: CloneDeps -> AutonomyLevel -> Registry
handoffRepoRegistry cloneDeps autonomy = mkRegistry [setupRepoOp cloneDeps autonomy]

-- | Dispatch 'SETUP_REPO' into the handoff session's transcript and record
-- its result for the user (the clone / no-op / conflict / failure text),
-- exactly as the gateway's @POST /api/sessions/:id/setup-repo@ endpoint and
-- @/new -r@ do. ACK-before-execute: 'dispatch' durably records the
-- invocation before the clone runs. A dispatch failure is logged; a clone
-- failure is recorded in the transcript. Neither aborts the session — the
-- goal may not need the files.
dispatchHandoffRepo
  :: IndexedTranscriptHandle -> Registry -> UIOEnv -> ToolTimeoutConfig
  -> AbortFlag -> RepoSpec -> Maybe Text -> App ()
dispatchHandoffRepo h reg uioEnv toolTimeout abortFlag repo mChannel = do
  -- Same argument shape the creating session used: @{url, branch?}@. The
  -- branch key is omitted (never null) when there is none, so the opcode
  -- asks for the remote's default branch.
  let input = object
        ([ "url" .= rsUrl repo ]
         <> maybe [] (\b -> ["branch" .= b]) (rsBranch repo))
  res <- dispatch reg h localBackend uioEnv toolTimeout abortFlag
                    (OpName "SETUP_REPO") input
  case res of
    Left dErr ->
      liftIO (globalLogIO WarningS
               (ls ("[handoff] SETUP_REPO dispatch failed for " <> rsUrl repo
                    <> ": " <> T.pack (show dErr))))
    Right opRes ->
      liftIO (recordSetupRepoResult h (OpName "SETUP_REPO") input opRes mChannel)

-- | Write a 'SessionMeta' for a top-level handoff session into its
-- top-level dir (@sessions\/\<sid\>\/session.json@): the session's own id,
-- the originating session's provider/model (for audit trail), channel
-- @"agent"@, 'smParent' = 'Nothing' (top-level — no parent), the def the
-- session runs (so a resume keeps its agent), and the repo it carries
-- (the task's @ctRepo@ when the opcode resolved one — the caller's explicit
-- values, else the calling session's own repo *and* branch; see
-- 'handoffRepo', which is idempotent and also covers a worker invoked with
-- no task repo at all). The handoff session IS visible to
-- 'Seal.Session.Store.listSessions' (it's a top-level dir, not nested under
-- @agents\/@). Returns the effective checkout, which the caller dispatches.
writeHandoffMeta
  :: DelegationWorkerDeps -> SessionId -> AgentDef -> Maybe RepoSpec
  -> IO (Maybe RepoSpec)
writeHandoffMeta deps childSid agentDef taskRepo = do
  mParent <- loadParentMeta deps
  now <- getCurrentTime
  let (provider, model) = case mParent of
        Just pm -> (smProvider pm, smModel pm)
        Nothing -> ("unknown", "unknown")
      repo = handoffRepo (rsUrl <$> taskRepo) (taskRepo >>= rsBranch) mParent
      agentName = let n = T.strip (adName agentDef)
                  in if T.null n then Nothing else Just n
  saveSessionMeta (dwdPaths deps) SessionMeta
    { smId = childSid
    , smProvider = provider
    , smModel = model
    , smChannel = "agent"
    , smParent = Nothing
    , smAgent = Just (adId agentDef)
    , smSystemOverride = Nothing
    , smAgentName = agentName
    , smDescription = Nothing
    , smSealFrontMatter = True
    , smRepoUrl = rsUrl <$> repo
    , smRepoBranch = repo >>= rsBranch
    , smCreatedAt = now
    , smLastActive = now
    }
  pure repo
