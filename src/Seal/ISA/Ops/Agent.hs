{-# LANGUAGE OverloadedStrings #-}
-- | The Agent opcode group: three Audited definition opcodes
-- (@AGENT_DEF_WRITE@, @AGENT_DEF_READ@, @AGENT_DEF_LIST@, @AGENT_DEF_DELETE@)
-- and four Trusted lifecycle opcodes (@AGENT_INSTANCES@, @AGENT_START@,
-- @AGENT_STATUS@, @AGENT_STOP@, @AGENT_INTERRUPT@). Only the *definition*
-- mutations are Audited — running an instance is harness-internal, not an
-- evolutionary mutation, so the lifecycle ops are Trusted.
--
-- @AGENT_DEF_WRITE@ is an upsert: if the def already exists, its name/system/
-- tools are updated (the original 'adSession' provenance and 'adCreatedAt' are
-- preserved; only 'adUpdatedAt' is bumped); if not, a fresh def is created.
-- This merges the former AGENT_DEF_CREATE + AGENT_DEF_UPDATE into a single
-- opcode. @orRecorded@ carries a @was_new@ flag so the audit log still
-- distinguishes create vs update.
--
-- @AGENT_INSTANCES@ (renamed from @AGENT_LIST@) snapshots the in-process agent
-- runtime (running instances), NOT the definitions. @AGENT_DEF_LIST@ lists the
-- definitions. The rename stops the confusion between "list definitions" and
-- "list running instances".
--
-- @AGENT_START@ is the Seal analog of Hermes' @delegate_task@: it spawns one
-- or more child agents with isolated context, runs each against a goal to
-- completion (synchronously), and returns a structured JSON result per child.
-- The parent blocks until all children finish (or time out). See
-- 'Seal.Agent.Runtime.Delegation' for the full feature list. The opcode is a
-- thin shim over 'runDelegate' — it normalizes the model's input, resolves the
-- def, delegates the worker construction to the wiring layer's
-- 'AgentWorkerBuilder', and serializes the 'ChildResult' list to JSON.
module Seal.ISA.Ops.Agent
  ( agentDefWriteOp
  , agentDefManageOp
  , agentManageOp
  , agentDefReadOp
  , agentDefListOp
  , agentDefDeleteOp
  , agentInstancesOp
  , agentStartOp
  , agentStatusOp
  , agentStopOp
  , agentInterruptOp
  , AgentWorkerBuilder
  , AgentStartWiring (..)
  , AgentStartGate (..)
  , gateOpen
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value (..), object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Vector qualified as V

import Seal.Agent.Def.Backend (AgentDefBackend (..))
import Seal.Agent.Def.Types
  ( AgentDef (..), mkAgentDefId, agentDefIdText
  , sanitizeAgentDefFields, sanitizeAgentTextField, agentFieldCapSmall
  )
import Seal.Agent.Runtime.Delegation.Worker (effectiveRole)
import Seal.Agent.Runtime.Delegation
  ( AgentWorkerBuilder
  , AgentCompletionCallback
  , SpawnCallback
  , ChildResult (..)
  , ChildTask (..)
  , DelegationConfig
  , DelegateInput (..)
  , SpawnInfo (..)
  , SpawnPauseFlag
  , ParentActivity
  , SubagentId (..)
  , resolveDelegationConfig
  , runDelegateAsync
  , subagentIdText
  )
import Seal.Agent.Runtime.Registry
  ( AgentInstance (..), AgentRuntime, AgentStatus (..)
  , agentInstanceBySubagentId
  , interruptAgent, listAgents
  , registerCompletedAgentResult, registerRunningAgent, stopAgent )
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, TrustLevel (..), sessionIdText)
import Seal.Types.App (App)
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AllowList (..))

-- ---------------------------------------------------------------------------
-- Worker-builder type
-- ---------------------------------------------------------------------------

-- (The 'AgentWorkerBuilder' type is re-exported from
-- 'Seal.Agent.Runtime.Delegation'; the wiring layer imports it from here for
-- convenience.)
-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Extract the @id@ string field from a JSON object.
idField :: Value -> Maybe Text
idField = parseMaybe (withObject "in" (.: "id"))

-- | Extract a required text field (defaults to empty when absent).
textField :: Text -> Value -> Text
textField name v = fromMaybe "" (parseMaybe (withObject "in" (.: fromText name)) v)

-- | Extract an optional text field (defaults to 'Nothing' when absent).
textFieldMaybe :: Text -> Value -> Maybe Text
textFieldMaybe name v =
  case parseMaybe (withObject "in" (.:? fromText name)) v :: Maybe (Maybe Text) of
    Just (Just t) -> Just t
    _             -> Nothing

-- | Decode the @tools@ field: @\"all\"@ (or absent) -> 'AllowAll'; an array of
-- opcode-name strings -> 'AllowOnly'. Malformed -> 'AllowAll' (permissive).
toolsField :: Value -> AllowList OpName
toolsField v =
  case parseMaybe (withObject "in" (.:? "tools")) v :: Maybe (Maybe Value) of
    Just (Just (String "all")) -> AllowAll
    Just (Just (Array xs))     -> AllowOnly (Set.fromList [ OpName t | String t <- V.toList xs ])
    _                          -> AllowAll

