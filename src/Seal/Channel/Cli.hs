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
  , mkSessionAgentEnv
  , debugRequestsPath
  , execBackendFromFile
  , Backends (..)
  , newBackends
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Either (fromRight)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Console.Haskeline
  ( InputT
  , Settings (..)
  , defaultSettings
  , getInputLine
  , getPassword
  , noCompletion
  , runInputT
  )
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))

import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec)
import Seal.Command.Call (callCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec
  ( CommandAction (..), Registry, mkRegistry, registrySpecs )
import Seal.Config.File (FileConfig, defaultFileConfig, loadFileConfig, providerBaseUrl, retrievalMaxScanBytes,
                          defaultRetrievalMaxScanBytes, untrustedExecConfigFromFile, onDemandSchemas,
                          fcDebugSessionTranscript, fcDelegation)
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionRequestsPath)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Git.Repo (ConfigRepo (..))
import Seal.Handles.Transcript
  ( TwoFileHandle, TwoFileHandle (..), withTwoFileTranscript )
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Opcode (localBackend, opName)
import Seal.ISA.Dispatch (dispatch)
#if !defined(REMOTE_ONLY_UNTRUSTED)
import Seal.Tools.Exec.Local (mkLocalExecHandle)
#endif
import Seal.Tools.Exec.Types (ExecBackend (..), TerminalBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Tools.Exec.Untrusted (selectExecBackend, UntrustedExecConfig (..))
import Seal.ISA.Ops.File (fileReadOp, fileWriteOp, filePatchOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Secret (secretGetOp)
import qualified Seal.ISA.Registry as ISA
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillLoadOp, skillWriteOp )
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp
  , agentInterruptOp, AgentStartWiring (..) )
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Registry (opcodeDescribeOp, opcodeListOp)
import Seal.Memory.Backend qualified as Mem
import Seal.Skills.Backend qualified as Skill
import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText)
import Seal.Agent.Runtime.Registry (AgentRuntime, newAgentRuntime)
import Seal.Agent.Runtime.Delegation
  ( DelegationConfig, defaultDelegationConfig, fromFileConfig
  , SpawnPauseFlag, newSpawnPauseFlag
  , ParentActivity, newParentActivity
  , ChildTask (..) )
import Seal.Agent.Runtime.Delegation.Worker
  ( mkDelegateWorker, filterBlocklisted, DelegationWorkerDeps (..) )
import Seal.Providers.Class (SomeProvider (..))
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry (parseProvider, resolveProvider)
import Seal.Routing.Route qualified
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AllowList (..), AutonomyLevel (..))
import Seal.Tabs (TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs)
import Seal.Tabs.Types (TabSlashCommand (..), ForceMode (..), tabCount, tlTabs, Tab(..), TabRef (..))
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, deliverNextAnswerAny, askHuman
  , newApprovalCache )
import Seal.Handles.Tab (tabIndexToChar, TabKind (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( SessionRuntime (..), defaultSessionSelection, formatSessionId
  , newSession, resolveDefaultAgent, saveSessionMeta )
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))

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
    <*> Skill.markdownSkillBackend skillsDir repo
    <*> Def.markdownAgentDefBackend agentsDir repo
    <*> pure rt
    <*> pure (pure defaultDelegationConfig)  -- overridden at call sites that have a config path
    <*> pure pauseFlag
    <*> pure parentAct

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
handlePlain :: AgentEnv -> Env -> Text -> IO ()
handlePlain agentEnv env t = runApp env (runTurn agentEnv t)

-- | Resolve the active session's provider from the vault, or explain why not.
-- Key bytes never surface: 'resolveProvider' returns an opaque 'SomeProvider'.
resolveSessionProvider
  :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveSessionProvider pr meta =
  case parseProvider (smProvider meta) of
    Nothing -> pure (Left ("unknown provider in session: " <> smProvider meta))
    Just kp -> do
      eCfg <- loadFileConfig (prConfigPath pr)
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
      eCfg <- loadFileConfig (prConfigPath pr)
      let baseUrl = fromMaybe defaultOllamaBaseUrl (either (const Nothing) (`providerBaseUrl` "ollama") eCfg)
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model (prCallCounter pr))

