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
  , handleSetupRepo
  , ensureTabForSession
  , handleAnswerDelivery
  , handleAnswerTextDelivery
  , parseAnswerBody
  , handleAskCancel
  , webCallDispatcher
  , mkWebTurnDeps
  , webAskCaps
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Monad (unless, when, void)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (Manager)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)
import Seal.Channel.Cli
  ( Backends (..) )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Call (CallDispatcher, callCommandSpec, renderDispatchError)
import Seal.Command.Skill (skillCommandSpec)

import Seal.Command.Model (modelCommandSpecForSession, mkModelTranscriptWriter)
import Seal.Command.Stop (stopCommandSpecForSession, mkStopTranscriptWriter)
import Seal.Command.Spec (CommandAction (..), CommandName (..), CommandSpec (..), Registry, mkRegistry, registrySpecs)
import Seal.Config.Paths (SealPaths, sessionDir, sessionLogPath)
import Seal.Core.TurnEngine
  (TurnDeps (..), TurnAdapter (..),
   TurnOutcome (..), runSessionTurn)
import qualified Seal.Core.TurnEngine as TurnEngine
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, sessionIdText)
import Seal.Git.Repo (ConfigRepo)
import Seal.Handles.AskReply
  ( AskId, ApprovalCache, ApprovalScope (..), AskReply (..), AskReplyStore
  , askHumanWithOptions, askIdText, cancelAsk, deliverAnswer, parseAskId
  , approvalScopeText, parseApprovalScope )
import Seal.Handles.Tab (TabKind (KindProvider), tabIndexToChar)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.Tabs (TabsHandle, ensureTabForSession, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabRef (..), lookupByRef)
import Seal.ISA.Ops.Repo (validateRepoUrl)
import Seal.ISA.Opcode (OpResult (..))
import Seal.Providers.Class
  ( SomeProvider, ToolResultPart (..) )
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner)
import Seal.Routing.Route (ParseError (..), RoutingDecision (..), route)
import Seal.Gateway.Broadcast (broadcastListsSnapshot)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.SourceControl.Registry (RepoRegistryHandle)
import qualified Seal.Security.Policy as Policy (AutonomyLevel (..))
import Seal.Session.ExecCache (SessionExecCache)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Session.Lock
  ( ReplyRegistry, replyFanout, replyFanoutMessage
  , SessionLocks )
import Seal.Tools.Exec.Abort (SessionAbortRegistry)
import Seal.Tools.Exec.Remote (RemoteRunner)
import Seal.ISA.Ops.Agent (AgentWorkerBuilder)
import Seal.Logging.Logger (SealLogger)
import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Util.StrictIO (decodeFileStrict)