-- | Resolve the @group@ field from the opcode input, preserving the existing
-- def's group when the input omits it (mirrors the gateway @stampAgentDef@
-- and the skill @stampSkill@ back-compat policy). An explicit empty string
-- clears the group (sets 'Nothing'); a non-empty stripped value sets it.
groupField :: Value -> Maybe AgentDef -> Maybe Text
groupField v mExisting =
  case textFieldMaybe "group" v of
    Just g  -> let g' = T.strip g in if T.null g' then Nothing else Just g'
    Nothing -> adGroup =<< mExisting

-- ---------------------------------------------------------------------------
-- Action enum (AGENT_DEF_MANAGE)
-- ---------------------------------------------------------------------------

data AgentDefAction = AdWrite | AdRead | AdList | AdDelete

parseAgentDefAction :: Value -> Either Text AgentDefAction
parseAgentDefAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "write"  -> Right AdWrite
      "read"   -> Right AdRead
      "list"   -> Right AdList
      "delete" -> Right AdDelete
      other    -> Left ("unknown agent def action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- | Shared id validator (used by write/read/delete).
checkAgentDefId :: Text -> Either Text ()
checkAgentDefId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- | Authorize gate for AGENT_DEF_MANAGE — dispatches per-action validation.
authorizeAgentDefManage :: Value -> Either Text ()
authorizeAgentDefManage v =
  case parseAgentDefAction v of
    Left e -> Left e
    Right action -> case action of
      AdWrite  -> authorizeDefWrite v
      AdRead   -> maybe (Left "read requires {id:string}") checkAgentDefId . idField $ v
      AdList   -> Right ()
      AdDelete -> maybe (Left "delete requires {id:string}") checkAgentDefId . idField $ v

-- | Authorize the write action (shared with the legacy AGENT_DEF_WRITE shim).
authorizeDefWrite :: Value -> Either Text ()
authorizeDefWrite v =
  case idField v of
    Nothing -> Left "AGENT_DEF_WRITE requires {id:string}"
    Just idTxt -> case checkAgentDefId idTxt of
      Left e -> Left e
      Right () -> case T.strip <$> textFieldMaybe "role" v of
        Nothing -> Right ()
        Just "" -> Right ()
        Just r
          | r == "orchestrator" || r == "leaf" -> Right ()
          | otherwise ->
            Left ("AGENT_DEF_WRITE: role must be \"orchestrator\" or \"leaf\" (got: " <> r <> ")")

-- | Handle the write action (shared with the legacy AGENT_DEF_WRITE shim).
handleDefWrite :: AgentDefBackend -> SessionId -> Value -> App OpResult
handleDefWrite backend session v = do
  let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      roleField vv = case T.strip <$> textFieldMaybe "role" vv of
        Just ""  -> Nothing
        r        -> r
  case mId of
    Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
    Just aid -> do
      mExisting <- liftIO (adbRead backend aid)
      now <- liftIO getCurrentTime
      let (def0, wasNew) = case mExisting of
            Just existing ->
              ( existing
                  { adName = textField "name" v
                  , adSystem = textFieldMaybe "system" v
                  , adTools = toolsField v
                  , adGroup = groupField v (Just existing)
                  , adRole = roleField v
                  , adDescription = sanitizeAgentTextField agentFieldCapSmall <$> textFieldMaybe "description" v
                  , adUpdatedAt = now
                  }
              , False
              )
            Nothing ->
              ( AgentDef
                  { adId = aid
                  , adName = textField "name" v
                  , adProvider = textField "provider" v
                  , adModel = ModelId (textField "model" v)
                  , adSystem = textFieldMaybe "system" v
                  , adTools = toolsField v
                  , adGroup = groupField v Nothing
                  , adRole = roleField v
                  , adDescription = sanitizeAgentTextField agentFieldCapSmall <$> textFieldMaybe "description" v
                  , adCreatedAt = now
                  , adUpdatedAt = now
                  , adSession = session
                  }
              , True
              )
          def = sanitizeAgentDefFields def0
          unknownTools =
            case adTools def of
              AllowOnly xs ->
                [ t | OpName t <- Set.toList xs, Set.notMember t knownOpNames ]
              AllowAll -> []
      liftIO (adbUpdate backend def)
      let recorded = encodeDefRecorded def wasNew unknownTools
      pure (OpResult [TrpText (if wasNew then "defined" else "updated")] False recorded)

-- | Handle the read action (shared with the legacy AGENT_DEF_READ shim).
handleDefRead :: AgentDefBackend -> Value -> App OpResult
handleDefRead backend v = do
  let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
  case mId of
    Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
    Just aid -> do
      mDef <- liftIO (adbRead backend aid)
      case mDef of
        Nothing -> pure (OpResult [TrpText "agent def not found"] True (object ["id" .= agentDefIdText aid]))
        Just d  -> do
          let rendered = renderDef d
              recorded = encodeDefRecorded d False []
          pure (OpResult [TrpText rendered] False recorded)

-- | Handle the list action (shared with the legacy AGENT_DEF_LIST shim).
handleDefList :: AgentDefBackend -> App OpResult
handleDefList backend = do
  defs <- liftIO (adbList backend)
  let rendered = case defs of
        [] -> "(no agent definitions)"
        _  -> T.intercalate "\n"
                [ agentDefIdText (adId d) <> roleSuffix (adRole d) <> ": " <> adName d
                    <> " (" <> adProvider d <> "/" <> modelName <> ")"
                | d <- defs, let ModelId modelName = adModel d ]
      recorded = object
        [ "count" .= length defs
        , "ids" .= fmap (agentDefIdText . adId) defs
        , "roles" .= object
            [ fromText (agentDefIdText (adId d)) .= adRole d | d <- defs ]
        ]
  pure (OpResult [TrpText rendered] False recorded)

-- | Handle the delete action (shared with the legacy AGENT_DEF_DELETE shim).
handleDefDelete :: AgentDefBackend -> Value -> App OpResult
handleDefDelete backend v = do
  let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
  case mId of
    Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
    Just aid -> do
      mExisting <- liftIO (adbRead backend aid)
      liftIO (adbDelete backend aid)
      let msg = case mExisting of
            Nothing -> "deleted (was not present)"
            Just _  -> "deleted"
          recorded = object ["id" .= agentDefIdText aid]
      pure (OpResult [TrpText msg] False recorded)

-- ---------------------------------------------------------------------------
-- knownOpNames — the universe of opcode names the harness exposes
-- ---------------------------------------------------------------------------

-- | The universe of opcode names the harness actually exposes. A tools
-- entry outside this set is silently dropped from the child registry
-- (intersection semantics) but recorded here so a def-author typo is
-- discoverable in the audit trail.
knownOpNames :: Set.Set Text
knownOpNames = Set.fromList
  [ "SHOW_HUMAN", "ASK_HUMAN", "SECRET_GET"
  , "MEMORY_WRITE", "MEMORY_READ", "MEMORY_LIST", "MEMORY_SEARCH", "MEMORY_ARCHIVE"
  , "MEMORY_MANAGE"
  , "SKILL_WRITE", "SKILL_LOAD", "SKILL_LIST", "SKILL_DELETE"
  , "SKILL_MANAGE"
  , "AGENT_DEF_WRITE", "AGENT_DEF_READ", "AGENT_DEF_LIST", "AGENT_DEF_DELETE"
  , "AGENT_DEF_MANAGE"
  , "AGENT_INSTANCES", "AGENT_START", "AGENT_STATUS", "AGENT_STOP", "AGENT_INTERRUPT"
  , "AGENT_MANAGE"
  , "SEARCH_FILES", "FILE_READ", "FILE_WRITE", "FILE_PATCH"
  , "SHELL_EXEC", "SETUP_REPO", "BIN_EXEC", "PROCESS_MANAGE"
  , "WEB_FETCH", "WEB_SEARCH"
  , "HARNESS_LIST", "HARNESS_START", "HARNESS_STOP"
  , "SESSION_NEW", "SESSION_LIST", "SESSION_SEARCH", "SESSION_GET"
  , "SESSION_MANAGE"
  , "OPCODE_DESCRIBE", "OPCODE_LIST"
  ]

-- ---------------------------------------------------------------------------
-- Consolidated opcode: AGENT_DEF_MANAGE
-- ---------------------------------------------------------------------------

-- | AGENT_DEF_MANAGE: action-based entry point for all agent definition
-- operations. The @action@ field discriminates between @write@, @read@,
-- @list@, and @delete@.
agentDefManageOp :: AgentDefBackend -> SessionId -> Opcode
agentDefManageOp backend session = TrustedOpcode
  { toName = OpName "AGENT_DEF_MANAGE"
  , toTrust = Trusted
  , toDesc = "Manage agent definitions. Use action to select: write (create/update upsert), read (by id), list (all defs), delete (by id, idempotent)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["write", "read", "list", "delete"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Agent def id ([A-Za-z0-9_-]+) (write, read, delete)." :: Text)
              ]
          , fromText "name" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Human-readable agent name (write)." :: Text)
              ]
          , fromText "provider" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Provider label, e.g. \"ollama\" (write)." :: Text)
              ]
          , fromText "model" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Model id, e.g. \"llama3\" (write)." :: Text)
              ]
          , fromText "system" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional system prompt (write)." :: Text)
              ]
          , fromText "tools" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("Allowed opcode names, or \"all\" (write)." :: Text)
              ]
          , fromText "group" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional display group (e.g. \"core\") (write). Omit for the default (ungrouped) section." :: Text)
              ]
          , fromText "role" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional delegation role: \"orchestrator\" or \"leaf\" (write)." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("One-line catalog summary (write)." :: Text)
              ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeAgentDefManage
  , toBlocking = False
  , toRun = \_ v ->
      case parseAgentDefAction v of
        Left e -> pure (OpResult [TrpText e] True (object []))
        Right action -> case action of
          AdWrite  -> handleDefWrite backend session v
          AdRead   -> handleDefRead backend v
          AdList   -> handleDefList backend
          AdDelete -> handleDefDelete backend v
  }

