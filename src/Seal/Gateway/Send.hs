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
  , webCallDispatcher
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Monad (when)
import Data.Foldable (for_)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

import Seal.Agent.Def.Backend (AgentDefBackend, adbRead)
import Seal.Agent.Def.Types (adModel, adProvider, adSystem, AgentDef (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), untrustedIOFromSecurity, mkSessionAgentEnv, resolveDefProvider )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Call (CallDispatcher)
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.File
  ( RuntimeConfig, defaultRetrievalMaxScanBytes, loadRuntimeConfig, retrievalMaxScanBytes
  , WebConfig (..), rcWeb
  , onDemandSchemas, rcDelegation, rcDebugSessionTranscript, resolvedAutoloadSkill )
import Seal.Config.Security (loadSecurityConfig)
import Seal.Config.Paths (SealPaths, securityFilePath, sessionConversationPath, sessionDir, sessionRequestsPath)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId, sessionIdText)
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
  ( skillDeleteOp, skillListOp, skillLoadOp, skillWriteOp )
import Seal.Skills.Autoload (injectAutoloadSkill)
import Seal.Skills.Backend (SkillBackend)
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp
  , agentInterruptOp, AgentStartWiring (..) )
import Seal.Agent.Runtime.Delegation
  ( fromFileConfig, ChildTask (..), AgentWorkerBuilder )
import Seal.Agent.Runtime.Delegation.Worker
  ( mkDelegateWorker, filterBlocklisted, DelegationWorkerDeps (..) )
import Seal.ISA.Opcode (localBackend, opName)
import Seal.ISA.Dispatch (dispatch, recordSkillLoadResult)
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Harness
  ( harnessListOp, harnessStartOp, harnessStopOp )
import Seal.ISA.Ops.Registry (opcodeDescribeOp, opcodeListOp)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner, mkTmuxIdent)
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Web.Fetch (webFetchOp, WebFetchConfig (..))
import Seal.Web.Search (webSearchOp, WebSearchConfig (..))
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..), SomeProvider)
import Seal.Routing.Route (ParseError (..), RoutingDecision (..), route)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.Workdir (ensureSessionWorkdir, mkSessionUntrustedIO)
import qualified Seal.Security.Policy as Policy (AutonomyLevel (..), SecurityPolicy (..), AllowList (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), formatSessionId)
import Seal.Session.Lock
  ( ReplyRegistry, replyFanout, SessionLocks, withSessionLock )
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub, UntrustedIO)
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
  , sdReplies :: ReplyRegistry
    -- ^ The per-session reply fan-out registry. After a web turn, the reply
    -- is fanned out to every 'ChannelHandle' subscribed to this session,
    -- so chat channels (Telegram, Signal) focused on the same tab receive
    -- the reply via 'chSend'. The web frontend already receives entries
    -- via the WS broker.
  , sdLocks :: SessionLocks
    -- ^ Per-session write locks. The web 'plainTurn' acquires the session's
    -- lock before 'withTwoFileTranscript' so a web send and a channel
    -- message on the same tab serialize rather than race.
  }

-- | The outcome of a send request. The HTTP layer ('Seal.Gateway.API') turns
-- this into the JSON response body the frontend's @SendResult@ parses.
data SendOutcome
  = SendSlash Text (Maybe SessionId)
    -- ^ transient slash-command output (no transcript entry). The optional
    -- 'SessionId' is set by slash commands that mint+focus a new session
    -- (e.g. @\/new@) so the frontend can navigate to it. 'Nothing' for
    -- ordinary slash commands.
  | SendAssistant       -- ^ plain turn; reply lands in the transcript
  | SendError Int Text  -- ^ HTTP status code + message (400/404/500)
  deriving stock (Eq, Show)

