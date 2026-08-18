{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Haskeline-backed CLI TUI channel. Plain (non-slash) input is routed through
-- the agent loop ('runTurn'); slash commands and rejections flow through the
-- existing command registry.
module Seal.Channel.Cli
  ( runCliTui
  , interpretDisposition
  , handlePlain
  , resolveSessionProvider
  , resolveDefProvider
  , TurnEnv (..)
  , mkSessionAgentEnv
  , debugRequestsPath
  , untrustedIOFromSecurity
  , Backends (..)
  , newBackends
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Either (fromRight)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Console.Haskeline
  ( InputT
  , Settings (..)
  , defaultSettings
  , getInputLine
  , getPassword
  , handleInterrupt
  , noCompletion
  , runInputT
  , withInterrupt
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec)
import Seal.Command.Call (callCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Stop (stopCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec
  ( CommandAction (..), Registry, mkRegistry, registrySpecs )
import Seal.Config.File (RuntimeConfig, defaultRuntimeConfig, loadRuntimeConfig, providerBaseUrl, retrievalMaxScanBytes,
                          defaultRetrievalMaxScanBytes, defaultMaxTurns, onDemandSchemas, maxTurnsConfig,
                          rcDebugSessionTranscript, rcDelegation, rcWeb, resolvedAutoloadSkill, resolvedAvailableSkills,
                          resolvedParallelToolGuidance, resolvedToolUseEnforcement, resolvedTaskCompletionGuidance,
                          toolTimeoutConfig)
import Seal.Config.Security (SecurityConfig, loadSecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Config.Paths (SealPaths (..), repoKeysDir, sessionDir, sessionRequestsPath, sessionLogPath, securityFilePath, sshAgentsDir)
import Seal.Core.Backends (Backends (..), newBackends)
import Seal.Core.TurnEngine (buildSessionRegistry, buildChildRegistry, resolveSystemPrompt)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSessionId)
import Seal.Handles.Transcript
  ( TwoFileHandle, TwoFileHandle (..), withTwoFileTranscript )
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Opcode (localBackend)
import qualified Seal.ISA.Registry as ISA
import Seal.ISA.Dispatch (dispatch, recordGitPushResult, recordSkillLoadResult)
#if !defined(REMOTE_ONLY_UNTRUSTED)
import Seal.Tools.Exec.UntrustedIO ( mkLocalUntrustedIO, mkRemoteUntrustedIO, mkRemoteUntrustedIOStub, UntrustedIO )
#else
import Seal.Tools.Exec.UntrustedIO ( mkRemoteUntrustedIO, mkRemoteUntrustedIOStub, UntrustedIO )
#endif
import Seal.Tools.Exec.Remote (mkRealRemoteRunner)
import Seal.Tools.Exec.Untrusted (UntrustedExecConfig (..))
import Seal.Tools.Exec.Abort (AbortFlag, SessionAbortRegistry, lookupOrCreateAbortFlag, newSessionAbortRegistry, setSessionAbort)
import Seal.Tools.Exec.UIO.Internal (UIOEnv)
import Seal.Tools.Timeout (ToolTimeoutConfig, defaultToolTimeoutConfig)
import Seal.ISA.Ops.Agent (AgentStartWiring (..))
import Seal.Skills.Autoload (injectAutoloadSkill)
import Seal.Skills.Backend qualified as Skill
import Seal.Skills.Prompt (injectAvailableSkills)
import Seal.Agent.PromptParts (injectStaticGuidance)
import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText)
import Seal.Agent.Runtime.Delegation
  ( fromFileConfig
  , ChildTask (..) )
import Seal.Agent.Runtime.Delegation.Worker
  ( mkDelegateWorker, DelegationWorkerDeps (..) )
import Seal.Providers.Class (SomeProvider (..))
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry (parseProvider, resolveProvider)
import Seal.Routing.Route qualified
import Seal.Session.Workdir (mkSessionExec, SessionExec (..), failClosedSessionExec)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.Tools.Ssh.Agent (mkRealSshAgentHandle)
import qualified Seal.SourceControl.Clone as Clone
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Tabs (TabsHandle, ensureTabForSession, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs)
import Seal.Tabs.Types (TabSlashCommand (..), ForceMode (..), tabCount, tlTabs, Tab(..), TabRef (..), lookupByRef)
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, deliverNextAnswerResolvedAny
  , askHumanWithOptions, formatQuestionWithOptions, newApprovalCache )
import Seal.Handles.Tab (tabIndexToChar, TabKind (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( SessionRuntime (..), defaultSessionSelection, formatSessionId
  , newSession, resolveDefaultAgent, saveSessionMeta )
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Logging.Logger (SealLogger)
import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Types.Env (Env, mkEnv, envLogger)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner)

-- | Map a 'Disposition' to its channel effect.
--
-- Extracted for testability: callers supply a 'ChannelCaps' and a handler for
-- plain (agent-bound) text; no Haskeline context is required. Routing plain
-- text through an injected handler keeps this function testable without a live
-- provider.
interpretDisposition :: ChannelCaps -> (Text -> IO ()) -> Disposition -> IO ()
interpretDisposition caps plainHandler = \case
  DispatchAction a -> runCommandAction a caps
  ShowText t       -> ccSend caps t
  PlainMessage t   -> plainHandler t
  Rejected msg     -> ccSend caps msg

-- | Drive one plain-text turn through the agent loop. The seam the wiring test
-- asserts against: a 'PlainMessage' becomes @runApp env (runTurn agentEnv t)@.
-- Catches exceptions (including 'TranscriptError' from a dead writer daemon)
-- so the TUI reports the error instead of crashing.
handlePlain :: AgentEnv -> Env -> Text -> IO ()
handlePlain agentEnv env t = do
  eResult <- withExceptionLogging (envLogger env) (aeLogPath agentEnv) "plain" $
    runApp env (runTurn agentEnv t)
  case eResult of
    Left errMsg -> ccSend (aeCaps agentEnv) ("turn failed: " <> errMsg)
    Right _     -> pure ()

-- | Resolve the active session's provider from the vault, or explain why not.
-- Key bytes never surface: 'resolveProvider' returns an opaque 'SomeProvider'.
resolveSessionProvider
  :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveSessionProvider pr meta =
  case parseProvider (smProvider meta) of
    Nothing -> pure (Left ("unknown provider in session: " <> smProvider meta))
    Just kp -> do
      eCfg <- loadRuntimeConfig (prConfigPath pr)
      let baseUrl = fromMaybe defaultOllamaBaseUrl (either (const Nothing) (`providerBaseUrl` "ollama") eCfg)
          model   = ModelId (smModel meta)
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model (prCallCounter pr))

-- | Resolve a provider+model from explicit labels (for AGENT_START, which
-- builds a fresh AgentEnv from a def rather than the active session).
resolveDefProvider :: ProviderRuntime -> Text -> ModelId -> IO (Either Text (SomeProvider, ModelId))
resolveDefProvider pr providerLabel model =
  case parseProvider providerLabel of
    Nothing -> pure (Left ("unknown provider in agent def: " <> providerLabel))
    Just kp -> do
      eCfg <- loadRuntimeConfig (prConfigPath pr)
      let baseUrl = fromMaybe defaultOllamaBaseUrl (either (const Nothing) (`providerBaseUrl` "ollama") eCfg)
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model (prCallCounter pr))

-- | A parameter object bundling the per-turn inputs to 'mkSessionAgentEnv'.
-- The 22 positional arguments are collected into one record so call sites
-- construct it with named-field syntax (no positional-counting mistakes)
-- and future additions are a one-field change. This is the W3 step-1
-- mechanical refactor: no behavior change, just argument bundling.
data TurnEnv = TurnEnv
  { teCaps          :: ChannelCaps
  , teProvider      :: SomeProvider
  , teProviderLabel :: Text
  , teModel         :: ModelId
  , teSession       :: SessionId
  , teSystem        :: Maybe Text
  , teRegistry      :: ISA.Registry
  , teTranscript    :: TwoFileHandle
  , teUioEnv        :: UIOEnv
  , teDebugReqPath  :: Maybe FilePath
  , teAutonomy      :: AutonomyLevel
  , teApprovals     :: ApprovalCache
  , teOnEntry       :: IO ()
  , teOnDemand      :: Bool
  , teLogPath       :: Maybe FilePath
  , teMaxTurns      :: Int
  , teOnUserMessage :: Maybe (IO ())
  , teChannel       :: Text
  , teOnStop        :: Maybe (Text -> IO ())
  , teAbortFlag     :: AbortFlag
  , teToolTimeout   :: ToolTimeoutConfig
  }

-- | Build the per-turn 'AgentEnv' from a 'TurnEnv'. Replaces the 22-argument
-- positional constructor. All fields come from the parameter object.
mkSessionAgentEnv :: TurnEnv -> AgentEnv
mkSessionAgentEnv te = AgentEnv
  { aeProvider   = teProvider te
  , aeProviderLabel = teProviderLabel te
  , aeModel      = teModel te
  , aeSystem     = teSystem te
  , aeRegistry   = teRegistry te
  , aeTranscript = teTranscript te
  , aeBackend    = localBackend
  , aeUIOEnv     = teUioEnv te
  , aeCaps       = teCaps te
  , aeSession    = teSession te
  , aeMaxTurns   = teMaxTurns te
  , aeChannel    = teChannel te
  , aeMessageSource = Nothing
  , aeAutonomy   = teAutonomy te
  , aeApprovals  = teApprovals te
  , aeDebugRequestsPath = teDebugReqPath te
  , aeOnEntry    = teOnEntry te
  , aeOnUserMessage = teOnUserMessage te
  , aeOnStop     = teOnStop te
  , aeOnDemandSchemas = teOnDemand te
  , aeLogPath    = teLogPath te
  , aeAbortFlag  = teAbortFlag te
  , aeToolTimeout = teToolTimeout te
  }

-- | Resolve the optional debug-requests path from the loaded config. When
-- @debug_session_transcript@ is @true@, returns @Just (sessionRequestsPath paths sid)@;
-- otherwise @Nothing@. The debug file (@requests.jsonl@) records each
-- 'CompletionRequest' in full (including the complete message history) exactly
-- as sent to the LLM, so we can debug whether the two-file storage format is
-- correctly feeding the session history to the provider.
debugRequestsPath :: SealPaths -> SessionId -> Either a RuntimeConfig -> Maybe FilePath
debugRequestsPath paths sid eCfg =
  case eCfg of
    Right cfg | Just True <- rcDebugSessionTranscript cfg ->
      Just (sessionRequestsPath paths sid)
    _ -> Nothing

-- | Resolve the on-demand-schemas flag from the loaded config. 'True' when
-- @on_demand_schemas@ is set in the config file; 'False' on load error or
-- when the key is absent (matching the default behavior).
onDemandFromCfg :: Either a RuntimeConfig -> Bool
onDemandFromCfg eCfg =
  case eCfg of
    Right cfg -> onDemandSchemas cfg
    _         -> False

-- | Run the Haskeline TUI loop.
--
-- History is persisted at @\<state\>\/history@; the agent transcript is written
-- under the session directory (@\<state\>\/sessions\/\<id\>\/transcript.jsonl@).
-- EOF (Ctrl-D) exits. The provider and model are resolved from the active
-- session on every turn so mid-session @\/model use@ changes take effect
-- immediately.
runCliTui
  :: SealPaths -> VaultRuntime -> RepoRegistryHandle -> ProviderRuntime -> SessionRuntime
  -> Registry -> PreprocessChain -> Backends -> TabsHandle -> AutonomyLevel
  -> AskReplyStore -> SealLogger -> HarnessRegistry -> TmuxRunner -> IO ()
runCliTui paths rt repoReg pr sr registry chain backends tabsH autonomy askReply logger harnessReg tmuxRunner = do
  approvals <- newApprovalCache
  abortReg <- newSessionAbortRegistry
  active0 <- readIORef (srActive sr)
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir paths)
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  eSecCfg <- loadSecurityConfig (securityFilePath paths)
  let isRemote = either (const False) (isJust . untrustedExecConfigFromSecurity) eSecCfg
      webCfg = either (const Nothing) rcWeb eCfg
      cloneDeps = Clone.CloneDeps
        { Clone.cdVault = rt
        , Clone.cdRepoReg = repoReg
        , Clone.cdSshAgent = mkRealSshAgentHandle
        , Clone.cdAgentRegistry = agentRegH
        , Clone.cdPinnedKnownHosts = pinnedGithubKnownHosts
        , Clone.cdKeyfilesDir = repoKeysDir paths
        , Clone.cdIsRemote = isRemote
        }
      histFile       = spState paths </> "history"
      innerSettings  = (defaultSettings :: Settings IO) { complete = noCompletion }
      hlSettings     = innerSettings { historyFile = Just histFile }
      caps = def
        { ccSend         = putStrLn . T.unpack
        , ccPrompt       = \(AskPrompt prompt opts) ->
            runInputT innerSettings $ do
              mLine <- getInputLine (T.unpack (formatQuestionWithOptions prompt opts))
              pure (maybe "" T.pack mLine)
        , ccPromptSecret = \prompt ->
            runInputT innerSettings $ do
              mPass <- getPassword (Just '*') (T.unpack prompt)
              pure (maybe "" T.pack mPass)
        }
  -- Startup diagnostic: show which provider+model the active session will use
  -- for plain-text turns (resolved from config at session creation), and the
  -- bound default agent (if any).
  let agentLine = case smAgent active0 of
        Nothing -> ""
        Just aid -> "  agent: " <> agentDefIdText aid
  ccSend caps ("session: " <> smProvider active0 <> " / " <> smModel active0 <> agentLine)
  appEnv <- mkEnv logger defaultConfig
  let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
      -- Per-session execution bundle: creates the workdir (local or remote)
      -- and constructs the UIOEnv + WorkdirFs + WorkspaceRoot. Handles both
      -- mode=local and mode=remote via mkSessionExec.
      mkSessionExecCli :: SessionId -> IO SessionExec
      mkSessionExecCli sid' = case eSecCfg of
        Left _err -> pure (failClosedSessionExec cloneDeps)
        Right sec -> mkSessionExec paths sec sid' cloneDeps mkRealRemoteRunner
  -- Per-turn transcript + ISA registry construction.
  --
  -- Previously the CLI opened one `withTwoFileTranscript` bracket at launch
  -- for `sid0` and built one `isaReg` at launch, baking `sid0` into
  -- `memoryWriteOp`/`skillWriteOp`/`agentDefWriteOp`. That was "correct by
  -- accident" while `srActive` never changed after launch — but it's a
  -- latent audit-trail integrity bug: any future change that swaps
  -- `srActive` (e.g. `/new`, or a CLI `/tab focus` that rebinds the active
  -- session) would silently write the new session's transcript + memory +
  -- skill + agent-def entries to the OLD session's dirs/keys.
  --
  -- The fix mirrors `runTurnOnSession` in `Seal.Channels.Loop`: rebuild
  -- `isaReg` and reopen the transcript **per turn** using `smId meta`
  -- read fresh from `srActive`. The per-turn helpers (`buildCliIsaReg`,
  -- `buildCliStartWiring`, `cliChildRegistryBuilder`, `cliResolveChildProvider`,
  -- `cliChildSystemPrompt`, `cliMintAgentSession`) close over the
  -- turn-invariant bits (wsRoot, eCfg, backends, caps, rt, paths, autonomy,
  -- approvals, appEnv, execBackend, askReply, pr, sr) and take `sid` (and
  -- `caps`/`tHandle` where needed) as parameters. The `withTwoFileTranscript`
  -- bracket moves inside `plainHandler` and `callDispatcher`. The `/bg`
  -- runner already opened its own per-invocation bracket, so it's unaffected
  -- (it mints its own bgSid and never touches `srActive`).
  --
  -- File-handle churn is acceptable: the inbox loop already pays this per
  -- turn. Legacy sessions with an existing `transcript.jsonl` are left
  -- untouched (the legacy read path handles them); new sessions get the
  -- `conversation.jsonl` + `entries.jsonl` pair. The evolutionary-store
  -- backends (memory/skills/agent-defs) are disk-backed Markdown files
  -- under `config/`, shared with the `/skill` and `/agent` command specs
  -- (built in `Seal.Tui.runTui` from the same `Backends` record). Disk is
  -- canonical; git is the versioning + audit layer. No startup
  -- materialization is needed — the backends read their directories on
  -- demand.
  let skillBackend     = bSkills backends
      agentDefBackend   = bAgentDefs backends
      agentRuntime      = bRuntime backends
      onDemand          = onDemandFromCfg eCfg
      -- Mint a fresh SessionId for a forked agent instance. Each start
      -- gets its own timestamped id (a re-start of the same def does not
      -- append to a prior instance's transcript).
      mintAgentSession sid = do
        now <- getCurrentTime
        case mkSessionId (formatSessionId now) of
          Right s  -> pure s
          -- unreachable: formatSessionId only emits digits and dashes
          Left _e  -> pure sid
      -- The AGENT_START worker-builder: build a fresh AgentEnv for the
      -- child (its own two-file transcript under
      -- @\<parent-session\>\/agents\/\<child-id\>@), run 'runTurn' with the
      -- goal as the first user message, and capture the final text
      -- response as the summary. The child's ISA registry is narrowed:
      -- the delegation blocklist strips AGENT_START/AGENT_DEF_*/lifecycle
      -- opcodes so the child can't recurse or mutate defs.
      --
      -- Provider resolution honors the [delegation] provider/model/base_url
      -- override when set, else falls back to the def's provider/model
      -- (which itself falls back to the active session's when empty).
      cliResolveChildProvider agentDef = do
        active <- readIORef (srActive sr)
        let fallBackProvider = if T.null (adProvider agentDef) then smProvider active else adProvider agentDef
            fallBackModel = case adModel agentDef of
              ModelId m | T.null m -> smModel active
                        | otherwise -> m
        resolveDefProvider pr fallBackProvider (ModelId fallBackModel)
      cliChildSystemPrompt agentDef task = do
        let base = adSystem agentDef
            ctx  = ctContext task
            basePrompt = case (base, ctx) of
              (Just b, Just c) | not (T.null c) -> Just (b <> "\n\nCONTEXT:\n" <> c)
              (Just b, _)                       -> Just b
              (Nothing, Just c)                 -> Just ("CONTEXT:\n" <> c)
              (Nothing, Nothing)                -> Nothing
        cfg <- fromRight defaultRuntimeConfig <$> loadRuntimeConfig (prConfigPath pr)
        let withGuidance = injectStaticGuidance (resolvedParallelToolGuidance cfg)
                                                 (resolvedToolUseEnforcement cfg)
                                                 (resolvedTaskCompletionGuidance cfg)
                                                 basePrompt
        withAutoload <- injectAutoloadSkill skillBackend (resolvedAutoloadSkill cfg) withGuidance
        if resolvedAvailableSkills cfg
          then injectAvailableSkills skillBackend withAutoload
          else pure withAutoload
      cliChildRegistryBuilder _def childSid childCaps = do
        childExec <- mkSessionExecCli childSid
        let childWsRoot = seWorkspaceRoot childExec
        pure (buildChildRegistry rt cloneDeps backends childWsRoot childSid
                operatorCeiling autonomy webCfg (Just (prManager pr)) childCaps)
      -- Build the AGENT_START wiring for a given parent sid. The worker
      -- builder is fixed across turns (it closes over the per-turn
      -- helpers above); only the parent sid varies.
      cliStartWiring sid sessionBackends =
        let delegateDeps = DelegationWorkerDeps
              { dwdPaths = paths
              , dwdParentSid = sid
              , dwdAppEnv = appEnv
              , dwdMkUIOEnv = (seUIOEnv <$>) . mkSessionExecCli
              , dwdAutonomy = autonomy
              , dwdApprovals = approvals
              , dwdOnDemand = onDemand
              , dwdParentDepth = 0
              , dwdResolveProvider = cliResolveChildProvider
              , dwdChildRegistry = cliChildRegistryBuilder
              , dwdChildSystemPrompt = cliChildSystemPrompt
              , dwdOnEntry = pure ()
              , dwdChannel = "cli"
              , dwdAbortFlag = lookupOrCreateAbortFlag abortReg
              , dwdToolTimeout = either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg
              }
            mkWorker = mkDelegateWorker delegateDeps
            delegationCfg = do
              eCfg' <- loadRuntimeConfig (prConfigPath pr)
              pure (fromFileConfig (either (const Nothing) rcDelegation eCfg'))
        in AgentStartWiring
          { aswDefBackend = bAgentDefs sessionBackends
          , aswRuntime = agentRuntime
          , aswConfig = delegationCfg
          , aswPauseFlag = bSpawnPauseFlag backends
          , aswParentActivity = Just (bParentActivity backends)
          , aswMintSession = mintAgentSession sid
          , aswParentDepth = 0
          , aswWorker = mkWorker
          }
      -- Build the session's ISA registry via the unified builder.
      cliIsaReg sid startWiring caps' wsRoot sessionBackends =
        buildSessionRegistry rt cloneDeps sessionBackends wsRoot sid
          operatorCeiling autonomy webCfg startWiring harnessReg tmuxRunner
          (Just (prManager pr)) caps' onDemand
      -- Resolve the bound agent's system prompt (re-read per turn; agent
      -- dirs are small). Nothing when no agent is bound or the def has no
      -- system prompt. The auto-loaded skill (default @seal-usage@, the
      -- fresh-workdir contract) is appended so the model is oriented to its
      -- per-session workspace from turn one. Disabled by setting
      -- @[skills] autoload = ""@ in @config.toml@. The
      -- @\<available_skills\>@ catalog is then appended so the model
      -- discovers and uses skills; disabled by
      -- @[skills] available_skills = false@. The catalog is built from the
      -- workdir-aware backend (repo-local skills discovered by SETUP_REPO
      -- ⊕ user ⊕ builtin, workdir-wins).
      resolveSystem meta wfs = do
        workdirAgentDefs <- Def.workdirAgentDefBackend wfs
        let sessionAgentDefs = Def.unionAgentDefBackend workdirAgentDefs agentDefBackend
        cfg <- fromRight defaultRuntimeConfig <$> loadRuntimeConfig (prConfigPath pr)
        workdirSkills <- Skill.workdirSkillBackend wfs
        let sessionSkills = Skill.tripleUnionSkillBackend workdirSkills skillBackend
        resolveSystemPrompt sessionAgentDefs sessionSkills
          (resolvedAutoloadSkill cfg) (resolvedAvailableSkills cfg)
          (resolvedParallelToolGuidance cfg) (resolvedToolUseEnforcement cfg)
          (resolvedTaskCompletionGuidance cfg) meta
      -- The per-turn body: open the transcript for `sid`, build the ISA
      -- registry, run a turn under a `withTwoFileTranscript` bracket.
      -- Mirrors `runTurnOnSession` from `Seal.Channels.Loop`. Used by
      -- `plainHandler` (for plain-text turns). `callDispatcher` uses
      -- `withCliTurnDispatch` below (it needs to return the structured
      -- `Either DispatchError OpResult`).
      withCliTurn meta act = do
        let sid = smId meta
            sessionDirPath' = sessionDir paths sid
        createDirectoryIfMissing True sessionDirPath'
        saveSessionMeta paths meta
        withTwoFileTranscript sessionDirPath' $ \tHandle -> do
          exec <- mkSessionExecCli sid
          let wfs = seWorkdirFs exec
              wsRoot = seWorkspaceRoot exec
          workdirAgentDefs <- Def.workdirAgentDefBackend wfs
          let sessionAgentDefs = Def.unionAgentDefBackend workdirAgentDefs agentDefBackend
              sessionBackends = backends { bAgentDefs = sessionAgentDefs }
              startWiring = cliStartWiring sid sessionBackends
              isaReg = cliIsaReg sid startWiring caps wsRoot sessionBackends
          tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err -> ccSend caps err
            Right (prov, model) -> do
              mSystem <- resolveSystem meta wfs
              act sid tHandle isaReg prov model mSystem
    -- The /bg runner: mint a fresh persisted session from the config
    -- defaults, build a ChannelCaps whose ccPrompt routes through askHuman
    -- (notify = print the question via ccSend, so the confirmation appears
    -- at the > prompt), and fork a turn against a bg-session-scoped ISA
    -- registry. The fork lets the CLI loop keep reading input; the loop's
    -- deliverNextAnswerAny routes the next line as the confirmation answer.
    -- The assistant reply is delivered via the bg caps' ccSend (println).
    -- No tab/cursor state is touched. The bg session's ISA registry is
    -- built per-invocation (its own sid, its own transcript bracket) —
    -- unchanged by the per-turn refactor.
      bgRunner = BgRunner $ \prompt -> do
        cfg <- fromRight defaultRuntimeConfig <$> loadRuntimeConfig (prConfigPath pr)
        (mAgent, mProv, mModel) <- resolveDefaultAgent agentDefBackend cfg
        let (cfgProv, cfgModel) = defaultSessionSelection cfg
            provider = fromMaybe cfgProv mProv
            model    = fromMaybe cfgModel mModel
        meta <- newSession paths provider model "bg" mAgent
        let bgSid = smId meta
            sessionDirPath' = sessionDir paths bgSid
        createDirectoryIfMissing True sessionDirPath'
        void (forkIO (withTwoFileTranscript sessionDirPath' $ \bgTHandle -> do
          let bgCaps = def
                { ccSend = ccSend caps
                , ccPrompt = \(AskPrompt q opts) -> do
                    outcome <- askHumanWithOptions askReply bgSid q opts
                                 (\_qid -> ccSend caps (formatQuestionWithOptions q opts))
                    pure (fromRight "" outcome)
                , ccPromptSecret = ccPromptSecret caps
                }
          bgExec <- mkSessionExecCli bgSid
          let bgWfs = seWorkdirFs bgExec
              bgWsRoot = seWorkspaceRoot bgExec
          bgWorkdirAgentDefs <- Def.workdirAgentDefBackend bgWfs
          let bgSessionBackends = backends { bAgentDefs = Def.unionAgentDefBackend bgWorkdirAgentDefs agentDefBackend }
              bgStartWiring = cliStartWiring bgSid bgSessionBackends
              bgIsaReg = cliIsaReg bgSid bgStartWiring bgCaps bgWsRoot bgSessionBackends
          tfwSetSecretOps bgTHandle (ISA.secretOpNames bgIsaReg)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err -> ccSend caps ("bg failed: " <> err)
            Right (prov, mdl) -> do
              mSystem <- resolveSystem meta bgWfs
              bgAbortFlag <- lookupOrCreateAbortFlag abortReg bgSid
              let env = mkSessionAgentEnv TurnEnv
                    { teCaps          = bgCaps
                    , teProvider      = prov
                    , teProviderLabel = smProvider meta
                    , teModel         = mdl
                    , teSession       = bgSid
                    , teSystem        = mSystem
                    , teRegistry      = bgIsaReg
                    , teTranscript    = bgTHandle
                    , teUioEnv        = seUIOEnv bgExec
                    , teDebugReqPath  = debugRequestsPath paths bgSid eCfg
                    , teAutonomy      = autonomy
                    , teApprovals     = approvals
                    , teOnEntry       = pure ()
                    , teOnDemand      = onDemand
                    , teLogPath       = Just (sessionLogPath paths bgSid)
                    , teMaxTurns      = either (const defaultMaxTurns) maxTurnsConfig eCfg
                    , teOnUserMessage = Nothing
                    , teChannel       = "cli"
                    , teOnStop        = Nothing
                    , teAbortFlag     = bgAbortFlag
                    , teToolTimeout   = either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg
                    }
              runApp appEnv (runTurn env prompt)))
      registryWithBg = mkRegistry (registrySpecs registry <> [backgroundCommandSpec bgRunner, callCommandSpec callDispatcher, skillCommandSpec skillBackend callDispatcher, stopCommandSpec abortReg sr])
      -- The /call dispatcher: dispatch an opcode against the active
      -- session's ISA registry + transcript under Full autonomy (the
      -- operator is the approver by typing /call). Returns the
      -- structured DispatchError/OpResult for the command to render.
      -- Rebuilt per invocation via `withCliTurn` so a `/new` swap of
      -- `srActive` flows the new sid's transcript + isaReg into the
      -- dispatch.
      callDispatcher callOpName val = do
        meta <- readIORef (srActive sr)
        let sid = smId meta
            sessionDirPath' = sessionDir paths sid
        createDirectoryIfMissing True sessionDirPath'
        saveSessionMeta paths meta
        withTwoFileTranscript sessionDirPath' $ \tHandle -> do
          exec <- mkSessionExecCli sid
          let wfs = seWorkdirFs exec
              wsRoot = seWorkspaceRoot exec
          callWorkdirAgentDefs <- Def.workdirAgentDefBackend wfs
          let callSessionBackends = backends { bAgentDefs = Def.unionAgentDefBackend callWorkdirAgentDefs agentDefBackend }
              startWiring = cliStartWiring sid callSessionBackends
              isaReg = cliIsaReg sid startWiring caps wsRoot callSessionBackends
          tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
          callAbortFlag <- lookupOrCreateAbortFlag abortReg sid
          res <- runApp appEnv (dispatch isaReg tHandle localBackend (seUIOEnv exec) (either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg) callAbortFlag callOpName val)
          case res of
            Right r -> do
              let opNm = case callOpName of OpName n -> n
              if opNm == "GIT_PUSH"
                then recordGitPushResult tHandle callOpName val r (Just "cli")
                else recordSkillLoadResult tHandle callOpName val r (Just "cli")
            Left _  -> pure ()
          pure res
      plainHandler t = do
        meta <- readIORef (srActive sr)
        withCliTurn meta $ \sid tHandle isaReg prov model mSystem -> do
          exec <- mkSessionExecCli sid
          turnAbortFlag <- lookupOrCreateAbortFlag abortReg sid
          handlePlain
            (mkSessionAgentEnv TurnEnv
               { teCaps          = caps
               , teProvider      = prov
               , teProviderLabel = smProvider meta
               , teModel         = model
               , teSession       = sid
               , teSystem        = mSystem
               , teRegistry      = isaReg
               , teTranscript    = tHandle
               , teUioEnv        = seUIOEnv exec
               , teDebugReqPath  = debugRequestsPath paths sid eCfg
               , teAutonomy      = autonomy
               , teApprovals     = approvals
               , teOnEntry       = pure ()
               , teOnDemand      = onDemand
               , teLogPath       = Just (sessionLogPath paths sid)
               , teMaxTurns      = either (const defaultMaxTurns) maxTurnsConfig eCfg
               , teOnUserMessage = Nothing
               , teChannel       = "cli"
               , teOnStop        = Nothing
               , teAbortFlag     = turnAbortFlag
               , teToolTimeout   = either (const defaultToolTimeoutConfig) toolTimeoutConfig eCfg
               })
            appEnv t
          -- W3 invariant 2: auto-tab the session after a CLI turn. Idempotent
          -- (no-op if a tab already binds sid). Uses KindAi (CLI tab kind).
          ensureTabForSession tabsH KindAi sid
  runInputT hlSettings (loop caps plainHandler tabsH registryWithBg abortReg)
  where
    loop :: ChannelCaps -> (Text -> IO ()) -> TabsHandle -> Registry -> SessionAbortRegistry -> InputT IO ()
    loop caps plainHandler th reg abortReg = do
      -- Ctrl-C handler: on interrupt, abort the active session's in-flight
      -- tool call (design Task 7 — CLI abort wiring). The interrupt is
      -- caught here (not propagated), so the loop continues; the next
      -- getInputLine re-prompts. The active session's abort flag is set
      -- via the SessionAbortRegistry.
      mLine <- withInterrupt
        (handleInterrupt
          (liftIO $ do
            active <- readIORef (srActive sr)
            setSessionAbort abortReg (smId active)
            ccSend caps "interrupted (in-flight tool call aborted)"
            pure Nothing
          )
          (getInputLine "> "))
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          -- A forked /bg turn may have registered a pending confirmation
          -- (askHuman) for its background session. Deliver the next input
          -- line as that answer before any normal routing; if no ask is
          -- pending, deliverNextAnswerAny returns False and the line is
          -- routed normally. This mirrors the per-session deliverNextAnswer
          -- the inbox-driven channels run at the top of their loop, but is
          -- session-agnostic because the CLI has one input stream serving
          -- the active session plus any /bg background sessions.
          (_resolved, delivered) <- liftIO $ deliverNextAnswerResolvedAny askReply (T.pack line)
          if delivered
            then loop caps plainHandler th reg abortReg
            else do
              case Seal.Routing.Route.route (T.pack line) of
                Right (Seal.Routing.Route.Focus idx) -> liftIO (focusTabH th idx) >>= \r -> liftIO $ ccSend caps (case r of Left e -> "focus: " <> e; Right _ -> "focused tab " <> T.singleton (tabIndexToChar idx))
                Right (Seal.Routing.Route.Inject idx payload) -> liftIO $ do
                  _ <- focusTabH th idx
                  plainHandler payload
                Right (Seal.Routing.Route.TabCommand tsc) -> liftIO (handleTabCommand caps th tsc)
                Right Seal.Routing.Route.CurrentTab -> liftIO $ do
                  active <- readIORef (srActive sr)
                  tl <- snapshotTabs th
                  case lookupByRef tl (BoundSession (smId active)) of
                    Just t  -> ccSend caps (renderTab t)
                    Nothing -> ccSend caps "no current tab"
                Right Seal.Routing.Route.NewSession -> do
                  -- /new is registered as a CommandSpec in the registry
                  -- (the CLI tracks "current" via srActive, not a cursor),
                  -- so re-route to the registry path below. Falling
                  -- through by re-parsing as SlashCommand.
                  d <- liftIO $ ingest reg chain (RawInbound (T.pack line))
                  liftIO $ interpretDisposition caps plainHandler d
                Right (Seal.Routing.Route.SlashCommand _) -> do
                  d <- liftIO $ ingest reg chain (RawInbound (T.pack line))
                  liftIO $ interpretDisposition caps plainHandler d
                Right (Seal.Routing.Route.Plain t) -> liftIO $ plainHandler t
                Left (Seal.Routing.Route.ParseError e) -> liftIO $ ccSend caps e
              loop caps plainHandler th reg abortReg

-- | Handle a parsed 'TabSlashCommand' by mutating the 'TabsHandle' and
-- replying via the channel caps. Pure-ish (the handle mutations are STM).
handleTabCommand :: ChannelCaps -> TabsHandle -> TabSlashCommand -> IO ()
handleTabCommand caps tabsH = \case
  TabListCmd -> do
    tl <- snapshotTabs tabsH
    if tabCount tl == 0
      then ccSend caps "no tabs"
      else mapM_ (ccSend caps . renderTab) (tlTabs tl)
  TabNewCmd _mKind -> do
    r <- insertTabH tabsH (BoundSession placeholderSid) KindAi Nothing
    case r of
      Left e  -> ccSend caps ("tab new failed: " <> e)
      Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " created")
  TabCloseCmd idx force -> do
    r <- removeTabH tabsH idx
    case r of
      Left e  -> ccSend caps (if force == Force then "force close: " <> e else "close failed: " <> e)
      Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar idx) <> " closed")
  TabFocusCmd idx -> do
    r <- focusTabH tabsH idx
    case r of
      Left e  -> ccSend caps ("focus failed: " <> e)
      Right _ -> ccSend caps ("focused tab " <> T.singleton (tabIndexToChar idx))
  TabResumeCmd sid -> do
    r <- insertTabH tabsH (BoundSession sid) KindAi Nothing
    case r of
      Left e  -> ccSend caps ("resume failed: " <> e)
      Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " resumed")
  TabRenameCmd idx name -> do
    r <- renameTabH tabsH idx name
    case r of
      Left e  -> ccSend caps ("rename failed: " <> e)
      Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar idx) <> " renamed to " <> name)
  where
    placeholderSid = case mkSessionId "tab-session" of
      Right s -> s
      Left _  -> error "placeholder session id"