-- ---------------------------------------------------------------------------
-- Legacy shims (backward compatibility)
-- ---------------------------------------------------------------------------

-- | AGENT_DEF_WRITE (legacy shim): delegates to the write handler.
agentDefWriteOp :: AgentDefBackend -> SessionId -> Opcode
agentDefWriteOp backend session = TrustedOpcode
  { toName = OpName "AGENT_DEF_WRITE"
  , toTrust = Trusted
  , toDesc = "Create or update an agent definition by id (upsert; preserves provenance on update). (Legacy — prefer AGENT_DEF_MANAGE with action=\"write\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Agent def id ([A-Za-z0-9_-]+)." :: Text)
              ]
          , fromText "name" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Human-readable agent name." :: Text)
              ]
          , fromText "provider" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Provider label, e.g. \"ollama\"." :: Text)
              ]
          , fromText "model" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Model id, e.g. \"llama3\"." :: Text)
              ]
          , fromText "system" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional system prompt." :: Text)
              ]
          , fromText "tools" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("Allowed opcode names, or \"all\"." :: Text)
              ]
          , fromText "group" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional display group (e.g. \"core\"). Omit for the default (ungrouped) section." :: Text)
              ]
          , fromText "role" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional delegation role: \"orchestrator\" (may spawn sub-agents, depth-capped) or \"leaf\" (default; cannot spawn). The def is authoritative — AGENT_START's per-task role can only narrow an orchestrator def to leaf, never widen a leaf." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional one-line description rendered into the <available_agents> catalog (single line; control characters and catalog-fence tokens are sanitized)." :: Text)
              ]
          ]
      , "required" .= (["id", "name", "provider", "model"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeDefWrite
  , toBlocking = False
  , toRun = \_ v -> handleDefWrite backend session v
  }
-- ---------------------------------------------------------------------------
-- AGENT_DEF_READ
-- ---------------------------------------------------------------------------

-- | AGENT_DEF_READ (legacy shim): delegates to the read handler.
agentDefReadOp :: AgentDefBackend -> Opcode
agentDefReadOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_READ"
  , toTrust = Trusted
  , toDesc = "Read one agent definition by id. (Legacy — prefer AGENT_DEF_MANAGE with action=\"read\".)"
  , toInSchema = singleStringSchema "id" "The agent def id to read."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_DEF_READ requires {id:string}") checkAgentDefId . idField
  , toBlocking = False
  , toRun = \_ v -> handleDefRead backend v
  }