-- | The dependencies the send handler needs (the agent-loop plumbing). Built
-- once in 'Seal.Command.Serve.runServeMain' and shared across requests. The
-- 'sdResolve' seam defaults to the real 'resolveSessionProvider' but tests
-- inject a fake to avoid the vault + live HTTP provider.
data SendDeps = SendDeps
  { sdPaths      :: SealPaths
  , sdVault      :: VaultRuntime
  , sdRepoReg    :: RepoRegistryHandle
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
  , sdAbortReg :: SessionAbortRegistry
    -- ^ Per-session abort registry (design Blocker Resolution #2). The web
    -- @POST /api/sessions/:id/stop@ endpoint calls 'setSessionAbort' on
    -- this; 'handleSend' looks up the per-session 'AbortFlag' via
    -- 'lookupOrCreateAbortFlag' and passes it into 'mkSessionAgentEnv' as
    -- 'aeAbortFlag'. Mirrors 'sdLocks' (the registry is a session-keyed
    -- map, lazily created per session).
  , sdTabsHandle :: TabsHandle
    -- ^ The shared tab handle. 'handleSend' auto-tabs the session after a
    -- successful turn (W2 invariant 2: any message sent to a session with
    -- no active tab creates one). Sourced from server-validated 'SessionMeta'
    -- only — never from raw client strings.
  , sdLogger :: SealLogger
    -- ^ The shared logger for structured katip logging. Built once at
    -- startup via 'withSealLogger'.
  , sdIsRemote :: Bool
    -- ^ Whether the untrusted executor runs commands over SSH (remote
    -- mode from the security config). Threaded into 'CloneDeps' so the
    -- deploy-key clone path knows to use agent forwarding (@ssh -A@).
  , sdExecCache :: SessionExecCache
    -- ^ The per-process session-exec + workdir-discovery cache, shared with
    -- the gateway's 'ApiDeps' so a scan runs once per session across ALL
    -- surfaces (turns, /call dispatches, GET /api/sessions/:id/agents).
  , sdRemoteRunner :: Maybe RemoteRunner
    -- ^ Test seam (mirrors 'TurnDeps.tdRemoteRunner'): when 'Just', replaces
    -- 'mkRealRemoteRunner' as the SSH runner used to build the session exec
    -- in mode=remote. 'Nothing' (production) uses the real runner. Gateway
    -- API integration tests inject a recording fake so the composed ssh
    -- argv — the fully-rendered remote command — is observable without a
    -- live SSH host.
  , sdMkWorker :: Maybe AgentWorkerBuilder
    -- ^ Test seam (mirrors 'sdRemoteRunner' / 'TurnDeps.tdMkWorker'): when
    -- 'Just', replaces 'buildWorker' as the 'AGENT_START' worker-builder.
    -- 'Nothing' (production) uses the real 'buildWorker' →
    -- 'mkDelegateWorker' path. Gateway API integration tests inject a stub
    -- worker so 'AGENT_START' can run through the gateway without a real
    -- provider call.
  }

-- | Replace the @call@, @skill@, @stop@, and @model@ specs in a registry with
-- per-request versions (W5: the call/skill dispatcher closes over the
-- request's explicit 'SessionId' instead of reading the process-global
-- @srActive@; the stop spec likewise targets the request's session so a
-- @\/stop@ typed in tab N aborts tab N, not whatever @srActive@ points at;
-- the model spec targets the request's session so a @\/model use@ in tab N
-- updates tab N's @session.json@, not @srActive@'s). The other specs are
-- reused as-is from the startup-built @sdRegistry@.
replaceCallSkillSpecs :: Registry -> CommandSpec -> CommandSpec -> CommandSpec -> CommandSpec -> Registry
replaceCallSkillSpecs baseReg skillSpec callSpec stopSpec modelSpec =
  mkRegistry (filter notPerRequestSpec (registrySpecs baseReg) <> [skillSpec, callSpec, stopSpec, modelSpec])
  where
    notPerRequestSpec s = let CommandName n = csName s in n `notElem` ["call", "skill", "stop", "model"]

-- | Build a 'TurnDeps' from a 'SendDeps' (the web wiring). The unified turn
-- adapter builder is the only place the web's 'SendDeps' shape meets the
-- engine's 'TurnDeps' shape. After W4 collapses 'SendDeps' + 'ChannelDeps'
-- + the CLI closures into one 'TurnDeps', this builder is dropped.
mkWebTurnDeps :: SendDeps -> TurnDeps
mkWebTurnDeps deps = TurnDeps
  { tdPaths        = sdPaths deps
  , tdVault        = sdVault deps
  , tdProvider     = sdProvider deps
  , tdResolve      = sdResolve deps
  , tdRepoReg      = sdRepoReg deps
  , tdAutonomy     = sdAutonomy deps
  , tdBroker       = sdBroker deps
  , tdHarnessReg   = sdHarnessRegistry deps
  , tdTmuxRunner   = sdTmuxRunner deps
  , tdHttpManager  = sdHttpManager deps
  , tdApprovals    = sdApprovals deps
  , tdReplies      = sdReplies deps
  , tdLocks        = sdLocks deps
  , tdAbortReg     = sdAbortReg deps
  , tdTabsHandle   = sdTabsHandle deps
  , tdLogger       = sdLogger deps
  , tdIsRemote     = sdIsRemote deps
  , tdBaseBackends = sdBackends deps
  , tdExecCache    = sdExecCache deps
  , tdRemoteRunner = sdRemoteRunner deps
  , tdMkWorker    = sdMkWorker deps
  }

-- | Build the web 'TurnAdapter' for a given 'ChannelCaps'. The web adapter:
-- * @taPreTurn@ — fans out the user's message to subscribed chat channels
--   (cross-channel mirroring, @"web"@ label). No 'replySubscribe' (the web
--   isn't an inbox-driven channel handle).
-- * @taChannelLabel@ — constant @"web"@.
-- * @taOnStop@ — 'Just' the reply fan-out so chat channels subscribed to
--   this session receive the final reply.
-- * @taOnUserMessage@ — 'Nothing' (web turns aren't /bg).
-- * @taPostTurn@ — @pure ()@ (the web's @lists@ snapshot is refreshed by
--   'triggerBroadcast' in 'handleSend', not here).
-- * @taStartWiring@ — the engine-owned 'TurnEngine.buildStartWiring' (W4
--   collapsed the per-surface builders into this single one).
mkWebTurnAdapter :: SendDeps -> TurnDeps -> ChannelCaps -> TurnAdapter
mkWebTurnAdapter deps td caps = TurnAdapter
  { taCaps          = caps
  , taPreTurn       = \sid _meta t -> replyFanoutMessage (sdReplies deps) sid "web" t
  , taChannelLabel  = const "web"
  , taOnStop        = Just . replyFanout (sdReplies deps)
  , taOnUserMessage = const (Just (pure ()))
  , taPostTurn      = \_ _ -> pure ()
  , taStartWiring   = \sessionBackends sid appEnv eCfg operatorCeiling _meta ->
      TurnEngine.buildStartWiring td sessionBackends sid appEnv eCfg operatorCeiling "web"
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

-- | Handle POST /api/sessions/:id/send. Loads the session meta by id, routes
-- the text, runs the turn, and returns the 'SendOutcome'. A missing session
-- -> 404; an unknown provider / vault error -> 400; an internal failure ->
-- 500 (logged to stderr).
--
-- After a successful 'Plain'/'SlashCommand'/'NewSession' turn (any outcome
-- that is NOT 'SendError'), auto-tabs the session via
-- 'ensureTabForSession' (W2 invariant 2). The 'TabCommand'/'Focus'/'Inject'
-- routes return 'SendSlash' but no message was sent — they are explicitly
-- excluded from auto-tabbing.
handleSend :: SendDeps -> SessionId -> Text -> IO SendOutcome
handleSend deps sid rawText = do
  mMeta <- loadSessionMeta (sdPaths deps) sid
  case mMeta of
    Nothing -> pure (SendError 404 "session not found")
    Just meta -> case route rawText of
      Left (ParseError e) -> pure (SendSlash e Nothing)
      Right (Plain t) -> do
        er <- withExceptionLogging (sdLogger deps) (Just (sessionLogPath (sdPaths deps) (smId meta))) "plainTurn" $
          plainTurn deps meta t
        case er of
          Left err -> pure (SendError 500 err)
          Right (Left err) -> pure (SendError 500 err)
          Right (Right ()) -> do
            ensureTabForSession (sdTabsHandle deps) KindProvider (smId meta)
            triggerBroadcast deps
            pure SendAssistant
      Right (SlashCommand cmdName) -> do
        -- W5: no srActive swap bracket. The per-request call/skill
        -- dispatcher closes over the request's explicit sid (see
        -- 'runSlash'). /new still swaps srActive via its ndRebind (the
        -- swap is how /new communicates the new session to
        -- 'newSessionIdIfChangedFrom').
        r <- runSlash deps meta rawText
        case r of
          SendError _ _ -> pure r
          _            -> do
            -- /tab owns its tab lifecycle (close/resume mutate the list);
            -- auto-tabbing the request's session afterward would resurrect
            -- a tab that /tab close just removed. Skip the auto-tab for
            -- /tab; still broadcast so the frontend reflects any mutation.
            unless (isTabCommand cmdName) $
              ensureTabForSession (sdTabsHandle deps) KindProvider (smId meta)
            triggerBroadcast deps
            pure r
      Right (NewSession _args) -> do
        r <- runSlash deps meta rawText
        case r of
          SendError _ _ -> pure r
          _            -> do
            ensureTabForSession (sdTabsHandle deps) KindProvider (smId meta)
            triggerBroadcast deps
            pure r
      Right (TabCommand _)   -> pure (SendSlash "(tab commands are not supported over the web send endpoint)" Nothing)
      Right CurrentTab        -> do
        tl <- snapshotTabs (sdTabsHandle deps)
        pure $ case lookupByRef tl (BoundSession (smId meta)) of
          Just t  -> SendSlash (renderWebTab t) Nothing
          Nothing -> SendSlash "no current tab" Nothing
      Right (Focus _)        -> pure (SendSlash "(focus is a tab-level operation; use the sidebar)" Nothing)
      Right (Inject _ _)    -> pure (SendSlash "(inject is a tab-level operation; use the sidebar)" Nothing)

-- | Render the current tab for the web send endpoint: @<index>  <kind>  [label]@.
renderWebTab :: Tab -> Text
renderWebTab t =
  T.singleton (tabIndexToChar (tIndex t)) <> "  " <> T.pack (show (tKind t))
    <> maybe "" ("  " <>) (tLabel t)

-- | True for slash commands that own their tab lifecycle (@/tab ...@).
-- Used to skip 'ensureTabForSession' on the web send path so a
-- @/tab close N@ that just removed a tab isn't immediately undone by the
-- auto-tab. The head word is checked case-insensitively (the registry
-- lookup is case-insensitive too).
isTabCommand :: Text -> Bool
isTabCommand cmdName =
  let headWord = T.takeWhile (/= ' ') (T.strip cmdName)
  in T.toCaseFold headWord == "tab"

-- | 'ensureTabForSession' is defined in 'Seal.Tabs' and re-exported here for
-- the web send path. See its Haddock there for the contract (idempotent,
-- race-safe, failure logged to stderr ids-only, sources SessionId only from
-- server-validated contexts).

-- | Push a fresh @lists@ snapshot to WS subscribers after a state change
-- (W6 broadcast trigger). No-op when 'sdBroker' is 'Nothing' (tests).
triggerBroadcast :: SendDeps -> IO ()
triggerBroadcast deps =
  case sdBroker deps of
    Nothing     -> pure ()
    Just broker -> broadcastListsSnapshot broker (sdTabsHandle deps) (sdPaths deps)

-- | Load a single session's 'SessionMeta' by id from disk. Returns Nothing
-- when the session directory or session.json is missing or undecodable.
loadSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)
loadSessionMeta paths sid = do
  let mp = sessionDir paths sid </> "session.json"
  exists <- doesFileExist mp
  if not exists
    then pure Nothing
    else decodeFileStrict mp :: IO (Maybe SessionMeta)

-- | Resolve the system prompt for a web turn. An ad-hoc
-- 'smSystemOverride' (set via PUT /api/sessions/:id/prompt from the
-- Session setup screen's "Use a one-off agent file" upload) takes
-- precedence over the bound agent's 'adSystem'. Returns 'Nothing' when
-- neither is set. The auto-loaded skill (default @seal-usage@, the
-- fresh-workdir contract) is appended so the model is oriented to its
-- per-session workspace from turn one. Disabled by setting
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
  let td = mkWebTurnDeps deps
  caps <- webAskCaps (sdBroker deps) (sdAskReply deps) (smId meta)
  let adapter = mkWebTurnAdapter deps td caps
  outcome <- runSessionTurn td adapter meta Nothing t
  pure (case toError outcome of
          Just err -> Left err
          Nothing  -> Right ())

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
  askCaps <- webAskCaps (sdBroker deps) (sdAskReply deps) (smId meta)
  let caps = askCaps { ccSend = \t' -> modifyMVar_ outVar (\acc -> pure (acc <> [t'])) }
      sid = smId meta
      td = mkWebTurnDeps deps
      -- W5: build a per-request call dispatcher that closes over the
      -- request's explicit sid (no srActive swap). The sdRegistry is
      -- rebuilt per-request by replacing the call/skill specs with
      -- per-request versions; the rest of the specs are reused as-is.
      perRequestCallDispatcher = webCallDispatcher deps td sid
      perRequestRegistry = replaceCallSkillSpecs (sdRegistry deps)
        (skillCommandSpec (bSkills (sdBackends deps)) perRequestCallDispatcher (Just (void . plainTurnWithCaps deps meta caps)))
        (callCommandSpec perRequestCallDispatcher)
        (stopCommandSpecForSession (sdAbortReg deps) sid
           (mkStopTranscriptWriter (sdPaths deps) (sdBroker deps)))
        (modelCommandSpecForSession (sdProvider deps) (sdPaths deps) (pure sid)
           (mkModelTranscriptWriter (sdPaths deps) (sdBroker deps)))
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
  d <- ingest perRequestRegistry (sdPreprocess deps) (RawInbound fullLine)
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
  let td = mkWebTurnDeps deps
      adapter = mkWebTurnAdapter deps td caps
  outcome <- runSessionTurn td adapter meta Nothing t
  pure (case toError outcome of
          Just err -> Left err
          Nothing  -> Right ())

