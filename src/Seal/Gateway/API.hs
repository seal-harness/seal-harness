{-# LANGUAGE OverloadedStrings #-}
-- | The REST API surface the SPA calls: sessions/tabs/agents/providers + send.
-- A manual WAI router (no servant/scotty dep) using @http-types@.
module Seal.Gateway.API
  ( apiApp
  , ApiDeps (..)
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Control.Exception (SomeException, try)
import Control.Monad (void, replicateM, when)
import Data.CaseInsensitive qualified as CI
import Data.Either (fromRight, isRight)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Vector qualified as V

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read (decimal)
import Network.HTTP.Types
  ( Header, HeaderName, Status, methodDelete, methodGet, methodOptions
  , methodPost, methodPut
  , status200, status201, status204, status400, status403, status404, status500, status501 )
import Network.Wai
  ( Application, Request, Response, getRequestBodyChunk, pathInfo
  , requestMethod, responseLBS )
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (proc, readCreateProcessWithExitCode)
import System.Random (randomRIO)

import Seal.Agent.Def.Backend (AgentDefBackend (..), workdirAgentDefBackend, unionAgentDefBackend)
import Seal.Agent.Def.Types
  ( AgentDef (..), AgentDefId (..), agentDefIdText, mkAgentDefId )
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSessionId, mkSystemSessionId, sessionIdText)
import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId, skillIdText)
import Seal.Config.File (RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig, updateRuntimeConfig)
import Seal.Config.Paths (SealPaths (..), repoKeysDir, sessionMetaPath, sessionWorkdir)
import Seal.Tools.Exec.Abort (SessionAbortRegistry, setSessionAbort)
import Seal.Session.Lock (sessionTurnInFlight)
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Handles.AskReply
  ( askIdText, pendingForSession, PendingQuestionInfo (..) )
import Seal.Gateway.Send
  ( SendDeps (..), handleAnswerDelivery, handleAnswerTextDelivery, parseAnswerBody
  , handleAskCancel, handleSend
  , handleSetupRepo, sendOutcomeJson )
import Seal.Gateway.Broadcast (broadcastListsSnapshot, broadcastAgentDefsChanged, broadcastSkillsChanged, broadcastReposChanged)
import Seal.Gateway.ListsSnapshot (buildListsSnapshot)
import Seal.Gateway.SessionJson
  ( sessionInfoJsonWithSnippet, tabToJson )
import Seal.Gateway.StreamBroker (StreamBroker, thinkingSessions)
import Seal.Gateway.Transcript
  (readTranscriptEntriesTimed, renderServerTiming, setEncodeMs, showIso)
import Seal.Handles.Tab (TabIndex, TabKind (..), mkTabIndex, tabIndexToInt)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry, snapshot)
import Seal.Providers.ContextWindow (modelContextWindow, modelMaxOutputTokens)
import Seal.Providers.Registry
  ( KnownProvider (..), parseProvider, providerLabel )
import Seal.Security.Adoption
  (AdoptError (..), ConsentChannel, authorizeAdoption)
import Seal.Session.Meta (SessionMeta (..))
import Seal.SourceControl.Repo
  ( RepoCredential (..), RepoId, SourceRepo (..), hostAllowed, mkRepoId
  , parseCredentialKind, parseRepoHost, parseVcsKind, repoIdText, urlShapeValid )
import Seal.SourceControl.Registry
  ( RepoRegistryHandle (..), removeRepo, upsertRepo )
import Seal.Security.Vault (VaultHandle (vhDelete, vhPut))
import Seal.Vault.Commands (VaultRuntime (vrHandleRef))
import Seal.Session.Store
  ( SessionRuntime (..), defaultSessionSelection, listArchivedSessions
  , listSessions, newSession, newSessionMeta, resolveDefaultAgent
  , saveSessionMeta, updateSessionAgent
  , updateSessionArchived, updateSessionSystemOverride
  , updateSessionDescription )
import Seal.Command.Tab (TabCloseNotifier)
import Seal.Tabs (TabsHandle, insertTabH, removeTabH, rebindTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabRef (..), tlTabs, lookupTab)
import Seal.Web.UiState
  ( LastOptions (..), UiState (..), UiStateHandle
  , addCustomModel, addRepoHistory, getUiState, setLastOptions )
import Seal.Util.StrictIO (decodeFileStrict)

