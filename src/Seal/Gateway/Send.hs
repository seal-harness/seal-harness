{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The POST /api/sessions/:id/send handler: route the inbound text (Layer-1
-- terse grammar → slash registry vs plain agent turn), run it, and return the
-- outcome. Mirrors 'Seal.Channel.Cli.runCliTui's @plainHandler@ / @loop@
-- routing, but pulls the session by id (not the active-session ref) and uses a
-- collector-backed 'ChannelCaps' so slash-command output can be returned in
-- the response body. Plain turns write the assistant reply to the transcript
-- (the frontend polls the transcript, so the reply surfaces there); the HTTP
-- response just carries @kind: "assistant"@ so the optimistic spinner clears.
module Seal.Gateway.Send
  ( SendDeps (..)
  , SendOutcome (..)
  , sendOutcomeJson
  , handleSend
  , handleAnswerDelivery
  , handleAskCancel
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Monad (when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.IORef (readIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))

import Seal.Agent.Def.Backend (adbRead)
import Seal.Agent.Def.Types (adModel, adProvider, adSystem, AgentDef (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), execBackendFromFile, mkSessionAgentEnv, resolveDefProvider )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.File
  ( FileConfig, defaultRetrievalMaxScanBytes, loadFileConfig, retrievalMaxScanBytes
  , fcDebugSessionTranscript )
import Seal.Config.Paths (SealPaths, agentSessionDir, sessionDir, sessionRequestsPath)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Git.Repo (ConfigRepo)
import Seal.Handles.AskReply
  ( AskId, ApprovalCache, ApprovalScope (..), AskReply (..), AskReplyStore
  , askHuman, askIdText, cancelAsk, deliverAnswer, parseAskId
  , approvalScopeText )
import Seal.Handles.Transcript (withTwoFileTranscript, tfwSetSecretOps)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Ops.File (fileReadOp, fileWriteOp, filePatchOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillReadOp, skillWriteOp )
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp
  , AgentWorkerBuilder
  )
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Code (codeExecOp)
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Harness
  ( harnessListOp, harnessStartOp, harnessStopOp )
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner, mkTmuxIdent)
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Web.Fetch (webFetchOp, WebFetchConfig (..))
import Seal.Web.Search (webSearchOp, WebSearchConfig (..))
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class (SomeProvider)
import Seal.Routing.Route (ParseError (..), RoutingDecision (..), route)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Security.Path (WorkspaceRoot (..))
import qualified Seal.Security.Policy as Policy (AutonomyLevel (..), SecurityPolicy (..), AllowList (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), formatSessionId)
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))

-- | The dependencies the send handler needs (the agent-loop plumbing). Built
-- once in 'Seal.Command.Serve.runServeMain' and shared across requests. The
-- 'sdResolve' seam defaults to the real 'resolveSessionProvider' but tests
-- inject a fake to avoid the vault + live HTTP provider.
data SendDeps = SendDeps
  { sdPaths      :: SealPaths
  , sdVault      :: VaultRuntime
  , sdProvider   :: ProviderRuntime
  , sdSession    :: SessionRuntime
  , sdBackends   :: Backends
  , sdConfigRepo :: ConfigRepo
  , sdPreprocess :: PreprocessChain
  , sdRegistry   :: Registry
  , sdResolve    :: SessionMeta -> IO (Either Text (SomeProvider, ModelId))
    -- ^ Resolve a session's provider+model. Defaults to
    -- 'resolveSessionProvider' (vault-backed); tests inject a fake.
  , sdAutonomy   :: Policy.AutonomyLevel
    -- ^ The CLI autonomy level (--yolo / --locked / default Supervised).
    -- When 'Full', the approval gate bypasses prompting so untrusted
    -- opcodes run without asking (ACK audit still recorded).
  , sdBroker     :: Maybe StreamBroker
    -- ^ The WS broker for pushing live transcript entries to the frontend.
    -- 'Nothing' in tests; in production, set by 'runServeMain'. After each
    -- turn, new entries are read from disk and broadcast as 'BeEntryRecorded'
    -- so the frontend's WS stream updates without a page refresh.
  , sdHarnessRegistry :: HarnessRegistry
    -- ^ The live harness registry (shared with the gateway's
    -- @adHarnessRegistry@). Backs HARNESS_LIST/START/STOP.
  , sdTmuxRunner  :: TmuxRunner
    -- ^ The tmux runner (real via 'mkRealTmuxRunner' in production;
    -- fail-closes to 'HeTmuxMissing' when tmux is absent). Backs
    -- HARNESS_START/STOP.
  , sdHttpManager :: Maybe Manager
    -- ^ The shared HTTP manager (TLS-configured) for WEB_FETCH and
    -- WEB_SEARCH. 'Nothing' fail-closes those opcodes (they return a
    -- structured error). Set by 'runServeMain'; tests use 'Nothing'.
  , sdAskReply :: AskReplyStore
    -- ^ The shared, medium-agnostic ask/reply store backing ASK_HUMAN on
    -- async channels (web, Signal, Telegram). The agent loop blocks on the
    -- store until the medium delivers an answer (web: POST
    -- /api/sessions/:id/questions/:qid/answer; Signal/Telegram: the next
    -- inbound message). Set by 'runServeMain'; tests use a fresh store.
  , sdApprovals :: ApprovalCache
    -- ^ The approval cache for Untrusted opcodes under 'Supervised' autonomy.
    -- Records "for this session" and "always" approvals so subsequent calls
    -- to the same opcode skip the prompt. Shared across all sessions (the
    -- "always" scope is global; "for this session" is keyed by session id).
  }