-- | Build a 'CallDispatcher' for the web channel. Resolves the active
-- session at call time, opens its transcript, builds the session's ISA
-- registry, and dispatches the opcode via 'Seal.ISA.Dispatch.dispatch'
-- under 'Full' autonomy semantics (the operator is the approver by
-- typing @/call@). Mirrors 'plainTurnWithCaps' but invokes 'dispatch'
-- directly instead of 'runTurn'. Returns the structured result for
-- 'Seal.Command.Call.renderOpResult' to render.
-- | Build a 'CallDispatcher' for the web channel. Closes over the request's
-- explicit 'SessionId' (W5: no longer reads the process-global @srActive@).
-- Delegates to the unified 'TurnEngine.callDispatcher'.
webCallDispatcher :: SendDeps -> TurnDeps -> SessionId -> CallDispatcher
webCallDispatcher deps td sid callOpName val = do
  caps <- webAskCaps (sdBroker deps) (sdAskReply deps) sid
  TurnEngine.callDispatcher td caps sid "web" callOpName val

-- | Build the web 'ChannelCaps' for a per-turn 'AskReplyStore'. 'ccSend'
-- accumulates streaming text deltas and broadcasts an @entry-update@ WS event
-- so the web frontend sees the response grow live (token-by-token) instead of
-- appearing only after the full LLM stream completes. 'ccPrompt' drives the
-- full ask/reply primitive: it mints a pending question (carrying the opcode
-- metadata when provided), broadcasts a 'BeAsk' event so the frontend renders
-- it, and blocks on the store until the human answers via POST
-- /api/sessions/:id/questions/:qid/answer (or the question is
-- cancelled/timed out). The returned 'Text' is the approval scope's wire form
-- (e.g. @"once"@, @"for_session"@, @"always"@, @"rejected"@) for the confirmation
-- gate, or the human's typed reply for @ASK_HUMAN@. 'ccPromptSecret' is
-- fail-closed.
webAskCaps
  :: Maybe StreamBroker -> AskReplyStore -> SessionId -> IO ChannelCaps