-- | Render one tab as a single line: @<index>  <kind>  [label]@.
renderTab :: Tab -> Text
renderTab t =
  T.singleton (tabIndexToChar (tIndex t)) <> "  " <> T.pack (show (tKind t))
    <> maybe "" ("  " <>) (tLabel t)

-- | Resolve the untrusted-execution 'UntrustedIO' capability handle from the
-- 'SecurityConfig'. Absent section / mode=local → the local arm (real local
-- executor wired to the workspace root). mode=remote + remote fully
-- configured → the remote arm (the SSH executor; the opcodes run remotely
-- via 'mkRemoteUntrustedIO'). mode=remote + remote absent/incomplete → the
-- fail-closed stub so untrusted opcodes fail at call time (the
-- 'UeExec ExecNotImplemented' error surfaces).
untrustedIOFromSecurity :: WorkspaceRoot -> SecurityConfig -> UntrustedIO
untrustedIOFromSecurity wsRoot cfg =
  case untrustedExecConfigFromSecurity cfg of
    Nothing -> defaultHandle
    Just uec ->
      case uecRemote uec of
        Nothing -> mkRemoteUntrustedIOStub  -- mode=remote, no remote configured
        Just sshCfg ->
          -- The remote SSH arm. The RemoteRunner is the real
          -- 'mkRealRemoteRunner' (System.Process-backed); the SSH argv +
          -- host-key pinning are inherited from 'Seal.Tools.Exec.Remote'.
          mkRemoteUntrustedIO sshCfg mkRealRemoteRunner
  where
#if !defined(REMOTE_ONLY_UNTRUSTED)
    defaultHandle = mkLocalUntrustedIO wsRoot
#else
    defaultHandle = mkRemoteUntrustedIOStub  -- local executor absent; fail-closed
    _ = wsRoot  -- keep wsRoot referenced under the flag (unused when local absent)
#endif

-- The CLI security policy and bin allow-list are now centralized in
-- 'Seal.Core.TurnEngine.buildSessionRegistry' (the unified ISA registry
-- builder). The CLI no longer defines its own 'cliSecurityPolicy' or
-- 'binAllowList' — it passes 'autonomy' to the unified builder, which
-- constructs 'Policy.SecurityPolicy Policy.AllowAll autonomy' internally.
