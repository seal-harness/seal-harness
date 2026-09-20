{-# LANGUAGE OverloadedStrings #-}
-- | The evolutionary-store backends + the in-process agent runtime.
--
-- Lives in 'Seal.Core' (not 'Seal.Channel.Cli') to avoid a module cycle:
-- 'Seal.Core.TurnEngine' needs 'Backends' for the ISA registry builder, and
-- 'Seal.Channel.Cli' needs 'Seal.Core.TurnEngine' for the unified
-- 'buildSessionRegistry'. 'Seal.Channel.Cli' re-exports 'Backends' and
-- 'newBackends' for backward compatibility.
module Seal.Core.Backends
  ( Backends (..)
  , newBackends
  ) where

import System.FilePath ((</>))

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Runtime.Delegation
  ( DelegationConfig, defaultDelegationConfig
  , SpawnPauseFlag, newSpawnPauseFlag
  , ParentActivity, newParentActivity )
import Seal.Agent.Runtime.Registry (AgentRuntime, newAgentRuntime)
import Seal.Config.Paths (SealPaths (..))
import Seal.Git.Repo (ConfigRepo)
import Seal.Memory.Embedding qualified as Emb
import Seal.Memory.Store qualified as Mem
import Seal.Skills.Backend qualified as Skill

-- | The evolutionary-store backends + the in-process agent runtime, created
-- once at startup and shared between the command specs (which read them via
-- @\/skill@ \/ @\/agent@) and the ISA opcodes (which mutate them). The
-- skills and agent-def stores are disk-backed (Markdown files under
-- @config\/@); disk is canonical and git is the versioning + audit layer.
-- The memory store is file-based under @\<sealHome\>\/memory\/@ with
-- @active\/@ and @archived\/@ directories (no git auto-commit — immutability
-- is enforced by the write-once + archive model). The embedding backend is
-- 'nullEmbeddingBackend' (engram wiring is deferred). The agent runtime is
-- an in-process STM registry (lifecycle only — not persisted). The
-- delegation knobs (config, pause flag, parent-activity cell) are
-- process-global so AGENT_START calls across all channels share one pause /
-- heartbeat state.
data Backends = Backends
  { bMemory    :: Mem.MemoryStore
  , bEmbedding :: Emb.EmbeddingBackend
  , bSkills    :: Skill.SkillBackend
  , bAgentDefs :: Def.AgentDefBackend
  , bRuntime   :: AgentRuntime
  , bDelegationConfig :: IO DelegationConfig
    -- ^ Reload the [delegation] config per AGENT_START call (so config
    -- changes take effect without a restart). The IO action reads
    -- @config.toml@ and returns the resolved 'DelegationConfig'.
  , bSpawnPauseFlag :: SpawnPauseFlag
    -- ^ Process-global spawn-pause flag (operator can freeze new fan-out).
  , bParentActivity :: ParentActivity
    -- ^ Process-global parent-activity cell (heartbeat target).
  }

-- | Construct the disk-backed backends for the given config repo and seal
-- paths. Skills and agent defs read their directories on demand (no startup
-- materialization needed — disk is canonical, so @\/skill list@ etc. just
-- enumerate the dir). The memory store is constructed from
-- @\<sealHome\>\/memory\/@ (NOT @\<configRoot\>\/memory\/@) — memory is a
-- separate store with its own immutability guarantees. The embedding backend
-- The embedding backend is passed in (resolved from config at the call
-- site) so this function doesn't depend on 'RuntimeConfig' or
-- 'Seal.Memory.EngramBackend'. The delegation knobs are process-global;
-- the config is re-read per AGENT_START call so config changes take effect
-- without a restart.
newBackends :: SealPaths -> ConfigRepo -> Emb.EmbeddingBackend -> IO Backends
newBackends paths repo embedding = do
  let skillsDir    = spConfig paths </> "skills"
      agentsDir    = spConfig paths </> "agents"
      memoryDir    = spHome paths </> "memory"
  rt          <- newAgentRuntime
  pauseFlag   <- newSpawnPauseFlag
  parentAct   <- newParentActivity
  memStore    <- Mem.fileMemoryStore memoryDir
  skills      <- Skill.unionSkillBackend <$> Skill.markdownSkillBackend skillsDir repo
  agentDefs   <- Def.markdownAgentDefBackend agentsDir repo
  pure (Backends
    { bMemory = memStore
    , bEmbedding = embedding
    , bSkills = skills
    , bAgentDefs = agentDefs
    , bRuntime = rt
    , bDelegationConfig = pure defaultDelegationConfig
    , bSpawnPauseFlag = pauseFlag
    , bParentActivity = parentAct
    })