-- | Encode a 'SendOutcome' as the JSON the frontend's @SendResult@ parses.
-- Errors carry an @error@ field (the frontend logs them); success carries
-- @kind@ + @response@; @\/new@ also carries @session_id@ so the SPA can
-- navigate to the freshly-minted session.
sendOutcomeJson :: SendOutcome -> (Int, Value)
sendOutcomeJson = \case
  SendSlash t mSid ->
    (200, object
      [ "kind" .= ("slash" :: Text)
      , "response" .= t
      , "session_id" .= (sessionIdText <$> mSid)
      ])
  SendAssistant  -> (200, object [ "kind" .= ("assistant" :: Text), "response" .= ("" :: Text) ])
  SendError c m  -> (c, object [ "error" .= m ])

-- | Resolve the optional debug-requests path from the loaded config. When
-- @debug_session_transcript@ is @true@, returns @Just (sessionRequestsPath paths sid)@;
-- otherwise @Nothing@. The debug file records each 'CompletionRequest' in
-- full (including the complete message history) exactly as sent to the LLM.
debugPath :: SealPaths -> SessionId -> Either a RuntimeConfig -> Maybe FilePath
debugPath paths sid eCfg =
  case eCfg of
    Right cfg | Just True <- rcDebugSessionTranscript cfg ->
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
      Left (ParseError e) -> pure (SendSlash e Nothing)
      Right (Plain t) -> do
        er <- plainTurn deps meta t
        case er of
          Left err -> pure (SendError 400 err)
          Right () -> pure SendAssistant
      Right (SlashCommand _) -> runSlash deps meta rawText
      Right NewSession       -> runSlash deps meta rawText
      Right (TabCommand _)   -> pure (SendSlash "(tab commands are not supported over the web send endpoint)" Nothing)
      Right (Focus _)        -> pure (SendSlash "(focus is a tab-level operation; use the sidebar)" Nothing)
      Right (Inject _ _)    -> pure (SendSlash "(inject is a tab-level operation; use the sidebar)" Nothing)

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

-- | Resolve the system prompt for a web turn. An ad-hoc
-- 'smSystemOverride' (set via PUT /api/sessions/:id/prompt from the
-- Session setup screen's "Use a one-off agent file" upload) takes
-- precedence over the bound agent's 'adSystem'. Returns 'Nothing' when
-- neither is set. The auto-loaded skill (default @seal-usage@, the
-- fresh-workdir contract) is appended so the model is oriented to its
-- per-session workspace from turn one. Disabled by setting
-- @[skills] autoload = ""@ in @config.toml@.
resolveSystemPrompt
  :: AgentDefBackend
  -> SkillBackend
  -> Maybe Text
  -- ^ The resolved auto-load skill id ('Nothing' disables injection).
  -> SessionMeta
  -> IO (Maybe Text)
resolveSystemPrompt agentDefBackend skillBackend autoloadId meta = do
  base <- case smSystemOverride meta of
    Just t | not (T.null (T.strip t)) -> pure (Just t)
    _ -> case smAgent meta of
           Nothing  -> pure Nothing
           Just aid -> maybe Nothing adSystem <$> adbRead agentDefBackend aid
  injectAutoloadSkill skillBackend autoloadId base

-- | Run a plain (non-slash) turn through the agent loop. Mirrors
-- 'Seal.Channel.Cli.runCliTui's @plainHandler@ but pulls the session by id
-- and uses the ask/reply-backed 'ChannelCaps' ('webAskCaps') so ASK_HUMAN
-- surfaces the question to the frontend and blocks until the human answers
-- (the web frontend reads replies + questions from the WS stream, not from
-- ccSend).
--
-- After the turn, the reply is fanned out to any chat channels (Telegram,
-- Signal) subscribed to this session via the 'ReplyRegistry', so a web
-- send on a channel-origin tab also delivers the reply to the channel.
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
      turnResult <- withSessionLock (sdLocks deps) sid
           (withTwoFileTranscript sessionDirPath (\tHandle -> do
            appEnv <- mkEnv defaultConfig
            eCfg <- loadRuntimeConfig (prConfigPath (sdProvider deps))
            eSecCfg <- loadSecurityConfig (securityFilePath (sdPaths deps))
            let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
            untrustedIO <- either (const (const (pure mkRemoteUntrustedIOStub))) (mkSessionUntrustedIO paths) eSecCfg sid
            eWd <- ensureSessionWorkdir paths sid
            let wsroot = case eWd of
                  Right wd -> WorkspaceRoot wd
                  Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
                agentDefBackend = bAgentDefs (sdBackends deps)
                caps = webAskCaps (sdBroker deps) (sdAskReply deps) sid
            let autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
            mSystem <- resolveSystemPrompt agentDefBackend (bSkills (sdBackends deps)) autoloadId meta
            let onDemand = either (const False) onDemandSchemas eCfg
                startWiring = webStartWiring
                  deps paths sid caps untrustedIO appEnv eCfg
                  wsroot operatorCeiling
                isaReg = buildWebRegistry
                  (sdVault deps) (sdBackends deps) wsroot sid operatorCeiling
                  (sdAutonomy deps) (either (const Nothing) rcWeb eCfg) startWiring
                  (sdHarnessRegistry deps) (sdTmuxRunner deps) (sdHttpManager deps)
                  caps onDemand
                env = mkSessionAgentEnv
                  caps prov (smProvider meta) model sid mSystem isaReg tHandle untrustedIO
                  (debugPath (sdPaths deps) sid eCfg) (sdAutonomy deps) (sdApprovals deps)
                  (broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta))
                  onDemand
            tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
            result <- runApp appEnv (runTurn env t)
            broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta)
            pure result))
      -- Fan out the reply to chat channels subscribed to this session.
      -- The web frontend already received entries via the WS broker above;
      -- only chat channels need the explicit chSend.
      fanoutLastReply (sdReplies deps) paths sid
      pure (Right turnResult)