-- | Build the per-turn 'AgentEnv' for a session's selected provider+model.
mkSessionAgentEnv
  :: ChannelCaps -> SomeProvider -> Text -> ModelId -> SessionId
  -> Maybe Text -> ISA.Registry -> TwoFileHandle -> ExecBackend
  -> Maybe FilePath -> AutonomyLevel -> ApprovalCache -> IO () -> Bool -> AgentEnv
mkSessionAgentEnv caps provider provLabel model sid system isaReg tHandle execBackend debugReqPath autonomy approvals onEntry onDemand = AgentEnv
  { aeProvider   = provider
  , aeProviderLabel = provLabel
  , aeModel      = model
  , aeSystem     = system
  , aeRegistry   = isaReg
  , aeTranscript = tHandle
  , aeBackend    = localBackend
  , aeExecBackend = execBackend
  , aeCaps       = caps
  , aeSession    = sid
  , aeMaxTurns   = 12
  , aeMessageSource = Nothing
  , aeAutonomy   = autonomy
  , aeApprovals  = approvals
  , aeDebugRequestsPath = debugReqPath
  , aeOnEntry    = onEntry
  , aeOnDemandSchemas = onDemand
  }

-- | Resolve the optional debug-requests path from the loaded config. When
-- @debug_session_transcript@ is @true@, returns @Just (sessionRequestsPath paths sid)@;
-- otherwise @Nothing@. The debug file (@requests.jsonl@) records each
-- 'CompletionRequest' in full (including the complete message history) exactly
-- as sent to the LLM, so we can debug whether the two-file storage format is
-- correctly feeding the session history to the provider.
debugRequestsPath :: SealPaths -> SessionId -> Either a FileConfig -> Maybe FilePath
debugRequestsPath paths sid eCfg =
  case eCfg of
    Right cfg | Just True <- fcDebugSessionTranscript cfg ->
      Just (sessionRequestsPath paths sid)
    _ -> Nothing

-- | Resolve the on-demand-schemas flag from the loaded config. 'True' when
-- @on_demand_schemas@ is set in the config file; 'False' on load error or
-- when the key is absent (matching the default behavior).
onDemandFromCfg :: Either a FileConfig -> Bool
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
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime
  -> Registry -> PreprocessChain -> Backends -> TabsHandle -> AutonomyLevel
  -> AskReplyStore -> IO ()