-- | The outcome of a send request. The HTTP layer ('Seal.Gateway.API') turns
-- this into the JSON response body the frontend's @SendResult@ parses.
data SendOutcome
  = SendSlash Text      -- ^ transient slash-command output (no transcript entry)
  | SendAssistant       -- ^ plain turn; reply lands in the transcript
  | SendError Int Text  -- ^ HTTP status code + message (400/404/500)
  deriving stock (Eq, Show)

-- | Encode a 'SendOutcome' as the JSON the frontend's @SendResult@ parses.
-- Errors carry an @error@ field (the frontend logs them); success carries
-- @kind@ + @response@.
sendOutcomeJson :: SendOutcome -> (Int, Value)
sendOutcomeJson = \case
  SendSlash t    -> (200, object [ "kind" .= ("slash" :: Text), "response" .= t ])
  SendAssistant  -> (200, object [ "kind" .= ("assistant" :: Text), "response" .= ("" :: Text) ])
  SendError c m  -> (c, object [ "error" .= m ])

-- | Resolve the optional debug-requests path from the loaded config. When
-- @debug_session_transcript@ is @true@, returns @Just (sessionRequestsPath paths sid)@;
-- otherwise @Nothing@. The debug file records each 'CompletionRequest' in
-- full (including the complete message history) exactly as sent to the LLM.
debugPath :: SealPaths -> SessionId -> Either a FileConfig -> Maybe FilePath
debugPath paths sid eCfg =
  case eCfg of
    Right cfg | Just True <- fcDebugSessionTranscript cfg ->
      Just (sessionRequestsPath paths sid)
    _ -> Nothing

-- | Handle POST /api/sessions/:id/send. Loads the session meta by id, routes
-- the text, runs the turn, and returns the 'SendOutcome'. A missing session
-- -> 404; an unknown provider / vault error -> 400; an internal failure ->
-- 500 (logged to stderr).
handleSend :: SendDeps -> SessionId -> Text -> IO SendOutcome
handleSend deps sid rawText = do
  mMeta <- loadSessionMeta (sdPaths deps) sid
  case mMeta of
    Nothing -> pure (SendError 404 "session not found")
    Just meta -> case route rawText of
      Left (ParseError e) -> pure (SendSlash e)
      Right (Plain t) -> do
        er <- plainTurn deps meta t
        case er of
          Left err -> pure (SendError 400 err)
          Right () -> pure SendAssistant
      Right (SlashCommand _) -> runSlash deps meta rawText
      Right (TabCommand _)   -> pure (SendSlash "(tab commands are not supported over the web send endpoint)")
      Right (Focus _)        -> pure (SendSlash "(focus is a tab-level operation; use the sidebar)")
      Right (Inject _ _)    -> pure (SendSlash "(inject is a tab-level operation; use the sidebar)")

-- | Load a single session's 'SessionMeta' by id from disk. Returns Nothing
-- when the session directory or session.json is missing or undecodable.
loadSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)
loadSessionMeta paths sid = do
  let mp = sessionDir paths sid </> "session.json"
  exists <- doesFileExist mp
  if not exists
    then pure Nothing
    else do
      (A.decode <$> BL.readFile mp) :: IO (Maybe SessionMeta)