-- | Build the ISA registry for a web turn. Mirrors
-- 'Seal.Channels.Signal.Run.buildRegistry' but includes AGENT_START (the
-- worker-builder is closed over per-turn values by the caller in
-- 'plainTurn'). Includes the Untrusted execution opcodes (SHELL_EXEC,
-- CODE_EXEC, PROCESS_MANAGE, FILE_WRITE, FILE_PATCH, SEARCH_FILES) wired
-- to the per-session 'UntrustedIO' and a 'SecurityPolicy' derived from
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
  -> Policy.AutonomyLevel
  -> Maybe WebConfig
  -> AgentStartWiring
  -> HarnessRegistry
  -> TmuxRunner
  -> Maybe Manager
  -> ChannelCaps
  -> Bool                     -- ^ on-demand schemas
  -> ISA.Registry
buildWebRegistry rt backends wsRoot sid operatorCeiling autonomy webCfg
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
      , binExecOp wsRoot securityPolicy binAllowList
      , processManageOp wsRoot securityPolicy
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
    -- Recursive knot: the describe/list ops close over the registry they
    -- belong to, so the model can introspect every opcode including itself.
    introspectionOps = [ opcodeDescribeOp reg, opcodeListOp reg ]
    reg = ISA.mkRegistry (baseOps ++ if onDemand then introspectionOps else [])
    securityPolicy = Policy.SecurityPolicy Policy.AllowAll autonomy
    binAllowList = Nothing
    -- Web tool config resolved from the @[web]@ section of config.toml.
    -- Absent section → fail-closed (empty endpoint, all domains allowed,
    -- operatorCeiling for fetch bytes). SSRF protection is always enforced
    -- (in the opcode, via Seal.Web.UrlSafety), regardless of allow-list.
    webSearchCfg = WebSearchConfig
      { wscManager   = httpManager
      , wscEndpoint  = unwrapOpt wcSearchEndpoint webCfg ""
      , wscAllowList = unwrapOpt wcSearchAllowList webCfg []
      , wscAuthKey   = Nothing
      }
    webFetchCfg = WebFetchConfig
      { wfcManager   = httpManager
      , wfcAllowList = unwrapOpt wcFetchAllowList webCfg []
      , wfcMaxBytes  = unwrapOpt wcMaxFetchBytes webCfg operatorCeiling
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
--
-- For @\/new@ specifically: the command's 'ndRebind' swaps the active-session
-- ref ('sdSession') to the freshly-minted session. After the action runs, we
-- re-read the active session and, if its id differs from the one we entered
-- with, include the new id in the 'SendSlash' outcome so the frontend can
-- navigate to it. (This avoids widening the 'CommandAction' contract or
-- threading a per-call IORef through the registry.)
runSlash :: SendDeps -> SessionMeta -> Text -> IO SendOutcome
runSlash deps meta fullLine = do
  outVar <- newMVar ([] :: [Text])
  let askCaps = webAskCaps (sdBroker deps) (sdAskReply deps) (smId meta)
      caps = askCaps { ccSend = \t' -> modifyMVar_ outVar (\acc -> pure (acc <> [t'])) }
  -- Snapshot the active-session ref BEFORE the action runs. The web
  -- gateway is multi-session: @srActive@ is a process-global ref that
  -- points at whatever session the last @\/new@ (or session creation)
  -- left it at — which may be a DIFFERENT session than the one this
  -- request is operating on. Comparing the post-action @srActive@ to
  -- the request's sid would falsely report a change for every session
  -- that isn't currently "active", causing the frontend to navigate
  -- away on benign slash commands like @\/skill list@. Instead we
  -- compare before vs after: only a slash command that actually
  -- swapped @srActive@ during THIS call (e.g. @\/new@) reports a
  -- change.
  activeBefore <- readIORef (srActive (sdSession deps))
  d <- ingest (sdRegistry deps) (sdPreprocess deps) (RawInbound fullLine)
  case d of
    DispatchAction (CommandAction act) -> do
      act caps
      chunks <- readMVar outVar
      -- If the action swapped the active session (e.g. /new), thread the
      -- new sid into the outcome so the frontend navigates to it.
      mNewSid <- newSessionIdIfChangedFrom deps (smId activeBefore)
      pure (SendSlash (T.intercalate "\n" chunks) mNewSid)
    ShowText t -> pure (SendSlash t Nothing)
    Rejected t -> pure (SendError 400 t)
    PlainMessage t -> do
      er <- plainTurnWithCaps deps meta caps t
      case er of
        Left err -> pure (SendError 400 err)
        Right () -> do
          chunks <- readMVar outVar
          pure (SendSlash (T.intercalate "\n" chunks) Nothing)