-- | AGENT_DEF_LIST (legacy shim): delegates to the list handler.
agentDefListOp :: AgentDefBackend -> Opcode
agentDefListOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_LIST"
  , toTrust = Trusted
  , toDesc = "List all agent definitions (id + role + name + provider/model). (Legacy — prefer AGENT_DEF_MANAGE with action=\"list\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ _ -> handleDefList backend
  }

-- | AGENT_DEF_DELETE (legacy shim): delegates to the delete handler.
agentDefDeleteOp :: AgentDefBackend -> Opcode
agentDefDeleteOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_DELETE"
  , toTrust = Trusted
  , toDesc = "Delete an agent definition by id (idempotent). (Legacy — prefer AGENT_DEF_MANAGE with action=\"delete\".)"
  , toInSchema = singleStringSchema "id" "The agent def id to delete."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_DEF_DELETE requires {id:string}") checkAgentDefId . idField
  , toBlocking = False
  , toRun = \_ v -> handleDefDelete backend v
  }
-- ---------------------------------------------------------------------------
-- AgentStartWiring (wiring-layer bundle for AGENT_START / AGENT_MANAGE start)
-- ---------------------------------------------------------------------------

-- | The wiring-layer bundle the AGENT_START opcode closes over. The
-- 'AgentWorkerBuilder' resolves the def's provider+model, opens a fresh
-- two-file transcript under @\<parent-session\>\/agents\/\<child-id\>@, builds
-- a fresh 'AgentEnv' bound to the new session + child transcript, runs the
-- turn with the goal as the first user message, and reports the outcome via
-- 'ChildWorkerOutcome'. The 'DelegationConfig' / 'SpawnPauseFlag' /
-- 'ParentActivity' are process-global (or per-channel) and threaded in
-- here so the opcode doesn't read config.
data AgentStartWiring = AgentStartWiring
  { aswDefBackend   :: AgentDefBackend
  , aswRuntime      :: AgentRuntime
  , aswConfig       :: IO DelegationConfig
  , aswPauseFlag    :: SpawnPauseFlag
  , aswParentActivity :: Maybe ParentActivity
  , aswMintSession  :: IO SessionId
  , aswParentDepth  :: Int
  , aswWorker       :: AgentWorkerBuilder
  , aswGate         :: AgentStartGate
  , aswPaths        :: SealPaths
    -- ^ The harness paths (for appending completion messages to the
    -- parent's transcript via direct file append).
  , aswParentSession :: SessionId
    -- ^ The parent's session id (so the completion callback knows which
    -- @conversation.jsonl@ to append to).
  }

-- | The role/switch condition the nested AGENT_START enforces before it
-- will spawn. Leaf children (and orchestrator children while the kill
-- switch is off) get a present-but-rejecting op whose authorize returns
-- the dedicated error.
data AgentStartGate = AgentStartGate
  { gEffectiveRole :: Maybe Text
  , gOrchEnabled   :: Bool
  }

-- | The open gate for top-level (operator-authorized) turns: spawning is
-- governed only by the depth cap, spawn-pause, and per-spawn resolver
-- checks.
gateOpen :: AgentStartGate
gateOpen = AgentStartGate { gEffectiveRole = Just "orchestrator", gOrchEnabled = True }

