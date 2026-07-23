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
  , filterBlocklisted
  , narrowAllowList
  , DelegationWorkerDeps (..)
  ) where

import Control.Exception (SomeException, catch)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)

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
import Seal.Config.Paths (SealPaths, agentSessionDir)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Handles.Transcript (withTwoFileTranscript)
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)
import Seal.Security.Policy (AllowList (..), AutonomyLevel)
import Seal.Tools.Exec.UntrustedIO (UntrustedIO)
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

-- | Apply the 'delegationBlocklist' to a child's tool allow-list. Only
-- narrows 'AllowOnly' (set-difference with the blocklist); 'AllowAll' is
-- returned unchanged because the blocklist is enforced at registry-build
-- time by omitting blocklisted opcodes from the ops list (we can't enumerate
-- the universe of opcode names to form a complement here).
narrowAllowList :: AllowList OpName -> AllowList OpName
narrowAllowList AllowAll       = AllowAll
narrowAllowList (AllowOnly xs) = AllowOnly (Set.difference xs delegationBlocklist)

-- | Filter a list of opcodes to remove any whose name is in the
-- 'delegationBlocklist'. The wiring layer calls this on its base ops list
-- before passing to 'Seal.ISA.Registry.mkRegistry' to build the child's
-- narrowed registry. This is the primary blocklist enforcement — it works
-- regardless of whether the def's @adTools@ is 'AllowAll' or 'AllowOnly'.
filterBlocklisted :: [opcode] -> (opcode -> OpName) -> [opcode]
filterBlocklisted ops getName =
  [ o | o <- ops, not (getName o `Set.member` delegationBlocklist) ]

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
  , dwdUntrustedIO  :: UntrustedIO
  , dwdAutonomy     :: AutonomyLevel
  , dwdApprovals    :: ApprovalCache
  , dwdOnDemand     :: Bool
  , dwdParentDepth  :: Int
    -- ^ The parent's delegation depth; the child's depth is this + 1.
  , dwdResolveProvider :: AgentDef -> IO (Either Text (SomeProvider, ModelId))
    -- ^ Resolve the child's provider+model from the def, applying any
    -- delegation.provider/model/base_url override (the wiring layer reads
    -- the override from the RuntimeConfig and threads it here).
  , dwdChildRegistry
      :: AgentDef -> SessionId -> ChannelCaps -> IO Registry
    -- ^ Build the child's narrowed ISA registry. The wiring layer is
    -- responsible for applying 'delegationBlocklist' to the def's
    -- @adTools@ allow-list and constructing the registry. The caps + sid
    -- are passed in so the registry can close over them (ASK_HUMAN etc.).
  , dwdChildSystemPrompt :: AgentDef -> ChildTask -> Maybe Text
    -- ^ Build the child's system prompt from the def's @adSystem@ + the
    -- task's @ctContext@. 'Nothing' means no system prompt.
  , dwdOnEntry :: IO ()
    -- ^ The on-entry hook for the child's transcript (live broadcast).
    -- 'pure ()' for the CLI; 'broadcastNewEntries' for web/channels.
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
mkDelegateWorker deps def childSid task _hooks = do
  let childDir = agentSessionDir (dwdPaths deps) (dwdParentSid deps) childSid
  createDirectoryIfMissing True childDir
  eProv <- dwdResolveProvider deps def
  case eProv of
    Left err -> pure (ChildWorkerOutcome
                       (Just ("agent start failed: " <> err))
                       CerError 0 0 (Just childSid))
    Right (prov, model) ->
      withTwoFileTranscript childDir $ \childTHandle -> do
        summaryRef <- newIORef (Nothing :: Maybe Text)
        let capturingCaps = ChannelCaps
              { ccSend = \t -> atomicModifyIORef' summaryRef (const (Just t, ()))
              , ccPrompt = \_ -> pure ""  -- children don't prompt the human
              , ccPromptSecret = \_ -> pure ""
              }
        childReg <- dwdChildRegistry deps def childSid capturingCaps
        let env = AgentEnv
              { aeProvider   = prov
              , aeProviderLabel = providerLabel def
              , aeModel      = model
              , aeSystem     = dwdChildSystemPrompt deps def task
              , aeRegistry   = childReg
              , aeTranscript = childTHandle
              , aeBackend    = localBackend
              , aeUntrustedIO = dwdUntrustedIO deps
              , aeCaps       = capturingCaps
              , aeSession    = childSid
              , aeMaxTurns   = 12
              , aeMessageSource = Nothing
              , aeAutonomy   = dwdAutonomy deps
              , aeApprovals  = dwdApprovals deps
              , aeDebugRequestsPath = Nothing
              , aeOnEntry    = dwdOnEntry deps
              , aeOnDemandSchemas = dwdOnDemand deps
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