-- | Run a plain (non-slash) turn through the agent loop. Mirrors
-- 'Seal.Channel.Cli.runCliTui's @plainHandler@ but pulls the session by id
-- and uses the ask/reply-backed 'ChannelCaps' ('webAskCaps') so ASK_HUMAN
-- surfaces the question to the frontend and blocks until the human answers
-- (the web frontend reads replies + questions from the WS stream, not from
-- ccSend).
plainTurn :: SendDeps -> SessionMeta -> Text -> IO (Either Text ())
plainTurn deps meta t = do
  eprov <- sdResolve deps meta
  case eprov of
    Left err -> pure (Left err)
    Right (prov, model) -> do
      let paths = sdPaths deps
          sid = smId meta
          sessionDirPath = sessionDir paths sid
      createDirectoryIfMissing True sessionDirPath
      Right <$> withTwoFileTranscript sessionDirPath (\tHandle -> do
        wsroot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath (sdProvider deps))
        let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsroot) eCfg
            defaultExecBackend = EbLocal mkLocalExecHandlePlaceholder  -- fail-closed default
            agentDefBackend = bAgentDefs (sdBackends deps)
            caps = webAskCaps (sdBroker deps) (sdAskReply deps) sid
        mSystem <- case smAgent meta of
          Nothing -> pure Nothing
          Just aid -> maybe Nothing adSystem <$> adbRead agentDefBackend aid
        let mintSession = webMintSession sid
            isaReg = buildWebRegistry
              (sdVault deps) (sdBackends deps) wsroot sid operatorCeiling
              execBackend (sdAutonomy deps) mintSession
              (webMkWorker deps paths sid caps execBackend appEnv eCfg isaReg)
              (sdHarnessRegistry deps) (sdTmuxRunner deps) (sdHttpManager deps)
              caps
            env = mkSessionAgentEnv
              caps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
              (debugPath (sdPaths deps) sid eCfg) (sdAutonomy deps) (sdApprovals deps)
              (broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta))
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        result <- runApp appEnv (runTurn env t)
        broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta)
        pure result)

