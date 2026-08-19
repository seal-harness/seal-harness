{-# LANGUAGE OverloadedStrings #-}
-- | The unified turn engine — the single implementation of the ISA registry
-- builder, the child registry builder, the system-prompt resolver, and the
-- turn body ('runSessionTurn').
--
-- This module replaces the three duplicated implementations that lived in
-- 'Seal.Gateway.Send.buildWebRegistry' + 'plainTurn',
-- 'Seal.Channels.Loop.buildIsaRegistry' + 'runTurnOnSession', and
-- 'Seal.Channel.Cli.cliIsaReg' + 'withCliTurn'. The structural guarantee: a
-- new opcode added to 'buildSessionRegistry' is available on all four
-- surfaces (Web, TUI, Telegram, Signal) with zero additional wiring per
-- surface, and a turn behaves identically regardless of which surface
-- originates it.
module Seal.Core.TurnEngine
  ( buildSessionRegistry
  , buildChildRegistry
  , resolveSystemPrompt
  , TurnDeps (..)
  , TurnAdapter (..)
  , TurnOutcome (..)
  , runSessionTurn
  , shouldAutoTab
  , callDispatcher
  , buildStartWiring
  , buildWorker
  , loadChannelLabel
  ) where

import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (adSystem, adModel, adProvider, AgentDef (..))
import Seal.Agent.Env (AgentEnv (..), TurnEnv (..), mkSessionAgentEnv)
import Seal.Agent.Loop (runTurn)
import Seal.Agent.PromptParts (injectStaticGuidance)
import Seal.Agent.Runtime.Delegation
  (ChildTask (..), ctContext, fromFileConfig)
import Seal.Agent.Runtime.Delegation.Worker
  (mkDelegateWorker, DelegationWorkerDeps (..))
import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Provider (ProviderRuntime (..), resolveDefProvider)
import Seal.Config.File
  ( RuntimeConfig, defaultRetrievalMaxScanBytes, defaultMaxTurns, loadRuntimeConfig
  , retrievalMaxScanBytes, onDemandSchemas, maxTurnsConfig, rcWeb, rcDelegation, rcDebugSessionTranscript
  , resolvedAutoloadSkill, resolvedAvailableSkills, resolvedParallelToolGuidance
  , resolvedToolUseEnforcement, resolvedTaskCompletionGuidance, toolTimeoutConfig
  , WebConfig (..) )
import Seal.Config.Paths
  (SealPaths, repoKeysDir, securityFilePath, sessionConversationPath, sessionDir,
   sessionLogPath, sessionRequestsPath, sshAgentsDir)
import Seal.Config.Security (loadSecurityConfig)
import Seal.Core.Backends (Backends (..))
import Seal.Core.MessageSource (MessageSource)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSessionId)
import Seal.Gateway.Broadcast
  (broadcastAgentDefsChanged, broadcastHarnessStatus, broadcastReplyDelivered)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Handles.Tab (TabKind (KindAi))
import Seal.Handles.Transcript (TwoFileHandle, withTwoFileTranscript, tfwSetSecretOps)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner, mkTmuxIdent)
import Seal.ISA.Dispatch
  (DispatchError (..), dispatch, recordSetupRepoResult,
   recordSkillLoadResult)