webAskCaps mBroker store sid = do
  accRef <- newIORef ("" :: Text)
  let caps = def
        { ccSend = \delta -> case mBroker of
            Nothing -> pure ()
            Just broker -> do
              acc <- atomicModifyIORef' accRef (\a -> (a <> delta, a <> delta))
              broadcast broker (BeEntryUpdate sid (streamingEntryJson acc))
        , ccPrompt = \(AskPrompt q opts) -> do
            outcome <- askHumanWithOptions store sid q opts (\qid ->
              case mBroker of
                Nothing -> pure ()
                Just broker ->
                  broadcast broker (BeAsk sid (object
                    [ "id" .= askIdText qid
                    , "question" .= q
                    , "options" .= opts
                    ])))
            pure (case outcome of
              Left _  -> "rejected"
              Right t -> t)
        }
  pure caps

-- | Build a synthetic streaming @entry-update@ JSON envelope for the
-- accumulated text so far. The entry id is the fixed sentinel @"streaming"@
-- so the frontend's 'reconcileEntries' replaces the same placeholder in place
-- as text grows. When the final @entry@ event arrives (after the response is
-- recorded to the transcript), the frontend evicts the streaming placeholder
-- and inserts the real entry. The payload mirrors a response entry's shape so
-- the frontend's 'transcriptToMessages' renders it as an assistant message.
streamingEntryJson :: Text -> Value
streamingEntryJson text = object
  [ "id"        .= ("streaming" :: Text)
  , "timestamp" .= ("" :: Text)
  , "direction" .= ("response" :: Text)
  , "payload"   .= object
      [ "content" .= [object ["type" .= ("text" :: Text), "text" .= text]]
      ]
  , "harness"   .= (Nothing :: Maybe Text)
  , "model"     .= (Nothing :: Maybe Text)
  , "channel"   .= (Nothing :: Maybe Text)
  , "raw"       .= ("" :: Text)
  ]

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