-- | Parse the model's input into a 'DelegateInput'. Single mode requires
-- @id@ + @goal@; batch mode requires a @tasks@ array of @{id, goal, ...}@.
parseInput :: Value -> IO (Either Text DelegateInput)
parseInput v =
  case parseMaybe (withObject "in" (.:? "tasks")) v :: Maybe (Maybe Value) of
    Just (Just (Array arr)) | not (V.null arr) -> do
      tasks <- mapM parseTask (V.toList arr)
      case sequence tasks of
        Left err     -> pure (Left err)
        Right tsList -> pure (Right (DiBatch tsList))
    _ -> do
      let mDefId = idField v
          mGoal  = textFieldMaybe "goal" v
      case (mDefId, mGoal) of
        (Just defId, Just goal) | not (T.null goal) ->
          pure (Right (DiSingle (ChildTask defId goal (textFieldMaybe "context" v) (textFieldMaybe "role" v))))
        (Just _, Just _) -> pure (Left "AGENT_START requires a non-empty 'goal'.")
        (Just _, Nothing) -> pure (Left "AGENT_START single-task mode requires a 'goal'.")
        (Nothing, _) -> pure (Left "AGENT_START requires an 'id' (agent def id) in single-task mode, or a 'tasks' array in batch mode.")

-- | Parse one element of the @tasks@ array into a 'ChildTask'.
parseTask :: Value -> IO (Either Text ChildTask)
parseTask v =
  case idField v of
    Nothing -> pure (Left "Each task requires an 'id' (agent def id).")
    Just defId ->
      case textFieldMaybe "goal" v of
        Nothing -> pure (Left "Each task requires a 'goal'.")
        Just goal | T.null goal -> pure (Left "Each task requires a non-empty 'goal'.")
                 | otherwise -> pure (Right (ChildTask defId goal (textFieldMaybe "context" v) (textFieldMaybe "role" v)))

-- | Resolve a task to its def + worker + fresh session id. Returns Left if
-- the def id is invalid, the def doesn't exist, or the effective-role /
-- kill-switch gate rejects the spawn.
resolveTask
  :: AgentDefBackend
  -> AgentRuntime
  -> IO SessionId
  -> Int
  -> Bool
  -> AgentWorkerBuilder
  -> ChildTask
  -> IO (Either Text (AgentDef, AgentWorkerBuilder, SessionId))
resolveTask defBackend _runtime mintSession _parentDepth orchEnabled worker task = do
  case mkAgentDefId (ctDefId task) of
    Left err -> pure (Left err)
    Right aid -> do
      mDef <- adbRead defBackend aid
      case mDef of
        Nothing  -> pure (Left ("agent def not found: " <> ctDefId task))
        Just def -> do
          let role = effectiveRole (adRole def) (ctRole task)
          if role == Just "orchestrator" && not orchEnabled
            then pure (Left killSwitchMsg)
            else do
              sid <- mintSession
              pure (Right (def, worker, sid))

-- | The dedicated kill-switch error. Distinct from the depth/leaf/pause
-- messages so the parent transcript distinguishes all spawn-failure causes.
killSwitchMsg :: Text
killSwitchMsg = "Delegation spawning is disabled: delegation.orchestrator_enabled = false. Re-trying will not succeed until the operator re-enables it."

-- | The dedicated leaf-role error: a leaf agent cannot spawn — actionable
-- for both the model and the operator.
leafMsg :: Text
leafMsg = "AGENT_START is not available to this agent: its definition is a leaf (role: leaf). Ask the operator to grant the orchestrator role if delegation is required."

