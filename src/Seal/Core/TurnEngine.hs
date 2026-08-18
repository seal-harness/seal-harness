{-# LANGUAGE OverloadedStrings #-}
-- | The unified turn engine — the single implementation of the ISA registry
-- builder, the child registry builder, and (in later work units) the turn
-- body, system-prompt resolver, call dispatcher, and start wiring.
--
-- This module replaces the three duplicated implementations that lived in
-- 'Seal.Gateway.Send.buildWebRegistry', 'Seal.Channels.Loop.buildIsaRegistry',
-- and 'Seal.Channel.Cli.cliIsaReg'. The structural guarantee: a new opcode
-- added to 'buildSessionRegistry' is available on all four surfaces (Web,
-- TUI, Telegram, Signal) with zero additional wiring per surface.
module Seal.Core.TurnEngine
  ( buildSessionRegistry
  , buildChildRegistry
  , resolveSystemPrompt
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (Manager)

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (adSystem)
import Seal.Agent.PromptParts (injectStaticGuidance)
import Seal.Channel.Caps (ChannelCaps)
import Seal.Core.Backends (Backends (..))
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (SessionId)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner, mkTmuxIdent)
import Seal.ISA.Ops.Agent
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.ISA.Ops.File (fileReadOp, fileWriteOp, filePatchOp)
import Seal.ISA.Ops.Git (gitFetchOp, gitPullOp, gitPushOp)
import Seal.ISA.Ops.Harness
  (harnessListOp, harnessStartOp, harnessStopOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Memory
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Registry (opcodeDescribeOp, opcodeListOp)
import Seal.ISA.Ops.Repo (setupRepoOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Skills
import Seal.ISA.Opcode (opName)
import qualified Seal.ISA.Registry as ISA
import Seal.Skills.Autoload (injectAutoloadSkill)
import Seal.Skills.Backend qualified as Skill
import Seal.Skills.Prompt (injectAvailableSkills)
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Security.Path (WorkspaceRoot)
import qualified Seal.Security.Policy as Policy
  (AutonomyLevel, SecurityPolicy (..), AllowList (..))
import qualified Seal.SourceControl.Clone as Clone
import Seal.Vault.Commands (VaultRuntime)
import Seal.Config.File (WebConfig (..))
import Seal.Web.Fetch (webFetchOp, WebFetchConfig (..))
import Seal.Web.Search
  (webSearchOp, WebSearchConfig (..), parseProvider)

import qualified Seal.Agent.Runtime.Delegation.Worker as Worker
  (filterBlocklisted)

-- | Unwrap a nested 'Maybe' field from an optional 'WebConfig'. Returns
-- the default when the @[web]@ section is absent or the field is 'Nothing'.
unwrapOpt :: (WebConfig -> Maybe a) -> Maybe WebConfig -> a -> a
unwrapOpt field webCfg deflt =
  maybe deflt (fromMaybe deflt . field) webCfg

-- | Like 'unwrapOpt' but for fields that are already 'Maybe a'. The
-- default is 'Nothing'.
unwrapOptMaybe :: (WebConfig -> Maybe a) -> Maybe WebConfig -> Maybe a
unwrapOptMaybe = maybe Nothing

-- | Resolve the system prompt for a session turn. This is the **single**
-- implementation — used by all four surfaces (Web, TUI, Telegram, Signal).
--
-- The resolution pipeline:
-- 1. If @smSystemOverride@ is set (non-empty), use it as the base.
-- 2. Otherwise, read the bound agent's @adSystem@ from the workdir-aware
--    agent-def backend.
-- 3. Inject static guidance (parallel / tool-use / task-completion).
-- 4. Inject the autoload skill body.
-- 5. Inject the available-skills catalog (if enabled).
--
-- The flags ('autoloadId', 'injectCatalog', 'parallel', 'toolUse',
-- 'taskCompletion') are passed as explicit args — the caller computes
-- them from the loaded 'RuntimeConfig'. This matches the web path's
-- existing convention and avoids re-reading config inside the resolver.
resolveSystemPrompt
  :: Def.AgentDefBackend
  -> Skill.SkillBackend
  -> Maybe Text
  -- ^ The resolved auto-load skill id ('Nothing' disables injection).
  -> Bool
  -- ^ Whether to inject the @\<available_skills\>@ catalog.
  -> Bool
  -- ^ Whether to inject the parallel tool-call guidance block.
  -> Bool
  -- ^ Whether to inject the tool-use enforcement guidance block.
  -> Bool
  -- ^ Whether to inject the task-completion guidance block.
  -> SessionMeta
  -> IO (Maybe Text)
resolveSystemPrompt agentDefBackend skillBackend autoloadId injectCatalog
                   parallel toolUse taskCompletion meta = do
  base <- case smSystemOverride meta of
    Just t | not (T.null (T.strip t)) -> pure (Just t)
    _ -> case smAgent meta of
           Nothing  -> pure Nothing
           Just aid -> maybe Nothing adSystem <$> Def.adbRead agentDefBackend aid
  let withGuidance = injectStaticGuidance parallel toolUse taskCompletion base
  withAutoload <- injectAutoloadSkill skillBackend autoloadId withGuidance
  if injectCatalog
    then injectAvailableSkills skillBackend withAutoload
    else pure withAutoload

-- | Build the ISA registry for a session turn. This is the **single**
-- implementation — used by all four surfaces (Web, TUI, Telegram, Signal).
-- Replaces 'Seal.Gateway.Send.buildWebRegistry',
-- 'Seal.Channels.Loop.buildIsaRegistry', and
-- 'Seal.Channel.Cli.cliIsaReg'.
buildSessionRegistry
  :: VaultRuntime
  -> Clone.CloneDeps
  -> Backends
  -> WorkspaceRoot
  -> SessionId
  -> Int
  -> Policy.AutonomyLevel
  -> Maybe WebConfig
  -> AgentStartWiring
  -> HarnessRegistry
  -> TmuxRunner
  -> Maybe Manager
  -> ChannelCaps
  -> Bool
  -> ISA.Registry
buildSessionRegistry rt cloneDeps backends wsRoot sid operatorCeiling autonomy webCfg
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

-- | Build the narrowed ISA registry for a delegated child agent. Blocklists
-- the management opcodes (AGENT_DEF_WRITE/DELETE, AGENT_INSTANCES,
-- AGENT_START/STATUS/STOP/INTERRUPT). Includes web/harness ops — the CLI
-- child previously lacked these; the unified child includes them.
buildChildRegistry
  :: VaultRuntime
  -> Clone.CloneDeps
  -> Backends
  -> WorkspaceRoot
  -> SessionId
  -> Int
  -> Policy.AutonomyLevel
  -> Maybe WebConfig
  -> Maybe Manager
  -> ChannelCaps
  -> ISA.Registry
buildChildRegistry rt cloneDeps backends childWsRoot childSid operatorCeiling
                   autonomy webCfg httpManager childCaps =
  ISA.mkRegistry (Worker.filterBlocklisted childBaseOps opName)
  where
    childBaseOps =
      [ showHumanOp childCaps
      , askHumanOp childCaps
      , secretGetOp rt
      , memoryWriteOp (bMemory backends) childSid
      , memoryRecallOp defaultPageParams (bMemory backends)
      , memoryDeleteOp (bMemory backends)
      , skillWriteOp (bSkills backends) childSid
      , skillLoadOp (bSkills backends)
      , skillListOp (bSkills backends)
      , skillDeleteOp (bSkills backends)
      , agentDefReadOp (bAgentDefs backends)
      , agentDefListOp (bAgentDefs backends)
      , searchFilesOp childWsRoot securityPolicy operatorCeiling
      , fileReadOp childWsRoot operatorCeiling
      , fileWriteOp childWsRoot operatorCeiling
      , filePatchOp childWsRoot
      , shellExecOp childWsRoot securityPolicy
      , setupRepoOp cloneDeps childWsRoot autonomy
      , gitFetchOp cloneDeps childWsRoot autonomy
      , gitPullOp cloneDeps childWsRoot autonomy
      , gitPushOp cloneDeps childWsRoot autonomy
      , binExecOp childWsRoot securityPolicy binAllowList
      , processManageOp childWsRoot securityPolicy
      , webFetchOp webFetchCfg
      , webSearchOp webSearchCfg
      ]
    securityPolicy = Policy.SecurityPolicy Policy.AllowAll autonomy
    binAllowList = Nothing
    webFetchCfg = WebFetchConfig
      { wfcManager = httpManager, wfcAllowList = []
      , wfcMaxBytes = operatorCeiling, wfcAuthKey = Nothing }
    webSearchCfg = WebSearchConfig
      { wscManager = httpManager
      , wscProvider = parseProvider (unwrapOpt wcSearchProvider webCfg "parallel")
      , wscEndpoint = unwrapOpt wcSearchEndpoint webCfg ""
      , wscAllowList = unwrapOpt wcSearchAllowList webCfg []
      , wscAuthKey = unwrapOptMaybe wcSearchAuthKey webCfg
      , wscMaxResults = unwrapOpt wcSearchMaxResults webCfg 10
      , wscVault = Just rt
      , wscSearXngUrl = unwrapOptMaybe wcSearXngUrl webCfg
      }