-- | The dependencies the API needs (injected so the test can supply fakes).
data ApiDeps = ApiDeps
  { adSessionRuntime  :: SessionRuntime
  , adTabsHandle      :: TabsHandle
  , adHarnessRegistry :: HarnessRegistry    -- ^ the live harness registry
  , adAdoptConsent    :: Maybe ConsentChannel  -- ^ 'Just CcWeb' for the web gateway; 'Nothing' headless
  , adAgentDefs       :: AgentDefBackend      -- ^ for /api/agents (T11) + /api/agents CRUD
  , adSkills          :: SkillBackend         -- ^ for /api/skills CRUD
  , adProviders       :: IO [KnownProvider]   -- ^ for /api/providers; an action that yields the *configured* provider list (T11)
  , adUiState         :: UiStateHandle        -- ^ for /api/ui/state + /api/ui/custom-models (persisted UI recall)
  , adSend            :: Maybe SendDeps       -- ^ the agent-loop plumbing for POST /send; Nothing = stub responses (tests)
  , adDefaultAgent    :: IO (Maybe Text)        -- ^ re-read @default_agent@ from config.toml on each call (so a PUT /api/agents/default is reflected without a restart)
  , adBroker          :: Maybe StreamBroker      -- ^ the WS broker for pushing @lists@ frames (W6 broadcast triggers); 'Nothing' in tests without a broker
  , adTabCloseNotifier :: TabCloseNotifier      -- ^ invoked after a tab is closed via the REST API so attached channels are notified; 'noTabCloseNotifier' in tests
  , adRepoRegistry     :: RepoRegistryHandle    -- ^ for /api/repos CRUD (W4)
  , adConfigRepo       :: ConfigRepo            -- ^ for the best-effort @gitCommitAll@ audit-commit of repos.toml after a mutation (W4)
  , adVault            :: VaultRuntime          -- ^ the vault runtime (for deploy-key generation: passphrase put/delete)
  , adPaths            :: SealPaths             -- ^ the seal paths (for repoKeysDir — the encrypted keyfile location)
  , adWsPort           :: Int                   -- ^ the WS stream server port (returned in /api/health so the frontend can discover it at runtime)
  , adAbortReg         :: SessionAbortRegistry  -- ^ per-session abort registry (design Blocker Resolution #2). The @POST /api/sessions/:id/stop@ endpoint calls 'setSessionAbort' on this.
  }

-- | The REST API as a WAI Application.
apiApp :: ApiDeps -> Application
apiApp deps req respond =
  case (requestMethod req, pathInfo req) of
    (m', ["api", "health"]) | m' == methodGet ->
      respond (jsonOk (object
        [ "status" .= ("ok" :: Text)
        , "wsPort" .= adWsPort deps
        ]))
    (m', ["api", "tabs"]) | m' == methodGet -> do
      tl <- snapshotTabs (adTabsHandle deps)
      let tabsJson = map tabToJson (tlTabs tl)
      respond (jsonLBS status200 (A.encode tabsJson))
    -- GET /api/lists -> the partitioned snapshot (tabs + recentSessions +
    -- archivedSessions + tabSessions). Mutually exclusive by construction
    -- via 'partitionSessions'. The bare 'ListsSnapshotWire' (no @type@
    -- field — the WS @lists@ frame wraps it with @{"type": "lists", ...}@).
    -- The frontend's primary source (WS) and REST fallback (this endpoint).
    (m', ["api", "lists"]) | m' == methodGet -> do
      thinkingSids <- case adBroker deps of
        Just broker -> thinkingSessions broker
        Nothing    -> pure Set.empty
      snap <- buildListsSnapshot (adTabsHandle deps) (srPaths (adSessionRuntime deps)) thinkingSids
      respond (jsonLBS status200 (A.encode snap))
    -- GET /api/sessions -> the recent, non-archived sessions. Archiving is a
    -- pure UI hint persisted as an @archived@ marker file in the session
    -- directory (the transcript + session.json stay on disk); 'listSessions'
    -- filters those out, and 'listArchivedSessions' returns them via
    -- @/api/sessions/archived@.
    (m', ["api", "sessions"]) | m' == methodGet -> do
      metas <- listSessions (srPaths (adSessionRuntime deps))
      infos <- mapM (sessionInfoJsonWithSnippet (srPaths (adSessionRuntime deps))) metas
      respond (jsonLBS status200 (A.encode infos))
    -- GET /api/sessions/archived -> the archived sessions (those carrying an
    -- @archived@ marker file). Same shape as /api/sessions.
    (m', ["api", "sessions", "archived"]) | m' == methodGet -> do
      metas <- listArchivedSessions (srPaths (adSessionRuntime deps))
      infos <- mapM (sessionInfoJsonWithSnippet (srPaths (adSessionRuntime deps))) metas
      respond (jsonLBS status200 (A.encode infos))
    -- T11: GET /api/sessions/:id/transcript -> the parsed @entries.jsonl@
    -- lines, as a JSON array. Missing file -> @[]@; unparseable lines are
    -- skipped.
    (m', ["api", "sessions", sid, "transcript"]) | m' == methodGet ->
      respond =<< handleTranscript deps sid
    -- POST /api/sessions/:id/send. When the agent-loop plumbing is wired
    -- ('adSend' = 'Just'), route the message through the real agent loop
    -- (slash registry vs plain turn) and return the outcome. When 'adSend'
    -- is 'Nothing' (tests without the full runtime), fall back to the stub
    -- response so the contract is preserved.
    (m', ["api", "sessions", sid, "send"]) | m' == methodPost -> do
      body <- collectBody req
      case adSend deps of
        Nothing -> respond (jsonOk (object ["kind" .= ("assistant" :: Text)]))
        Just sendDeps -> do
          let msg = parseSendMessage body
          case mkSessionId sid of
            Left e   -> respond (errJson status400 ("invalid session id: " <> e))
            Right sId -> do
              outcome <- handleSend sendDeps sId msg
              let (code, val) = sendOutcomeJson outcome
              respond (jsonLBS (statusFromInt code) (A.encode val))
    -- POST /api/sessions/:id/stop — abort the session's in-flight tool call
    -- (and any future tool call until the next turn starts). Returns 200
    -- {aborted: true, pending: bool} where pending=true means no turn was
    -- in flight (the flag is set but will be cleared at the next runTurn
    -- entry). The abort flag is looked up from the SessionAbortRegistry
    -- (design Blocker Resolution #2 — ApiDeps has no AgentEnv at this call
    -- site). Trust boundary: loopback-only, matching /api/repos.
    (m', ["api", "sessions", sid, "stop"]) | m' == methodPost -> do
      case mkSessionId sid of
        Left e   -> respond (errJson status400 ("invalid session id: " <> e))
        Right sId -> do
          setSessionAbort (adAbortReg deps) sId
          -- pending: whether a turn is currently in flight. Determined via a
          -- non-blocking tryReadMVar on the session's lock (from sdLocks if
          -- adSend is wired; else assume not-in-flight). True = no turn in
          -- flight (the abort will be a no-op, cleared at next runTurn entry).
          pending <- case adSend deps of
            Just sendDeps -> sessionTurnInFlight (sdLocks sendDeps) sId
            Nothing       -> pure True
          respond (jsonOk (object
            [ "aborted" .= True
            , "pending" .= pending
            ]))
    -- POST /api/sessions/:id/setup-repo — clone a repo into the session's
    -- workdir before the first turn (the web "set up repo" combo box calls
    -- this). Shares the clone logic with the SETUP_REPO opcode via
    -- 'cloneRepoIO'. Returns 200 {ok:true, target, status} on
    -- cloned/noop, 409 on a conflict, 400 on an invalid url, 503 on a
    -- clone failure. When 'adSend' is Nothing (tests without the full
    -- runtime), returns a stub 200.
    (m', ["api", "sessions", sid, "setup-repo"]) | m' == methodPost -> do
      body <- collectBody req
      case parseRepoUrl body of
        Nothing -> respond (errJson status400 "missing or invalid 'url' field")
        Just url -> case adSend deps of
          Nothing -> respond (jsonOk (object ["ok" .= True, "target" .= ("" :: Text), "status" .= ("stubbed" :: Text)]))
          Just sendDeps -> case mkSessionId sid of
            Left e -> respond (errJson status400 ("invalid session id: " <> e))
            Right sId -> do
              -- Broadcast agent-defs-changed after a successful SETUP_REPO so
              -- the frontend's session-scoped Agent dropdown re-fetches (the
              -- clone may have introduced repo-local .agents/ defs). The
              -- existing BeAgentDefsChanged event is reused (§3.6).
              eRes <- handleSetupRepo sendDeps sId url
              when (isRight eRes) $
                broadcastAgentDefsChanged (adBroker deps)
              respond (handleSetupRepoResponse eRes)
    -- GET /api/sessions/:id/agents — the session-scoped agent-defs list
    -- (workdir ⊕ user, workdir-wins). Returns 200 + AgentInfo[] with
    -- isDefault per §3.2 (user default_agent > repo agents.md > none);
    -- 404 for an unknown session (no session.json). The frontend's
    -- Session setup Agent dropdown populates from this (W3).
    (m', ["api", "sessions", sid, "agents"]) | m' == methodGet -> do
      case mkSessionId sid of
        Left e -> respond (errJson status400 ("invalid session id: " <> e))
        Right sId -> respond =<< handleSessionAgents deps sId
    -- PUT /api/sessions/:id/description — set or clear the user-set
    -- display title for a session (the chat-header pencil). Body:
    -- {"description":"<text>"} (empty/missing/whitespace clears it).
    -- Persists via 'updateSessionDescription' (a field on session.json)
    -- and triggers a lists broadcast so the sidebar picks up the new
    -- label without a refresh. Returns 200 {ok:true} on success, 404
    -- when the session has no session.json on disk, 400 on invalid JSON.
    (m', ["api", "sessions", sid, "description"]) | m' == methodPut -> do
      body <- collectBody req
      case mkSessionId sid of
        Left e  -> respond (errJson status400 ("invalid session id: " <> e))
        Right sId -> respond =<< handleSessionDescription deps sId body
    -- PUT /api/sessions/:id/archived — set or clear the archive flag. Body:
    -- {"archived": true|false}. Persists via 'updateSessionArchived' (a marker
    -- file in the session directory). Returns 200 {ok:true} on success, 404
    -- when the session has no session.json on disk, 400 on invalid JSON or a
    -- missing/non-boolean @archived@ field.
    (m', ["api", "sessions", sid, "archived"]) | m' == methodPut -> do
      body <- collectBody req
      case mkSessionId sid of
        Left e  -> respond (errJson status400 ("invalid session id: " <> e))
        Right sId -> case parseArchivedFlag body of
          Nothing       -> respond (errJson status400 "missing or invalid 'archived' field")
          Just archived -> respond =<< handleSessionArchived deps sId archived
    -- PUT /api/sessions/:id/prompt — set or clear an ad-hoc system prompt
    -- override for the session (the Session setup screen's "Use a one-off
    -- agent file" upload). Body: {"prompt":"<text>"} (empty/missing
    -- clears). When set, 'plainTurn' uses this verbatim as the system
    -- prompt instead of the bound agent's 'adSystem'. Returns 200 {ok:true}
    -- on success, 404 when the session doesn't exist.
    (m', ["api", "sessions", sid, "prompt"]) | m' == methodPut -> do
      body <- collectBody req
      case mkSessionId sid of
        Left e  -> respond (errJson status400 ("invalid session id: " <> e))
        Right sId -> respond =<< handleSessionPrompt deps sId body
    -- PUT /api/sessions/:id/agent — bind (or clear) the session's agent
    -- definition. Body: {"agent":"<id>"} (empty/missing clears). Persists
    -- the updated 'SessionMeta' to disk so subsequent /send turns pick up
    -- the new system prompt. Returns 200 {ok:true} on success, 404 when
    -- the session doesn't exist, 400 on an invalid agent id.
    (m', ["api", "sessions", sid, "agent"]) | m' == methodPut -> do
      body <- collectBody req
      case mkSessionId sid of
        Left e  -> respond (errJson status400 ("invalid session id: " <> e))
        Right sId -> respond =<< handleSessionAgent deps sId body
    -- GET /api/sessions/:id/questions -> the session's pending ASK_HUMAN
    -- questions (oldest-first). The frontend renders these as dismissible
    -- prompts; the operator answers via POST .../questions/:qid/answer or
    -- cancels via POST .../questions/:qid/cancel. Requires 'adSend' (the
    -- 'AskReplyStore' lives on the 'SendDeps'); returns [] when unwired.
    (m', ["api", "sessions", sid, "questions"]) | m' == methodGet ->
      case adSend deps of
        Nothing -> respond (jsonLBS status200 (A.encode ([] :: [Value])))
        Just _sendDeps -> respond =<< handleListQuestions deps sid
    -- POST /api/sessions/:id/questions/:qid/answer -> deliver the operator's
    -- approval scope OR a free-text answer to a pending ASK_HUMAN question,
    -- unblocking the agent-loop thread. Body: {"scope":"once|for_session|
    -- always|rejected"} (the confirmation gate) OR {"answer":"<text>"} (an
    -- ASK_HUMAN reply — a chosen option label or a typed "Other"). Both
    -- fields present → 400 (ambiguous); neither → 400. Returns 200
    -- {ok:true, accepted:true} when the answer was accepted, or
    -- {ok:true, accepted:false} when already answered/cancelled/unknown.
    -- A malformed ask id or body yields 400.
    (m', ["api", "sessions", sid, "questions", qid, "answer"]) | m' == methodPost -> do
      body <- collectBody req
      case adSend deps of
        Nothing -> respond (errJson status501 "ask/reply not wired")
        Just sendDeps -> case mkSessionId sid of
          Left e -> respond (errJson status400 ("invalid session id: " <> e))
          Right sId -> case parseAnswerBody body of
            Left e -> respond (errJson status400 e)
            Right (Left scope) -> do
              eRes <- handleAnswerDelivery sendDeps sId qid scope
              case eRes of
                Left e     -> respond (errJson status400 e)
                Right acc -> respond (jsonOk (object ["ok" .= True, "accepted" .= acc]))
            Right (Right answerText) -> do
              eRes <- handleAnswerTextDelivery sendDeps sId qid answerText
              case eRes of
                Left e     -> respond (errJson status400 e)
                Right acc -> respond (jsonOk (object ["ok" .= True, "accepted" .= acc]))
    -- POST /api/sessions/:id/questions/:qid/cancel -> cancel a pending
    -- ASK_HUMAN question (the operator dismissed it). Returns 200
    -- {ok:true, cancelled:true} when the question was pending and is now
    -- cancelled, or 200 {ok:true, cancelled:false} when it was already
    -- resolved or unknown. A malformed ask id yields 400.
    (m', ["api", "sessions", sid, "questions", qid, "cancel"]) | m' == methodPost ->
      case adSend deps of
        Nothing -> respond (errJson status501 "ask/reply not wired")
        Just sendDeps -> case mkSessionId sid of
          Left e -> respond (errJson status400 ("invalid session id: " <> e))
          Right sId -> do
            eRes <- handleAskCancel sendDeps sId qid
            case eRes of
              Left e -> respond (errJson status400 e)
              Right cnl -> respond (jsonOk (object ["ok" .= True, "cancelled" .= cnl]))
    (m', ["api", "harnesses"]) | m' == methodGet -> do
      entries <- snapshot (adHarnessRegistry deps)
      respond (jsonLBS status200 (A.encode entries))
    (m', ["api", "harnesses", "discover"]) | m' == methodGet ->
      respond (jsonLBS status200 (A.encode ([] :: [Value])))
    -- T11: GET /api/agents -> the agent defs. @isDefault@ is a UI
    -- convenience; it's resolved against 'adDefaultAgent' (the configured
    -- @default_agent@ id) by name. The full def (provider/model/system/
    -- tools/timestamps) is returned so the Agents CRUD UI can render + edit
    -- every field. The @name@ field carries the agent's id (not the
    -- human-readable display name) so the frontend can echo it back as
    -- @body.agent@ / PUT /agent and the backend can re-validate it via
    -- 'mkAgentDefId'. The display name lives in the def's frontmatter.
    (m', ["api", "agents"]) | m' == methodGet -> do
      defs <- adbList (adAgentDefs deps)
      mDef <- adDefaultAgent deps
      respond (jsonLBS status200 (A.encode (map (agentInfoJson mDef) defs)))
    -- GET /api/agents/default -> the configured default agent id (or null).
    -- Must precede the /api/agents/:id routes so "default" isn't captured
    -- as an agent id.
    (m', ["api", "agents", "default"]) | m' == methodGet ->
      respond =<< handleAgentGetDefault deps
    -- PUT /api/agents/default -> set the default agent. Body:
    -- {"agent":"<id>"} to set, {"agent":null} (or empty) to clear. Persists
    -- to config.toml so the change survives restarts. 400 on a malformed
    -- id; 404 when the named agent doesn't exist.
    (m', ["api", "agents", "default"]) | m' == methodPut -> do
      body <- collectBody req
      respond =<< handleAgentSetDefault deps body
    -- GET /api/agents/:id -> a single agent def by id. 404 when absent or
    -- the id fails 'mkAgentDefId'.
    (m', ["api", "agents", aid]) | m' == methodGet ->
      respond =<< handleAgentGet deps aid
    -- POST /api/agents -> create a new agent def. The id is the caller's
    -- (must pass 'isValidAgentDefId'); provider/model/system/tools are
    -- optional. Returns 201 + the created def on success, 400 on a bad id
    -- or invalid body. If a def with the id already exists, it is REPLACED
    -- (matching the backend's idempotent 'adbUpdate').
    (m', ["api", "agents"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleAgentCreate deps body
    -- PUT /api/agents/:id -> replace an existing agent def. The body may
    -- omit the id (it's taken from the path); the path id must pass
    -- 'isValidAgentDefId'. Returns 200 + the updated def on success, 400 on
    -- a bad id or invalid body, 404 when no def exists at that id.
    (m', ["api", "agents", aid]) | m' == methodPut -> do
      body <- collectBody req
      respond =<< handleAgentUpdate deps aid body
    -- DELETE /api/agents/:id -> remove a def. Idempotent (204 whether or
    -- not the def existed). 400 on a malformed id.
    (m', ["api", "agents", aid]) | m' == methodDelete ->
      respond =<< handleAgentDelete deps aid
    -- GET /api/skills -> all skills, sorted by id.
    (m', ["api", "skills"]) | m' == methodGet -> do
      skills <- sbList (adSkills deps)
      respond (jsonLBS status200 (A.encode (map skillInfoJson skills)))
    -- GET /api/skills/:id -> a single skill by id. 404 when absent or the id
    -- fails 'mkSkillId'.
    (m', ["api", "skills", sid]) | m' == methodGet ->
      respond =<< handleSkillGet deps sid
    -- POST /api/skills -> create a new skill. The id is the caller's; the
    -- body must include @description@ and @body@. Returns 201 + the created
    -- skill. Replaces an existing skill with the same id (idempotent
    -- 'sbCreate').
    (m', ["api", "skills"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleSkillCreate deps body
    -- PUT /api/skills/:id -> replace an existing skill. Body may omit the
    -- id (taken from the path). Returns 200 + the updated skill, or 404
    -- when no skill exists at that id.
    (m', ["api", "skills", sid]) | m' == methodPut -> do
      body <- collectBody req
      respond =<< handleSkillUpdate deps sid body
    -- DELETE /api/skills/:id -> remove a skill. Idempotent (204 whether or
    -- not the skill existed). 400 on a malformed id.
    (m', ["api", "skills", sid]) | m' == methodDelete ->
      respond =<< handleSkillDelete deps sid
    -- GET /api/repos -> all repos in the registry. A corrupt repos.toml
    -- surfaces as 500 (NOT a silent empty list — the AC5/S2 mitigation).
    (m', ["api", "repos"]) | m' == methodGet -> do
      eRepos <- rrhList (adRepoRegistry deps)
      case eRepos of
        Left err -> respond (errJson status500 err)
        Right rs -> respond (jsonLBS status200 (A.encode (map repoInfoJson rs)))
    -- POST /api/repos -> create/replace a repo (idempotent upsert, 201).
    (m', ["api", "repos"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleRepoCreate deps body
    -- GET /api/repos/:id -> a single repo by id. 404 when absent, 400 on a
    -- malformed id.
    (m', ["api", "repos", rid]) | m' == methodGet ->
      respond =<< handleRepoGet deps rid
    -- PUT /api/repos/:id -> replace an existing repo (ids are stable; no
    -- rename). 200 on success, 404 when the id doesn't already exist, 400
    -- on a malformed id or invalid body.
    (m', ["api", "repos", rid]) | m' == methodPut -> do
      body <- collectBody req
      respond =<< handleRepoUpdate deps rid body
    -- DELETE /api/repos/:id -> remove a repo. Idempotent (204 whether or
    -- not the repo existed). 400 on a malformed id.
    (m', ["api", "repos", rid]) | m' == methodDelete ->
      respond =<< handleRepoDelete deps rid
    -- GET /api/repos/:id/deploy-key -> the deploy-key public key + setup
    -- instructions (host-aware). 404 if the repo is absent or not a
    -- deploy-key repo; 400 on a malformed id.
    (m', ["api", "repos", rid, "deploy-key"]) | m' == methodGet ->
      respond =<< handleRepoDeployKey deps rid
    -- POST /api/repos/:id/deploy-key/generate -> rotation: generate a new
    -- keypair (overwrites the encrypted keyfile + passphrase) + returns the
    -- new public key + instructions. 404/400 as above.
    (m', ["api", "repos", rid, "deploy-key", "generate"]) | m' == methodPost ->
      respond =<< handleRepoDeployKeyGenerate deps rid
    -- T11: GET /api/providers -> the configured provider list. @isDefault@
    -- and @defaultModel@ are UI conveniences not threaded into 'ApiDeps' for
    -- T11, so only @name@ is emitted.
    (m', ["api", "providers"]) | m' == methodGet -> do
      providers <- adProviders deps
      respond (jsonLBS status200 (A.encode (map providerInfoJson providers)))
    -- T11: GET /api/providers/:p/models -> a STATIC list of models for the
    -- provider (the real /v1/models upstream call needs vault credentials +
    -- a live HTTP request and is out of scope). Context windows come from
    -- 'Seal.Providers.ContextWindow'.
    (m', ["api", "providers", p, "models"]) | m' == methodGet ->
      respond (jsonLBS status200 (A.encode (providerModelsJson p)))
    -- T11: GET /api/providers/:p/models/:m/context -> the context-window +
    -- max-output-tokens for the model (from 'Seal.Providers.ContextWindow').
    (m', ["api", "providers", _p, "models", m, "context"]) | m' == methodGet ->
      respond (jsonOk (object
        [ "contextWindow" .= modelContextWindow m
        , "maxOutputTokens" .= modelMaxOutputTokens m
        ]))
    -- GET /api/ui/state -> the persisted last-chosen "new tab" options and
    -- the custom-model id history. The frontend loads this on mount so the
    -- form opens with the last-used selection; the custom-model combobox
    -- is populated from the history list.
    (m', ["api", "ui", "state"]) | m' == methodGet -> do
      st <- getUiState (adUiState deps)
      respond (jsonLBS status200 (A.encode (uiStateJson st)))
    -- PUT /api/ui/state -> replace the last-chosen options. The body is the
    -- `last_options` object (the frontend's NewTabSpec shape). Custom-model
    -- history is NOT touched here (it's append-only via /api/ui/custom-models).
    (m', ["api", "ui", "state"]) | m' == methodPut -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleUiStatePut deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
    -- POST /api/ui/custom-models -> add a custom model id to the persisted
    -- history. Body: { "model": "<id>" }. Idempotent + deduped + capped.
    (m', ["api", "ui", "custom-models"]) | m' == methodPost -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleUiCustomModelAdd deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
    -- POST /api/ui/repos -> add a repo URL to the persisted history. Body:
    -- { "url": "<url>" }. Idempotent + deduped + capped. The "set up repo"
    -- combo box records a URL here on submit so the history populates.
    (m', ["api", "ui", "repos"]) | m' == methodPost -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleUiRepoAdd deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
    (m', ["api", "tabs", "new"]) | m' == methodPost -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleTabNew deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
    -- POST /api/sessions/new — create a bare session (no tab attached) and
    -- focus it. The "Recent Sessions +" button calls this. Body is optional
    -- (provider/model/agent override config defaults when present, matching
    -- POST /api/tabs/new's provider branch).
    (m', ["api", "sessions", "new"]) | m' == methodPost -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleSessionNew deps v
        Nothing -> respond =<< handleSessionNew deps (A.object [])
    -- POST /api/sessions/:id/new — rebind the tab (if any) bound to :id to a
    -- fresh session, and return the new sid + tab_index + rebound flag. The
    -- old session is kept on disk. 404 when :id doesn't resolve to an
    -- on-disk session (matches handleSessionPrompt/handleSessionAgent —
    -- prevents orphan-session spam).
    (m', ["api", "sessions", sid, "new"]) | m' == methodPost ->
      respond =<< handleSessionRebindNew deps sid
    (m', ["api", "tabs", idx, "close"]) | m' == methodPost ->
      respond =<< handleTabRemove deps idx
    (m', ["api", "tabs", idx, "dismiss"]) | m' == methodPost ->
      respond =<< handleTabRemove deps idx
    (m', ["api", "tabs", idx, "acknowledge"]) | m' == methodPost ->
      respond =<< handleTabAck deps idx
    (m', ["api", "tabs", idx, "release"]) | m' == methodPost ->
      respond =<< handleTabAck deps idx
    (m', ["api", "tabs", idx, "destroy"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleTabDestroy deps idx body
    (m', ["api", "adopt"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleAdopt deps body
    (m', _) | m' == methodOptions ->
      respond (responseLBS status200 corsHeaders "")
    _ -> respond (responseLBS status404 [("Content-Type", "application/json")] "{\"error\":\"not found\"}")

-- | Read the entire request body (collect chunks until empty).
collectBody :: Request -> IO BL.ByteString
collectBody req = go []
  where
    go acc = do
      chunk <- getRequestBodyChunk req
      if BC.null chunk
        then pure (BL.fromChunks (reverse acc))
        else go (chunk : acc)

-- | Push a fresh @lists@ snapshot to every WS subscriber. Called after
-- every state change that affects the sidebar partition (W6 broadcast
-- trigger). No-op when 'adBroker' is 'Nothing' (tests without a broker).
-- The WS envelope (@{"type": "lists", ...}@) is added by
-- 'Seal.Gateway.Broadcast.broadcastListsSnapshot'.
triggerBroadcast :: ApiDeps -> IO ()
triggerBroadcast deps =
  case adBroker deps of
    Nothing      -> pure ()
    Just broker  -> broadcastListsSnapshot broker (adTabsHandle deps) (srPaths (adSessionRuntime deps))

-- | Parse the @message@ field from a POST /send body. Returns "" on a
-- missing/invalid body so the agent loop receives an empty turn (the routing
-- grammar treats empty input as 'Plain ""').
parseSendMessage :: BL.ByteString -> Text
parseSendMessage body =
  case A.decode body :: Maybe A.Value of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromText "message") o of
      Just (A.String t) -> t
      _                 -> ""
    _ -> ""

-- | Parse the @url@ field from a POST /setup-repo body. Returns 'Nothing'
-- on a missing/invalid body or a non-string @url@.
parseRepoUrl :: BL.ByteString -> Maybe Text
parseRepoUrl body =
  case A.decode body :: Maybe A.Value of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromText "url") o of
      Just (A.String t) | not (T.null (T.strip t)) -> Just t
      _ -> Nothing
    _ -> Nothing

-- | Handle @POST /api/sessions/:id/setup-repo@: build the response from the
-- 'Either Text CloneResult' returned by 'handleSetupRepo'. 200 on
-- cloned/no-op, 409 on conflict, 503 on clone failure, 400 on an invalid
-- url, 500 on a capability/workdir failure.
handleSetupRepoResponse :: Either Text Text -> Response
handleSetupRepoResponse eRes =
  case eRes of
    Left err -> errJson status400 err
    -- The opcode dispatched + recorded into the transcript. Return
    -- ok:true with the opcode's message text so the frontend can show
    -- it (and the user sees the result in the chat transcript too).
    Right msg -> jsonOk (object [ "ok" .= True, "message" .= msg ])

-- | Map an integer HTTP status code to a 'Status'. The send outcome carries
-- an Int (so 'Seal.Gateway.Send' doesn't depend on @http-types@); this
-- rehydrates it. Unknown codes fall back to 500.
statusFromInt :: Int -> Status
statusFromInt 200 = status200
statusFromInt 400 = status400
statusFromInt 404 = status404
statusFromInt 500 = status500
statusFromInt _   = status500

-- | Parse the @kind@ field from a JSON body.
parseKind :: A.Value -> Maybe Text
parseKind (A.Object o) = case KeyMap.lookup (Key.fromText "kind") o of
  Just (A.String k) -> Just k
  _                 -> Nothing
parseKind _ = Nothing

-- | Parse the @provider@ and @model@ fields from a POST /api/tabs/new body.
-- Defaults to @("ollama", "llama3.2")@ when either is missing — the frontend
-- always sends both (the NewTabComposer preselects them), so the fallback is
-- purely defensive.
parseProviderModel :: A.Value -> (Text, Text)
parseProviderModel v = case v of
  A.Object o ->
    let lookupT k = case KeyMap.lookup (Key.fromText k) o of
          Just (A.String t) | not (T.null t) -> Just t
          _                                   -> Nothing
    in ( fromMaybe "ollama" (lookupT "provider")
       , fromMaybe "llama3.2" (lookupT "model") )
  _ -> ("ollama", "llama3.2")

-- | Parse the optional @agent@ field from a POST /api/tabs/new body into an
-- 'AgentDefId'. Returns 'Nothing' when absent/empty/invalid.
parseAgentField :: A.Value -> Maybe AgentDefId
parseAgentField (A.Object o) =
  case KeyMap.lookup (Key.fromText "agent") o of
    Just (A.String t) | not (T.null t) -> eitherToMaybe (mkAgentDefId t)
    _                                  -> Nothing
  where eitherToMaybe (Right x) = Just x
        eitherToMaybe (Left _)   = Nothing
parseAgentField _ = Nothing

-- | Handle POST /api/tabs/new.
handleTabNew :: ApiDeps -> A.Value -> IO Response
handleTabNew deps v =
  case parseKind v of
    Nothing       -> pure (errJson status400 "missing or invalid 'kind' field")
    Just "shell"  -> pure (errJson status501 "shell/ssh tabs require Phase 4 untrusted execution")
    Just "ssh"    -> pure (errJson status501 "shell/ssh tabs require Phase 4 untrusted execution")
    Just "attach" -> pure (errJson status501 "attach flow goes through /api/adopt")
    Just "provider" -> do
      -- Mint the session id first, then insert the tab, and only persist
      -- session.json AFTER the tab insert succeeds. If the insert fails
      -- (full tab list, or a rare I2 collision), no session.json is left
      -- on disk — otherwise the orphaned session would surface in Recent
      -- Sessions with no tab to back it. newSessionMeta mints the id
      -- without touching disk; saveSessionMeta writes the atomically.
      let paths = srPaths (adSessionRuntime deps)
          (provider, model) = parseProviderModel v
          mAgent = parseAgentField v
      meta <- newSessionMeta paths provider model "web" mAgent
      let sid = smId meta
      res <- insertTabH (adTabsHandle deps) (BoundSession sid) KindProvider Nothing
      case res of
        Left e   -> pure (errJson status400 e)
        Right _  -> do
          saveSessionMeta paths meta
          triggerBroadcast deps
          pure (tabInsertResponse res (Just sid) "session:provider")
    Just "harness" -> do
      hid <- newHarnessId
      let label = parseHarnessLabel v
      res <- insertTabH (adTabsHandle deps) (BoundHarness hid) KindHarness label
      triggerBroadcast deps
      pure (tabInsertResponse res Nothing "harness")
    Just _ -> pure (errJson status400 "unknown 'kind' field")

-- | Handle POST /api/sessions/new — create a bare session (no tab attached)
-- and return its id. The "Recent Sessions +" button calls this. Body is
-- optional; provider/model/agent override the CONFIG defaults when present
-- — so a user who configured `default_provider = "anthropic"` gets
-- anthropic as the default, not a hardcoded fallback. When the body omits
-- a field, the config default applies; when no default agent is
-- configured, the session starts unbound. Does NOT touch TabsHandle.
handleSessionNew :: ApiDeps -> A.Value -> IO Response
handleSessionNew deps v = do
  let paths = srPaths (adSessionRuntime deps)
      cfgPath = srConfigPath (adSessionRuntime deps)
  eCfg <- loadRuntimeConfig cfgPath
  let cfg = fromRight defaultRuntimeConfig eCfg
  (mDefAgent, mDefProv, mDefModel) <- resolveDefaultAgent (adAgentDefs deps) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe (fromMaybe cfgProv mDefProv) (lookupBodyStr "provider")
      model    = fromMaybe (fromMaybe cfgModel mDefModel) (lookupBodyStr "model")
      mAgent = case lookupBodyStr "agent" of
        Just t  -> eitherToMaybe (mkAgentDefId t)
        Nothing -> mDefAgent
  meta <- newSession paths provider model "web" mAgent
  triggerBroadcast deps
  pure (jsonOk (object [ "session_id" .= sessionIdText (smId meta) ]))
  where
    objOf (A.Object o) = Just o
    objOf _            = Nothing
    lookupBodyStr k = case objOf v >>= KeyMap.lookup (Key.fromText k) of
      Just (A.String t) | not (T.null t) -> Just t
      _                                 -> Nothing
    eitherToMaybe (Right x) = Just x
    eitherToMaybe (Left _)  = Nothing

-- | Handle POST /api/sessions/:id/new — rebind the tab (if any) bound to
-- :id to a fresh session, and return the new sid + tab_index + rebound
-- flag. The old session is kept on disk (still in /session list). 404 when
-- :id doesn't resolve to an on-disk session (prevents orphan-session spam;
-- matches handleSessionPrompt/handleSessionAgent).
handleSessionRebindNew :: ApiDeps -> Text -> IO Response
handleSessionRebindNew deps sidTxt =
  case mkSessionId sidTxt of
    Left e  -> pure (errJson status400 ("invalid session id: " <> e))
    Right oldSid -> do
      let paths = srPaths (adSessionRuntime deps)
          mp = sessionMetaPath paths oldSid
      exists <- doesFileExist mp
      if not exists
        then pure (errJson status404 "session not found")
        else do
          mOldMeta <- decodeFileStrict mp :: IO (Maybe SessionMeta)
          case mOldMeta of
            Nothing -> pure (errJson status404 "session not found")
            Just oldMeta -> do
              meta <- newSession paths (smProvider oldMeta) (smModel oldMeta) "web" (smAgent oldMeta)
              let newSid = smId meta
              snap <- snapshotTabs (adTabsHandle deps)
              case [ t | t <- tlTabs snap, tRef t == BoundSession oldSid ] of
                []       -> do
                  triggerBroadcast deps
                  pure (jsonOk (object
                    [ "session_id" .= sessionIdText newSid
                    , "tab_index" .= (Nothing :: Maybe Int)
                    , "rebound" .= False
                    ]))
                (tab : _) -> do
                  r <- rebindTabH (adTabsHandle deps) (tIndex tab) (BoundSession newSid)
                  case r of
                    Left e -> pure (errJson status400 ("tab rebind failed: " <> e))
                    Right _ -> do
                      triggerBroadcast deps
                      pure (jsonOk (object
                        [ "session_id" .= sessionIdText newSid
                        , "tab_index" .= tabIndexToInt (tIndex tab)
                        , "rebound" .= True
                        ]))

-- | Handle PUT /api/sessions/:id/archived. Sets or clears the archive flag
-- via 'updateSessionArchived'. Returns 200 {ok:true} on success, 404 when
-- the session has no @session.json@ on disk.
handleSessionArchived :: ApiDeps -> SessionId -> Bool -> IO Response
handleSessionArchived deps sid archived = do
  ok <- updateSessionArchived (srPaths (adSessionRuntime deps)) sid archived
  if ok then triggerBroadcast deps >> pure (jsonOk (object ["ok" .= True]))
        else pure (errJson status404 "session not found")

-- | Handle PUT /api/sessions/:id/description. Parses the @description@
-- field from the body (an empty/missing/whitespace value clears it),
-- and persists via 'updateSessionDescription'. Triggers a lists broadcast
-- so the sidebar picks up the new label without a refresh. Returns 200
-- {ok:true} on success, 404 when the session has no @session.json@ on
-- disk, 400 on invalid JSON.
handleSessionDescription :: ApiDeps -> SessionId -> BL.ByteString -> IO Response
handleSessionDescription deps sid body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> do
      let mDesc = case v of
            A.Object o -> case KeyMap.lookup (Key.fromText "description") o of
              Just (A.String t) -> Just t
              _                 -> Nothing
            _ -> Nothing
      ok <- updateSessionDescription (srPaths (adSessionRuntime deps)) sid mDesc
      if ok then triggerBroadcast deps >> pure (jsonOk (object ["ok" .= True]))
            else pure (errJson status404 "session not found")

-- | Handle GET /api/sessions/:id/agents — the session-scoped agent-defs
-- list (workdir ⊕ user, workdir-wins). Returns 200 + the unioned
-- @AgentInfo[]@ with @isDefault@ per §3.2:
--
--   1. If the user's configured @default_agent@ resolves (id is in the
--      union), that def is @isDefault=true@.
--   2. Else if @agents-md@ (the repo's @.agents\/agents.md@) is in the
--      union, it is @isDefault=true@ (the repo default fallback).
--   3. Else no entry is marked default.
--
-- 404 for an unknown session (no @session.json@). 200 + user-only defs for
-- a known session with an empty/missing workdir (the workdir contributes
-- @[]@). Reuses 'agentInfoJson' for the wire shape so the frontend's
-- 'AgentInfo'/'AgentDefInfo' types deserialize unchanged.
handleSessionAgents :: ApiDeps -> SessionId -> IO Response
handleSessionAgents deps sid = do
  let paths = srPaths (adSessionRuntime deps)
      metaPath = sessionMetaPath paths sid
  exists <- doesFileExist metaPath
  if not exists
    then pure (errJson status404 "session not found")
    else do
      let wd = sessionWorkdir paths sid
      workdirBackend <- workdirAgentDefBackend wd
      let unionBackend = unionAgentDefBackend workdirBackend (adAgentDefs deps)
      defs <- adbList unionBackend
      mDefaultId <- adDefaultAgent deps
      -- Precedence: repo agents.md > user default_agent > none. The repo's
      -- project-level agents.md is the initial selection when it exists
      -- (it carries the project's intended persona); the user's configured
      -- default_agent is the fallback when no repo agents.md is present.
      let mUserDefault = mDefaultId >>= rightToMaybe . mkAgentDefId
          mEffectiveDefault
            | Just agentsMd <- agentsMdInUnion defs = Just agentsMd
            | userDefaultResolves defs mUserDefault = mUserDefault
            | otherwise = Nothing
      pure (jsonLBS status200 (A.encode (map (agentInfoJson (fmap agentDefIdText mEffectiveDefault)) defs)))
  where
    userDefaultResolves ds (Just aid) = any ((== aid) . adId) ds
    userDefaultResolves _ Nothing = False
    -- The repo default is the prefixed agents-md def (e.g.
    -- @vtag--agents-md@). The prefix is the repo's top-level dir name, which
    -- varies per session, so we match by the @"--agents-md"@ suffix rather
    -- than the bare 'deriveAgentsMdId'. Returns the full prefixed id so the
    -- @isDefault@ flag is set on the right def.
    agentsMdInUnion ds =
      case [ adId d | d <- ds, "--agents-md" `T.isSuffixOf` agentDefIdText (adId d) ] of
        (aid:_) -> Just aid
        []      -> Nothing
    rightToMaybe (Right a) = Just a
    rightToMaybe (Left _) = Nothing

-- | Parse the @archived@ boolean field from a PUT /api/sessions/:id/archived
-- body. Returns 'Nothing' when the body is invalid JSON or the field is
-- missing/non-boolean.
parseArchivedFlag :: BL.ByteString -> Maybe Bool
parseArchivedFlag body =
  case A.decode body :: Maybe A.Value of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromText "archived") o of
      Just (A.Bool b) -> Just b
      _               -> Nothing
    _ -> Nothing

-- | Handle PUT /api/sessions/:id/prompt. Parses the @prompt@ field from
-- the body (an empty/missing value clears the override), trims it, and
-- persists via 'updateSessionSystemOverride'. The optional @name@ field
-- is a fallback display label (e.g. the uploaded filename) used when the
-- file content has no TOML frontmatter @id@. Returns 200 {ok:true} on
-- success, 404 when the session has no @session.json@ on disk, 400 on
-- invalid JSON.
handleSessionPrompt :: ApiDeps -> SessionId -> BL.ByteString -> IO Response
handleSessionPrompt deps sid body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> do
      let (mPrompt, mName) = case v of
            A.Object o ->
              let p = case KeyMap.lookup (Key.fromText "prompt") o of
                    Just (A.String t)
                      | not (T.null (T.strip t)) -> Just t
                      | otherwise                -> Nothing
                    _                            -> Nothing
                  n = case KeyMap.lookup (Key.fromText "name") o of
                    Just (A.String t)
                      | not (T.null (T.strip t)) -> Just (T.strip t)
                      | otherwise                -> Nothing
                    _                            -> Nothing
              in (p, n)
            _ -> (Nothing, Nothing)
      ok <- updateSessionSystemOverride (srPaths (adSessionRuntime deps)) sid mPrompt mName
      pure (if ok then jsonOk (object ["ok" .= True])
                  else errJson status404 "session not found")

-- | Handle PUT /api/sessions/:id/agent. Parses the @agent@ field from the
-- body (an empty/missing value clears the binding), validates it as an
-- 'AgentDefId', and persists the change via 'updateSessionAgent'. Returns
-- 200 {ok:true} on success, 404 when the session has no @session.json@ on
-- disk, 400 on an invalid agent id or JSON.
handleSessionAgent :: ApiDeps -> SessionId -> BL.ByteString -> IO Response
handleSessionAgent deps sid body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseAgentBinding v of
      AgentClear -> do
        ok <- updateSessionAgent (srPaths (adSessionRuntime deps)) sid Nothing
        pure (if ok then jsonOk (object ["ok" .= True])
                    else errJson status404 "session not found")
      AgentSet aid -> do
        ok <- updateSessionAgent (srPaths (adSessionRuntime deps)) sid (Just aid)
        pure (if ok then jsonOk (object ["ok" .= True])
                    else errJson status404 "session not found")
      AgentInvalid e -> pure (errJson status400 ("invalid agent id: " <> e))

-- | Parse the @agent@ field for PUT /api/sessions/:id/agent. Distinguishes
-- "absent/empty" (clear the binding) from "present but malformed" (400).
data AgentBinding = AgentClear | AgentSet AgentDefId | AgentInvalid Text
parseAgentBinding :: A.Value -> AgentBinding
parseAgentBinding (A.Object o) =
  case KeyMap.lookup (Key.fromText "agent") o of
    Nothing                 -> AgentClear
    Just (A.String t)
      | T.null (T.strip t)  -> AgentClear
      | otherwise           -> case mkAgentDefId t of
                                 Right aid -> AgentSet aid
                                 Left e    -> AgentInvalid e
    Just _                  -> AgentInvalid "expected a string"
parseAgentBinding _ = AgentClear

-- ── Agent CRUD ───────────────────────────────────────────────────────────

-- | Handle GET /api/agents/:id. Returns 200 + the def on success, 404 when
-- the def is absent, 400 on a malformed id.
handleAgentGet :: ApiDeps -> Text -> IO Response
handleAgentGet deps aidTxt =
  case mkAgentDefId aidTxt of
    Left e  -> pure (errJson status400 ("invalid agent id: " <> e))
    Right aid -> do
      m <- adbRead (adAgentDefs deps) aid
      case m of
        Nothing -> pure (errJson status404 "agent not found")
        Just d  -> do
          mDef <- adDefaultAgent deps
          pure (jsonOk (agentInfoJson mDef d))

-- | Handle POST /api/agents. The body carries @id@, optional @name@
-- (defaults to the id), @provider@, @model@, @system@, @tools@. Provenance
-- fields (@created_at@ / @updated_at@ / @session@) are stamped server-side
-- so the client cannot forge them. The id must pass 'isValidAgentDefId'.
-- An existing def with the same id is REPLACED (matches the idempotent
-- 'adbUpdate' semantics). Returns 201 + the created def.
handleAgentCreate :: ApiDeps -> BL.ByteString -> IO Response
handleAgentCreate deps body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseAgentIdField v of
      Left e -> pure (errJson status400 ("invalid or missing 'id': " <> e))
      Right aid -> do
        d <- stampAgentDef deps aid v Nothing
        adbUpdate (adAgentDefs deps) d
        broadcastAgentDefsChanged (adBroker deps)
        mDef <- adDefaultAgent deps
        pure (jsonCreated (agentInfoJson mDef d))

-- | Handle PUT /api/agents/:id. The path id is authoritative for finding
-- the existing def; the body may carry a @new_id@ field to RENAME the def
-- (the old id is deleted, the new one is written — provenance is
-- preserved). Without @new_id@ the id is unchanged. The body may also
-- supply @name@ / @provider@ / @model@ / @system@ / @tools@. Returns 200 +
-- the updated def, 404 when no def exists at the path id, 400 on a bad id
-- or invalid @new_id@.
handleAgentUpdate :: ApiDeps -> Text -> BL.ByteString -> IO Response
handleAgentUpdate deps aidTxt body =
  case mkAgentDefId aidTxt of
    Left e -> pure (errJson status400 ("invalid agent id: " <> e))
    Right aid -> do
      mExisting <- adbRead (adAgentDefs deps) aid
      case mExisting of
        Nothing -> pure (errJson status404 "agent not found")
        Just existing -> case A.decode body :: Maybe A.Value of
          Nothing -> pure (errJson status400 "invalid JSON body")
          Just v  -> case parseRenameId v of
            Just (Left e) -> pure (errJson status400 ("invalid new_id: " <> e))
            Just (Right newId) | newId /= aid -> do
              d <- stampAgentDef deps newId v (Just existing)
              adbUpdate (adAgentDefs deps) d
              adbDelete (adAgentDefs deps) aid
              broadcastAgentDefsChanged (adBroker deps)
              mDef <- adDefaultAgent deps
              pure (jsonOk (agentInfoJson mDef d))
            _ -> do
              d <- stampAgentDef deps aid v (Just existing)
              adbUpdate (adAgentDefs deps) d
              broadcastAgentDefsChanged (adBroker deps)
              mDef <- adDefaultAgent deps
              pure (jsonOk (agentInfoJson mDef d))

-- | Parse an optional @new_id@ field from a JSON body for rename-on-PUT.
-- Returns 'Nothing' when the field is absent or @null@; @Just (Left err)@
-- on a malformed value; @Just (Right aid)@ on a valid 'AgentDefId'.
parseRenameId :: A.Value -> Maybe (Either Text AgentDefId)
parseRenameId (A.Object o) =
  case KeyMap.lookup (Key.fromText "new_id") o of
    Nothing              -> Nothing
    Just A.Null          -> Nothing
    Just (A.String t)
      | T.null (T.strip t) -> Nothing
      | otherwise         -> Just (mkAgentDefId t)
    Just _               -> Just (Left "new_id must be a string")
parseRenameId _ = Nothing

-- | Handle DELETE /api/agents/:id. Idempotent: 204 whether or not the def
-- existed. 400 on a malformed id.
handleAgentDelete :: ApiDeps -> Text -> IO Response
handleAgentDelete deps aidTxt =
  case mkAgentDefId aidTxt of
    Left e  -> pure (errJson status400 ("invalid agent id: " <> e))
    Right aid -> do
      adbDelete (adAgentDefs deps) aid
      pure noContent

-- | Handle GET /api/agents/default. Returns 200 + {"agent": "<id>"} or
-- {"agent": null} when no default is configured.
handleAgentGetDefault :: ApiDeps -> IO Response
handleAgentGetDefault deps = do
  mDef <- adDefaultAgent deps
  pure (jsonOk (A.object [ "agent" .= mDef ]))

-- | Handle PUT /api/agents/default. Body: {"agent":"<id>"} to set,
-- {"agent":null} or {} to clear. Persists to config.toml via
-- 'updateRuntimeConfig' so the change survives restarts. The named agent
-- must exist (404 otherwise) so users can't set a default to a def that
-- isn't on disk. 400 on a malformed id or invalid JSON.
handleAgentSetDefault :: ApiDeps -> BL.ByteString -> IO Response
handleAgentSetDefault deps body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseDefaultAgentBody v of
      DefaultClear -> do
        let cfgPath = srConfigPath (adSessionRuntime deps)
        eRes <- updateRuntimeConfig cfgPath (\cfg -> cfg { rcDefaultAgent = Nothing })
        case eRes of
          Left e  -> pure (errJson status500 ("config write failed: " <> e))
          Right _ -> do
            broadcastAgentDefsChanged (adBroker deps)
            pure (jsonOk (A.object [ "agent" .= (Nothing :: Maybe Text) ]))
      DefaultSet aidTxt -> case mkAgentDefId aidTxt of
        Left e -> pure (errJson status400 ("invalid agent id: " <> e))
        Right aid -> do
          m <- adbRead (adAgentDefs deps) aid
          case m of
            Nothing -> pure (errJson status404 "agent not found")
            Just _ -> do
              let cfgPath = srConfigPath (adSessionRuntime deps)
                  val = agentDefIdText aid
              eRes <- updateRuntimeConfig cfgPath (\cfg -> cfg { rcDefaultAgent = Just val })
              case eRes of
                Left e  -> pure (errJson status500 ("config write failed: " <> e))
                Right _ -> pure (jsonOk (A.object [ "agent" .= val ]))
      DefaultInvalid -> pure (errJson status400 "expected 'agent' to be a string or null")

-- | Parse the @agent@ field from a PUT /api/agents/default body.
data DefaultAgentBinding = DefaultClear | DefaultSet Text | DefaultInvalid
parseDefaultAgentBody :: A.Value -> DefaultAgentBinding
parseDefaultAgentBody (A.Object o) =
  case KeyMap.lookup (Key.fromText "agent") o of
    Nothing              -> DefaultClear
    Just A.Null          -> DefaultClear
    Just (A.String t)
      | T.null (T.strip t) -> DefaultClear
      | otherwise         -> DefaultSet t
    Just _               -> DefaultInvalid
parseDefaultAgentBody _ = DefaultClear

-- | Build an 'AgentDef' from a JSON body + the authoritative id. When
-- @mExisting@ is 'Just', provenance (@created_at@ / @session@) is preserved
-- from the existing def; otherwise both are stamped now (@session@ = @"web"@).
-- @updated_at@ is always re-stamped. The body may supply @name@ (defaults to
-- the id), @provider@ (default @""@), @model@ (default @""@), @system@
-- (default 'Nothing' when absent or @null@), and @tools@ (default 'AllowAll').
stampAgentDef :: ApiDeps -> AgentDefId -> A.Value -> Maybe AgentDef -> IO AgentDef
stampAgentDef _deps aid v mExisting = do
  now <- getCurrentTime
  let o = case v of A.Object o' -> o'; _ -> KeyMap.empty
      lookupStr k = case KeyMap.lookup (Key.fromText k) o of
        Just (A.String t) -> Just t
        _                 -> Nothing
      lookupVal k = KeyMap.lookup (Key.fromText k) o
      nm          = fromMaybe (agentDefIdText aid) (lookupStr "name")
      provider    = fromMaybe "" (lookupStr "provider")
      model       = ModelId (fromMaybe "" (lookupStr "model"))
      mSystem     = case lookupVal "system" of
        Just (A.String t) | not (T.null t) -> Just t
        Just A.Null                        -> Nothing
        Nothing                            -> Nothing
        _                                  -> Nothing
      tools       = maybe AllowAll allowListFromValue (lookupVal "tools")
      createdAt   = maybe now adCreatedAt mExisting
      session     = maybe (mkSystemSessionId "web") adSession mExisting
  pure AgentDef
    { adId        = aid
    , adName      = nm
    , adProvider  = provider
    , adModel     = model
    , adSystem    = mSystem
    , adTools     = tools
    , adCreatedAt = createdAt
    , adUpdatedAt = now
    , adSession   = session
    }

-- | Parse the @id@ field from a POST /api/agents body. Returns 'Left' with
-- an error message when absent, empty, or fails 'isValidAgentDefId'.
parseAgentIdField :: A.Value -> Either Text AgentDefId
parseAgentIdField (A.Object o) =
  case KeyMap.lookup (Key.fromText "id") o of
    Just (A.String t)
      | not (T.null (T.strip t)) -> case mkAgentDefId t of
                                      Right aid -> Right aid
                                      Left e    -> Left e
      | otherwise                -> Left "id is empty"
    Just _                       -> Left "id must be a string"
    Nothing                      -> Left "id is required"
parseAgentIdField _ = Left "id is required"

-- ── Skill CRUD ───────────────────────────────────────────────────────────

-- | Handle GET /api/skills/:id. Returns 200 + the skill on success, 404
-- when absent, 400 on a malformed id.
handleSkillGet :: ApiDeps -> Text -> IO Response
handleSkillGet deps sidTxt =
  case mkSkillId sidTxt of
    Left e  -> pure (errJson status400 ("invalid skill id: " <> e))
    Right sid -> do
      m <- sbRead (adSkills deps) sid
      case m of
        Nothing -> pure (errJson status404 "skill not found")
        Just s  -> pure (jsonOk (skillInfoJson s))

-- | Handle POST /api/skills. The body carries @id@, @description@, and
-- @body@. Provenance (@created_at@ / @updated_at@ / @session@) is stamped
-- server-side. An existing skill with the same id is REPLACED (matches the
-- idempotent 'sbCreate' semantics). Returns 201 + the created skill.
handleSkillCreate :: ApiDeps -> BL.ByteString -> IO Response
handleSkillCreate deps body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseSkillIdField v of
      Left e -> pure (errJson status400 ("invalid or missing 'id': " <> e))
      Right sid -> do
        s <- stampSkill sid v Nothing
        sbCreate (adSkills deps) s
        broadcastSkillsChanged (adBroker deps)
        pure (jsonCreated (skillInfoJson s))

-- | Handle PUT /api/skills/:id. The path id is authoritative for finding
-- the existing skill; the body may carry a @new_id@ field to RENAME the
-- skill (old id deleted, new one written — provenance preserved). Without
-- @new_id@ the id is unchanged. Returns 200 + the updated skill, 404 when
-- no skill exists at the path id, 400 on a bad id or invalid @new_id@.
handleSkillUpdate :: ApiDeps -> Text -> BL.ByteString -> IO Response
handleSkillUpdate deps sidTxt body =
  case mkSkillId sidTxt of
    Left e -> pure (errJson status400 ("invalid skill id: " <> e))
    Right sid -> do
      mExisting <- sbRead (adSkills deps) sid
      case mExisting of
        Nothing -> pure (errJson status404 "skill not found")
        Just existing -> case A.decode body :: Maybe A.Value of
          Nothing -> pure (errJson status400 "invalid JSON body")
          Just v  -> case parseSkillRenameId v of
            Just (Left e) -> pure (errJson status400 ("invalid new_id: " <> e))
            Just (Right newSid) | newSid /= sid -> do
              s <- stampSkill newSid v (Just existing)
              sbUpdate (adSkills deps) s
              sbDelete (adSkills deps) sid
              broadcastSkillsChanged (adBroker deps)
              pure (jsonOk (skillInfoJson s))
            _ -> do
              s <- stampSkill sid v (Just existing)
              sbUpdate (adSkills deps) s
              broadcastSkillsChanged (adBroker deps)
              pure (jsonOk (skillInfoJson s))

-- | Parse an optional @new_id@ field for rename-on-PUT of a skill.
-- 'Nothing' when absent/null/empty; @Just (Left err)@ on a malformed
-- value; @Just (Right sid)@ on a valid 'SkillId'.
parseSkillRenameId :: A.Value -> Maybe (Either Text SkillId)
parseSkillRenameId (A.Object o) =
  case KeyMap.lookup (Key.fromText "new_id") o of
    Nothing              -> Nothing
    Just A.Null          -> Nothing
    Just (A.String t)
      | T.null (T.strip t) -> Nothing
      | otherwise         -> Just (mkSkillId t)
    Just _               -> Just (Left "new_id must be a string")
parseSkillRenameId _ = Nothing

-- | Handle DELETE /api/skills/:id. Idempotent: 204 whether or not the
-- skill existed. 400 on a malformed id.
handleSkillDelete :: ApiDeps -> Text -> IO Response
handleSkillDelete deps sidTxt =
  case mkSkillId sidTxt of
    Left e  -> pure (errJson status400 ("invalid skill id: " <> e))
    Right sid -> do
      sbDelete (adSkills deps) sid
      broadcastSkillsChanged (adBroker deps)
      pure noContent

-- | Build a 'Skill' from a JSON body + the authoritative id. When
-- @mExisting@ is 'Just', provenance (@created_at@ / @session@) is preserved
-- from the existing skill; otherwise both are stamped now (@session@ =
-- @"web"@). @updated_at@ is always re-stamped. The body may supply
-- @description@ (default @""@) and @body@ (default @""@).
stampSkill :: SkillId -> A.Value -> Maybe Skill -> IO Skill
stampSkill sid v mExisting = do
  now <- getCurrentTime
  let o = case v of A.Object o' -> o'; _ -> KeyMap.empty
      lookupStr k = case KeyMap.lookup (Key.fromText k) o of
        Just (A.String t) -> Just t
        _                 -> Nothing
      description = fromMaybe "" (lookupStr "description")
      body        = fromMaybe "" (lookupStr "body")
      mGroup      = T.strip <$> lookupStr "group"
      group_      = case (mGroup, mExisting) of
        (Just g, _) | not (T.null g) -> Just g
        (Nothing, Just ex)           -> skGroup ex
        _                            -> Nothing
      createdAt   = maybe now skCreatedAt mExisting
      session     = maybe (mkSystemSessionId "web") skSession mExisting
  pure Skill
    { skId          = sid
    , skDescription = description
    , skBody        = body
    , skGroup       = group_
    , skCreatedAt   = createdAt
    , skUpdatedAt   = now
    , skSession     = session
    }

-- | Parse the @id@ field from a POST /api/skills body. Returns 'Left' with
-- an error message when absent, empty, or fails 'mkSkillId'.
parseSkillIdField :: A.Value -> Either Text SkillId
parseSkillIdField (A.Object o) =
  case KeyMap.lookup (Key.fromText "id") o of
    Just (A.String t)
      | not (T.null (T.strip t)) -> case mkSkillId t of
                                       Right sid -> Right sid
                                       Left e    -> Left e
       | otherwise                -> Left "id is empty"
    Just _                       -> Left "id must be a string"
    Nothing                      -> Left "id is required"
parseSkillIdField _ = Left "id is required"

-- ── Repo CRUD ─────────────────────────────────────────────────────────────

-- | Map a 'SourceRepo' to the frontend's repo descriptor JSON. Uses the W1
-- 'ToJSON SourceRepo' instance (the credential object carries only vault
-- key /names/ + a public username — never secret bytes).
repoInfoJson :: SourceRepo -> Value
repoInfoJson = A.toJSON

-- | Handle GET /api/repos/:id. Returns 200 + the repo on success, 404 when
-- absent, 400 on a malformed id.
handleRepoGet :: ApiDeps -> Text -> IO Response
handleRepoGet deps ridTxt =
  case mkRepoId ridTxt of
    Left e  -> pure (errJson status400 ("invalid repo id: " <> e))
    Right rid -> do
      eRepos <- rrhList (adRepoRegistry deps)
      case eRepos of
        Left err -> pure (errJson status500 err)
        Right rs -> case findRepo rid rs of
          Nothing -> pure (errJson status404 "repo not found")
          Just r  -> pure (jsonOk (repoInfoJson r))

-- | Handle POST /api/repos. The body carries @id@, @url@, @vcs_kind@, and a
-- @credential@ object (@{kind, vault_key, username?}@). Validates the id
-- ('mkRepoId'), URL shape ('urlShapeValid'), host allow-list
-- ('parseRepoHost' + 'hostAllowed'), VCS kind, and credential kind. An
-- existing repo with the same id is REPLACED (idempotent upsert, mirrors
-- 'handleSkillCreate'). Returns 201 + the created descriptor. After a
-- successful write, a best-effort @gitCommitAll@ audit-commits
-- @repos.toml@ (a commit failure is swallowed — the registry write already
-- succeeded) and a @repos-changed@ WS broadcast is fired.
handleRepoCreate :: ApiDeps -> BL.ByteString -> IO Response
handleRepoCreate deps body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseRepoFromBody v of
      Left e -> pure (errJson status400 e)
      Right repo -> do
        -- Check for generate_key: true (iff credential.kind == deploy_key).
        let genKey = case v of
              A.Object o -> case KeyMap.lookup (Key.fromText "generate_key") o of
                Just (A.Bool True) -> True
                _                  -> False
              _ -> False
            isDeployKey = case srCredential repo of
              CredDeployKey _ -> True
              _              -> False
        if genKey && isDeployKey
          then do
            -- Generate the keypair + store the repo with the public key.
            mh <- readIORef (vrHandleRef (adVault deps))
            case mh of
              Nothing -> pure (errJson status500 "vault locked — run /vault unlock")
              Just vh -> do
                let keyfilePath = repoKeysDir (adPaths deps) </> T.unpack (repoIdText (srId repo))
                    vaultKey = cVaultKey (srCredential repo)
                eGen <- generateDeployKey vh vaultKey keyfilePath (repoIdText (srId repo))
                case eGen of
                  Left err -> pure (errJson status500 err)
                  Right pub -> do
                    let repo' = repo { srDeployKeyPublic = Just pub
                                     , srKeyfilePath = Just (T.pack keyfilePath) }
                    eRes <- rrhMutate (adRepoRegistry deps) (upsertRepo repo')
                    case eRes of
                      Left err -> pure (errJson status500 err)
                      Right _  -> do
                        bestEffortCommitRepos deps
                        broadcastReposChanged (adBroker deps)
                        pure (jsonCreated (repoInfoJson repo'))
          else do
            -- Standard upsert (no key generation).
            eRes <- rrhMutate (adRepoRegistry deps) (upsertRepo repo)
            case eRes of
              Left err -> pure (errJson status500 err)
              Right _  -> do
                bestEffortCommitRepos deps
                broadcastReposChanged (adBroker deps)
                pure (jsonCreated (repoInfoJson repo))

-- | Handle PUT /api/repos/:id. The path id is authoritative; the body must
-- carry @url@, @vcs_kind@, and @credential@ (the id may be omitted — it is
-- taken from the path). The id must ALREADY exist (404 otherwise); ids are
-- stable (no @new_id@ rename). Returns 200 + the updated descriptor on
-- success. Same validation + best-effort commit + broadcast as Create.
handleRepoUpdate :: ApiDeps -> Text -> BL.ByteString -> IO Response
handleRepoUpdate deps ridTxt body =
  case mkRepoId ridTxt of
    Left e  -> pure (errJson status400 ("invalid repo id: " <> e))
    Right rid -> do
      eRepos <- rrhList (adRepoRegistry deps)
      case eRepos of
        Left err -> pure (errJson status500 err)
        Right rs
          | not (any ((== rid) . srId) rs) -> pure (errJson status404 "repo not found")
          | otherwise -> case A.decode body :: Maybe A.Value of
              Nothing -> pure (errJson status400 "invalid JSON body")
              Just v  -> case parseRepoWithId rid v of
                Left e -> pure (errJson status400 e)
                Right repo -> do
                  eRes <- rrhMutate (adRepoRegistry deps) (upsertRepo repo)
                  case eRes of
                    Left err -> pure (errJson status500 err)
                    Right _  -> do
                      bestEffortCommitRepos deps
                      broadcastReposChanged (adBroker deps)
                      pure (jsonOk (repoInfoJson repo))

-- | Handle DELETE /api/repos/:id. Idempotent: 204 whether or not the repo
-- existed. 400 on a malformed id. Best-effort @gitCommitAll@ + broadcast
-- after a successful mutation.
handleRepoDelete :: ApiDeps -> Text -> IO Response
handleRepoDelete deps ridTxt =
  case mkRepoId ridTxt of
    Left e  -> pure (errJson status400 ("invalid repo id: " <> e))
    Right rid -> do
      -- Look up the repo BEFORE deleting (to get the keyfile path + vault key
      -- for cleanup).
      eRepos <- rrhList (adRepoRegistry deps)
      case eRepos of
        Left err -> pure (errJson status500 err)
        Right rs -> do
          let mRepo = findRepo rid rs
          -- Delete the encrypted keyfile + .pub (if present) + the vault
          -- passphrase (best-effort — swallow IO errors so a missing file
          -- doesn't block the delete).
          case mRepo of
            Just repo | CredDeployKey vk <- srCredential repo -> do
              -- Delete the encrypted keyfile + .pub.
              case srKeyfilePath repo of
                Just p -> void (try @SomeException (do
                  let path = T.unpack p
                  _ <- try @SomeException (removeFile path) :: IO (Either SomeException ())
                  _ <- try @SomeException (removeFile (path <> ".pub")) :: IO (Either SomeException ())
                  pure ()))
                Nothing -> pure ()
              -- Delete the passphrase from the vault (best-effort).
              mh <- readIORef (vrHandleRef (adVault deps))
              case mh of
                Just vh -> void (try @SomeException (vhDelete vh vk))
                Nothing -> pure ()
            _ -> pure ()
          -- Delete the repo from the registry.
          _eRes <- rrhMutate (adRepoRegistry deps) (removeRepo rid)
          case _eRes of
            Left err -> pure (errJson status500 err)
            Right _  -> do
              bestEffortCommitRepos deps
              broadcastReposChanged (adBroker deps)
              pure noContent

-- | Best-effort @gitCommitAll repos.toml@ after a registry mutation. The
-- registry write already succeeded (atomic write+rename), so a commit
-- failure (missing repo, git not on PATH, nothing to commit) is swallowed
-- — wrapped in @try @SomeException@ so it never propagates to the HTTP
-- response.
bestEffortCommitRepos :: ApiDeps -> IO ()
bestEffortCommitRepos deps =
  void (try @SomeException (gitCommitAll (adConfigRepo deps) "repos.toml" "seal: update repo registry"))

-- | Find a repo by id within a loaded list (the registry handle exposes
-- only @rrhList@, so a single-repo lookup filters the whole list).
findRepo :: RepoId -> [SourceRepo] -> Maybe SourceRepo
findRepo rid = foldr (\r acc -> if srId r == rid then Just r else acc) Nothing

-- | Parse a 'SourceRepo' from a POST /api/repos body. The @id@ field is
-- authoritative and validated via 'mkRepoId'. Validates URL shape, host
-- allow-list, VCS kind, and credential kind; returns a 'Left' error message
-- on any validation failure.
parseRepoFromBody :: A.Value -> Either Text SourceRepo
parseRepoFromBody v@(A.Object o) = do
  ridTxt <- case KeyMap.lookup (Key.fromText "id") o of
    Just (A.String t) | not (T.null (T.strip t)) -> Right t
    Just (A.String _) -> Left "id is empty"
    Just _            -> Left "id must be a string"
    Nothing           -> Left "id is required"
  rid <- mkRepoId ridTxt
  parseRepoWithId rid v
parseRepoFromBody _ = Left "id is required"

-- | Parse a 'SourceRepo' from a JSON body when the 'RepoId' is already
-- known (e.g. taken from the PUT path). Validates @url@, @vcs_kind@, and
-- @credential@. The @id@ field in the body (if present) is ignored — the
-- path id wins.
parseRepoWithId :: RepoId -> A.Value -> Either Text SourceRepo
parseRepoWithId rid (A.Object o) = do
  url <- case KeyMap.lookup (Key.fromText "url") o of
    Just (A.String t) | not (T.null (T.strip t)) -> Right t
    Just (A.String _) -> Left "url is empty"
    Just _            -> Left "url must be a string"
    Nothing           -> Left "url is required"
  -- URL shape (SSH scp-form or HTTPS) — guards against malformed input
  -- before the host allow-list check.
  unlessRight (urlShapeValid url) "url is neither SSH (git@<host>:...) nor HTTPS (https://<host>/...)"
  -- Host allow-list (GitHub-first). A URL whose parsed host is not in
  -- 'githubHosts' is rejected with 400.
  host <- parseRepoHost url
  unlessRight (hostAllowed host) ("host not allowed: " <> host)
  vcsKindTxt <- case KeyMap.lookup (Key.fromText "vcs_kind") o of
    Just (A.String t) | not (T.null (T.strip t)) -> Right t
    Just (A.String _) -> Left "vcs_kind is empty"
    Just _            -> Left "vcs_kind must be a string"
    Nothing           -> Left "vcs_kind is required"
  vcsKind <- parseVcsKind vcsKindTxt
  cred <- case KeyMap.lookup (Key.fromText "credential") o of
    Just (A.Object co) -> parseCredentialObj co
    Just _             -> Left "credential must be an object"
    Nothing            -> Left "credential is required"
  Right SourceRepo { srId = rid, srUrl = url, srVcsKind = vcsKind, srCredential = cred
                   , srDeployKeyPublic = Nothing, srKeyfilePath = Nothing }
parseRepoWithId _ _ = Left "invalid JSON body"

-- | Parse the @credential@ object (@{kind, vault_key, username?}@) into a
-- 'RepoCredential' via 'parseCredentialKind'.
parseCredentialObj :: KeyMap.KeyMap A.Value -> Either Text RepoCredential
parseCredentialObj co = do
  kind <- case KeyMap.lookup (Key.fromText "kind") co of
    Just (A.String t) | not (T.null (T.strip t)) -> Right t
    Just (A.String _) -> Left "credential.kind is empty"
    Just _            -> Left "credential.kind must be a string"
    Nothing           -> Left "credential.kind is required"
  vaultKey <- case KeyMap.lookup (Key.fromText "vault_key") co of
    Just (A.String t) | not (T.null (T.strip t)) -> Right t
    Just (A.String _) -> Left "credential.vault_key is empty"
    Just _            -> Left "credential.vault_key must be a string"
    Nothing           -> Left "credential.vault_key is required"
  mUsername <- case KeyMap.lookup (Key.fromText "username") co of
    Just (A.String t) -> Right (Just t)
    Just A.Null       -> Right Nothing
    Just _            -> Left "credential.username must be a string"
    Nothing           -> Right Nothing
  parseCredentialKind kind vaultKey mUsername

-- | Fail with @err@ when the predicate is @False@, otherwise pass through.
unlessRight :: Bool -> Text -> Either Text ()
unlessRight True _  = Right ()
unlessRight False e = Left e

-- | Encode the persisted 'UiState' for GET /api/ui/state. The shape mirrors
-- the on-disk JSON: an object with @last_options@ (the LastOptions record)
-- and @custom_models@ (a list of strings, most-recent first).
uiStateJson :: UiState -> Value
uiStateJson s = object
  [ "last_options"  .= usLastOptions s
  , "custom_models" .= usCustomModels s
  , "repo_history"  .= usRepoHistory s
  ]

-- | Handle PUT /api/ui/state. The body is the @last_options@ object (the
-- frontend's NewTabSpec shape). Decodes the `kind` field defensively (the
-- frontend always sends it); an invalid body yields a 400.
handleUiStatePut :: ApiDeps -> A.Value -> IO Response
handleUiStatePut deps v =
  case A.fromJSON v :: A.Result LastOptions of
    A.Success opts -> do
      setLastOptions (adUiState deps) opts
      pure (jsonOk (object ["ok" .= True]))
    A.Error err     -> pure (errJson status400 ("invalid last_options: " <> T.pack err))

-- | Handle POST /api/ui/custom-models. The body is @{"model":"<id>"}@. A
-- blank/missing model is a no-op success (the frontend shouldn't send one,
-- but the store is defensive).
handleUiCustomModelAdd :: ApiDeps -> A.Value -> IO Response
handleUiCustomModelAdd deps v = do
  let mModel = parseModelField v
  case mModel of
    Nothing -> pure (errJson status400 "missing 'model' field")
    Just m  -> do
      addCustomModel (adUiState deps) m
      pure (jsonOk (object ["ok" .= True]))

-- | Parse the @model@ field from a JSON body.
parseModelField :: A.Value -> Maybe Text
parseModelField (A.Object o) = case KeyMap.lookup (Key.fromText "model") o of
  Just (A.String t) -> Just t
  _                -> Nothing
parseModelField _ = Nothing

-- | Handle POST /api/ui/repos. The body is @{"url":"<url>"}@. A
-- blank/missing url is a no-op success (the frontend shouldn't send one,
-- but the store is defensive).
handleUiRepoAdd :: ApiDeps -> A.Value -> IO Response
handleUiRepoAdd deps v = do
  let mUrl = parseUrlField v
  case mUrl of
    Nothing -> pure (errJson status400 "missing 'url' field")
    Just u  -> do
      addRepoHistory (adUiState deps) u
      pure (jsonOk (object ["ok" .= True]))

-- | Parse the @url@ field from a JSON body.
parseUrlField :: A.Value -> Maybe Text
parseUrlField (A.Object o) = case KeyMap.lookup (Key.fromText "url") o of
  Just (A.String t) -> Just t
  _                 -> Nothing
parseUrlField _ = Nothing

-- | Parse the @harness_id@ field (the flavour-name or @custom:<binary>@
-- encoding) into the tab's label.
parseHarnessLabel :: A.Value -> Maybe Text
parseHarnessLabel (A.Object o) = case KeyMap.lookup (Key.fromText "harness_id") o of
  Just (A.String h) -> Just h
  _                 -> Nothing
parseHarnessLabel _ = Nothing

-- | Build the 200 response for a tab insert (Right idx) or a 400 error
-- (Left err). The body is the widened NewTabResponse.
tabInsertResponse :: Either Text TabIndex -> Maybe SessionId -> Text -> Response
tabInsertResponse (Left e) _ _ = errJson status400 e
tabInsertResponse (Right idx) mSid kind =
  jsonOk (object
    [ "tab_index" .= tabIndexToInt idx
    , "session_id" .= (sessionIdText <$> mSid)
    , "kind" .= kind
    ])

-- | Handle POST /api/tabs/:index/close + /dismiss (remove the tab).
-- Snapshots the tab's 'TabRef' before removing so attached channels can be
-- notified via 'adTabCloseNotifier'.
handleTabRemove :: ApiDeps -> Text -> IO Response
handleTabRemove deps idxTxt =
  case parseIndex idxTxt of
    Nothing   -> pure (errJson status400 "invalid tab index")
    Just idx  -> do
      mRef <- tabRefAt (adTabsHandle deps) idx
      r <- removeTabH (adTabsHandle deps) idx
      case r of
        Left _  -> pure (errJson status404 "tab index out of range")
        Right _ -> do
          triggerBroadcast deps
          maybe (pure ()) (adTabCloseNotifier deps) mRef
          pure noContent

-- | Handle POST /api/tabs/:index/acknowledge + /release (no-op for T10).
handleTabAck :: ApiDeps -> Text -> IO Response
handleTabAck deps idxTxt =
  case parseIndex idxTxt of
    Nothing   -> pure (errJson status400 "invalid tab index")
    Just _idx -> triggerBroadcast deps >> pure noContent

-- | Handle POST /api/tabs/:index/destroy (remove + delete from registry if
-- harness; for T10 just remove). Notifies attached channels via
-- 'adTabCloseNotifier' (same as close).
handleTabDestroy :: ApiDeps -> Text -> BL.ByteString -> IO Response
handleTabDestroy deps idxTxt _body =
  case parseIndex idxTxt of
    Nothing   -> pure (errJson status400 "invalid tab index")
    Just idx  -> do
      mRef <- tabRefAt (adTabsHandle deps) idx
      r <- removeTabH (adTabsHandle deps) idx
      case r of
        Left _  -> pure (errJson status404 "tab index out of range")
        Right _ -> do
          triggerBroadcast deps
          maybe (pure ()) (adTabCloseNotifier deps) mRef
          pure noContent

-- | Handle POST /api/adopt (consent-gated; the actual adoption wiring is
-- Phase 6a's domain).
handleAdopt :: ApiDeps -> BL.ByteString -> IO Response
handleAdopt deps body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseConsent v of
      Nothing       -> pure (errJson status400 "consent_confirmed is required")
      Just consent  -> case authorizeAdoption (adAdoptConsent deps) consent of
        Left AeConsentMissing      -> pure (errJson status400 "consent_confirmed is required")
        Left AeHeadlessNoConsent   -> pure (errJson status403 "headless runs cannot confirm adoption consent")
        Left (AeAlreadyManaged _)  -> pure (errJson status403 "window already managed")
        Right ()                   -> pure (jsonOk (object ["ok" .= True, "session_id" .= (Nothing :: Maybe Text)]))

-- | Parse the @consent_confirmed@ field from a JSON body.
parseConsent :: A.Value -> Maybe Bool
parseConsent (A.Object o) = case KeyMap.lookup (Key.fromText "consent_confirmed") o of
  Just (A.Bool b) -> Just b
  _               -> Nothing
parseConsent _ = Nothing

-- | Parse a tab index from its text form (a non-negative integer).
parseIndex :: Text -> Maybe TabIndex
parseIndex t =
  case decimal t of
    Right (n, rest) | T.null rest, n >= 0 ->
      case mkTabIndex n of
        Right idx -> Just idx
        Left _    -> Nothing
    _ -> Nothing

-- | Look up the 'TabRef' at a tab index ('Nothing' if out of range). Used
-- by close/destroy to snapshot the backing ref before removal so attached
-- channels can be notified.
tabRefAt :: TabsHandle -> TabIndex -> IO (Maybe TabRef)
tabRefAt h idx = do
  tl <- snapshotTabs h
  pure (tRef <$> lookupTab tl idx)

-- | T11: handle GET /api/sessions/:id/transcript. Returns the session's
-- transcript as the frontend's @TranscriptEntry@ shape
-- (@id@/@timestamp@/@direction@/@payload@/@model@/@harness@/@raw@).
--
-- Two on-disk formats are supported:
--   1. The legacy @transcript.jsonl@ (one Haskell 'TranscriptEntry' per line,
--      @te*@-prefixed fields). Each line is mapped to the frontend shape.
--   2. The new two-file @conversation.jsonl@ (one 'Message' per line,
--      @msgRole@/@msgContent@). Each line is synthesized into a
--      @TranscriptEntry@-shaped JSON (User → request, Assistant → response);
--      timestamps/model are not available in this file so they're set to
--      the session's @smCreatedAt@/@smModel@ from @session.json@.
--
-- Missing files -> @[]@; unparseable lines are skipped.
--
-- Emits a @Server-Timing@ header (per <https://www.w3.org/TR/server-timing/>)
-- with per-phase durations (file-read / parse / reconstruct / rewrite / total)
-- and the transcript source (legacy / conv+entries / conv-only / missing) +
-- entry count. The frontend parses this via @performance.getEntriesByName@ or
-- by reading the @Server-Timing@ response header directly to direct
-- optimization work without needing a separate tracing harness.
handleTranscript :: ApiDeps -> Text -> IO Response
handleTranscript deps sidTxt =
  case mkSessionId sidTxt of
    Left _  -> pure (jsonLBS status200 (A.encode ([] :: [Value])))
    Right sid -> do
      let paths = srPaths (adSessionRuntime deps)
      active <- readIORef (srActive (adSessionRuntime deps))
      tReadStart <- getCurrentTime
      (entries, tt0) <- readTranscriptEntriesTimed paths (smModel active) (showIso (smCreatedAt active)) sid
      tEncStart <- getCurrentTime
      let body = A.encode entries
      tEncEnd <- getCurrentTime
      -- Fold the encode duration + the gap between read-complete and
      -- encode-start (negligible) into the timings so the @en@ token
      -- reflects the JSON-serialization cost and @tt@ reflects the full
      -- read+encode cost. This is where the slow tab's time is hiding —
      -- A.encode of a deeply-nested Value tree (web_fetch tool_result
      -- carrying full page HTML) is pathologically slow on large strings.
      let tt = setEncodeMs (msDiff tEncStart tEncEnd) (msDiff tReadStart tEncEnd) tt0
          timingHeader = (mkHN "Server-Timing", renderServerTiming tt)
      pure (responseLBS status200 (corsHeaders <> [jsonHeader, timingHeader]) body)
  where
    msDiff a b = round (realToFrac (b `diffUTCTime` a) * 1000 :: Double)

-- | Handle GET /api/sessions/:id/questions. Returns the session's pending
-- ASK_HUMAN questions as JSON objects (@id@/@question@/@createdAt@/@meta?@/
-- @options?@), oldest first. Requires 'adSend' (the 'AskReplyStore' lives on
-- 'SendDeps'); returns @[]@ when unwired or the session id is invalid.
handleListQuestions :: ApiDeps -> Text -> IO Response
handleListQuestions deps sidTxt =
  case mkSessionId sidTxt of
    Left _ -> pure (jsonLBS status200 (A.encode ([] :: [Value])))
    Right sid -> case adSend deps of
      Nothing -> pure (jsonLBS status200 (A.encode ([] :: [Value])))
      Just sendDeps -> do
        pending <- pendingForSession (sdAskReply sendDeps) sid
        let vals = map questionJson pending
        pure (jsonLBS status200 (A.encode vals))
  where
    questionJson info =
      let base = [ "id" .= askIdText (pqiId info)
                 , "question" .= pqiQuestion info
                 , "createdAt" .= pqiCreatedAt info
                 ]
          withMeta = case pqiMeta info of
            Nothing -> base
            Just m  -> base ++ ["meta" .= m]
          withOptions = case pqiOptions info of
            [] -> withMeta
            os -> withMeta ++ ["options" .= os]
      in object withOptions

-- | Map an 'AgentDef' to the frontend's 'AgentInfo' JSON shape. @isDefault@
-- is a UI convenience resolved by id against the configured
-- @default_agent@ id (threaded via 'adDefaultAgent'). The @name@ field
-- carries the agent's id (not the human-readable display name) so the
-- frontend can echo it back as @body.agent@ / PUT /agent and the backend
-- can re-validate it via 'mkAgentDefId'. The display name lives in the
-- def's frontmatter and isn't needed by the dropdown.
--
-- The full def (provider/model/system/tools/timestamps) is included so the
-- Agents CRUD UI can render + edit every field without a second round-trip.
-- The @tools@ field uses the same wire shape as 'AgentDef''s JSON instance:
-- @"all"@ or an array of opcode-name strings.
agentInfoJson :: Maybe Text -> AgentDef -> Value
agentInfoJson mDefaultId d = A.object
  [ "name" .= agentDefIdText (adId d)
  , "isDefault" .= (Just (agentDefIdText (adId d)) == mDefaultId)
  , "id" .= agentDefIdText (adId d)
  , "displayName" .= adName d
  , "provider" .= adProvider d
  , "model" .= adModel d
  , "system" .= adSystem d
  , "tools" .= allowListToValue (adTools d)
  , "created_at" .= adCreatedAt d
  , "updated_at" .= adUpdatedAt d
  , "session" .= adSession d
  ]

-- | Render an 'AllowList OpName' as a JSON value: @"all"@ for 'AllowAll', or
-- an array of opcode-name strings for 'AllowOnly'. Mirrors the instance in
-- "Seal.Agent.Def.Types" but inlined here to avoid an orphan instance.
allowListToValue :: AllowList OpName -> Value
allowListToValue AllowAll       = String "all"
allowListToValue (AllowOnly xs) = A.toJSON (map unOpNameText (Set.toList xs))
  where unOpNameText (OpName t) = t

-- | Decode an 'AllowList OpName' from @"all"@, an array of opcode-name
-- strings, or @null@/missing (treated as 'AllowAll').
allowListFromValue :: Value -> AllowList OpName
allowListFromValue (String "all") = AllowAll
allowListFromValue (A.Array xs)   = AllowOnly (Set.fromList [ OpName t | String t <- V.toList xs ])
allowListFromValue _               = AllowAll

-- | Map a 'Skill' to the frontend's 'SkillInfo' JSON shape (snake_case keys
-- match the wire convention used elsewhere). The body is included in full
-- so the Skills CRUD UI can render + edit it without a second round-trip.
skillInfoJson :: Skill -> Value
skillInfoJson s = A.object
  [ "id" .= skillIdText (skId s)
  , "description" .= skDescription s
  , "body" .= skBody s
  , "created_at" .= skCreatedAt s
  , "updated_at" .= skUpdatedAt s
  , "session" .= skSession s
  ]

-- | A 201 Created with a JSON body + CORS headers.
jsonCreated :: Value -> Response
jsonCreated v = responseLBS status201 (corsHeaders <> [jsonHeader]) (A.encode v)

-- | Map a 'KnownProvider' to the frontend's 'ProviderInfo' JSON shape. T11
-- emits only @name@; @isDefault@ / @defaultModel@ are UI conveniences not
-- threaded into 'ApiDeps' for T11.
providerInfoJson :: KnownProvider -> Value
providerInfoJson p = object ["name" .= providerLabel p]

-- | T11: the STATIC model list for a provider. The real @/v1/models@
-- upstream call needs vault credentials + a live HTTP request and is out of
-- scope. Unknown providers -> @[]@. Each model's @contextWindow@ comes from
-- 'Seal.Providers.ContextWindow'.
providerModelsJson :: Text -> [Value]
providerModelsJson pTxt =
  case parseProvider pTxt of
    Nothing -> []
    Just p  -> map (modelEntryJson p) (staticModelsFor p)

-- | The static model id list for a provider (T11 best-known table).
staticModelsFor :: KnownProvider -> [Text]
staticModelsFor AnthropicProvider =
  [ "claude-sonnet-4-20250514"
  , "claude-opus-4-8"
  , "claude-haiku-4-5"
  ]
staticModelsFor OllamaProvider = ["llama3.2", "llama3.1"]

-- | One model entry: @{name, contextWindow}@.
modelEntryJson :: KnownProvider -> Text -> Value
modelEntryJson _p mName = object
  [ "name" .= mName
  , "contextWindow" .= modelContextWindow mName
  ]

-- | A 200 OK with a JSON body + CORS headers.
jsonOk :: Value -> Response
jsonOk v = jsonLBS status200 (A.encode v)

-- | A response with a raw JSON bytestring + CORS headers.
jsonLBS :: Status -> BL.ByteString -> Response
jsonLBS st = responseLBS st (corsHeaders <> [jsonHeader])

-- | A 204 No Content (no body).
noContent :: Response
noContent = responseLBS status204 corsHeaders ""

-- | A JSON error response with a status code.
errJson :: Status -> Text -> Response
errJson st msg = responseLBS st (corsHeaders <> [jsonHeader])
  (A.encode (object ["error" .= msg]))

----------------------------------------------------------------------------
-- Deploy-key generation endpoints (W5)
----------------------------------------------------------------------------

-- | The JSON shape returned by GET /api/repos/:id/deploy-key and POST
-- /api/repos/:id/deploy-key/generate: @{public_key, setup_instructions}@.
deployKeyInfoJson :: Text -> Text -> Value
deployKeyInfoJson pubKey instructions =
  object [ "public_key" .= pubKey, "setup_instructions" .= instructions ]

-- | Host-aware setup instructions for a deploy key. GitHub repos get the
-- GitHub-specific template; others get a generic fallback interpolating
-- the URL + host.
deployKeyInstructions :: Text -> Text
deployKeyInstructions url =
  case parseRepoHost url of
    Right host | host == "github.com" ->
      "Go to your GitHub repo → Settings → Deploy keys → Add deploy key. Paste the public key above. Do NOT check \"Allow write access\" unless you need push. The key is ready immediately — no further action needed."
    Right host ->
      "Add the public key above to your " <> host <> " repo's deploy-key settings. The key is ready immediately."
    Left _ ->
      "Add the public key above to your repo's deploy-key settings."

-- | Handle GET /api/repos/:id/deploy-key. Returns 200 + the deploy-key
-- public key + host-aware setup instructions. 404 if the repo is absent or
-- not a deploy-key repo (srDeployKeyPublic is Nothing). 400 on a malformed id.
handleRepoDeployKey :: ApiDeps -> Text -> IO Response
handleRepoDeployKey deps ridTxt =
  case mkRepoId ridTxt of
    Left e  -> pure (errJson status400 ("invalid repo id: " <> e))
    Right rid -> do
      eRepos <- rrhList (adRepoRegistry deps)
      case eRepos of
        Left err -> pure (errJson status500 err)
        Right rs -> case findRepo rid rs of
          Nothing -> pure (errJson status404 "repo not found")
          Just r  -> case srDeployKeyPublic r of
            Nothing -> pure (errJson status404 "repo has no deploy key (not a deploy-key repo, or key not generated)")
            Just pk -> pure (jsonOk (deployKeyInfoJson pk (deployKeyInstructions (srUrl r))))

-- | Handle POST /api/repos/:id/deploy-key/generate. Rotation: generate a
-- new random 32-byte passphrase (base64) → vhPut under the SAME vault key
-- name → ssh-keygen overwrites the encrypted keyfile → read the .pub →
-- upsert the SourceRepo with the new srDeployKeyPublic. Returns 200 + the
-- new public key + instructions. 404 if the repo is absent or not a
-- deploy-key repo. 400 on a malformed id. 500 if the vault is locked or
-- ssh-keygen fails.
handleRepoDeployKeyGenerate :: ApiDeps -> Text -> IO Response
handleRepoDeployKeyGenerate deps ridTxt =
  case mkRepoId ridTxt of
    Left e  -> pure (errJson status400 ("invalid repo id: " <> e))
    Right rid -> do
      eRepos <- rrhList (adRepoRegistry deps)
      case eRepos of
        Left err -> pure (errJson status500 err)
        Right rs -> case findRepo rid rs of
          Nothing -> pure (errJson status404 "repo not found")
          Just r  -> case srCredential r of
            CredDeployKey _ -> do
              -- Resolve the vault handle.
              mh <- readIORef (vrHandleRef (adVault deps))
              case mh of
                Nothing -> pure (errJson status500 "vault locked — run /vault unlock")
                Just vh -> do
                  -- Generate a new passphrase + overwrite the keyfile.
                  let keyfilePath = T.unpack (fromMaybe (T.pack (repoKeysDir (adPaths deps) </> T.unpack (repoIdText rid))) (srKeyfilePath r))
                      vaultKey = cVaultKey (srCredential r)
                  eGen <- generateDeployKey vh vaultKey keyfilePath (repoIdText rid)
                  case eGen of
                    Left err -> pure (errJson status500 err)
                    Right newPub -> do
                      -- Upsert the repo with the new public key.
                      let r' = r { srDeployKeyPublic = Just newPub
                                 , srKeyfilePath = Just (T.pack keyfilePath) }
                      eRes <- rrhMutate (adRepoRegistry deps) (upsertRepo r')
                      case eRes of
                        Left err -> pure (errJson status500 err)
                        Right _  -> do
                          bestEffortCommitRepos deps
                          broadcastReposChanged (adBroker deps)
                          pure (jsonOk (deployKeyInfoJson newPub (deployKeyInstructions (srUrl r))))
            _ -> pure (errJson status404 "repo is not a deploy-key repo")

-- | Generate a new deploy keypair: random 32-byte passphrase (base64) →
-- vhPut the passphrase under the vault key → ssh-keygen -t ed25519 -f
-- <keyfilePath> -N "<passphrase>" -C "seal-deploy-key:<id>" → read the .pub
-- file. Returns 'Just <pubkey>' on success, 'Left <err>' on failure. The
-- encrypted keyfile is ciphertext (stays on the harness disk; the
-- passphrase lives in the vault). The .pub is public data.
generateDeployKey :: VaultHandle -> Text -> FilePath -> Text -> IO (Either Text Text)
generateDeployKey vh vaultKey keyfilePath repoId = do
  -- Ensure the parent directory exists (ssh-keygen won't create it).
  let keyfilesDir = takeDirectory keyfilePath
  createDirectoryIfMissing True keyfilesDir
  -- Generate a random 32-byte passphrase, base64-encoded.
  rawPass <- randomByteString 32
  let passphrase = TE.decodeUtf8Lenient (B64.encode rawPass)
  -- Store the passphrase in the vault.
  ePut <- vhPut vh vaultKey (TE.encodeUtf8 passphrase)
  case ePut of
    Left ve -> pure (Left ("vault put failed: " <> T.pack (show ve)))
    Right _ -> do
      -- Run ssh-keygen to overwrite the encrypted keyfile + .pub.
      let args = ["-t", "ed25519", "-f", keyfilePath, "-N", T.unpack passphrase
                 , "-C", "seal-deploy-key-" <> T.unpack repoId]
      (ec, _out, err) <- readCreateProcessWithExitCode (proc "ssh-keygen" args) ""
      case ec of
        ExitSuccess -> do
          -- Read the .pub file.
          let pubPath = keyfilePath <> ".pub"
          pubExists <- doesFileExist pubPath
          if pubExists
            then do
              pubBytes <- BS.readFile pubPath
              pure (Right (TE.decodeUtf8Lenient pubBytes))
            else pure (Left "ssh-keygen succeeded but .pub file not found")
        ExitFailure n -> pure (Left ("ssh-keygen failed (exit " <> T.pack (show n) <> "): " <> T.pack err))

-- | Generate a random ByteString of the given length.
randomByteString :: Int -> IO ByteString
randomByteString n = BS.pack <$> replicateM n (randomRIO (0, 255))

----------------------------------------------------------------------------
-- CORS headers
corsHeaders :: [Header]
corsHeaders =
  [ (mkHN "Access-Control-Allow-Origin", "*")
  , (mkHN "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
  , (mkHN "Access-Control-Allow-Headers", "Content-Type")
  ]

jsonHeader :: Header
jsonHeader = (mkHN "Content-Type", "application/json")

-- | Make a HeaderName from a String.
mkHN :: String -> HeaderName
mkHN = CI.mk . BC.pack