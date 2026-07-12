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

import Control.Monad.IO.Class (liftIO)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
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
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.File (FileConfig, loadFileConfig, providerBaseUrl, retrievalMaxScanBytes,
                          defaultRetrievalMaxScanBytes, untrustedExecConfigFromFile,
                          fcDebugSessionTranscript)
import Seal.Config.Paths (SealPaths (..), agentSessionDir, sessionDir, sessionRequestsPath)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Git.Repo (ConfigRepo (..))
import Seal.Handles.Transcript
  ( TwoFileHandle, TwoFileHandle (..), withTwoFileTranscript )
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Opcode (localBackend)
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
  ( skillDeleteOp, skillListOp, skillReadOp, skillWriteOp )
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp )
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Code (codeExecOp)
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.Memory.Backend qualified as Mem
import Seal.Skills.Backend qualified as Skill
import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText)
import Seal.Agent.Runtime.Registry (AgentRuntime, newAgentRuntime)
import Seal.Providers.Class (SomeProvider (..))
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry (parseProvider, resolveProvider)
import Seal.Routing.Route qualified
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AllowList (..), AutonomyLevel (..))
import Seal.Tabs (TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs)
import Seal.Tabs.Types (TabSlashCommand (..), ForceMode (..), tabCount, tlTabs, Tab(..), TabRef (..))
import Seal.Handles.Tab (tabIndexToChar, TabKind (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), formatSessionId)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))

-- | The evolutionary-store backends + the in-process agent runtime, created
-- once at startup and shared between the command specs (which read them via
-- @\/skill@ \/ @\/agent@) and the ISA opcodes (which mutate them). The three
-- store backends are disk-backed (Markdown files under @config\/@); disk is
-- canonical and git is the versioning + audit layer. The agent runtime is an
-- in-process STM registry (lifecycle only — not persisted).
data Backends = Backends
  { bMemory    :: Mem.MemoryBackend
  , bSkills    :: Skill.SkillBackend
  , bAgentDefs :: Def.AgentDefBackend
  , bRuntime   :: AgentRuntime
  }

-- | Construct the disk-backed backends for the given config repo. The three
-- stores read their directories on demand (no startup materialization needed
-- — disk is canonical, so @\/skill list@ etc. just enumerate the dir).
newBackends :: FilePath -> ConfigRepo -> IO Backends
newBackends cfgRoot repo = do
  let skillsDir    = cfgRoot </> "skills"
      agentsDir    = cfgRoot </> "agents"
      memoryDir    = cfgRoot </> "memory"
  Backends
    <$> Mem.markdownMemoryBackend memoryDir repo
    <*> Skill.markdownSkillBackend skillsDir repo
    <*> Def.markdownAgentDefBackend agentsDir repo
    <*> newAgentRuntime

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
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model)

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
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model)

-- | Build the per-turn 'AgentEnv' for a session's selected provider+model.
mkSessionAgentEnv
  :: ChannelCaps -> SomeProvider -> Text -> ModelId -> SessionId
  -> Maybe Text -> ISA.Registry -> TwoFileHandle -> ExecBackend
  -> Maybe FilePath -> AgentEnv