-- | After a slash action runs, check whether the active session changed
-- DURING this call. Returns the new 'SessionId' if 'sdSession' now points
-- at a different session than @beforeSid@ (the snapshot taken before the
-- action ran); 'Nothing' otherwise. Used by @\/new@ to thread the
-- freshly-minted sid into the 'SendSlash' outcome. Comparing to the
-- pre-action snapshot (rather than the request's sid) avoids false
-- positives on multi-session web gateways where @srActive@ may already
-- point at a different session than the one this request targets.
newSessionIdIfChangedFrom :: SendDeps -> SessionId -> IO (Maybe SessionId)
newSessionIdIfChangedFrom deps beforeSid = do
  active <- readIORef (srActive (sdSession deps))
  if smId active == beforeSid
    then pure Nothing
    else pure (Just (smId active))

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
        appEnv <- mkEnv defaultConfig
        eCfg <- loadRuntimeConfig (prConfigPath (sdProvider deps))
        eSecCfg <- loadSecurityConfig (securityFilePath (sdPaths deps))
        let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
        untrustedIO <- either (const (const (pure mkRemoteUntrustedIOStub))) (mkSessionUntrustedIO paths) eSecCfg sid
        eWd <- ensureSessionWorkdir paths sid
        let wsRoot = case eWd of
              Right wd -> WorkspaceRoot wd
              Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
            agentDefBackend = bAgentDefs (sdBackends deps)
        let autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
        mSystem <- resolveSystemPrompt agentDefBackend (bSkills (sdBackends deps)) autoloadId meta
        let onDemand = either (const False) onDemandSchemas eCfg
            startWiring = webStartWiring
              deps paths sid caps untrustedIO appEnv eCfg
              wsRoot operatorCeiling
            isaReg = buildWebRegistry
              (sdVault deps) (sdBackends deps) wsRoot sid operatorCeiling
              (sdAutonomy deps) (either (const Nothing) rcWeb eCfg) startWiring
              (sdHarnessRegistry deps) (sdTmuxRunner deps) (sdHttpManager deps)
              caps onDemand
            env = mkSessionAgentEnv
              caps prov (smProvider meta) model sid mSystem isaReg tHandle untrustedIO
              (debugPath (sdPaths deps) sid eCfg) (sdAutonomy deps) (sdApprovals deps)
              (broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta))
              onDemand
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        result <- runApp appEnv (runTurn env t)
        broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta)
        pure result)