-- | Build the ISA registry for a web turn. Mirrors
-- 'Seal.Channels.Signal.Run.buildRegistry' but includes AGENT_START (the
-- worker-builder is closed over per-turn values by the caller in
-- 'plainTurn'). Includes the Untrusted execution opcodes (SHELL_EXEC,
-- CODE_EXEC, PROCESS_MANAGE, FILE_WRITE, FILE_PATCH, SEARCH_FILES) wired
-- to the per-session 'ExecBackend' and a 'SecurityPolicy' derived from
-- the CLI autonomy level. The fail-closed provider-pluggable opcodes
-- (WEB_SEARCH, WEB_FETCH, BROWSER_OPEN/CLICK/READ, IMAGE_GENERATE/
-- DESCRIBE, TEXT_TO_SPEECH) are registered with their default fail-closed
-- providers so they surface as available tools to the LLM and return a
-- structured error until a real provider is configured. The HARNESS_*
-- opcodes (LIST/START/STOP) are wired to the shared 'HarnessRegistry' +
-- 'TmuxRunner'; HARNESS_START uses a fixed tmux session/window (\"seal\" /
-- \"harness\") and 'HfGeneric' flavour — the 6b wiring that resolves
-- per-call session/window/flavour from the input is a later phase.
buildWebRegistry
  :: VaultRuntime -> Backends -> WorkspaceRoot -> SessionId -> Int
  -> ExecBackend -> Policy.AutonomyLevel
  -> IO SessionId            -- ^ mint a fresh SessionId for a forked agent
  -> AgentWorkerBuilder       -- ^ the AGENT_START worker (closes over per-turn tHandle/caps/execBackend)
  -> HarnessRegistry          -- ^ the live harness registry (shared with the gateway)
  -> TmuxRunner               -- ^ the tmux runner (real via mkRealTmuxRunner; fail-closes when tmux absent)
  -> Maybe Manager            -- ^ shared HTTP manager for WEB_FETCH / WEB_SEARCH (Nothing = fail-closed)
  -> ChannelCaps              -- ^ the per-turn caps (ASK_HUMAN/SHOW_HUMAN use these; built by 'webAskCaps')
  -> ISA.Registry
buildWebRegistry rt backends wsRoot sid operatorCeiling execBackend autonomy
                 mintSession mkWorker harnessReg tmuxRunner httpManager caps =
  ISA.mkRegistry
    [ showHumanOp caps
    , askHumanOp caps
    , secretGetOp rt
    , memoryWriteOp (bMemory backends) sid
    , memoryRecallOp defaultPageParams (bMemory backends)
    , memoryDeleteOp (bMemory backends)
    , skillWriteOp (bSkills backends) sid
    , skillReadOp (bSkills backends)
    , skillListOp (bSkills backends)
    , skillDeleteOp (bSkills backends)
    , agentDefWriteOp (bAgentDefs backends) sid
    , agentDefReadOp (bAgentDefs backends)
    , agentDefListOp (bAgentDefs backends)
    , agentDefDeleteOp (bAgentDefs backends)
    , agentInstancesOp (bRuntime backends)
    , agentStartOp (bAgentDefs backends) (bRuntime backends) mintSession mkWorker
    , agentStatusOp (bRuntime backends)
    , agentStopOp (bRuntime backends)
    , searchFilesOp wsRoot securityPolicy operatorCeiling execBackend
    , fileReadOp wsRoot operatorCeiling
    , fileWriteOp wsRoot operatorCeiling
    , filePatchOp wsRoot
    , shellExecOp wsRoot securityPolicy execBackend
    , codeExecOp wsRoot securityPolicy codeAllowList execBackend
    , processManageOp wsRoot securityPolicy execBackend
    , webFetchOp webFetchCfg
    , webSearchOp webSearchCfg
    , harnessListOp harnessReg
    , harnessStartOp harnessReg tmuxRunner harnessSession harnessWindow
        HfGeneric newHarnessId
    , harnessStopOp harnessReg tmuxRunner
    -- TODO browser, image, and tts ops
    -- , browserOpenOp noBrowserDriver
    -- , browserClickOp noBrowserDriver
    -- , browserReadOp noBrowserDriver
    -- , imageGenerateOp noImageProvider
    -- , imageDescribeOp noImageProvider
    -- , textToSpeechOp noTtsProvider
    ]
  where
    securityPolicy = Policy.SecurityPolicy Policy.AllowAll autonomy
    codeAllowList = Set.fromList ["python3", "node", "bash", "sh"]
    -- Fail-closed defaults for the provider-pluggable opcodes. These surface
    -- as available tools to the LLM; the opcodes return a structured error
    -- until a real provider is configured (operator-supplied via config in a
    -- follow-up). Empty allow-lists mean all domains are permitted at the
    -- gate; the fail-closed run path is what enforces the boundary today.
    webSearchCfg = WebSearchConfig
      { wscManager   = httpManager
      , wscEndpoint  = ""
      , wscAllowList = []
      , wscAuthKey   = Nothing
      }
    webFetchCfg = WebFetchConfig
      { wfcManager   = httpManager
      , wfcAllowList = []
      , wfcMaxBytes  = operatorCeiling
      , wfcAuthKey   = Nothing
      }
    -- Fixed tmux session/window idents for HARNESS_START. The 6b wiring that
    -- resolves per-call session/window/flavour from the opcode input is a
    -- later phase; for now every HARNESS_START spawns into the same \"seal\"
    -- session / \"harness\" window. 'mkTmuxIdent' is total on these literals
    -- (validated idents), so the 'either (error ...) id' is unreachable.
    harnessSession = either (error "unreachable: seal is a valid TmuxIdent") id (mkTmuxIdent "seal")
    harnessWindow  = either (error "unreachable: harness is a valid TmuxIdent") id (mkTmuxIdent "harness")

-- | Run a slash command. The output is collected via a 'ChannelCaps' whose
-- 'ccSend' appends to an MVar-backed list, then returned as the @response@.
-- 'ccPrompt' routes through the ask/reply store so ASK_HUMAN (e.g. from a
-- slash command that delegates to the agent) surfaces to the frontend.
runSlash :: SendDeps -> SessionMeta -> Text -> IO SendOutcome
runSlash deps meta fullLine = do
  outVar <- newMVar ([] :: [Text])
  let askCaps = webAskCaps (sdBroker deps) (sdAskReply deps) (smId meta)
      caps = askCaps { ccSend = \t' -> modifyMVar_ outVar (\acc -> pure (acc <> [t'])) }
  d <- ingest (sdRegistry deps) (sdPreprocess deps) (RawInbound fullLine)
  case d of
    DispatchAction (CommandAction act) -> do
      act caps
      chunks <- readMVar outVar
      pure (SendSlash (T.intercalate "\n" chunks))
    ShowText t -> pure (SendSlash t)
    Rejected t -> pure (SendError 400 t)
    PlainMessage t -> do
      er <- plainTurnWithCaps deps meta caps t
      case er of
        Left err -> pure (SendError 400 err)
        Right () -> do
          chunks <- readMVar outVar
          pure (SendSlash (T.intercalate "\n" chunks))