-- | Register a finished child in the runtime registry (post-hoc; the worker
-- ran synchronously to completion). Records the instance with status
-- 'Stopped' (the synchronous child has already finished by the time this is
-- ---------------------------------------------------------------------------
-- Agent runtime action enum (AGENT_MANAGE)
-- ---------------------------------------------------------------------------

data AgentAction
  = AgInstances
  | AgStart
  | AgStatus
  | AgStop
  | AgInterrupt

parseAgentAction :: Value -> Either Text AgentAction
parseAgentAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "instances" -> Right AgInstances
      "start"     -> Right AgStart
      "status"    -> Right AgStatus
      "stop"      -> Right AgStop
      "interrupt" -> Right AgInterrupt
      other       -> Left ("unknown agent action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- | Authorize gate for the `start` action (shared with the legacy
-- AGENT_START shim). Checks both the input shape (goal or tasks present)
-- and the role/kill-switch gate from the wiring.
authorizeStart :: AgentStartWiring -> Value -> Either Text ()
authorizeStart wiring v =
  let shapeGate =
        let hasGoal = case textFieldMaybe "goal" v of { Just _ -> True; Nothing -> False }
            hasTasks = case parseMaybe (withObject "in" (.:? "tasks")) v :: Maybe (Maybe Value) of { Just (Just _) -> True; _ -> False }
        in if hasGoal || hasTasks
             then Right ()
             else Left "AGENT_START requires {goal:string} (single) or {tasks:array} (batch)."
      roleGate = case (gEffectiveRole (aswGate wiring), gOrchEnabled (aswGate wiring)) of
        (Just "orchestrator", True) -> Right ()
        (Just "orchestrator", False) -> Left killSwitchMsg
        (_, _) -> Left leafMsg
  in shapeGate *> roleGate

-- | Authorize gate for AGENT_MANAGE — dispatches per-action validation.
authorizeAgentManage :: AgentStartWiring -> Value -> Either Text ()
authorizeAgentManage wiring v =
  case parseAgentAction v of
    Left e -> Left e
    Right action -> case action of
      AgInstances -> Right ()
      AgStart     -> authorizeStart wiring v
      AgStatus    -> maybe (Left "status requires {subagent_id:string}") (const (Right ())) . subagentIdField $ v
      AgStop      -> maybe (Left "stop requires {subagent_id:string}") (const (Right ())) . subagentIdField $ v
      AgInterrupt -> maybe (Left "interrupt requires {subagent_id:string}") (const (Right ())) . subagentIdField $ v

-- | Handle the instances action (shared with the legacy AGENT_INSTANCES shim).
handleInstances :: AgentRuntime -> App OpResult
handleInstances runtime = do
  insts <- liftIO (listAgents runtime)
  let rendered = case insts of
        [] -> "(no agents running)"
        _  -> T.intercalate "\n"
                [ subagentIdText (aiSubagentId i) <> ": " <> agentDefIdText (aiId i) <> " — " <> renderStatus (aiStatus i)
                | i <- insts ]
      recorded = object
        [ "count" .= length insts
        , "ids" .= fmap (subagentIdText . aiSubagentId) insts
        ]
  pure (OpResult [TrpText rendered] False recorded)

-- | Handle the start action (shared with the legacy AGENT_START shim).
-- Async: forks children, returns immediately with per-child SpawnInfo.
handleStart :: AgentStartWiring -> Value -> App OpResult
handleStart wiring v = do
  input <- liftIO (parseInput v)
  case input of
    Left err -> pure (OpResult [TrpText err] True (object []))
    Right di -> do
      cfg <- liftIO (aswConfig wiring)
      let (_, _, _, orchEnabled) = resolveDelegationConfig cfg
          runtime = aswRuntime wiring
          callback :: AgentCompletionCallback
          callback result = do
            registerCompletedAgentResult runtime (crSubagentId result) result
            -- TODO: append completion message to parent's conversation.jsonl.
            -- Disabled for now: the direct O_APPEND write conflicts with the
            -- single-writer daemon's in-memory diff state (tfsWritten),
            -- corrupting the transcript. A proper fix requires either:
            -- (a) a queue drained by the turn engine, or
            -- (b) writing to a sidecar file that the next turn reads.
            -- The completion result IS stored in the registry via
            -- registerCompletedAgentResult, so AGENT_STATUS works.
          spawnCb :: SpawnCallback
          spawnCb sid def childSid =
            registerRunningAgent runtime (adId def) sid childSid (aswParentDepth wiring + 1)
      eSpawnInfos <- liftIO (runDelegateAsync
                               cfg
                               (aswPauseFlag wiring)
                               (aswParentActivity wiring)
                               (aswParentDepth wiring)
                               di
                               (resolveTask (aswDefBackend wiring)
                                            runtime
                                            (aswMintSession wiring)
                                            (aswParentDepth wiring)
                                            orchEnabled
                                            (aswWorker wiring))
                               callback
                               spawnCb
                               (aswMintSession wiring))
      case eSpawnInfos of
        Left err -> pure (OpResult [TrpText err] True (object []))
        Right spawnInfos ->
          pure (OpResult [TrpText (encodeSpawnInfos spawnInfos)] False
                 (object ["results" .= fmap toJSONSpawnInfo spawnInfos]))

-- | Handle the status action (shared with the legacy AGENT_STATUS shim).
-- Enriched: when the registry has a completed entry with aiResult, the
-- response includes summary, child_session, exit_reason, and duration.
handleStatus :: AgentRuntime -> Value -> App OpResult
handleStatus runtime v = do
  let mSid = subagentIdField v
  case mSid of
    Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
    Just sid -> do
      mInst <- liftIO (agentInstanceBySubagentId runtime sid)
      case mInst of
        Nothing -> pure (OpResult [TrpText "not running"] False
                         (object ["subagent_id" .= subagentIdText sid, "status" .= ("stopped" :: Text)]))
        Just inst -> do
          let s = aiStatus inst
              baseRecord = [ "subagent_id" .= subagentIdText sid
                           , "status" .= renderStatus s
                           ]
          case aiResult inst of
            Nothing ->
              pure (OpResult [TrpText (renderStatus s)] False (object baseRecord))
            Just result ->
              let enriched = baseRecord
                    ++ [ "summary" .= crSummary result
                       , "child_session" .= fmap sessionIdText (crChildSession result)
                       , "exit_reason" .= T.pack (show (crExitReason result))
                       , "duration_seconds" .= crDurationSeconds result
                       ]
                  statusText = renderStatus s <> maybe "" ("\n" <>) (crSummary result)
              in pure (OpResult [TrpText statusText] False (object enriched))

-- | Handle the stop action (shared with the legacy AGENT_STOP shim).
handleStop :: AgentRuntime -> Value -> App OpResult
handleStop runtime v = do
  let mSid = subagentIdField v
  case mSid of
    Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
    Just sid -> do
      _ <- liftIO (stopAgent runtime sid)
      pure (OpResult [TrpText "stopped"] False (object ["subagent_id" .= subagentIdText sid]))

-- | Handle the interrupt action (shared with the legacy AGENT_INTERRUPT shim).
handleInterrupt :: AgentRuntime -> Value -> App OpResult
handleInterrupt runtime v = do
  let mSid = subagentIdField v
  case mSid of
    Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
    Just sid -> do
      found <- liftIO (interruptAgent runtime sid)
      let msg = if found then "interrupt requested" else "subagent not running"
      pure (OpResult [TrpText msg] False (object ["subagent_id" .= subagentIdText sid, "found" .= found]))

-- ---------------------------------------------------------------------------
-- Consolidated opcode: AGENT_MANAGE
-- ---------------------------------------------------------------------------

-- | AGENT_MANAGE: action-based entry point for all agent runtime lifecycle
-- operations. The @action@ field discriminates between @instances@, @start@,
-- @status@, @stop@, and @interrupt@. The @start@ action carries the full
-- 'AgentStartWiring' (delegation config, worker builder, role/kill-switch
-- gate, batch mode).
agentManageOp :: AgentStartWiring -> Opcode
agentManageOp wiring = TrustedOpcode
  { toName = OpName "AGENT_MANAGE"
  , toTrust = Trusted
  , toDesc = "Manage agent runtime. Use action to select: instances (list running), start (spawn child agents), status (check one agent), stop (kill agent), interrupt (cooperative stop)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["instances", "start", "status", "stop", "interrupt"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Agent def id (start, single-task)." :: Text)
              ]
          , fromText "goal" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Task goal (start, single-task)." :: Text)
              ]
          , fromText "context" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Background context (start)." :: Text)
              ]
          , fromText "role" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Role hint: \"leaf\" (start)." :: Text)
              ]
          , fromText "tasks" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("Batch: [{id, goal, context?, role?}] (start)." :: Text)
              ]
          , fromText "subagent_id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Subagent id (status/stop/interrupt)." :: Text)
              ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeAgentManage wiring
  , toBlocking = True
  , toRun = \_ v ->
      case parseAgentAction v of
        Left e -> pure (OpResult [TrpText e] True (object []))
        Right action -> case action of
          AgInstances -> handleInstances (aswRuntime wiring)
          AgStart     -> handleStart wiring v
          AgStatus    -> handleStatus (aswRuntime wiring) v
          AgStop      -> handleStop (aswRuntime wiring) v
          AgInterrupt -> handleInterrupt (aswRuntime wiring) v
  }