-- | Handle @POST /api/sessions/:id/setup-repo@: clone a repo into the
-- session's workdir before the first turn. The web "set up repo" combo box
-- calls this. Rather than calling 'cloneRepoIO' directly (which is
-- unaudited — a side channel that never appears in the transcript), this
-- dispatches the real 'SETUP_REPO' opcode via 'webCallDispatcher'. The
-- clone (and any failure) is therefore recorded in the session's
-- transcript exactly like a model-invoked SETUP_REPO, so the user sees it
-- in the chat and any error is visible there — not silent.
--
-- The 'srActive' ref is scoped to the target session for the duration of
-- the dispatch (the web gateway is multi-session; 'webCallDispatcher'
-- reads 'srActive' to pick the transcript), then restored.
--
-- Returns @Left err@ for an invalid url or a dispatch failure; @Right msg@
-- with the opcode's text result (the clone/no-op/conflict/failure message)
-- for the API layer to pass through to the frontend.
handleSetupRepo :: SendDeps -> SessionId -> Text -> IO (Either Text Text)
handleSetupRepo deps sid url =
  case validateRepoUrl url of
    Left err -> pure (Left ("invalid url: " <> err))
    Right cleanUrl -> do
      mMeta <- loadSessionMeta (sdPaths deps) sid
      case mMeta of
        Nothing -> pure (Left "session not found")
        Just _targetMeta -> do
          -- Dispatch SETUP_REPO via the audited path (records into the
          -- transcript + broadcasts the entry so the frontend sees it).
          -- W5: the dispatcher takes the explicit sid (no srActive swap).
          let td = mkWebTurnDeps deps
              dispatcher = webCallDispatcher deps td sid
          res <- dispatcher (OpName "SETUP_REPO") (object ["url" .= cleanUrl])
          case res of
            Left dErr -> pure (Left ("SETUP_REPO dispatch failed: " <> renderDispatchError dErr))
            Right opRes ->
              if orIsError opRes
                then pure (Left (opResultText opRes))
                else pure (Right (opResultText opRes))