-- | The plain-turn helper for a slash-dispatched PlainMessage (when the
-- preprocess chain passes a leading-/ line through but the registry doesn't
-- claim it). Mirrors 'plainTurn' but takes the caller's caps.
plainTurnWithCaps :: SendDeps -> SessionMeta -> ChannelCaps -> Text -> IO (Either Text ())
plainTurnWithCaps deps meta caps t = do
  eprov <- sdResolve deps meta
  case eprov of
    Left err -> pure (Left err)
    Right (prov, model) -> do
      let paths = sdPaths deps
          sid = smId meta
          sessionDirPath = sessionDir paths sid
      createDirectoryIfMissing True sessionDirPath
      Right <$> withTwoFileTranscript sessionDirPath (\tHandle -> do
        wsRoot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath (sdProvider deps))
        let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsRoot) eCfg
            defaultExecBackend = EbLocal mkLocalExecHandlePlaceholder
            agentDefBackend = bAgentDefs (sdBackends deps)
        mSystem <- case smAgent meta of
          Nothing -> pure Nothing
          Just aid -> maybe Nothing adSystem <$> adbRead agentDefBackend aid
        let mintSession = webMintSession sid
            isaReg = buildWebRegistry
              (sdVault deps) (sdBackends deps) wsRoot sid operatorCeiling
              execBackend (sdAutonomy deps) mintSession
              (webMkWorker deps paths sid caps execBackend appEnv eCfg isaReg)
              (sdHarnessRegistry deps) (sdTmuxRunner deps) (sdHttpManager deps)
              caps
            env = mkSessionAgentEnv
              caps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
              (debugPath (sdPaths deps) sid eCfg) (sdAutonomy deps) (sdApprovals deps)
              (broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta))
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        result <- runApp appEnv (runTurn env t)
        broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta)
        pure result)

-- | Mint a fresh 'SessionId' for a forked agent instance (mirrors the CLI's
-- 'mintAgentSession'). Each start gets its own timestamped id.
webMintSession :: SessionId -> IO SessionId
webMintSession fallback = do
  now <- getCurrentTime
  case mkSessionId (formatSessionId now) of
    Right s  -> pure s
    -- unreachable: formatSessionId only emits digits and dashes
    Left _e  -> pure fallback

-- | The AGENT_START worker-builder for the web channel. Mirrors the CLI's
-- 'mkWorker': resolve the def's provider+model, open a fresh two-file
-- transcript under the parent session's agents dir, build a fresh 'AgentEnv'
-- bound to the child session + transcript, and run the turn loop. The child
-- shares the parent's 'isaReg' (same tool set) but gets its OWN 'TwoFileHandle'
-- so its conversation/entries stay separate (the two-file format's
-- 'erConvLen' and envelope-delta fold are per-session). Web 'ChannelCaps' are
-- no-op (replies surface via transcript poll), so provider-resolution errors
-- are swallowed here and surface only in the agent transcript.
webMkWorker
  :: SendDeps -> SealPaths -> SessionId -> ChannelCaps -> ExecBackend -> Env
  -> Either a FileConfig -> ISA.Registry -> AgentWorkerBuilder