runCliTui paths rt pr sr registry chain backends tabsH autonomy askReply = do
  approvals <- newApprovalCache
  active0 <- readIORef (srActive sr)
  let histFile       = spState paths </> "history"
      innerSettings  = (defaultSettings :: Settings IO) { complete = noCompletion }
      hlSettings     = innerSettings { historyFile = Just histFile }
      caps = ChannelCaps
        { ccSend         = putStrLn . T.unpack
        , ccPrompt       = \prompt ->
            runInputT innerSettings $ do
              mLine <- getInputLine (T.unpack prompt)
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
  wsRoot <- WorkspaceRoot <$> getCurrentDirectory
  appEnv <- mkEnv defaultConfig
  -- Resolve the operator-configured retrieval ceiling (the hard upper bound
  -- on bytes scanned per FILE_READ). Falls back to the 128 KiB default when
  -- the [retrieval] section is absent. Loaded once at startup; a config
  -- change takes effect on the next session.
  eCfg <- loadFileConfig (prConfigPath pr)
  let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
      -- Resolve the untrusted-execution backend (Phase 4 4b-T3). Absent
      -- section or mode=local → the local executor (wired to wsRoot);
      -- mode=remote → the SSH executor (if fully configured) or fail-closed
      -- (the dispatcher surfaces the structured error at call time). The
      -- remote executor itself lands in 4g; until then mode=remote without
      -- a real SSH executor falls back to the local executor's placeholder
      -- (the opcode fail-closes via 'ExecNotImplemented' if it actually
      -- needs the remote). 4b-T3 wires the LOCAL arm to the real
      -- 'mkLocalExecHandle wsRoot'; the remote arm is a placeholder until 4g.
      execBackend = either (const defaultExecBackend) (execBackendFromFile wsRoot) eCfg
      defaultExecBackend = EbLocal mkLocalExecHandlePlaceholder  -- fail-closed default; real local executor wired by execBackendFromFile
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
  let memoryBackend    = bMemory backends
      skillBackend     = bSkills backends
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
      cliResolveChildProvider def = do
        active <- readIORef (srActive sr)
        let fallBackProvider = if T.null (adProvider def) then smProvider active else adProvider def
            fallBackModel = case adModel def of
              ModelId m | T.null m -> smModel active
                        | otherwise -> m
        resolveDefProvider pr fallBackProvider (ModelId fallBackModel)
      cliChildSystemPrompt def task =
        let base = adSystem def
            ctx  = ctContext task
        in case (base, ctx) of
             (Just b, Just c) | not (T.null c) -> Just (b <> "\n\nCONTEXT:\n" <> c)
             (Just b, _)                       -> Just b
             (Nothing, Just c)                 -> Just ("CONTEXT:\n" <> c)
             (Nothing, Nothing)                -> Nothing
      cliChildRegistryBuilder _def childSid childCaps = do
        let childBaseOps =
              [ showHumanOp childCaps
              , askHumanOp childCaps
              , fileReadOp wsRoot operatorCeiling
              , secretGetOp rt
              , memoryWriteOp memoryBackend childSid
              , memoryRecallOp defaultPageParams memoryBackend
              , memoryDeleteOp memoryBackend
              , skillWriteOp skillBackend childSid
              , skillLoadOp skillBackend
              , skillListOp skillBackend
              , skillDeleteOp skillBackend
              , agentDefReadOp agentDefBackend
              , agentDefListOp agentDefBackend
              -- blocklisted: AGENT_DEF_WRITE, AGENT_DEF_DELETE,
              -- AGENT_INSTANCES, AGENT_START, AGENT_STATUS, AGENT_STOP,
              -- AGENT_INTERRUPT
              , shellExecOp wsRoot cliSecurityPolicy execBackend
              , binExecOp wsRoot cliSecurityPolicy binAllowList execBackend
              , processManageOp wsRoot cliSecurityPolicy execBackend
              , fileWriteOp wsRoot operatorCeiling
              , filePatchOp wsRoot
              , searchFilesOp wsRoot cliSecurityPolicy operatorCeiling execBackend
              ]
        pure (ISA.mkRegistry
                (filterBlocklisted childBaseOps opName
                   ++ if onDemand
                        then [opcodeDescribeOp (ISA.mkRegistry []), opcodeListOp (ISA.mkRegistry [])]
                        else []))
      -- Build the AGENT_START wiring for a given parent sid. The worker
      -- builder is fixed across turns (it closes over the per-turn
      -- helpers above); only the parent sid varies.
      cliStartWiring sid =
        let delegateDeps = DelegationWorkerDeps
              { dwdPaths = paths
              , dwdParentSid = sid
              , dwdAppEnv = appEnv
              , dwdExecBackend = execBackend
              , dwdAutonomy = autonomy
              , dwdApprovals = approvals
              , dwdOnDemand = onDemand
              , dwdParentDepth = 0
              , dwdResolveProvider = cliResolveChildProvider
              , dwdChildRegistry = cliChildRegistryBuilder
              , dwdChildSystemPrompt = cliChildSystemPrompt
              , dwdOnEntry = pure ()
              }
            mkWorker = mkDelegateWorker delegateDeps
            delegationCfg = do
              eCfg' <- loadFileConfig (prConfigPath pr)
              pure (fromFileConfig (either (const Nothing) fcDelegation eCfg'))
        in AgentStartWiring
          { aswDefBackend = agentDefBackend
          , aswRuntime = agentRuntime
          , aswConfig = delegationCfg
          , aswPauseFlag = bSpawnPauseFlag backends
          , aswParentActivity = Just (bParentActivity backends)
          , aswMintSession = mintAgentSession sid
          , aswParentDepth = 0
          , aswWorker = mkWorker
          }
      -- Build the session's ISA registry for a given sid + caps + startWiring.
      -- `caps'` is the ChannelCaps the showHuman/askHuman opcodes close over
      -- (the main turn uses `caps`; the /bg runner uses `bgCaps` so bg-spawned
      -- ASK_HUMAN routes through `askHuman` keyed to bgSid). The recursive
      -- describe/list ops close over the registry they belong to (let-knot).
      -- `tHandle` is NOT closed over here — the dispatcher threads it at call
      -- time.
      cliIsaReg sid startWiring caps' =
        let reg = ISA.mkRegistry
              (baseOps reg ++ if onDemand
                                then [opcodeDescribeOp reg, opcodeListOp reg]
                                else [])
            baseOps _reg =
              [ showHumanOp caps'
              , askHumanOp caps'
              , fileReadOp wsRoot operatorCeiling
              , secretGetOp rt
              , memoryWriteOp memoryBackend sid
              , memoryRecallOp defaultPageParams memoryBackend
              , memoryDeleteOp memoryBackend
              , skillWriteOp skillBackend sid
              , skillLoadOp skillBackend
              , skillListOp skillBackend
              , skillDeleteOp skillBackend
              , agentDefWriteOp agentDefBackend sid
              , agentDefReadOp agentDefBackend
              , agentDefListOp agentDefBackend
              , agentDefDeleteOp agentDefBackend
              , agentInstancesOp agentRuntime
              , agentStartOp startWiring
              , agentStatusOp agentRuntime
              , agentStopOp agentRuntime
              , agentInterruptOp agentRuntime
              , shellExecOp wsRoot cliSecurityPolicy execBackend
              , binExecOp wsRoot cliSecurityPolicy binAllowList execBackend
              , processManageOp wsRoot cliSecurityPolicy execBackend
              , fileWriteOp wsRoot operatorCeiling
              , filePatchOp wsRoot
              , searchFilesOp wsRoot cliSecurityPolicy operatorCeiling execBackend
              ]
        in reg
      -- Resolve the bound agent's system prompt (re-read per turn; agent
      -- dirs are small). Nothing when no agent is bound or the def has no
      -- system prompt.
      resolveSystem meta = case smAgent meta of
        Nothing  -> pure Nothing
        Just aid -> maybe Nothing adSystem <$> Def.adbRead agentDefBackend aid
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
          let startWiring = cliStartWiring sid
              isaReg = cliIsaReg sid startWiring caps
          tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err -> ccSend caps err
            Right (prov, model) -> do
              mSystem <- resolveSystem meta
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
        cfg <- fromRight defaultFileConfig <$> loadFileConfig (prConfigPath pr)
        (mAgent, mProv, mModel) <- resolveDefaultAgent agentDefBackend cfg
        let (cfgProv, cfgModel) = defaultSessionSelection cfg
            provider = fromMaybe cfgProv mProv
            model    = fromMaybe cfgModel mModel
        meta <- newSession paths provider model "bg" mAgent
        let bgSid = smId meta
            sessionDirPath' = sessionDir paths bgSid
        createDirectoryIfMissing True sessionDirPath'
        void (forkIO (withTwoFileTranscript sessionDirPath' $ \bgTHandle -> do
          let bgCaps = ChannelCaps
                { ccSend = ccSend caps
                , ccPrompt = \q -> do
                    outcome <- askHuman askReply bgSid q (\_qid -> ccSend caps q)
                    pure (fromRight "" outcome)
                , ccPromptSecret = ccPromptSecret caps
                }
              bgStartWiring = cliStartWiring bgSid
              bgIsaReg = cliIsaReg bgSid bgStartWiring bgCaps
          tfwSetSecretOps bgTHandle (ISA.secretOpNames bgIsaReg)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err -> ccSend caps ("bg failed: " <> err)
            Right (prov, mdl) -> do
              mSystem <- resolveSystem meta
              let env = mkSessionAgentEnv bgCaps prov (smProvider meta) mdl bgSid mSystem bgIsaReg bgTHandle execBackend
                    (debugRequestsPath paths bgSid eCfg) autonomy approvals (pure ()) onDemand
              runApp appEnv (runTurn env prompt)))
      registryWithBg = mkRegistry (registrySpecs registry <> [backgroundCommandSpec bgRunner, callCommandSpec callDispatcher, skillCommandSpec skillBackend callDispatcher])
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
          let startWiring = cliStartWiring sid
              isaReg = cliIsaReg sid startWiring caps
          tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
          runApp appEnv (dispatch isaReg tHandle localBackend execBackend callOpName val)
      plainHandler t = do
        meta <- readIORef (srActive sr)
        withCliTurn meta $ \sid tHandle isaReg prov model mSystem ->
          handlePlain
            (mkSessionAgentEnv caps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
               (debugRequestsPath paths sid eCfg) autonomy approvals (pure ()) onDemand)
            appEnv t
  runInputT hlSettings (loop caps plainHandler tabsH registryWithBg)
  where
    loop :: ChannelCaps -> (Text -> IO ()) -> TabsHandle -> Registry -> InputT IO ()
    loop caps plainHandler th reg = do
      mLine <- getInputLine "> "
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
          delivered <- liftIO $ deliverNextAnswerAny askReply (T.pack line)
          if delivered
            then loop caps plainHandler th reg
            else do
              case Seal.Routing.Route.route (T.pack line) of
                Right (Seal.Routing.Route.Focus idx) -> liftIO (focusTabH th idx) >>= \r -> liftIO $ ccSend caps (case r of Left e -> "focus: " <> e; Right _ -> "focused tab " <> T.singleton (tabIndexToChar idx))
                Right (Seal.Routing.Route.Inject idx payload) -> liftIO $ do
                  _ <- focusTabH th idx
                  plainHandler payload
                Right (Seal.Routing.Route.TabCommand tsc) -> liftIO (handleTabCommand caps th tsc)
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
              loop caps plainHandler th reg

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
    renderTab t =
      T.singleton (tabIndexToChar (tIndex t)) <> "  " <> T.pack (show (tKind t))
        <> maybe "" ("  " <>) (tLabel t)

-- | Resolve the untrusted-execution 'ExecBackend' from the 'FileConfig'.
-- Absent section / mode=local → 'EbLocal' (the real local executor wired
-- to the workspace root). mode=remote + remote fully configured → 'EbRemote'
-- (the SSH executor; the opcodes run remotely). mode=remote + remote
-- absent/incomplete → 'EbLocal' with a no-op handle so untrusted opcodes
-- fail-closed at call time (the 'ExecNotImplemented' error surfaces).
execBackendFromFile :: WorkspaceRoot -> FileConfig -> ExecBackend
execBackendFromFile _wsRoot cfg =
  case untrustedExecConfigFromFile cfg of
    Nothing -> defaultBackend
    Just uec ->
      case uecRemote uec of
        Nothing -> failClosedBackend  -- mode=remote, no remote configured
        Just sshCfg ->
          case selectExecBackend uec (TbSsh sshCfg) of
            Right (EbRemote s) -> EbRemote s
            _ -> failClosedBackend
  where
#if !defined(REMOTE_ONLY_UNTRUSTED)
    defaultBackend = EbLocal (mkLocalExecHandle _wsRoot)
#else
    defaultBackend = failClosedBackend  -- local executor absent; fail-closed
#endif
    failClosedBackend = EbLocal mkLocalExecHandlePlaceholder  -- no-op: opcodes fail-closed

-- | The CLI security policy: allow all commands. The autonomy level is
-- threaded separately via 'aeAutonomy' (the operator-selected @--yolo@ vs
-- default 'Supervised'); the policy here gates command-name allow-listing
-- (orthogonal to the human-confirmation gate).
cliSecurityPolicy :: SecurityPolicy
cliSecurityPolicy = SecurityPolicy AllowAll Supervised

-- | The set of binaries BIN_EXEC may run (optional allow-list). 'Nothing'
-- disables the allow-list (any binary, subject only to the autonomy policy).
binAllowList :: Maybe (Set Text)
binAllowList = Nothing