-- | Build a 'CallDispatcher' for the web channel. Resolves the active
-- session at call time, opens its transcript, builds the session's ISA
-- registry, and dispatches the opcode via 'Seal.ISA.Dispatch.dispatch'
-- under 'Full' autonomy semantics (the operator is the approver by
-- typing @/call@). Mirrors 'plainTurnWithCaps' but invokes 'dispatch'
-- directly instead of 'runTurn'. Returns the structured result for
-- 'Seal.Command.Call.renderOpResult' to render.
webCallDispatcher :: SendDeps -> CallDispatcher
webCallDispatcher deps callOpName val = do
  meta <- readIORef (srActive (sdSession deps))
  let sid = smId meta
      paths = sdPaths deps
      sessionDirPath = sessionDir paths sid
  createDirectoryIfMissing True sessionDirPath
  withTwoFileTranscript sessionDirPath $ \tHandle -> do
    appEnv <- mkEnv defaultConfig
    eCfg <- loadRuntimeConfig (prConfigPath (sdProvider deps))
    eSecCfg <- loadSecurityConfig (securityFilePath (sdPaths deps))
    let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
    untrustedIO <- either (const (const (pure mkRemoteUntrustedIOStub))) (mkSessionUntrustedIO paths) eSecCfg sid
    eWd <- ensureSessionWorkdir paths sid
    let wsRoot = case eWd of
          Right wd -> WorkspaceRoot wd
          Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
        caps = webAskCaps (sdBroker deps) (sdAskReply deps) sid
    let onDemand = either (const False) onDemandSchemas eCfg
        startWiring = webStartWiring
          deps paths sid caps untrustedIO appEnv eCfg
          wsRoot operatorCeiling
        isaReg = buildWebRegistry
              (sdVault deps) (sdBackends deps) wsRoot sid operatorCeiling
              (sdAutonomy deps) (either (const Nothing) rcWeb eCfg) startWiring
          (sdHarnessRegistry deps) (sdTmuxRunner deps) (sdHttpManager deps)
          caps onDemand
    tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
    res <- runApp appEnv (dispatch isaReg tHandle localBackend untrustedIO callOpName val)
    case res of
      Right r -> recordSkillLoadResult tHandle callOpName val r
      Left _  -> pure ()
    pure res

-- | Mint a fresh 'SessionId' for a forked agent instance (mirrors the CLI's
-- 'mintAgentSession'). Each start gets its own timestamped id.
webMintSession :: SessionId -> IO SessionId
webMintSession fallback = do
  now <- getCurrentTime
  case mkSessionId (formatSessionId now) of
    Right s  -> pure s
    -- unreachable: formatSessionId only emits digits and dashes
    Left _e  -> pure fallback

-- | Unwrap a nested 'Maybe' field from an optional 'WebConfig'. Returns
-- the default when the config section or the field is absent.
unwrapOpt :: (WebConfig -> Maybe a) -> Maybe WebConfig -> a -> a
unwrapOpt field webCfg def =
  case webCfg of
    Nothing   -> def
    Just cfg  -> fromMaybe def (field cfg)