-- ---------------------------------------------------------------------------
-- Legacy shims (backward compatibility)
-- ---------------------------------------------------------------------------

-- | AGENT_INSTANCES (legacy shim): delegates to the instances handler.
agentInstancesOp :: AgentRuntime -> Opcode
agentInstancesOp runtime = TrustedOpcode
  { toName = OpName "AGENT_INSTANCES"
  , toTrust = Trusted
  , toDesc = "List running agent instances (subagent_id + def id + status). (Legacy — prefer AGENT_MANAGE with action=\"instances\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ _ -> handleInstances runtime
  }

-- | AGENT_START (legacy shim): delegates to the start handler.
agentStartOp :: AgentStartWiring -> Opcode
agentStartOp wiring = TrustedOpcode
  { toName = OpName "AGENT_START"
  , toTrust = Trusted
  , toDesc = "Spawn one or more child agents, run each against a goal to completion, return a JSON result per child. Single mode: {id, goal, context?, role?}. Batch mode: {tasks: [{id, goal, context?, role?}, ...]}. (Legacy — prefer AGENT_MANAGE with action=\"start\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Agent def id (single-task mode)." :: Text)
              ]
          , fromText "goal" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The task goal — becomes the child's first user message (single-task mode)." :: Text)
              ]
          , fromText "context" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional background context appended to the child's system prompt." :: Text)
              ]
          , fromText "role" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional narrow-only role hint: only \"leaf\" is meaningful per-task (downgrades an orchestrator def's child to leaf). Spawning capability comes from the def's role field — a leaf def can never be widened by task input." :: Text)
              ]
          , fromText "tasks" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("Batch mode: array of {id, goal, context?, role?}. Cap on parallelism is delegation.max_concurrent_children." :: Text)
              ]
          ]
      , "required" .= (["goal"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeStart wiring
  , toBlocking = True
  , toRun = \_ v -> handleStart wiring v
  }

-- | AGENT_STATUS (legacy shim): delegates to the status handler.
agentStatusOp :: AgentRuntime -> Opcode
agentStatusOp runtime = TrustedOpcode
  { toName = OpName "AGENT_STATUS"
  , toTrust = Trusted
  , toDesc = "Read one running agent's status by subagent_id. (Legacy — prefer AGENT_MANAGE with action=\"status\".)"
  , toInSchema = singleStringSchema "subagent_id" "The subagent id (from AGENT_START's result)."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STATUS requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toBlocking = False
  , toRun = \_ v -> handleStatus runtime v
  }

-- | AGENT_STOP (legacy shim): delegates to the stop handler.
agentStopOp :: AgentRuntime -> Opcode
agentStopOp runtime = TrustedOpcode
  { toName = OpName "AGENT_STOP"
  , toTrust = Trusted
  , toDesc = "Stop a running agent instance by subagent_id (idempotent). (Legacy — prefer AGENT_MANAGE with action=\"stop\".)"
  , toInSchema = singleStringSchema "subagent_id" "The subagent id to stop."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STOP requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toBlocking = False
  , toRun = \_ v -> handleStop runtime v
  }

-- | AGENT_INTERRUPT (legacy shim): delegates to the interrupt handler.
agentInterruptOp :: AgentRuntime -> Opcode
agentInterruptOp runtime = TrustedOpcode
  { toName = OpName "AGENT_INTERRUPT"
  , toTrust = Trusted
  , toDesc = "Request that a running subagent stop at its next iteration boundary (cooperative; the worker polls an interrupt flag between turns). (Legacy — prefer AGENT_MANAGE with action=\"interrupt\".)"
  , toInSchema = singleStringSchema "subagent_id" "The subagent id to interrupt."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_INTERRUPT requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toBlocking = False
  , toRun = \_ v -> handleInterrupt runtime v
  }

-- ---------------------------------------------------------------------------
-- JSON encoding of ChildResult
-- ---------------------------------------------------------------------------

renderStatus :: AgentStatus -> Text
renderStatus = \case
  Starting     -> "starting"
  Running      -> "running"
  Idle         -> "idle"
  Stopped      -> "stopped"
  Interrupted  -> "interrupted"
  Crashed m    -> "crashed: " <> m

-- | Extract the @subagent_id@ string field from a JSON object.
subagentIdField :: Value -> Maybe SubagentId
subagentIdField v = do
  t <- parseMaybe (withObject "in" (.: "subagent_id")) v
  if T.null t then Nothing else Just (SubagentId t)

-- ---------------------------------------------------------------------------
-- Helpers (def rendering / encoding)
-- ---------------------------------------------------------------------------

-- | Build a JSON-Schema object with a single required string property.
singleStringSchema :: Text -> Text -> Value
singleStringSchema fieldName fieldDesc =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [fromText fieldName .= object
           [ "type" .= ("string" :: Text)
           , "description" .= fieldDesc
           ]]
    , "required" .= ([fieldName] :: [Text])
    ]