import Seal.ISA.Ops.Agent
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.ISA.Ops.File (fileReadOp, fileWriteOp, filePatchOp)
import Seal.ISA.Ops.Harness (harnessListOp, harnessStartOp, harnessStopOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Memory
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Registry (opcodeDescribeOp, opcodeListOp)
import Seal.ISA.Ops.Repo (setupRepoOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Skills
import Seal.ISA.Opcode (OpResult (..), localBackend, opName, orIsError)
import qualified Seal.ISA.Registry as ISA
import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Logging.Logger (SealLogger)
import Seal.Providers.Class
  (ContentBlock (..), Message (..), Role (..), SomeProvider)
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Session.Lock
  (ReplyRegistry, replyFanout, replySubscriberCount,
   SessionLocks, withSessionLock)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (autoBindRepoAgent, formatSessionId, saveSessionMeta, updateSessionRepoUrl)
import Seal.Session.Workdir (mkSessionExec, SessionExec (..), failClosedSessionExec)
import Seal.Security.Path (WorkspaceRoot)
import qualified Seal.Security.Policy as Policy
  (AutonomyLevel, SecurityPolicy (..), AllowList (..))
import Seal.Skills.Autoload (injectAutoloadSkill)
import Seal.Skills.Backend qualified as Skill
import Seal.Skills.Prompt (injectAvailableSkills)
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.Tools.Ssh.Agent (mkRealSshAgentHandle)
import qualified Seal.SourceControl.Clone as Clone
import Seal.Tools.Exec.Abort (SessionAbortRegistry, lookupOrCreateAbortFlag)
import Seal.Tools.Exec.Remote (mkRealRemoteRunner)
import Seal.Tools.Timeout (defaultToolTimeoutConfig)
import Seal.Tabs (TabsHandle, ensureTabForSession)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Util.StrictIO (decodeFileStrict, readFileTextStrict)
import Seal.Vault.Commands (VaultRuntime)
import Seal.Web.Fetch (webFetchOp, WebFetchConfig (..))
import Seal.Web.Search (webSearchOp, WebSearchConfig (..), parseProvider)

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
      , setupRepoOp cloneDeps wsRoot autonomy
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

-- ---------------------------------------------------------------------------
-- TurnDeps — the unified wiring record (design §5.1)
-- ---------------------------------------------------------------------------

-- | The unified wiring record — everything the turn body needs, constructed
-- once at startup and threaded into every turn. Replaces @SendDeps@ +
-- @ChannelDeps@ + the CLI's @where@-block closures.
--
-- @tdResolve@ is the injection seam for provider resolution: production
-- defaults to 'Seal.Channel.Cli.resolveSessionProvider'; tests inject a
-- fake. @tdSecurityConfig@ and @tdConfig@ are not fields here — the engine
-- re-reads them per turn via 'loadSecurityConfig' / 'loadRuntimeConfig'
-- (matching the three original paths' live-config-reload behaviour).
data TurnDeps = TurnDeps
  { tdPaths        :: SealPaths
  , tdVault        :: VaultRuntime
  , tdProvider     :: ProviderRuntime
  , tdResolve      :: SessionMeta -> IO (Either Text (SomeProvider, ModelId))
  , tdRepoReg      :: RepoRegistryHandle
  , tdAutonomy     :: Policy.AutonomyLevel
  , tdBroker       :: Maybe StreamBroker
  , tdHarnessReg   :: HarnessRegistry
  , tdTmuxRunner   :: TmuxRunner
  , tdHttpManager  :: Maybe Manager
  , tdApprovals    :: ApprovalCache
  , tdReplies      :: ReplyRegistry
  , tdLocks        :: SessionLocks
  , tdAbortReg     :: SessionAbortRegistry
  , tdTabsHandle   :: TabsHandle
  , tdLogger       :: SealLogger
  , tdIsRemote     :: Bool
  , tdBaseBackends :: Backends
  }

-- | The adapter-owned per-turn hooks (design §5.2 step table). These are the
-- ONLY medium-specific pieces the engine calls back into — the adapter
-- constructs them, the engine runs them at the right points.
--
-- * @taCaps@ — the 'ChannelCaps' for this turn (the only medium-specific
--   I/O seam).
-- * @taPreTurn@ — runs BEFORE the engine broadcasts "thinking" + acquires
--   the lock. Used by inbox-driven channels to 'replySubscribe' the channel
--   handle and 'replyFanoutMessage' the inbound text to other subscribed
--   channels (cross-channel mirroring). Web/CLI pass @pure ()@ (no
--   subscription, no mirror — the web frontend sees the message directly,
--   the CLI is the only surface).
-- * @taChannelLabel@ — the label stamped into the transcript's @channel@
--   field (e.g. @"web"@, @"cli"@, @smChannel@ for inbox-driven channels).
-- * @taOnStop@ — builds the 'aeOnStop' fan-out hook for a given 'SessionId'.
--   'Just' for surfaces that want cross-channel reply fan-out after the turn
--   (web + channels); 'Nothing' for the CLI (no chat channels subscribe to a
--   CLI session).
-- * @taOnUserMessage@ — builds the 'aeOnUserMessage' hook for a given
--   'SessionMeta' (e.g. the /bg 'broadcastTabs' refresh when
--   'shouldAutoTab' is false). 'Nothing' for normal turns.
-- * @taPostTurn@ — runs AFTER the engine's own post-turn broadcast +
--   auto-tab. Used by channels to refresh the @lists@ snapshot
--   ('broadcastTabs') when 'shouldAutoTab' is false (the /bg path). Web/CLI
--   pass @pure ()@.
-- * @taStartWiring@ — builds the 'AgentStartWiring' for this turn, given
--   the per-turn 'SessionMeta' (after 'autoBindRepoAgent' may have rebound
--   it). The per-surface builders (@webStartWiring@,
--   @channelStartWiring@, @cliStartWiring@) are passed in here; W4
--   collapses them into a single engine-owned @buildStartWiring@.
data TurnAdapter = TurnAdapter
  { taCaps          :: ChannelCaps
  , taPreTurn       :: SessionId -> SessionMeta -> Text -> IO ()
  , taChannelLabel  :: SessionMeta -> Text
  , taOnStop        :: SessionId -> Maybe (Text -> IO ())
  , taOnUserMessage :: SessionMeta -> Maybe (IO ())
  , taPostTurn      :: SessionId -> SessionMeta -> IO ()
  , taStartWiring   :: forall a. Backends -> SessionId -> Env
                    -> Either a RuntimeConfig -> Int -> SessionMeta -> AgentStartWiring
  }

-- | The outcome of a unified turn. 'toError' is 'Just' when the provider
-- could not be resolved or the turn threw a synchronous exception;
-- 'Nothing' on a clean run.
newtype TurnOutcome = TurnOutcome { toError :: Maybe Text }

-- | The single turn body (design §5.2). Replaces @plainTurn@ (Send.hs),
-- @runTurnOnSession@ (Loop.hs), and @withCliTurn@ (Cli.hs).
--
-- The engine owns (per the §5.2 step table): load meta, resolve provider,
-- broadcast "thinking", the per-session lock (OUTSIDE the transcript
-- bracket — serializes the entire turn), the transcript bracket,
-- mkSessionExec, workdir-aware backends, the system prompt, the ISA
-- registry, AgentEnv construction, runTurn, broadcast "idle" + new entries,
-- reply fan-out, and auto-tab. The adapter owns: 'replySubscribe' +
-- 'replyFanoutMessage' (@taPreTurn@, runs before the lock), the channel
-- label, the on-stop/on-user-message hooks, the start-wiring builder, and
-- the post-turn @lists@ refresh (@taPostTurn@).
--
-- Broadcast timing + exception safety: the "thinking" signal fires before
-- the lock; the "idle" signal + 'fanoutLastReply' run in a 'bracket' cleanup
-- so a turn killed mid-way (success, sync exception, async 'ThreadKilled')
-- cannot leave the tab stuck in "thinking". This matches the existing web +
-- channel paths; the CLI converges to the same guarantee.
runSessionTurn
  :: TurnDeps -> TurnAdapter -> SessionMeta -> Maybe MessageSource -> Text -> IO TurnOutcome
runSessionTurn td adapter meta mSrc t = do
  let paths = tdPaths td
      sid   = smId meta
      sessionDirPath = sessionDir paths sid
  eprov <- tdResolve td meta
  case eprov of
    Left err -> do
      -- Provider resolution failed: still run the adapter's pre-turn hook so
      -- the adapter isn't left in an inconsistent state (e.g. a channel
      -- handle that subscribed but never sees the turn complete). The
      -- engine's bracket is NOT entered (no "thinking" signal was sent).
      taPreTurn adapter sid meta t
      pure (TurnOutcome (Just err))
    Right (prov, model) -> do
      createDirectoryIfMissing True sessionDirPath
      saveSessionMeta paths meta
      -- [adapter] Pre-turn: subscribe + cross-channel mirror (inbox-driven
      -- channels); no-op for web/CLI.
      taPreTurn adapter sid meta t
      -- [engine] Broadcast "thinking" (before the lock, matches the existing
      -- web + channel paths).
      broadcastHarnessStatus (tdBroker td) sid "thinking"
      mErr <- bracket
        (pure ())
        (\_ -> do
          -- [engine] Guaranteed cleanup: signal idle + fan out the last
          -- assistant reply to subscribed chat channels (so a turn that
          -- dies mid-way still releases the tab + delivers any partial
          -- reply).
          broadcastHarnessStatus (tdBroker td) sid "idle"
          fanoutLastReply (tdReplies td) (tdBroker td) paths sid
          broadcastReplyDelivered (tdBroker td) sid)
        (\_ -> withSessionLock (tdLocks td) sid $
          withTwoFileTranscript sessionDirPath $ \tHandle ->
            runTurnBody td adapter meta mSrc t sid paths prov model tHandle)
      -- [engine] Auto-tab the session (idempotent; no-op if a tab already
      -- binds sid). Gated on shouldAutoTab so /bg sessions stay headless.
      when (shouldAutoTab meta) $
        ensureTabForSession (tdTabsHandle td) KindAi sid
      -- [adapter] Post-turn (e.g. /bg lists refresh).
      taPostTurn adapter sid meta
      pure (TurnOutcome mErr)

-- | The transcript-bracket body: build the per-turn execution environment
-- + AgentEnv, run 'runTurn', broadcast new entries, return 'Just' on error.
-- Extracted from 'runSessionTurn' to flatten the nesting (the bracket's
-- third arg is a single function call, not a deeply-nested do-block).
runTurnBody
  :: TurnDeps -> TurnAdapter -> SessionMeta -> Maybe MessageSource -> Text
  -> SessionId -> SealPaths
  -> SomeProvider -> ModelId -> TwoFileHandle
  -> IO (Maybe Text)
runTurnBody td adapter meta mSrc t sid paths prov model tHandle = do
  appEnv <- mkEnv (tdLogger td) defaultConfig
  eCfg <- loadRuntimeConfig (prConfigPath (tdProvider td))
  eSecCfg <- loadSecurityConfig (securityFilePath paths)
  let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
  cloneDeps <- mkCloneDepsTurn td
  exec <- either (const (const (const (const (pure (failClosedSessionExec cloneDeps) :: IO SessionExec))))) (mkSessionExec paths) eSecCfg sid cloneDeps mkRealRemoteRunner
  let wfs    = seWorkdirFs exec
      wsRoot = seWorkspaceRoot exec
      uioEnv = seUIOEnv exec
  -- [engine] autoBindRepoAgent (design §5.2 step 3b — currently web-only;
  -- unifying means channels/CLI gain it, the desired behavioural
  -- convergence). Runs over the same WorkdirFs the turn uses, so mode=local
  -- and mode=remote behave identically.
  autoBindRepoAgent wfs paths sid
  mMetaAfterBind <- loadSessionMeta paths sid
  let meta' = fromMaybe meta mMetaAfterBind
  -- [engine] Workdir-aware backends (per-turn merge; tdBaseBackends is the
  -- base, never mutated).
  workdirSkills <- Skill.workdirSkillBackend wfs
  workdirAgentDefs <- Def.workdirAgentDefBackend wfs
  let sessionSkills = Skill.tripleUnionSkillBackend workdirSkills (bSkills (tdBaseBackends td))
      sessionBackends = (tdBaseBackends td)
        { bAgentDefs = Def.unionAgentDefBackend workdirAgentDefs (bAgentDefs (tdBaseBackends td)) }
      agentDefBackend = bAgentDefs sessionBackends
      autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
      injectCatalog = either (const True) resolvedAvailableSkills eCfg
      parallel = either (const True) resolvedParallelToolGuidance eCfg
      toolUse = either (const True) resolvedToolUseEnforcement eCfg
      taskCompletion = either (const True) resolvedTaskCompletionGuidance eCfg
  -- [engine] System prompt (single resolver, honors smSystemOverride).
  mSystem <- resolveSystemPrompt agentDefBackend sessionSkills
              autoloadId injectCatalog parallel toolUse taskCompletion meta'
  turnAbortFlag <- lookupOrCreateAbortFlag (tdAbortReg td) sid
  let onDemand = either (const False) onDemandSchemas eCfg
      startWiring = taStartWiring adapter sessionBackends sid appEnv eCfg operatorCeiling meta'
      isaReg = buildSessionRegistry (tdVault td) cloneDeps sessionBackends wsRoot sid operatorCeiling
                 (tdAutonomy td) (either (const Nothing) rcWeb eCfg) startWiring
                 (tdHarnessReg td) (tdTmuxRunner td) (tdHttpManager td) (taCaps adapter) onDemand
  tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
  let onEntry = broadcastNewEntries (tdBroker td) paths sid (modelText model) (smCreatedAt meta')
      env = (mkSessionAgentEnv TurnEnv
              { teCaps          = taCaps adapter
              , teProvider      = prov
              , teProviderLabel = smProvider meta'
              , teModel         = model
              , teSession       = sid
              , teSystem        = mSystem
              , teRegistry      = isaReg
              , teTranscript    = tHandle
              , teUioEnv        = uioEnv
              , teDebugReqPath  = debugRequestsPath paths sid eCfg
              , teAutonomy      = tdAutonomy td
              , teApprovals     = tdApprovals td
              , teOnEntry       = onEntry
              , teOnDemand      = onDemand
              , teLogPath       = Just (sessionLogPath paths sid)
              , teMaxTurns      = either (const defaultMaxTurns) maxTurnsConfig eCfg
              , teOnUserMessage = taOnUserMessage adapter meta'
              , teChannel       = taChannelLabel adapter meta'
              , teOnStop        = taOnStop adapter sid
              , teAbortFlag     = turnAbortFlag
              , teToolTimeout   = either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg
              })
            { aeMessageSource = mSrc }
  eResult <- withExceptionLogging (tdLogger td) (Just (sessionLogPath paths sid)) "turn" $
    runApp appEnv (runTurn env t)
  case eResult of
    Left errMsg -> pure (Just errMsg)
    Right _     -> do
      -- [engine] Broadcast new transcript entries (one canonical post-turn
      -- sequence; the per-entry live broadcast already fired via aeOnEntry).
      broadcastNewEntries (tdBroker td) paths sid (modelText model) (smCreatedAt meta')
      pure Nothing

-- | Build 'Clone.CloneDeps' from a 'TurnDeps' (the in-scope vault runtime +
-- repo registry handle + paths). The ssh-agent is real (production:
-- 'mkRealSshAgentHandle'); the pinned host keys are compile-time-embedded.
mkCloneDepsTurn :: TurnDeps -> IO Clone.CloneDeps
mkCloneDepsTurn td = do
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir (tdPaths td))
  pure Clone.CloneDeps
    { Clone.cdVault = tdVault td
    , Clone.cdRepoReg = tdRepoReg td
    , Clone.cdSshAgent = mkRealSshAgentHandle
    , Clone.cdAgentRegistry = agentRegH
    , Clone.cdPinnedKnownHosts = pinnedGithubKnownHosts
    , Clone.cdKeyfilesDir = repoKeysDir (tdPaths td)
    , Clone.cdIsRemote = tdIsRemote td
    }

-- | Load a session's 'SessionMeta' by id from disk. Returns 'Nothing' when
-- the session directory or @session.json@ is missing or undecodable. The
-- engine uses this to re-read meta after 'autoBindRepoAgent' may have
-- rebound 'smAgent'.
loadSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)
loadSessionMeta paths sid = do
  let mp = sessionDir paths sid System.FilePath.</> "session.json"
  exists <- System.Directory.doesFileExist mp
  if not exists
    then pure Nothing
    else decodeFileStrict mp

-- | Should 'runSessionTurn' auto-tab the session after a turn? 'True' for
-- normal turns (every channel-originated session is visible in the sidebar).
-- 'False' for @/bg@ sessions, whose 'smChannel' is @"bg"@: a /bg turn runs
-- headless on a fresh session that must NOT surface in the web sidebar.
shouldAutoTab :: SessionMeta -> Bool
shouldAutoTab meta = smChannel meta /= "bg"

-- | Broadcast new transcript entries over the WS broker so the frontend
-- updates live without a page refresh. Reads the full transcript from disk
-- and broadcasts every entry — the frontend dedupes by id. 'Nothing' broker
-- (tests) is a no-op.
broadcastNewEntries
  :: Maybe StreamBroker -> SealPaths -> SessionId -> Text -> UTCTime -> IO ()
broadcastNewEntries mBroker paths sid model createdAt =
  case mBroker of
    Nothing -> pure ()
    Just broker -> do
      entries <- readTranscriptEntries paths model (showIso createdAt) sid
      mapM_ (broadcast broker . BeEntryRecorded sid) entries

-- | Fan out the last assistant reply to subscribed chat channels, and emit
-- a @reply-delivered@ signal when ≥1 chat channel received it (so the web
-- sidebar marks the tab Idle Read). No-op when the session has no
-- @conversation.json@ (CLI/tests).
fanoutLastReply :: ReplyRegistry -> Maybe StreamBroker -> SealPaths -> SessionId -> IO ()
fanoutLastReply replies mBroker paths sid = do
  let convPath = sessionConversationPath paths sid
  exists <- doesFileExist convPath
  if not exists
    then pure ()
    else do
      raw <- readFileTextStrict convPath
      let lines' = filter (not . T.null) (T.lines raw)
          msgs = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8) lines' :: [Message]
      for_ (lastAssistantText msgs) $ \reply -> do
        replyFanout replies sid reply
        count <- replySubscriberCount replies sid
        when (count > 0) (broadcastReplyDelivered mBroker sid)

-- | Extract the concatenated text content of the last 'Assistant' message.
lastAssistantText :: [Message] -> Maybe Text
lastAssistantText msgs =
  case reverse (filter (\m -> msgRole m == Assistant) msgs) of
    (m : _) -> case [t | CbText t <- msgContent m] of
      (t : _) -> Just t
      []      -> Nothing
    []      -> Nothing

-- | Extract the 'Text' from a 'ModelId'.
modelText :: ModelId -> Text
modelText (ModelId t) = t

-- | Resolve the optional debug-requests path from the loaded config. When
-- @debug_session_transcript@ is @true@, returns @Just (sessionRequestsPath paths sid)@;
-- otherwise @Nothing@. The debug file (@requests.jsonl@) records each
-- 'CompletionRequest' in full exactly as sent to the LLM.
debugRequestsPath :: SealPaths -> SessionId -> Either a RuntimeConfig -> Maybe FilePath
debugRequestsPath paths sid eCfg =
  case eCfg of
    Right cfg | Just True <- rcDebugSessionTranscript cfg ->
      Just (sessionRequestsPath paths sid)
    _ -> Nothing

-- | Load a session's channel label (e.g. @"telegram"@, @"web"@, @"cli"@)
-- from its @session.json@. Returns 'Nothing' when the session directory or
-- file is missing or undecodable. Used by 'callDispatcher' to stamp
-- channel origin into the SKILL_LOAD transcript entry.
loadChannelLabel :: SealPaths -> SessionId -> IO (Maybe Text)
loadChannelLabel paths sid = do
  mMeta <- loadSessionMeta paths sid
  pure (smChannel <$> mMeta)

-- | The unified call dispatcher (design §5.3 — replaces @webCallDispatcher@,
-- @channelCallDispatcher@, and the CLI's inline @callDispatcher@). Takes
-- explicit 'TurnDeps' + 'SessionId' + 'ChannelCaps' + the channel label (for
-- the transcript entry's @erMeta.channel@). Opens the transcript, builds the
-- session's ISA registry, dispatches the opcode via
-- 'Seal.ISA.Dispatch.dispatch' under 'Full' autonomy semantics (the operator
-- is the approver by typing @/call@), records the result, and broadcasts new
-- entries.
--
-- SETUP_REPO convergence (W4): the unified dispatcher runs
-- 'recordSetupRepoResult' + 'autoBindRepoAgent' + 'broadcastAgentDefsChanged'
-- for ALL surfaces (was web-only). This matches W3's autoBindRepoAgent
-- convergence — channels/CLI gain the auto-bind behavior.
callDispatcher
  :: TurnDeps -> ChannelCaps -> SessionId -> Text
  -> OpName -> Value -> IO (Either DispatchError OpResult)
callDispatcher td caps sid channelLabel callOpName val = do
  let paths = tdPaths td
      sessionDirPath = sessionDir paths sid
  createDirectoryIfMissing True sessionDirPath
  mMeta <- loadSessionMeta paths sid
  withTwoFileTranscript sessionDirPath $ \tHandle -> do
    appEnv <- mkEnv (tdLogger td) defaultConfig
    eCfg <- loadRuntimeConfig (prConfigPath (tdProvider td))
    eSecCfg <- loadSecurityConfig (securityFilePath paths)
    let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
    cloneDeps <- mkCloneDepsTurn td
    exec <- either (const (const (const (const (pure (failClosedSessionExec cloneDeps) :: IO SessionExec))))) (mkSessionExec paths) eSecCfg sid cloneDeps mkRealRemoteRunner
    let wfs = seWorkdirFs exec
        wsRoot = seWorkspaceRoot exec
        uioEnv = seUIOEnv exec
    workdirAgentDefs <- Def.workdirAgentDefBackend wfs
    let onDemand = either (const False) onDemandSchemas eCfg
        sessionBackends = (tdBaseBackends td)
          { bAgentDefs = Def.unionAgentDefBackend workdirAgentDefs (bAgentDefs (tdBaseBackends td)) }
        startWiring = buildStartWiring td sessionBackends sid appEnv eCfg operatorCeiling channelLabel
        isaReg = buildSessionRegistry (tdVault td) cloneDeps sessionBackends wsRoot sid operatorCeiling
                   (tdAutonomy td) (either (const Nothing) rcWeb eCfg) startWiring
                   (tdHarnessReg td) (tdTmuxRunner td) (tdHttpManager td) caps onDemand
    tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
    callAbortFlag <- lookupOrCreateAbortFlag (tdAbortReg td) sid
    res <- runApp appEnv (dispatch isaReg tHandle localBackend uioEnv (either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg) callAbortFlag callOpName val)
    case res of
      Right r -> do
        let opNm = case callOpName of OpName n -> n
        if opNm == "SETUP_REPO"
          then do
            recordSetupRepoResult tHandle callOpName val r (Just channelLabel)
            unless (orIsError r) $ do
              autoBindRepoAgent wfs paths sid
              -- Record the repo URL on the session meta so the frontend
              -- can display the repo ID in the sidebar.
              let mUrl = parseMaybe (withObject "SETUP_REPO" (.: "url")) val
              _ <- updateSessionRepoUrl paths sid mUrl
              pure ()
            broadcastAgentDefsChanged (tdBroker td)
          else recordSkillLoadResult tHandle callOpName val r (Just channelLabel)
        case mMeta of
          Just meta -> broadcastNewEntries (tdBroker td) paths sid (smModel meta) (smCreatedAt meta)
          Nothing   -> pure ()
      Left _  -> pure ()
    pure res

-- | Build the 'AgentStartWiring' for a unified turn (design §5.3 — replaces
-- @webStartWiring@, @channelStartWiring@, @cliStartWiring@). The
-- worker-builder is 'buildWorker' (the single implementation). The child
-- registry is the unified 'buildChildRegistry'.
buildStartWiring
  :: TurnDeps -> Backends -> SessionId
  -> Env -> Either a RuntimeConfig -> Int -> Text
  -> AgentStartWiring
buildStartWiring td sessionBackends parentSid appEnv eCfg operatorCeiling channel =
  AgentStartWiring
    { aswDefBackend = bAgentDefs sessionBackends
    , aswRuntime = bRuntime (tdBaseBackends td)
    , aswConfig = do
        eCfg' <- loadRuntimeConfig (prConfigPath (tdProvider td))
        pure (fromFileConfig (either (const Nothing) rcDelegation eCfg'))
    , aswPauseFlag = bSpawnPauseFlag (tdBaseBackends td)
    , aswParentActivity = Just (bParentActivity (tdBaseBackends td))
    , aswMintSession = mintSession parentSid
    , aswParentDepth = 0
    , aswWorker = buildWorker td parentSid appEnv eCfg operatorCeiling channel
    }

-- | Mint a fresh 'SessionId' for a forked agent instance (mirrors the three
-- @*MintSession@ helpers). Each start gets its own timestamped id.
mintSession :: SessionId -> IO SessionId
mintSession fallback = do
  now <- getCurrentTime
  case mkSessionId (formatSessionId now) of
    Right s  -> pure s
    Left _e  -> pure fallback

-- | The unified AGENT_START worker-builder (design §5.3 — replaces
-- @webMkWorker@, @channelMkWorker@, @cliMkWorker@). Resolves the def's
-- provider+model (falling back to the parent session meta when the def
-- fields are empty), opens a fresh two-file transcript under the parent
-- session's agents dir, builds a narrowed child ISA registry (the unified
-- 'buildChildRegistry'), and runs 'runTurn' with the goal as the first user
-- message.
buildWorker
  :: TurnDeps -> SessionId -> Env -> Either a RuntimeConfig -> Int -> Text
  -> AgentWorkerBuilder
buildWorker td parentSid appEnv eCfg operatorCeiling channel =
  mkDelegateWorker DelegationWorkerDeps
    { dwdPaths = tdPaths td
    , dwdParentSid = parentSid
    , dwdAppEnv = appEnv
    , dwdMkUIOEnv = \childSid -> do
        childCloneDeps <- mkCloneDepsTurn td
        eSecCfg <- loadSecurityConfig (securityFilePath (tdPaths td))
        seUIOEnv <$> either (const (const (const (const (pure (failClosedSessionExec childCloneDeps) :: IO SessionExec))))) (mkSessionExec (tdPaths td)) eSecCfg childSid childCloneDeps mkRealRemoteRunner
    , dwdAutonomy = tdAutonomy td
    , dwdApprovals = tdApprovals td
    , dwdOnDemand = either (const False) onDemandSchemas eCfg
    , dwdParentDepth = 0
    , dwdResolveProvider = resolveChild
    , dwdChildRegistry = buildChildRegistryAdapter td eCfg operatorCeiling
    , dwdChildSystemPrompt = childSystemPrompt td eCfg
    , dwdOnEntry = pure ()
    , dwdChannel = channel
    , dwdAbortFlag = lookupOrCreateAbortFlag (tdAbortReg td)
    , dwdToolTimeout = either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg
    }
  where
    resolveChild agentDef = do
      mParentMeta <- loadSessionMeta (tdPaths td) parentSid
      now <- getCurrentTime
      let parent = fromMaybe (fallbackMeta now) mParentMeta
          fallBackProvider = if T.null (adProvider agentDef) then smProvider parent else adProvider agentDef
          fallBackModel = case adModel agentDef of
            ModelId m | T.null m -> smModel parent
                      | otherwise -> m
      resolveDefProvider (tdProvider td) fallBackProvider (ModelId fallBackModel)
    fallbackMeta tnow = SessionMeta
      { smId = parentSid, smProvider = "ollama", smModel = "glm-5.2:cloud"
      , smChannel = "cli", smAgent = Nothing, smSystemOverride = Nothing, smAgentName = Nothing
      , smRepoUrl = Nothing
      , smDescription = Nothing
      , smCreatedAt = tnow, smLastActive = tnow }

-- | Build a narrowed child registry via the unified 'buildChildRegistry'.
buildChildRegistryAdapter
  :: TurnDeps -> Either a RuntimeConfig -> Int
  -> AgentDef -> SessionId -> ChannelCaps -> IO ISA.Registry
buildChildRegistryAdapter td eCfg operatorCeiling _def childSid childCaps = do
  childCloneDeps <- mkCloneDepsTurn td
  eSecCfg <- loadSecurityConfig (securityFilePath (tdPaths td))
  childExec <- either (const (const (const (const (pure (failClosedSessionExec childCloneDeps) :: IO SessionExec))))) (mkSessionExec (tdPaths td)) eSecCfg childSid childCloneDeps mkRealRemoteRunner
  let childWsRoot = seWorkspaceRoot childExec
      childWebCfg = either (const Nothing) rcWeb eCfg
  pure (buildChildRegistry (tdVault td) childCloneDeps (tdBaseBackends td)
          childWsRoot childSid operatorCeiling (tdAutonomy td)
          childWebCfg (tdHttpManager td) childCaps)

-- | Resolve the child agent's system prompt. Mirrors the three original
-- @*ChildSystemPrompt@ helpers: the def's 'adSystem' (with the task context
-- appended) + the static guidance + autoload skill + available-skills
-- catalog. Uses 'tdBaseBackends' (the child registry doesn't get
-- workdir-aware skills — matching the original implementations).
childSystemPrompt
  :: TurnDeps -> Either a RuntimeConfig
  -> AgentDef -> ChildTask -> IO (Maybe Text)
childSystemPrompt td eCfg agentDef task = do
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
  withAutoload <- injectAutoloadSkill (bSkills (tdBaseBackends td)) autoloadId withGuidance
  if injectCatalog
    then injectAvailableSkills (bSkills (tdBaseBackends td)) withAutoload
    else pure withAutoload