webMkWorker deps paths parentSid caps execBackend appEnv eCfg isaReg def childSid = do
  let childDir = agentSessionDir paths parentSid childSid
  createDirectoryIfMissing True childDir
  -- Resolve the def's provider+model. Empty fields fall back to the parent
  -- session's provider+model (symmetric with the CLI). A non-empty-but-unknown
  -- provider fails; the error surfaces in the agent transcript (web caps are
  -- no-op so we can't ccSend it).
  active <- readIORef (srActive (sdSession deps))
  let fallBackProvider = if T.null (adProvider def) then smProvider active else adProvider def
      fallBackModel = case adModel def of
        ModelId m | T.null m -> smModel active
                  | otherwise -> m
  eChildProv <- resolveDefProvider (sdProvider deps) fallBackProvider (ModelId fallBackModel)
  case eChildProv of
    Left _err             -> pure ()  -- web caps are no-op; error logged via transcript
    Right (childProv, childModel) ->
      withTwoFileTranscript childDir $ \childTHandle -> do
        let childEnv = mkSessionAgentEnv
              caps childProv fallBackProvider childModel childSid
              (adSystem def) isaReg childTHandle execBackend
              (debugPath paths childSid eCfg) (sdAutonomy deps) (sdApprovals deps)
              (broadcastNewEntries (sdBroker deps) paths childSid (modelText childModel) (smCreatedAt active))
        runApp appEnv (runTurn childEnv "")

-- | Extract the 'Text' from a 'ModelId'.
modelText :: ModelId -> Text
modelText (ModelId t) = t

-- | Broadcast new transcript entries over the WS broker so the frontend
-- updates live without a page refresh. Reads the full transcript from disk
-- and broadcasts every entry — the frontend dedupes by id, so already-seen
-- entries are no-ops. 'Nothing' broker (tests) is a no-op.
broadcastNewEntries
  :: Maybe StreamBroker -> SealPaths -> SessionId -> Text -> UTCTime -> IO ()
broadcastNewEntries mBroker paths sid model createdAt =
  case mBroker of
    Nothing -> pure ()
    Just broker -> do
      entries <- readTranscriptEntries paths model (showIso createdAt) sid
      mapM_ (broadcast broker . BeEntryRecorded sid) entries

-- | Build the web 'ChannelCaps' for a per-turn 'AskReplyStore'. 'ccSend' is a
-- no-op (web replies surface via the transcript poll); 'ccPrompt' drives the
-- full ask/reply primitive: it mints a pending question (carrying the opcode
-- metadata when provided), broadcasts a 'BeAsk' event so the frontend renders
-- it, and blocks on the store until the human answers via POST
-- /api/sessions/:id/questions/:qid/answer (or the question is
-- cancelled/timed out). The returned 'Text' is the approval scope's wire form
-- (e.g. @"once"@, @for_session@, @always@, @rejected@) for the confirmation
-- gate, or the human's typed reply for @ASK_HUMAN@. 'ccPromptSecret' is
-- fail-closed.
webAskCaps
  :: Maybe StreamBroker -> AskReplyStore -> SessionId -> ChannelCaps
webAskCaps mBroker store sid = ChannelCaps
  { ccSend = \_ -> pure ()  -- web: replies surface via transcript poll
  , ccPrompt = \q -> do
      outcome <- askHuman store sid q (\qid ->
        case mBroker of
          Nothing -> pure ()
          Just broker ->
            broadcast broker (BeAsk sid (object
              [ "id" .= askIdText qid
              , "question" .= q
              ])))
      pure (case outcome of
        Left _  -> "rejected"
        Right t -> t)
  , ccPromptSecret = \_ -> pure ""  -- web: hidden prompts are a later phase
  }

-- | Notify the broker that a pending question was resolved (answered or
-- cancelled) so the frontend dismisses it. 'Nothing' broker (tests) is a
-- no-op.
broadcastAskResolved
  :: Maybe StreamBroker -> SessionId -> AskId -> Text -> IO ()
broadcastAskResolved mBroker sid qid resolution =
  case mBroker of
    Nothing -> pure ()
    Just broker ->
      broadcast broker (BeAskResolved sid (object
        [ "id" .= askIdText qid
        , "resolution" .= resolution
        ]))

-- | Deliver an answer to a pending question for a session. Returns 'True'
-- if the answer was accepted (the question was pending and not yet
-- answered). Also broadcasts 'BeAskResolved' so the frontend dismisses the
-- question. A 'Left' parse error is returned for a malformed ask id or
-- approval scope.
handleAnswerDelivery
  :: SendDeps -> SessionId -> Text -> ApprovalScope -> IO (Either Text Bool)
handleAnswerDelivery deps sid qidTxt scope =
  case parseAskId qidTxt of
    Left e -> pure (Left e)
    Right qid -> do
      let reply = AskReply scope (approvalScopeText scope)
      accepted <- deliverAnswer (sdAskReply deps) qid reply
      when accepted $
        broadcastAskResolved (sdBroker deps) sid qid "answered"
      pure (Right accepted)

-- | Cancel a pending question for a session. Returns 'True' if the question
-- was pending and is now cancelled. Broadcasts 'BeAskResolved' so the
-- frontend dismisses it.
handleAskCancel
  :: SendDeps -> SessionId -> Text -> IO (Either Text Bool)
handleAskCancel deps sid qidTxt =
  case parseAskId qidTxt of
    Left e -> pure (Left e)
    Right qid -> do
      cancelled <- cancelAsk (sdAskReply deps) qid
      when cancelled $
        broadcastAskResolved (sdBroker deps) sid qid "cancelled"
      pure (Right cancelled)