-- | Build the 'AgentStartWiring' for a web turn. Closes over the per-turn
-- 'SendDeps' + parent session id + 'ChannelCaps' + 'UntrustedIO' + 'Env' +
-- loaded config + wsRoot + operatorCeiling.
webStartWiring
  :: SendDeps -> SealPaths -> SessionId -> ChannelCaps -> UntrustedIO -> Env
  -> Either a RuntimeConfig -> WorkspaceRoot -> Int -> AgentStartWiring
webStartWiring deps paths parentSid caps untrustedIO appEnv eCfg wsRoot operatorCeiling =
  AgentStartWiring
    { aswDefBackend = bAgentDefs (sdBackends deps)
    , aswRuntime = bRuntime (sdBackends deps)
    , aswConfig = do
        eCfg' <- loadRuntimeConfig (prConfigPath (sdProvider deps))
        pure (fromFileConfig (either (const Nothing) rcDelegation eCfg'))
    , aswPauseFlag = bSpawnPauseFlag (sdBackends deps)
    , aswParentActivity = Just (bParentActivity (sdBackends deps))
    , aswMintSession = webMintSession parentSid
    , aswParentDepth = 0
    , aswWorker = webMkWorker deps paths parentSid caps untrustedIO appEnv eCfg wsRoot operatorCeiling
    }

-- | The AGENT_START worker-builder for the web channel. Mirrors the CLI's
-- worker: resolve the def's provider+model (falling back to the parent
-- session meta when the def fields are empty), open a fresh two-file
-- transcript under the parent session's agents dir, build a narrowed child
-- ISA registry (blocklist strips AGENT_START/AGENT_DEF_*/lifecycle opcodes),
-- and run 'runTurn' with the goal as the first user message. The final text
-- response is captured via a 'ChannelCaps' whose 'ccSend' writes to an
-- IORef; the worker reads it after the run and returns it as the summary.
webMkWorker
  :: SendDeps -> SealPaths -> SessionId -> ChannelCaps -> UntrustedIO -> Env
  -> Either a RuntimeConfig -> WorkspaceRoot -> Int
  -> AgentWorkerBuilder
webMkWorker deps paths parentSid _caps _untrustedIO appEnv eCfg _wsRoot operatorCeiling =
  mkDelegateWorker DelegationWorkerDeps
    { dwdPaths = paths
    , dwdParentSid = parentSid
    , dwdAppEnv = appEnv
    , dwdMkUntrustedIO = \childSid -> do
        eChildWd <- ensureSessionWorkdir paths childSid
        let childWsRoot = case eChildWd of
              Right wd -> WorkspaceRoot wd
              Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
        eSecCfg <- loadSecurityConfig (securityFilePath paths)
        pure (either (const mkRemoteUntrustedIOStub) (untrustedIOFromSecurity childWsRoot) eSecCfg)
    , dwdAutonomy = sdAutonomy deps
    , dwdApprovals = sdApprovals deps
    , dwdOnDemand = either (const False) onDemandSchemas eCfg
    , dwdParentDepth = 0
    , dwdResolveProvider = resolveChild
    , dwdChildRegistry = buildChildRegistry
    , dwdChildSystemPrompt = childSystemPrompt
    , dwdOnEntry = pure ()  -- web child onEntry: no live broadcast (would need the broker + child sid)
    }
  where
    resolveChild def = do
      active <- readIORef (srActive (sdSession deps))
      let fallBackProvider = if T.null (adProvider def) then smProvider active else adProvider def
          fallBackModel = case adModel def of
            ModelId m | T.null m -> smModel active
                      | otherwise -> m
      resolveDefProvider (sdProvider deps) fallBackProvider (ModelId fallBackModel)
    childSystemPrompt def task = do
      let base = adSystem def
          ctx  = ctContext task
          basePrompt = case (base, ctx) of
            (Just b, Just c) | not (T.null c) -> Just (b <> "\n\nCONTEXT:\n" <> c)
            (Just b, _)                       -> Just b
            (Nothing, Just c)                 -> Just ("CONTEXT:\n" <> c)
            (Nothing, Nothing)                -> Nothing
      let autoloadId = either (const Nothing) resolvedAutoloadSkill eCfg
      injectAutoloadSkill (bSkills (sdBackends deps)) autoloadId basePrompt
    buildChildRegistry _def childSid childCaps = do
      eChildWd <- ensureSessionWorkdir paths childSid
      let childWsRoot = case eChildWd of
            Right wd -> WorkspaceRoot wd
            Left _err -> WorkspaceRoot "/nonexistent-workdir-fail-closed"
      let childBaseOps =
            [ showHumanOp childCaps
            , askHumanOp childCaps
            , secretGetOp (sdVault deps)
            , memoryWriteOp (bMemory (sdBackends deps)) childSid
            , memoryRecallOp defaultPageParams (bMemory (sdBackends deps))
            , memoryDeleteOp (bMemory (sdBackends deps))
            , skillWriteOp (bSkills (sdBackends deps)) childSid
            , skillLoadOp (bSkills (sdBackends deps))
            , skillListOp (bSkills (sdBackends deps))
            , skillDeleteOp (bSkills (sdBackends deps))
            , agentDefReadOp (bAgentDefs (sdBackends deps))
            , agentDefListOp (bAgentDefs (sdBackends deps))
            -- blocklisted: AGENT_DEF_WRITE, AGENT_DEF_DELETE,
            -- AGENT_INSTANCES, AGENT_START, AGENT_STATUS, AGENT_STOP,
            -- AGENT_INTERRUPT
            , searchFilesOp childWsRoot securityPolicy operatorCeiling
            , fileReadOp childWsRoot operatorCeiling
            , fileWriteOp childWsRoot operatorCeiling
            , filePatchOp childWsRoot
            , shellExecOp childWsRoot securityPolicy
            , binExecOp childWsRoot securityPolicy binAllowList
            , processManageOp childWsRoot securityPolicy
            , webFetchOp webFetchCfg
            , webSearchOp webSearchCfg
            ]
      pure (ISA.mkRegistry (filterBlocklisted childBaseOps opName))
      where
        securityPolicy = Policy.SecurityPolicy Policy.AllowAll (sdAutonomy deps)
        binAllowList = Nothing
        webFetchCfg = WebFetchConfig
          { wfcManager = sdHttpManager deps, wfcAllowList = []
          , wfcMaxBytes = operatorCeiling, wfcAuthKey = Nothing }
        webSearchCfg = WebSearchConfig
          { wscManager = sdHttpManager deps, wscEndpoint = ""
          , wscAllowList = [], wscAuthKey = Nothing }

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
-- frontend dismisses the question.
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

-- | Read the last assistant message from a session's transcript and fan
-- it out to every chat channel subscribed to the session. The web frontend
-- already received entries via the WS broker; only chat channels need the
-- explicit 'chSend'. Reads @conversation.jsonl@ directly (the two-file
-- format), parsing the last 'Assistant' message's text content blocks.
fanoutLastReply :: ReplyRegistry -> SealPaths -> SessionId -> IO ()
fanoutLastReply replies paths sid = do
  let convPath = sessionConversationPath paths sid
  exists <- doesFileExist convPath
  if not exists
    then pure ()
    else do
      raw <- TIO.readFile convPath
      let lines' = filter (not . T.null) (T.lines raw)
          msgs = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8) lines' :: [Message]
      for_ (lastAssistantText msgs) $ \reply ->
        replyFanout replies sid reply

-- | Extract the concatenated text content of the last 'Assistant' message
-- in a list. Tool-use blocks are skipped (only 'CbText' is extracted).
lastAssistantText :: [Message] -> Maybe Text
lastAssistantText msgs =
  case reverse (filter (\m -> msgRole m == Assistant) msgs) of
    (m : _) -> case [t | CbText t <- msgContent m] of
      (t : _) -> Just t
      []      -> Nothing
    [] -> Nothing