mkSessionAgentEnv caps provider provLabel model sid system isaReg tHandle execBackend debugReqPath = AgentEnv
  { aeProvider   = provider
  , aeProviderLabel = provLabel
  , aeModel      = model
  , aeSystem     = system
  , aeRegistry   = isaReg
  , aeTranscript = tHandle
  , aeBackend    = localBackend
  , aeExecBackend = execBackend
    -- ^ The untrusted-execution backend (Local vs Remote SSH) from the
    -- runtime 'UntrustedExecConfig' (4b-T3). Trusted/Audited opcodes
    -- ignore it (the GADT 'Opcode' has no 'ExecBackend' field for them —
    -- type-level capability scoping, spec §4/§8).
  , aeCaps       = caps
  , aeSession    = sid
  , aeMaxTurns   = 12
  , aeMessageSource = Nothing
  , aeDebugRequestsPath = debugReqPath
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

-- | Run the Haskeline TUI loop.
--
-- History is persisted at @\<state\>\/history@; the agent transcript is written
-- under the session directory (@\<state\>\/sessions\/\<id\>\/transcript.jsonl@).
-- EOF (Ctrl-D) exits. The provider and model are resolved from the active
-- session on every turn so mid-session @\/model use@ changes take effect
-- immediately.
runCliTui
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime
  -> Registry -> PreprocessChain -> Backends -> TabsHandle -> IO ()
runCliTui paths rt pr sr registry chain backends tabsH = do
  active0 <- readIORef (srActive sr)
  let histFile       = spState paths </> "history"
      sessionDirPath = sessionDir paths (smId active0)
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
  -- The two-file transcript bracket wraps the whole loop so every turn shares
  -- one writer. The opcodes (and thus the ISA registry) close over `caps`, so
  -- they are built here where both `caps` and the transcript handle are in
  -- scope. Legacy sessions with an existing @transcript.jsonl@ are left
  -- untouched (the legacy read path handles them); new sessions get the
  -- @conversation.jsonl@ + @entries.jsonl@ pair. The evolutionary-store
  -- backends (memory/skills/agent-defs) are disk-backed Markdown files under
  -- @config\/@, shared with the @\/skill@ and @\/agent@ command specs (built in
  -- 'Seal.Tui.runTui' from the same 'Backends' record). Disk is canonical;
  -- git is the versioning + audit layer. No startup materialization is needed
  -- — the backends read their directories on demand.
  let memoryBackend    = bMemory backends
      skillBackend     = bSkills backends
      agentDefBackend  = bAgentDefs backends
      agentRuntime     = bRuntime backends
  withTwoFileTranscript sessionDirPath $ \tHandle -> do
    let sid0 = smId active0
        -- Mint a fresh SessionId for a forked agent instance. Each start
        -- gets its own timestamped id (a re-start of the same def does not
        -- append to a prior instance's transcript).
        mintAgentSession = do
          now <- getCurrentTime
          case mkSessionId (formatSessionId now) of
            Right s  -> pure s
            -- unreachable: formatSessionId only emits digits and dashes
            Left _e  -> pure sid0
        -- The AGENT_START worker-builder: resolve the def's provider+model,
        -- open a fresh two-file transcript under
        -- @\<parent-session\>\/agents\/\<child-id\>@, build a fresh AgentEnv
        -- bound to the new session + child transcript, and run a turn. The
        -- child gets its OWN TwoFileHandle so its conversation/entries stay
        -- separate from the parent's — mixing them would corrupt the two-file
        -- format's per-session erConvLen and envelope-delta fold.
        mkWorker def sid = do
          let childDir = agentSessionDir paths sid0 sid
          createDirectoryIfMissing True childDir
          -- Resolve the def's provider+model. Empty fields (e.g. a
          -- DirScheme agent with no AGENTS.md frontmatter) fall back to
          -- the active session's provider+model (symmetric). A
          -- non-empty-but-unknown provider still fails with the existing
          -- error.
          active <- readIORef (srActive sr)
          let fallBackProvider = if T.null (adProvider def) then smProvider active else adProvider def
              fallBackModel = case adModel def of
                ModelId m | T.null m -> smModel active
                          | otherwise -> m
          eprov <- resolveDefProvider pr fallBackProvider (ModelId fallBackModel)
          case eprov of
            Left err              -> ccSend caps ("agent start failed: " <> err)
            Right (prov, model)   ->
              withTwoFileTranscript childDir $ \childTHandle -> do
                let env = mkSessionAgentEnv caps prov fallBackProvider model sid (adSystem def) isaReg childTHandle execBackend
                      (debugRequestsPath paths sid eCfg)
                runApp appEnv (runTurn env "")
        isaReg = ISA.mkRegistry
          [ showHumanOp caps
          , askHumanOp caps
          , fileReadOp wsRoot operatorCeiling
          , secretGetOp rt
          , memoryWriteOp memoryBackend sid0
          , memoryRecallOp defaultPageParams memoryBackend
          , memoryDeleteOp memoryBackend
          , skillWriteOp skillBackend sid0
          , skillReadOp skillBackend
          , skillListOp skillBackend
          , skillDeleteOp skillBackend
          , agentDefWriteOp agentDefBackend sid0
          , agentDefReadOp agentDefBackend
          , agentDefListOp agentDefBackend
          , agentDefDeleteOp agentDefBackend
          , agentInstancesOp agentRuntime
          , agentStartOp agentDefBackend agentRuntime mintAgentSession mkWorker
          , agentStatusOp agentRuntime
          , agentStopOp agentRuntime
          , shellExecOp wsRoot cliSecurityPolicy execBackend
          , codeExecOp wsRoot cliSecurityPolicy codeAllowList execBackend
          , processManageOp wsRoot cliSecurityPolicy execBackend
          , fileWriteOp wsRoot operatorCeiling
          , filePatchOp wsRoot
          , searchFilesOp wsRoot cliSecurityPolicy operatorCeiling execBackend
          ]
    tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
    let plainHandler t = do
          meta  <- readIORef (srActive sr)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err            -> ccSend caps err
            Right (prov, model) -> do
              -- Resolve the bound agent's system prompt (re-read per turn;
              -- agent dirs are small). Nothing when no agent is bound or
              -- the def has no system prompt.
              mSystem <- case smAgent meta of
                Nothing -> pure Nothing
                Just aid -> maybe Nothing adSystem <$> Def.adbRead agentDefBackend aid
              handlePlain
                (mkSessionAgentEnv caps prov (smProvider meta) model (smId meta) mSystem isaReg tHandle execBackend
                   (debugRequestsPath paths (smId meta) eCfg))
                appEnv t
    runInputT hlSettings (loop caps plainHandler tabsH)
  where
    loop :: ChannelCaps -> (Text -> IO ()) -> TabsHandle -> InputT IO ()
    loop caps plainHandler th = do
      mLine <- getInputLine "> "
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          case Seal.Routing.Route.route (T.pack line) of
            Right (Seal.Routing.Route.Focus idx) -> liftIO (focusTabH th idx) >>= \r -> liftIO $ ccSend caps (case r of Left e -> "focus: " <> e; Right _ -> "focused tab " <> T.singleton (tabIndexToChar idx))
            Right (Seal.Routing.Route.Inject idx payload) -> liftIO $ do
              _ <- focusTabH th idx
              plainHandler payload
            Right (Seal.Routing.Route.TabCommand tsc) -> liftIO (handleTabCommand caps th tsc)
            Right (Seal.Routing.Route.SlashCommand _) -> do
              d <- liftIO $ ingest registry chain (RawInbound (T.pack line))
              liftIO $ interpretDisposition caps plainHandler d
            Right (Seal.Routing.Route.Plain t) -> liftIO $ plainHandler t
            Left (Seal.Routing.Route.ParseError e) -> liftIO $ ccSend caps e
          loop caps plainHandler th

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

-- | The CLI security policy: allow all commands, full autonomy. The TUI has
-- no web approval gate, so untrusted opcodes run without prompting (ACK
-- audit still recorded).
cliSecurityPolicy :: SecurityPolicy
cliSecurityPolicy = SecurityPolicy AllowAll Full

-- | The set of interpreters CODE_EXEC may run. Conservative default; can be
-- tightened via config in a later phase.
codeAllowList :: Set Text
codeAllowList = Set.fromList ["python3", "node", "bash", "sh"]