-- | Encode the secret-free 'AgentDef' fields into the 'orRecorded' payload.
-- The @was_new@ flag distinguishes create vs update in the audit log.
encodeDefRecorded :: AgentDef -> Bool -> [Text] -> Value
encodeDefRecorded d wasNew unknownTools = object $
  [ "id"         .= agentDefIdText (adId d)
  , "name"       .= adName d
  , "provider"   .= adProvider d
  , "model"      .= adModel d
  , "system"     .= adSystem d
  , "tools"      .= encodeTools (adTools d)
  , "group"      .= adGroup d
  , "role"       .= adRole d
  , "description" .= adDescription d
  , "created_at" .= adCreatedAt d
  , "updated_at" .= adUpdatedAt d
  , "session"    .= adSession d
  , "was_new"    .= wasNew
  ] ++ [ "unknown_tools" .= unknownTools | not (null unknownTools) ]

-- | The @[\<role\>]@ suffix rendered after a def id in AGENT_DEF_LIST
-- output (and the W3 catalog): present only when the def carries a role.
roleSuffix :: Maybe Text -> Text
roleSuffix (Just r) = " [" <> r <> "]"
roleSuffix Nothing  = ""

-- | Encode an 'AllowList OpName' for the recorded payload: @\"all\"@ for
-- 'AllowAll', or a JSON array of opcode-name strings for 'AllowOnly'.
encodeTools :: AllowList OpName -> Value
encodeTools AllowAll       = String "all"
encodeTools (AllowOnly xs) = Array (V.fromList [ String t | OpName t <- Set.toList xs ])

-- | Render an 'AgentDef' as a Markdown-ish text block for the model.
renderDef :: AgentDef -> Text
renderDef d =
  "# " <> adName d <> " (" <> agentDefIdText (adId d) <> ")\n\n"
  <> "provider: " <> adProvider d <> "\n"
  <> "model: " <> modelName <> "\n"
  <> "system: " <> fromMaybe "(none)" (adSystem d) <> "\n"
  <> "tools: " <> renderTools (adTools d)
  where
    ModelId modelName = adModel d

-- | Render an 'AllowList OpName' as a comma-separated list, or @\"all\"@.
renderTools :: AllowList OpName -> Text
renderTools AllowAll       = "all"
renderTools (AllowOnly xs) = T.intercalate ", " [ t | OpName t <- Set.toList xs ]

-- ---------------------------------------------------------------------------
-- Async spawn helpers
-- ---------------------------------------------------------------------------

-- | Render the spawn-info list as a text block for the model (the
-- @orParts@ text the model sees). One line per child:
-- @subagent_id | child_session | status@.
encodeSpawnInfos :: [SpawnInfo] -> Text
encodeSpawnInfos [] = "(no children spawned)"
encodeSpawnInfos infos = T.intercalate "\n" (map renderOne infos)
  where
    renderOne si =
      subagentIdText (siSubagentId si) <> " | " <>
      sessionIdText (siChildSession si) <> " | running"

-- | Encode a 'SpawnInfo' as JSON for the 'orRecorded' payload.
toJSONSpawnInfo :: SpawnInfo -> Value
toJSONSpawnInfo si = object
  [ "subagent_id"   .= subagentIdText (siSubagentId si)
  , "child_session" .= sessionIdText (siChildSession si)
  , "status"        .= ("running" :: Text)
  ]