-- | Join the text parts of an 'OpResult' into a single message (the
-- clone/no-op/conflict/failure text from SETUP_REPO).
opResultText :: OpResult -> Text
opResultText r = T.intercalate "\n" [ t | TrpText t <- orParts r ]

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

-- | Deliver a free-text answer (a chosen option's label or a typed "Other"
-- reply) to a pending ASK_HUMAN question. The 'ApprovalScope' is always
-- 'ScopeOnce' (ASK_HUMAN replies are never cached). Returns 'True' if the
-- answer was accepted. Broadcasts 'BeAskResolved' so the frontend dismisses
-- the question. A 'Left' parse error is returned for a malformed ask id.
handleAnswerTextDelivery
  :: SendDeps -> SessionId -> Text -> Text -> IO (Either Text Bool)
handleAnswerTextDelivery deps sid qidTxt answerText =
  case parseAskId qidTxt of
    Left e -> pure (Left e)
    Right qid -> do
      let reply = AskReply ScopeOnce answerText
      accepted <- deliverAnswer (sdAskReply deps) qid reply
      when accepted $
        broadcastAskResolved (sdBroker deps) sid qid "answered"
      pure (Right accepted)

-- | Parse the POST .../questions/:qid/answer body. Accepts EITHER
-- @{scope: "once|for_session|always|rejected"}@ (the confirmation gate) OR
-- @{answer: "<text>"}@ (ASK_HUMAN). Returns 'Right (Left scope)' for the
-- scope path, 'Right (Right answerText)' for the answer path. 'Left' with
-- an error message when both fields are present (ambiguous), neither is
-- present, or a value is malformed. This is the explicit both-reject parser
-- (gate: Security #6) — a body with both @scope@ and @answer@ is rejected
-- with 400, NOT silently delivering @answer@ with @scope@ semantics.
parseAnswerBody :: BL.ByteString -> Either Text (Either ApprovalScope Text)
parseAnswerBody body =
  case A.decode body :: Maybe A.Value of
    Just (A.Object o) ->
      let mScope  = KeyMap.lookup (Key.fromText "scope") o
          mAnswer = KeyMap.lookup (Key.fromText "answer") o
      in case (mScope, mAnswer) of
        (Just (A.String t), Nothing) ->
          case parseApprovalScope t of
            Right scope -> Right (Left scope)
            Left e -> Left e
        (Nothing, Just (A.String t)) -> Right (Right t)
        (Just _, Just _) -> Left "ambiguous: send either {scope} or {answer}, not both"
        (Nothing, Nothing) -> Left "missing 'scope' or 'answer' field"
        (Just _, Nothing) -> Left "invalid 'scope' field (expected a string)"
        (Nothing, Just _) -> Left "invalid 'answer' field (expected a string)"
    _ -> Left "invalid JSON body"

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
