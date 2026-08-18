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
import Seal.Git.Repo (ConfigRepo)
import Seal.Memory.Backend qualified as Mem
import Seal.Skills.Backend qualified as Skill

-- | The evolutionary-store backends + the in-process agent runtime, created
-- once at startup and shared between the command specs (which read them via
-- @\/skill@ \/ @\/agent@) and the ISA opcodes (which mutate them). The three
-- store backends are disk-backed (Markdown files under @config\/@); disk is
-- canonical and git is the versioning + audit layer. The agent runtime is an
-- in-process STM registry (lifecycle only — not persisted). The delegation
-- knobs (config, pause flag, parent-activity cell) are process-global so
-- AGENT_START calls across all channels share one pause / heartbeat state.
data Backends = Backends
  { bMemory    :: Mem.MemoryBackend
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

-- | Construct the disk-backed backends for the given config repo. The three
-- stores read their directories on demand (no startup materialization needed
-- — disk is canonical, so @\/skill list@ etc. just enumerate the dir). The
-- delegation knobs are process-global; the config is re-read per AGENT_START
-- call so config changes take effect without a restart.
newBackends :: FilePath -> ConfigRepo -> IO Backends
newBackends cfgRoot repo = do
  let skillsDir    = cfgRoot </> "skills"
      agentsDir    = cfgRoot </> "agents"
      memoryDir    = cfgRoot </> "memory"
  rt          <- newAgentRuntime
  pauseFlag   <- newSpawnPauseFlag
  parentAct   <- newParentActivity
  Backends
    <$> Mem.markdownMemoryBackend memoryDir repo
    <*> (Skill.unionSkillBackend <$> Skill.markdownSkillBackend skillsDir repo)
    <*> Def.markdownAgentDefBackend agentsDir repo
    <*> pure rt
    <*> pure (pure defaultDelegationConfig)  -- overridden at call sites that have a config path
    <*> pure pauseFlag
    <*> pure parentAct