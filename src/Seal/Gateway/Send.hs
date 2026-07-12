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
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))

import Seal.Agent.Def.Backend (adbRead)
import Seal.Agent.Def.Types (adSystem)
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), execBackendFromFile, mkSessionAgentEnv )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.File
  ( FileConfig, defaultRetrievalMaxScanBytes, loadFileConfig, retrievalMaxScanBytes
  , fcDebugSessionTranscript )
import Seal.Config.Paths (SealPaths, sessionDir, sessionRequestsPath)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), SessionId)
import Seal.Git.Repo (ConfigRepo)
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
  , agentInstancesOp, agentStatusOp, agentStopOp )
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.Code (codeExecOp)
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class (SomeProvider)
import Seal.Routing.Route (ParseError (..), RoutingDecision (..), route)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast)
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Security.Path (WorkspaceRoot (..))
import qualified Seal.Security.Policy as Policy (AutonomyLevel (..), SecurityPolicy (..), AllowList (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
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
-- and uses a no-op 'ChannelCaps' (the web frontend reads replies from the
-- transcript poll, not from ccSend).
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
        wsRoot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath (sdProvider deps))
        let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsRoot) eCfg
            defaultExecBackend = EbLocal mkLocalExecHandlePlaceholder  -- fail-closed default
            agentDefBackend = bAgentDefs (sdBackends deps)
        mSystem <- case smAgent meta of
          Nothing -> pure Nothing
          Just aid -> maybe Nothing adSystem <$> adbRead agentDefBackend aid
        let isaReg = buildWebRegistry
              (sdVault deps) (sdBackends deps) wsRoot sid operatorCeiling
              execBackend (sdAutonomy deps)
            caps = ChannelCaps
              { ccSend = \_ -> pure ()  -- web: replies surface via transcript poll
              , ccPrompt = \_ -> pure ""  -- web can't prompt inline (deferral is a later phase)
              , ccPromptSecret = \_ -> pure ""
              }
            env = mkSessionAgentEnv
              caps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
              (debugPath (sdPaths deps) sid eCfg)
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        result <- runApp appEnv (runTurn env t)
        broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta)
        pure result)

-- | Build the ISA registry for a web turn. Mirrors
-- 'Seal.Channels.Signal.Run.buildRegistry' (no AGENT_START worker over the
-- web; sub-agents over the web is a later phase). Includes the Untrusted
-- execution opcodes (SHELL_EXEC, CODE_EXEC, PROCESS_MANAGE, FILE_WRITE,
-- FILE_PATCH, SEARCH_FILES) wired to the per-session 'ExecBackend' and a
-- 'SecurityPolicy' derived from the CLI autonomy level. HARNESS_* opcodes
-- are omitted (they need tmux infrastructure not available over the web).
buildWebRegistry
  :: VaultRuntime -> Backends -> WorkspaceRoot -> SessionId -> Int
  -> ExecBackend -> Policy.AutonomyLevel -> ISA.Registry
buildWebRegistry rt backends wsRoot sid operatorCeiling execBackend autonomy =
  ISA.mkRegistry
    [ showHumanOp simpleCaps
    , askHumanOp simpleCaps
    , fileReadOp wsRoot operatorCeiling
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
    , agentStatusOp (bRuntime backends)
    , agentStopOp (bRuntime backends)
    , shellExecOp wsRoot securityPolicy execBackend
    , codeExecOp wsRoot securityPolicy codeAllowList execBackend
    , processManageOp wsRoot securityPolicy execBackend
    , fileWriteOp wsRoot operatorCeiling
    , filePatchOp wsRoot
    , searchFilesOp wsRoot securityPolicy operatorCeiling execBackend
    ]
  where
    securityPolicy = Policy.SecurityPolicy Policy.AllowAll autonomy
    codeAllowList = Set.fromList ["python3", "node", "bash", "sh"]
    simpleCaps = ChannelCaps
      { ccSend = \_ -> pure ()
      , ccPrompt = \_ -> pure ""
      , ccPromptSecret = \_ -> pure ""
      }

-- | Run a slash command. The output is collected via a 'ChannelCaps' whose
-- 'ccSend' appends to an MVar-backed list, then returned as the @response@.
runSlash :: SendDeps -> SessionMeta -> Text -> IO SendOutcome
runSlash deps meta fullLine = do
  outVar <- newMVar ([] :: [Text])
  let caps = ChannelCaps
        { ccSend = \t' -> modifyMVar_ outVar (\acc -> pure (acc <> [t']))
        , ccPrompt = \_ -> pure ""
        , ccPromptSecret = \_ -> pure ""
        }
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
        let isaReg = buildWebRegistry (sdVault deps) (sdBackends deps) wsRoot sid operatorCeiling
              execBackend (sdAutonomy deps)
            env = mkSessionAgentEnv
              caps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
              (debugPath (sdPaths deps) sid eCfg)
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        result <- runApp appEnv (runTurn env t)
        broadcastNewEntries (sdBroker deps) paths sid (modelText model) (smCreatedAt meta)
        pure result)

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