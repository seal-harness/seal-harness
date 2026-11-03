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
  , SpawnMode (..)
  , parseSpawnMode
  , gateOpen
  , authorizeStart
  , encodeForegroundResults
  , renderChildStatus
  , renderChildExit
  , continueHint
  , noReplyClause
  , continueNudge
  , timeoutContinuationClause
  , noFinalTextPlaceholder
  , outcomeHeader
  , outcomeBody
  , encodeSpawnInfos
  , completionMessage
  , killSwitchMsg
  , leafMsg
  , allowSpawnBlockedMsg
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.STM (TMVar, atomically, takeTMVar)
import Control.Exception
  ( SomeAsyncException, SomeException, fromException, throwIO, try )
import Control.Monad (join, forM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value (..), object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe, isJust)
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Vector qualified as V

import Seal.Agent.Def.Backend (AgentDefBackend (..), ResolveResult (..), resolveAgentDefEntry)
import Seal.Agent.Def.Types
  ( AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText
  , sanitizeAgentDefFields, sanitizeAgentTextField, agentFieldCapSmall
  )
import Seal.Agent.Runtime.Delegation.Worker ()
import Seal.Agent.Runtime.Delegation
  ( AgentWorkerBuilder
  , AgentCompletionCallback
  , SpawnCallback
  , ChildExitReason (..)
  , ChildResult (..)
  , ChildStatus (..)
  , ChildTask (..)
  , DelegationConfig
  , DelegateInput (..)
  , SpawnInfo (..)
  , SpawnPauseFlag
  , runDelegate
  , ParentActivity
  , SubagentId (..)
  , resolveDelegationConfig
  , runChildTask
  , runDelegateAsync
  , isSpawnPaused
  , spawnPausedMsg
  , mkErrorResult
  , subagentIdText
  )
import Seal.Agent.Runtime.Registry
  ( AgentInstance (..), AgentRuntime, AgentStatus (..)
  , Delivery (..)
  , SpawnOrigin (..)
  , StopOutcome (..)
  , agentStatusFor
  , countRunningChildren
  , endRun
  , hasRunningChildren
  , interruptAgent, listAgents, listAgentsFor
  , ownsChild
  , pollUntil
  , registerRunCrash, registerRunResult, registerRunningChild
  , resumeAgent
  , stopAgent
  , workerSettled )
import Seal.Agent.Runtime.RunRecord qualified as RunRecord
  ( RunRecordRegistry, shouldDeferDelivery )
import Seal.Config.Paths (SealPaths, childConversationPresent)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, TrustLevel (..), sessionIdText)
import Seal.Handles.Transcript (appendCompletionToSidecar)
import Katip (Severity (..), ls)
import Seal.Logging.Global (globalLogIO)
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

-- | Extract an optional boolean field (defaults to 'Nothing' when absent
-- or non-boolean). Mirrors 'Seal.ISA.Ops.Session.boolField'.
boolField :: Value -> Text -> Maybe Bool
boolField v key = join (parseMaybe (withObject "in" (.:? fromText key)) v)

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
, adAllowSpawn = Nothing
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
, adAllowSpawn = Nothing
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
      rDef <- liftIO (resolveAgentDefEntry backend aid)
      case rDef of
        ResolveNotFound ->
          pure (OpResult [TrpText "agent def not found"] True (object ["id" .= agentDefIdText aid]))
        ResolveAmbiguous ids ->
          pure (OpResult [TrpText (ambiguousAgentDefMsg aid ids)] True (object ["id" .= agentDefIdText aid]))
        ResolveFound d  -> do
          let rendered = renderDef d
              recorded = encodeDefRecorded d False []
          pure (OpResult [TrpText rendered] False recorded)

-- | Format an ambiguity error for an agent def id, listing the
-- fully-qualified ids that matched so the user can disambiguate.
ambiguousAgentDefMsg :: AgentDefId -> [Text] -> Text
ambiguousAgentDefMsg aid ids =
  "ambiguous agent def id \"" <> agentDefIdText aid <> "\". Matching ids: "
    <> T.intercalate ", " ids
    <> ". Use the full id to disambiguate."

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
      rExisting <- liftIO (resolveAgentDefEntry backend aid)
      case rExisting of
        ResolveAmbiguous ids ->
          pure (OpResult [TrpText (ambiguousAgentDefMsg aid ids)] True (object ["id" .= agentDefIdText aid]))
        ResolveNotFound -> do
          liftIO (adbDelete backend aid)
          pure (OpResult [TrpText "deleted (was not present)"] False (object ["id" .= agentDefIdText aid]))
        ResolveFound _ -> do
          liftIO (adbDelete backend aid)
          pure (OpResult [TrpText "deleted"] False (object ["id" .= agentDefIdText aid]))

-- ---------------------------------------------------------------------------
-- knownOpNames — the universe of opcode names the harness exposes
-- ---------------------------------------------------------------------------

-- | The universe of opcode names the harness actually exposes. A tools
-- entry outside this set is silently dropped from the child registry
-- (intersection semantics) but recorded here so a def-author typo is
-- discoverable in the audit trail.
knownOpNames :: Set.Set Text
knownOpNames = Set.fromList
  [ "SHOW_HUMAN", "ASK_HUMAN", "SECRET_MANAGE"
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
 , "WEB_FETCH", "WEB_SEARCH", "BROWSER_MANAGE"
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
-- indexed transcript under @\<parent-session\>\/agents\/\<child-id\>@, builds
-- a fresh 'AgentEnv' bound to the new session + child transcript, runs the
-- turn with the goal as the first user message, and reports the outcome via
-- 'ChildWorkerOutcome'. The 'DelegationConfig' / 'SpawnPauseFlag' /
-- 'ParentActivity' are process-global (or per-channel) and threaded in
-- here so the opcode doesn't read config. The spawner's lineage is not
-- carried in this record: it reaches spawned children via @buildWorker@'s
-- @parentLineage@ parameter → @DelegationWorkerDeps@'s @dwdParentLineage@
-- → the worker prepends the minted @childSid@ and passes the chain to the
-- child-registry seam, where it is baked into the child session ops.
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
  , aswRunRecords   :: Maybe RunRecord.RunRecordRegistry
    -- ^ The durable run-record registry (WU-5). When 'Just', the
    -- completion callback checks 'shouldDeferDelivery' before appending to
    -- the sidecar — a child with pending descendants has its delivery
    -- deferred until the descendants settle. 'Nothing' in test wirings
    -- without the registry (delivery is never deferred).
  , aswOnIdleCompletion :: Maybe (IO ())
    -- ^ Wake-up hook: when a background sub-agent completes and the parent
    -- session is idle (no turn in flight), this action triggers a synthetic
    -- turn so the sidecar completions are read and processed. 'Nothing' in
    -- test wirings. The action is closed over the parent session id at
    -- wiring time.
  }

-- | The role/switch condition the nested AGENT_START enforces before it
-- will spawn. Leaf children (and orchestrator children while the kill
-- switch is off) get a present-but-rejecting op whose authorize returns
-- the dedicated error. The per-def @adAllowSpawn@ override is captured in
-- 'gAllowSpawn': @Just False@ blocks spawning regardless of role; @Just
-- True@ allows spawning even for a leaf role (escape hatch); @Nothing@
-- defers to the role-based default.
data AgentStartGate = AgentStartGate
  { gEffectiveRole :: Maybe Text
  , gOrchEnabled   :: Bool
  , gAllowSpawn    :: Maybe Bool
  }

-- | The open gate for top-level (operator-authorized) turns: spawning is
-- governed only by the depth cap, spawn-pause, and per-spawn resolver
-- checks.
gateOpen :: AgentStartGate
gateOpen = AgentStartGate { gEffectiveRole = Just "orchestrator", gOrchEnabled = True, gAllowSpawn = Nothing }

-- | The spawn mode parsed from the @mode@ field of @AGENT_MANAGE start@.
-- @foreground@ blocks and returns results in-band; @background@ (the
-- default) forks children and delivers completion via push notification.
data SpawnMode = SpawnModeForeground | SpawnModeBackground
  deriving stock (Eq, Show)

-- | Parse the @mode@ field from the input value. Defaults to
-- 'SpawnModeBackground' when absent or unrecognized.
parseSpawnMode :: Value -> SpawnMode
parseSpawnMode v =
  case textFieldMaybe "mode" v of
    Just "foreground" -> SpawnModeForeground
    _                 -> SpawnModeBackground

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
          pure (Right (DiSingle (ChildTask defId goal (textFieldMaybe "context" v) (textFieldMaybe "role" v) (fromMaybe False (boolField v "isolate_workdir")))))
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
                 | otherwise -> pure (Right (ChildTask defId goal (textFieldMaybe "context" v) (textFieldMaybe "role" v) (fromMaybe False (boolField v "isolate_workdir"))))

-- | Resolve a task to its def + worker. Returns Left if the def id is
-- invalid or the def doesn't exist. The role/kill-switch gate is enforced
-- at authorize time ('authorizeStart') and in 'buildChildRegistryAdapter'
-- (which consults the def's @adAllowSpawn@ when building the child's
-- nested gate). The session id is NOT minted here — 'spawnOne' in
-- 'runDelegateAsync' mints the session before calling the resolver,
-- eliminating the double-mint that doubled the collision surface.
resolveTask
  :: AgentDefBackend
  -> AgentRuntime
  -> Int
  -> Bool
  -> AgentWorkerBuilder
  -> ChildTask
  -> IO (Either Text (AgentDef, AgentWorkerBuilder))
resolveTask defBackend _runtime _parentDepth _orchEnabled worker task = do
  case mkAgentDefId (ctDefId task) of
    Left err -> pure (Left err)
    Right aid -> do
      mDef <- adbRead defBackend aid
      case mDef of
        Nothing  -> pure (Left ("agent def not found: " <> ctDefId task))
        Just def -> pure (Right (def, worker))

-- | The dedicated kill-switch error. Distinct from the depth/leaf/pause
-- messages so the parent transcript distinguishes all spawn-failure causes.
killSwitchMsg :: Text
killSwitchMsg = "Delegation spawning is disabled: delegation.orchestrator_enabled = false. Re-trying will not succeed until the operator re-enables it."

-- | The dedicated leaf-role error: a leaf agent cannot spawn — actionable
-- for both the model and the operator.
leafMsg :: Text
leafMsg = "AGENT_START is not available to this agent: its definition is a leaf (role: leaf). Ask the operator to grant the orchestrator role if delegation is required."

-- | The dedicated @adAllowSpawn = Just False@ error: the def explicitly
-- forbids spawning, overriding the role-based default.
allowSpawnBlockedMsg :: Text
allowSpawnBlockedMsg =
  "AGENT_START is not available to this agent: its definition has \
  \allow_spawn = false. Re-trying will not succeed until the operator \
  \sets allow_spawn = true on this agent definition."

-- | Register a finished child in the runtime registry (post-hoc; the worker
-- ran synchronously to completion). Records the instance with status
-- 'Stopped' (the synchronous child has already finished by the time this is
-- ---------------------------------------------------------------------------
-- Agent runtime action enum (AGENT_MANAGE)
-- ---------------------------------------------------------------------------

data AgentAction
  = AgInstances
  | AgStart
  | AgContinue
  | AgStatus
  | AgStop
  | AgInterrupt

parseAgentAction :: Value -> Either Text AgentAction
parseAgentAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "instances" -> Right AgInstances
      "start"     -> Right AgStart
      "continue"  -> Right AgContinue
      "status"    -> Right AgStatus
      "stop"      -> Right AgStop
      "interrupt" -> Right AgInterrupt
      other       -> Left ("unknown agent action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- | Authorize gate for the `start` action (shared with the legacy
-- AGENT_START shim). Checks both the input shape (goal or tasks present)
-- and the role/kill-switch/@adAllowSpawn@ gate from the wiring. The
-- @gAllowSpawn@ override takes precedence: @Just False@ always blocks,
-- @Just True@ always allows (even a leaf), @Nothing@ defers to the
-- role-based default.
authorizeStart :: AgentStartWiring -> Value -> Either Text ()
authorizeStart wiring v =
  let shapeGate =
        let hasGoal = case textFieldMaybe "goal" v of { Just _ -> True; Nothing -> False }
            hasTasks = case parseMaybe (withObject "in" (.:? "tasks")) v :: Maybe (Maybe Value) of { Just (Just _) -> True; _ -> False }
        in if hasGoal || hasTasks
             then Right ()
             else Left "AGENT_START requires {goal:string} (single) or {tasks:array} (batch)."
      roleGate = case gAllowSpawn (aswGate wiring) of
        Just False -> Left allowSpawnBlockedMsg
        Just True  -> Right ()
        Nothing -> case (gEffectiveRole (aswGate wiring), gOrchEnabled (aswGate wiring)) of
          (Just "orchestrator", True)  -> Right ()
          (Just "orchestrator", False) -> Left killSwitchMsg
          (_, _)                       -> Left leafMsg
  in shapeGate *> roleGate

-- | Authorize gate for AGENT_MANAGE — dispatches per-action validation.
authorizeAgentManage :: AgentStartWiring -> Value -> Either Text ()
authorizeAgentManage wiring v =
  case parseAgentAction v of
    Left e -> Left e
    Right action -> case action of
      AgInstances -> Right ()
      AgStart     -> authorizeStart wiring v
      AgContinue  -> authorizeContinue v
      AgStatus    -> maybe (Left "status requires {subagent_id:string}") (const (Right ())) . subagentIdField $ v
      AgStop      -> maybe (Left "stop requires {subagent_id:string}") (const (Right ())) . subagentIdField $ v
      AgInterrupt -> maybe (Left "interrupt requires {subagent_id:string}") (const (Right ())) . subagentIdField $ v

-- | Handle the instances action (shared with the legacy AGENT_INSTANCES shim).
handleInstances :: AgentRuntime -> SessionId -> App OpResult
handleInstances runtime owner = do
  insts <- liftIO (listAgentsFor runtime owner)
  -- Live children only, plus ONE bounded line about the retained ones.
  -- Retained entries are resumable but finished; listing them here would grow
  -- the model's context without bound and make "(no agents running)"
  -- unreachable.
  let live = filter (isLiveStatus . aiStatus) insts
      finished = length insts - length live
      liveLines = case live of
        [] -> ["(no agents running)"]
        _  -> [ subagentIdText (aiSubagentId i) <> ": "
                  <> agentDefIdText (aiId i) <> " — " <> renderStatus (aiStatus i)
                  <> maybe "" (" — " <>) (crSummary =<< aiResult i)
              | i <- live ]
      summaryLines =
        [ "(" <> tshow finished
            <> " finished child(ren) from this session, all resumable with AGENT_MANAGE continue)"
        | finished > 0 ]
      rendered = T.intercalate "\n" (liveLines <> summaryLines)
      recorded = object
        -- "count"/"ids" stay "children this session knows about" (the render
        -- is what became live-only); "live"/"finished" split it out.
        [ "count" .= length insts
        , "live" .= length live
        , "finished" .= finished
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
      let mode = parseSpawnMode v
      case mode of
        SpawnModeForeground -> handleStartForeground wiring v di
        SpawnModeBackground -> handleStartBackground wiring v di

-- | Handle the start action in foreground (blocking) mode. Calls
-- 'runDelegate' (synchronous) and returns the ChildResult(s) directly as
-- the tool result text. No sidecar append — the result is in-band.
handleStartForeground :: AgentStartWiring -> Value -> DelegateInput -> App OpResult
handleStartForeground wiring _v di = do
  cfg <- liftIO (aswConfig wiring)
  let (_, _, _, orchEnabled) = resolveDelegationConfig cfg
      runtime = aswRuntime wiring
      resolver task = do
        mResolve <- resolveTask (aswDefBackend wiring)
                                runtime
                                (aswParentDepth wiring)
                                orchEnabled
                                (aswWorker wiring)
                                task
        case mResolve of
          Left err -> pure (Left err)
          Right (def, worker) -> do
            childSid <- aswMintSession wiring
            pure (Right (def, worker, childSid))
  eResults <- liftIO (runDelegate
                        cfg
                        (aswPauseFlag wiring)
                        (aswParentActivity wiring)
                        (aswParentDepth wiring)
                        di
                        resolver)
  case eResults of
    Left err -> pure (OpResult [TrpText err] True (object []))
    Right results ->
      pure (OpResult [TrpText (encodeForegroundResults results)] False
             (object ["results" .= fmap toJSONChildResult results]))

-- | The run generation a freshly registered instance carries
-- ('registerRunningChild' inserts at generation 1). The spawn callback's crash
-- write is guarded by it, so a stop or interrupt that raced the run — and
-- bumped the generation — is not overwritten by the dying run.
initialRunGeneration :: Int
initialRunGeneration = 1

-- | Handle the start action in background (async) mode. Forks children,
-- returns immediately with per-child SpawnInfo. Existing behavior.
handleStartBackground :: AgentStartWiring -> Value -> DelegateInput -> App OpResult
handleStartBackground wiring _v di = do
      cfg <- liftIO (aswConfig wiring)
      let (_, _, _, orchEnabled) = resolveDelegationConfig cfg
          runtime = aswRuntime wiring
          parentSid = aswParentSession wiring
          callback :: AgentCompletionCallback
          callback result = do
            -- Generation-guarded: a stop or interrupt that landed while this
            -- run was in flight leaves the retained entry's status alone and
            -- suppresses the delivery, so the parent is never told that work
            -- failed after it asked for it to stop.
            mInst <- agentStatusFor runtime parentSid (crSubagentId result)
            delivery <- case mInst of
              -- A child that never registered (a resolve error) has no run to
              -- suppress: the parent must still learn the spawn failed.
              Left _   -> pure DeliverResult
              Right _  -> registerRunResult runtime (crSubagentId result)
                            initialRunGeneration result
            globalLogIO DebugS (ls ("[idle-diag] completion callback fired: subagent=" <> subagentIdText (crSubagentId result)
              <> " parentSid=" <> sessionIdText parentSid))
            case delivery of
              SuppressDelivery ->
                globalLogIO DebugS (ls ("[idle-diag] delivery suppressed (intentional termination): subagent=" <> subagentIdText (crSubagentId result)))
              DeliverResult ->
                deliverToParent wiring parentSid (completionMessage result) result
          spawnCb :: SpawnCallback
          spawnCb sid def childSid task body = do
            -- 'runDelegateAsync' calls this from the forked child thread, so
            -- this thread IS the run's control handle: record it before the
            -- body starts, or 'stopAgent' has nothing to kill.
            tid <- myThreadId
            -- The batch index is not part of the spawn seam (only 'spawnOne'
            -- knows it), so a background child records 0; the foreground path
            -- records the real index from 'crTaskIndex' post-hoc.
            registerRunningChild runtime (adId def) sid parentSid childSid
              (aswParentDepth wiring + 1) tid (Just task) (Just def) 0
              SoStartBackground
            outcome <- try body
            -- Clear the handle BEFORE reporting, so the parent's wake turn can
            -- continue the child the moment it reads the completion.
            endRun runtime sid
            case outcome of
              Right result -> pure result
              Left e -> do
                registerRunCrash runtime sid initialRunGeneration e
                case fromException e :: Maybe SomeAsyncException of
                  -- Killed by 'stopAgent' / 'interruptAgent', or abandoned
                  -- before the cap let it start. A killed run is not a
                  -- completed run: re-throw, so 'runDelegateAsync' reports no
                  -- completion — the parent must never be told the work
                  -- failed. Nothing synchronous escapes the run body today
                  -- ('runChildTask' catches the worker around its timeout), so
                  -- the arm below is the seam's defensive floor rather than a
                  -- live path.
                  Just _ -> throwIO e
                  Nothing -> pure (mkErrorResult 0 sid 0 (T.pack (show e))
                                                  (Just childSid))
      eSpawnInfos <- liftIO (runDelegateAsync
                               cfg
                               (aswPauseFlag wiring)
                               (aswParentActivity wiring)
                               (aswParentDepth wiring)
                               di
                               (resolveTask (aswDefBackend wiring)
                                            runtime
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
handleStatus :: AgentRuntime -> SessionId -> Value -> App OpResult
handleStatus runtime owner v = do
  let mSid = subagentIdField v
  case mSid of
    Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
    Just sid -> do
      rInst <- liftIO (agentStatusFor runtime owner sid)
      case rInst of
        Left err -> pure (OpResult [TrpText err] False
                         (object ["subagent_id" .= subagentIdText sid, "status" .= ("unknown" :: Text)]))
        Right inst -> do
          let s = aiStatus inst
              terminal = isTerminalStatus s
              header = "status=" <> renderStatus s
                         <> " runs=" <> tshow (aiRuns inst)
                         <> " origin=" <> renderOrigin (aiOrigin inst)
                         <> maybe "" (\r -> " exit=" <> renderChildExit (crExitReason r)
                                              <> maybe "" ((" child_session=" <>) . sessionIdText)
                                                   (crChildSession r))
                                  (aiResult inst)
              text = header
                       <> maybe "" (("\n" <>) . outcomeBody) (aiResult inst)
                       <> (if terminal
                             then "\nresumable: AGENT_MANAGE continue with this subagent_id"
                             else "")
              recorded = [ "subagent_id" .= subagentIdText sid
                         , "status" .= renderStatus s
                         , "runs" .= aiRuns inst
                         , "origin" .= renderOrigin (aiOrigin inst)
                         , "resumable" .= terminal
                         ]
                       ++ case aiResult inst of
                            Nothing -> []
                            Just result ->
                              [ "summary" .= crSummary result
                              , "child_session" .= fmap sessionIdText (crChildSession result)
                              , "exit_reason" .= renderChildExit (crExitReason result)
                              , "duration_seconds" .= crDurationSeconds result
                              ]
          pure (OpResult [TrpText text] False (object recorded))

-- | Handle the stop action (shared with the legacy AGENT_STOP shim).
handleStop :: AgentRuntime -> SessionId -> Value -> App OpResult
handleStop runtime owner v = do
  let mSid = subagentIdField v
  case mSid of
    Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
    Just sid -> do
      rOut <- liftIO (stopAgent runtime owner sid)
      case rOut of
        Left err -> pure (OpResult [TrpText err] True
                           (object ["subagent_id" .= subagentIdText sid]))
        Right StopOk -> pure (OpResult
          [TrpText "stopped (resumable with AGENT_MANAGE continue)"] False
          (object ["subagent_id" .= subagentIdText sid, "outcome" .= ("stopped" :: Text)]))
        Right StillShuttingDown -> pure (OpResult
          [TrpText "could not stop: the child is still inside a provider call; retry or wait"] True
          (object ["subagent_id" .= subagentIdText sid, "outcome" .= ("still_shutting_down" :: Text)]))

-- | Handle the interrupt action (shared with the legacy AGENT_INTERRUPT shim).
handleInterrupt :: AgentRuntime -> SessionId -> Value -> App OpResult
handleInterrupt runtime owner v = do
  let mSid = subagentIdField v
  case mSid of
    Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
    Just sid -> do
      rFound <- liftIO (interruptAgent runtime owner sid)
      case rFound of
        Left err -> pure (OpResult [TrpText err] True
                           (object ["subagent_id" .= subagentIdText sid]))
        Right found ->
          let msg = if found
                      then "interrupt requested (the child stays continuable)"
                      else "subagent not running"
          in pure (OpResult [TrpText msg] False
                    (object ["subagent_id" .= subagentIdText sid, "found" .= found]))

-- ---------------------------------------------------------------------------
-- continue: resume a child this session spawned
-- ---------------------------------------------------------------------------

-- | Cap on a @prompt@: it is fsync'd into the child's transcript and re-sent on
-- every later turn of that child, so it is bounded.
promptCap :: Int
promptCap = 32 * 1024

-- | The run budget a child may consume across continues (both modes; the claim
-- re-checks it). Mirrors 'Seal.Agent.Runtime.Registry.maxContinuesPerChild'.
continueRunLimit :: Int
continueRunLimit = 50

-- | Refusal texts — one per failed precondition, in the pinned order. Each
-- names the precondition that failed and what to do about it.
continueUnknownMsg :: SubagentId -> Text
continueUnknownMsg sid =
  "continue: unknown subagent id \"" <> subagentIdText sid
    <> "\". It was not spawned by this session, or was lost to a restart or to \
       \retention pruning. Start a new child."

continueNotOwnerMsg :: Text
continueNotOwnerMsg =
  "continue: that subagent belongs to a different session; a session may only \
  \continue the children it spawned."

continueStillRunningMsg :: SubagentId -> Text
continueStillRunningMsg sid =
  "continue: subagent " <> subagentIdText sid
    <> " is still running. Stop or interrupt it before continuing."

continueNotSettledMsg :: SubagentId -> Text
continueNotSettledMsg sid =
  "continue: subagent " <> subagentIdText sid
    <> " is still finishing its previous turn. If this persists, stop it."

continueChildrenRunningMsg :: SubagentId -> Text
continueChildrenRunningMsg sid =
  "continue: subagent " <> subagentIdText sid
    <> " still has running subagents of its own; wait for them or stop them."

continueParentBudgetMsg :: Int -> Text
continueParentBudgetMsg n =
  "continue: delegation.max_concurrent_children reached (" <> tshow n
    <> "); wait for a child to finish."

continueNoSnapshotMsg :: SubagentId -> Text
continueNoSnapshotMsg sid =
  "continue: subagent " <> subagentIdText sid
    <> " was registered without a task snapshot and cannot be continued; \
       \start a new child."

continueRunBudgetMsg :: SubagentId -> Text
continueRunBudgetMsg sid =
  "continue: subagent " <> subagentIdText sid <> " has been continued "
    <> tshow continueRunLimit <> " times; start a fresh child for new work."

continueMissingDirMsg :: SubagentId -> Text
continueMissingDirMsg sid =
  "continue: subagent " <> subagentIdText sid
    <> " has no transcript on disk any more; start a new child."

continueNoIdMsg :: Text
continueNoIdMsg =
  "continue requires {subagent_id:string} (non-empty, at most 256 characters, \
  \no control characters)."

continueEmptyPromptMsg :: Text
continueEmptyPromptMsg =
  "continue: \"prompt\" must not be empty; omit it to send the default \
  \continuation nudge."

continuePromptTooLongMsg :: Int -> Text
continuePromptTooLongMsg n =
  "continue: \"prompt\" is " <> tshow n <> " characters; the limit is "
    <> tshow promptCap <> "."

continuePromptControlMsg :: Text
continuePromptControlMsg =
  "continue: \"prompt\" must not contain NUL or control characters."

continueBadModeMsg :: Text
continueBadModeMsg =
  "continue: \"mode\" must be \"foreground\" or \"background\"."

-- | Fields that only @start@ accepts. Ignoring them would spend a whole child
-- turn on the wrong message.
startOnlyFields :: [Text]
startOnlyFields = ["id", "goal", "context", "role", "tasks"]

-- | Is @field@ present in the object (whatever its type)?
hasField :: Value -> Text -> Bool
hasField v f =
  case parseMaybe (withObject "in" (.:? fromText f)) v :: Maybe (Maybe Value) of
    Just (Just _) -> True
    _             -> False

-- | Authorize gate for @continue@: shape first (prompt, mode), then the
-- start-only fields, then the id text. Pure — no IO, no state.
authorizeContinue :: Value -> Either Text ()
authorizeContinue v = do
  case textFieldMaybe "prompt" v of
    Nothing -> pure ()
    Just p
      | T.null p              -> Left continueEmptyPromptMsg
      | T.length p > promptCap -> Left (continuePromptTooLongMsg (T.length p))
      | T.any isControlChar p  -> Left continuePromptControlMsg
      | otherwise              -> pure ()
  case parseMaybe (withObject "in" (.:? "mode")) v :: Maybe (Maybe Text) of
    Just (Just m) | m /= "foreground" && m /= "background" -> Left continueBadModeMsg
    _ -> pure ()
  forM_ startOnlyFields $ \f ->
    when (hasField v f) $
      Left ("continue: \"" <> f <> "\" is a start-only field; pass the "
              <> "instruction as \"prompt\".")
  case subagentIdField v of
    Nothing -> Left continueNoIdMsg
    Just _  -> Right ()

-- | Bounded settle wait: the ordinary kill→cleanup window is not a refusal.
settleWait :: AgentInstance -> IO Bool
settleWait inst = do
  settled <- workerSettled inst
  if settled then pure True else pollUntil 250 (workerSettled inst)

-- | Refuse a continue: log the reason (never the prompt body, never the
-- instance), return the text, and spend no run budget.
refuseContinue :: SubagentId -> Text -> Text -> App OpResult
refuseContinue sid reason msg = do
  liftIO $ globalLogIO DebugS (ls ("[continue] refused reason=" <> reason
    <> " sid=" <> subagentIdText sid))
  pure (OpResult [TrpText msg] True
         (object ["subagent_id" .= subagentIdText sid, "refused" .= reason]))

-- | Handle the @continue@ action. The prechecks run in the pinned order —
-- lookup, ownership, pause, terminal status, settle, the child's own children,
-- the per-parent budget — and the claim then re-checks ownership, status, the
-- snapshot and the run budget atomically.
handleContinue :: AgentStartWiring -> Value -> App OpResult
handleContinue wiring v = do
  let runtime = aswRuntime wiring
      owner = aswParentSession wiring
  case subagentIdField v of
    Nothing -> pure (OpResult [TrpText continueNoIdMsg] True (object []))
    Just sid -> do
      insts <- liftIO (listAgents runtime)
      case find (\i -> aiSubagentId i == sid) insts of
        Nothing -> refuseContinue sid "unknown-id" (continueUnknownMsg sid)
        Just inst
          | not (ownsChild owner inst) ->
              refuseContinue sid "not-owner" continueNotOwnerMsg
          | otherwise -> do
              paused <- liftIO (isSpawnPaused (aswPauseFlag wiring))
              if paused
                then refuseContinue sid "paused" spawnPausedMsg
                else if not (isTerminalStatus (aiStatus inst))
                  then refuseContinue sid "not-terminal" (continueStillRunningMsg sid)
                  else do
                    settled <- liftIO (settleWait inst)
                    if not settled
                      then refuseContinue sid "not-settled" (continueNotSettledMsg sid)
                      else do
                        childrenRunning <- liftIO (hasRunningChildren runtime (aiSession inst))
                        if childrenRunning
                          then refuseContinue sid "children-running"
                                 (continueChildrenRunningMsg sid)
                          else do
                            cfg <- liftIO (aswConfig wiring)
                            let (maxConc, childTimeout, _, _) = resolveDelegationConfig cfg
                                mode = parseSpawnMode v
                            withinBudget <- case mode of
                              SpawnModeForeground -> pure True
                              SpawnModeBackground ->
                                (< maxConc) <$> liftIO (countRunningChildren runtime owner)
                            if not withinBudget
                              then refuseContinue sid "parent-budget"
                                     (continueParentBudgetMsg maxConc)
                              else startContinue wiring v sid inst mode childTimeout

-- | The claim and the run. The message, the def, the child session, the task
-- index and the worker builder are all the spawn's — only the user message
-- changes.
startContinue
  :: AgentStartWiring -> Value -> SubagentId -> AgentInstance
  -> SpawnMode -> Double -> App OpResult
startContinue wiring v sid inst mode childTimeout =
  case (aiTask inst, aiDef inst) of
    (Just task, Just def)
      -- The claim re-checks this atomically; checking here first is what lets
      -- the refusal name the run budget instead of a generic claim failure.
      | aiRuns inst >= continueRunLimit ->
          refuseContinue sid "run-budget" (continueRunBudgetMsg sid)
      | otherwise -> do
      let runtime = aswRuntime wiring
          owner = aswParentSession wiring
          paths = aswPaths wiring
          prompt = textFieldMaybe "prompt" v
          promptChars = maybe 0 T.length prompt
          modeText = case mode of
            SpawnModeForeground -> "foreground" :: Text
            SpawnModeBackground -> "background"
          origin = case mode of
            SpawnModeForeground -> SoContinueForeground
            SpawnModeBackground -> SoContinueBackground
          recorded runs = object
            [ "subagent_id" .= subagentIdText sid
            , "child_session" .= sessionIdText (aiSession inst)
            , "mode" .= modeText
            , "prompt_present" .= isJust prompt
            , "prompt_chars" .= promptChars
            , "runs" .= runs
            , "status" .= ("running" :: Text)
            ]
      conv <- liftIO (childConversationPresent paths owner (aiSession inst))
      case conv of
        Nothing -> refuseContinue sid "missing-dir" (continueMissingDirMsg sid)
        Just hasConversation -> do
          let message = fromMaybe
                          (if hasConversation then continueNudge else ctGoal task)
                          prompt
              worker = aswWorker wiring
          start <- liftIO getCurrentTime
          let body = runChildTask (aswParentActivity wiring) childTimeout start
                       (aiTaskIndex inst) sid (aiSession inst) def worker
                       (task { ctGoal = message })
          claim <- liftIO (resumeAgent runtime owner sid origin body)
          case claim of
            Left e ->
              refuseContinue sid "claim-lost"
                ("continue: could not start the run (" <> e
                   <> "); check AGENT_STATUS and retry.")
            Right (claimed, sink) -> do
              let runs = aiRuns claimed
              liftIO $ globalLogIO DebugS (ls ("[continue] started sid="
                <> subagentIdText sid <> " runs=" <> tshow runs
                <> " mode=" <> modeText <> " prompt_chars=" <> tshow promptChars))
              case mode of
                SpawnModeForeground -> do
                  outcome <- liftIO (atomically (takeTMVar sink))
                  case outcome of
                    Right (_, result) ->
                      pure (OpResult
                             [TrpText (continueForegroundText runs result)]
                             False (recorded runs))
                    Left e ->
                      pure (OpResult
                             [TrpText ("continue: the run failed (" <> tshow e
                                         <> "); check AGENT_STATUS.")]
                             True (recorded runs))
                SpawnModeBackground -> do
                  liftIO $ void $ forkIO $
                    deliverContinued wiring owner runs sink
                  pure (OpResult
                         [TrpText (continueAckText sid (aiSession inst) runs)]
                         False (recorded runs))
    _ -> refuseContinue sid "no-snapshot" (continueNoSnapshotMsg sid)

-- | Wait for a background continue's run to finish and deliver its reply
-- through the shared completion path (sidecar + idle wake), off the worker
-- thread. The sink is always filled, so this cannot block for ever.
deliverContinued
  :: AgentStartWiring -> SessionId -> Int
  -> TMVar (Either SomeException (Delivery, ChildResult)) -> IO ()
deliverContinued wiring parentSid runs sink = do
  outcome <- atomically (takeTMVar sink)
  case outcome of
    Right (DeliverResult, result) ->
      deliverToParent wiring parentSid (continueCompletionText runs result) result
    Right (SuppressDelivery, result) ->
      globalLogIO DebugS (ls ("[continue] delivery suppressed (intentional termination): subagent="
        <> subagentIdText (crSubagentId result)))
    Left e ->
      globalLogIO DebugS (ls ("[continue] run failed, nothing to deliver: " <> tshow e))

-- | Background acknowledgement: the child is working, its reply will arrive on
-- its own.
continueAckText :: SubagentId -> SessionId -> Int -> Text
continueAckText sid childSid runs =
  subagentIdText sid <> " | " <> sessionIdText childSid
    <> " | running (continued #" <> tshow runs <> ")\n\n"
    <> "The child is working in the background. Its reply will arrive as a "
    <> "separate message headed [subagent " <> subagentIdText sid
    <> " replied (continue #" <> tshow runs <> ")] — do NOT call AGENT_MANAGE "
    <> "status, sleep, or any polling tool."

-- | The reply header for a continued child.
continueTitle :: Int -> Text
continueTitle runs = "replied (continue #" <> tshow runs <> ")"

-- | Foreground result: returned in this tool result, so no NO_REPLY clause and
-- no wake.
continueForegroundText :: Int -> ChildResult -> Text
continueForegroundText runs r =
  outcomeHeader (continueTitle runs) r <> "\n" <> outcomeBody r
    <> "\n\n" <> continueHint

-- | Background completion message: the reply the parent asked for.
continueCompletionText :: Int -> ChildResult -> Text
continueCompletionText runs r =
  outcomeHeader (continueTitle runs) r
    <> "\nThis is the reply you requested. " <> outcomeBody r
    <> "\n\n" <> continueHint <> "\n\n" <> noReplyClause

-- | Append a completion to the parent's sidecar and wake it if idle — the one
-- delivery path, shared by spawn and continue.
--
-- Honours the descendant-settle rule: a child with pending descendants has only
-- a partial answer, so the delivery waits for them and the child then
-- synthesizes a final summary. When the run-record registry is unavailable
-- (tests) or the child has no pending descendants, delivery is immediate.
--
-- The sidecar (not @conversation.jsonl@) is the target because writing straight
-- into the conversation while the single-writer daemon is active desynchronizes
-- its in-memory diff and silently drops messages.
deliverToParent :: AgentStartWiring -> SessionId -> Text -> ChildResult -> IO ()
deliverToParent wiring parentSid message result = do
  let mRunRecords = aswRunRecords wiring
  defer <- case (mRunRecords, crChildSession result) of
    (Just reg, Just childSid) -> RunRecord.shouldDeferDelivery reg childSid
    _                         -> pure False
  if defer
    then globalLogIO DebugS (ls ("[idle-diag] completion deferred (descendants pending): subagent=" <> subagentIdText (crSubagentId result)))
    else do
      appendCompletionToSidecar (aswPaths wiring) parentSid message
      globalLogIO DebugS (ls ("[idle-diag] completion appended to sidecar: subagent=" <> subagentIdText (crSubagentId result)
        <> " parentSid=" <> sessionIdText parentSid
        <> " childSession=" <> maybe "none" sessionIdText (crChildSession result)
        <> " messageChars=" <> tshow (T.length message)))
      globalLogIO DebugS (ls ("[idle-diag] firing onIdleCompletion hook: subagent=" <> subagentIdText (crSubagentId result)))
      forM_ (aswOnIdleCompletion wiring) id

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
  , toDesc = "Manage agent runtime. Use action to select: instances (list the children this session spawned that are running now), start (spawn child agents), continue (resume a child this session spawned and keep its conversation — only after it has finished, been stopped, been interrupted, or crashed; with prompt it receives that as its next user message, without prompt it receives \"[System: the harness is resuming you. Continue your previous task from where you left off. Pick up whatever is unfinished; do not start over.]\"; its agent def and tool grant are the ones it was spawned with), status (debugging/observability only — NOT for completion checking), stop (kill the agent — no completion message arrives — and it stays continuable), interrupt (cooperative stop; its reply still arrives). start and continue deliver the reply automatically in background mode — do NOT call AGENT_MANAGE status, sleep, or any polling tool. mode: \"foreground\" blocks until the reply and returns it in this tool result (it can block for up to delegation.child_timeout_seconds and cannot be interrupted); mode: \"background\" (default) returns immediately and the reply arrives later as a separate message. Replies are headed [subagent <sid> replied (continue #n)], where #n is the child's run number (1 = the original spawn). A continued child stays resumable: pass the same subagent_id to continue again. Ids do not survive a harness restart and finished children may be pruned."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["instances", "start", "continue", "status", "stop", "interrupt"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "mode" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["foreground", "background"] :: [Text])
              , "description" .= ("Run mode (start/continue). \"foreground\" blocks until the child finishes and returns the reply in this tool result; \"background\" (default) returns immediately and the reply arrives as a separate message. Foreground can block for child_timeout_seconds and cannot be interrupted. Must be one of these two values." :: Text)
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
              , "description" .= ("Batch: [{id, goal, context?, role?, isolate_workdir?}] (start)." :: Text)
              ]
          , fromText "prompt" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Next user message for the child (continue). A non-empty string of at most 32 KiB; it is re-sent on every later turn of this child, so keep it short. Omit to send the default continuation nudge. Not the system prompt — that is fixed by the agent def. Start-only fields (id/goal/context/role/tasks) are rejected, not ignored." :: Text)
              ]
          , fromText "subagent_id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Subagent id, as returned by start/continue and echoed in completion messages (status/stop/interrupt/continue)." :: Text)
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
          AgInstances -> handleInstances (aswRuntime wiring) (aswParentSession wiring)
          AgStart     -> handleStart wiring v
          AgContinue  -> handleContinue wiring v
          AgStatus    -> handleStatus (aswRuntime wiring) (aswParentSession wiring) v
          AgStop      -> handleStop (aswRuntime wiring) (aswParentSession wiring) v
          AgInterrupt -> handleInterrupt (aswRuntime wiring) (aswParentSession wiring) v
  }

-- ---------------------------------------------------------------------------
-- Legacy shims (backward compatibility)
-- ---------------------------------------------------------------------------

-- | AGENT_INSTANCES (legacy shim): delegates to the instances handler.
agentInstancesOp :: SessionId -> AgentRuntime -> Opcode
agentInstancesOp owner runtime = TrustedOpcode
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
  , toRun = \_ _ -> handleInstances runtime owner
  }

-- | AGENT_START (legacy shim): delegates to the start handler.
agentStartOp :: AgentStartWiring -> Opcode
agentStartOp wiring = TrustedOpcode
  { toName = OpName "AGENT_START"
  , toTrust = Trusted
  , toDesc = "Spawn one or more child agents asynchronously. Returns immediately with per-child subagent_id + child_session (status=running). Completion is delivered automatically via push notification — do NOT poll AGENT_STATUS for completion. Single mode: {id, goal, context?, role?, isolate_workdir?}. Batch mode: {tasks: [{id, goal, context?, role?, isolate_workdir?}, ...]}. (Legacy — prefer AGENT_MANAGE with action=\"start\".)"
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
agentStatusOp :: SessionId -> AgentRuntime -> Opcode
agentStatusOp owner runtime = TrustedOpcode
  { toName = OpName "AGENT_STATUS"
  , toTrust = Trusted
  , toDesc = "Read one running agent's status by subagent_id. For debugging/observability only — NOT for completion checking. Completion is delivered automatically via push notification. (Legacy — prefer AGENT_MANAGE with action=\"status\".)"
  , toInSchema = singleStringSchema "subagent_id" "The subagent id (from AGENT_START's result)."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STATUS requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toBlocking = False
  , toRun = \_ v -> handleStatus runtime owner v
  }

-- | AGENT_STOP (legacy shim): delegates to the stop handler.
agentStopOp :: SessionId -> AgentRuntime -> Opcode
agentStopOp owner runtime = TrustedOpcode
  { toName = OpName "AGENT_STOP"
  , toTrust = Trusted
  , toDesc = "Stop a running agent instance by subagent_id (idempotent). (Legacy — prefer AGENT_MANAGE with action=\"stop\".)"
  , toInSchema = singleStringSchema "subagent_id" "The subagent id to stop."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STOP requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toBlocking = False
  , toRun = \_ v -> handleStop runtime owner v
  }

-- | AGENT_INTERRUPT (legacy shim): delegates to the interrupt handler.
agentInterruptOp :: SessionId -> AgentRuntime -> Opcode
agentInterruptOp owner runtime = TrustedOpcode
  { toName = OpName "AGENT_INTERRUPT"
  , toTrust = Trusted
  , toDesc = "Request that a running subagent stop at its next iteration boundary (cooperative; the worker polls an interrupt flag between turns). (Legacy — prefer AGENT_MANAGE with action=\"interrupt\".)"
  , toInSchema = singleStringSchema "subagent_id" "The subagent id to interrupt."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_INTERRUPT requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toBlocking = False
  , toRun = \_ v -> handleInterrupt runtime owner v
  }

-- ---------------------------------------------------------------------------
-- Outcome vocabulary and reply texts
-- ---------------------------------------------------------------------------

-- | The single @status=@ dialect, shared by every render (@AGENT_STATUS@,
-- foreground results, completion messages). Pinned by the design so the model
-- never sees a Haskell constructor name.
renderChildStatus :: ChildStatus -> Text
renderChildStatus = \case
  CsCompleted   -> "completed"
  CsFailed      -> "failed"
  CsTimeout     -> "timeout"
  CsInterrupted -> "interrupted"
  CsError       -> "error"

-- | The single @exit=@ dialect.
renderChildExit :: ChildExitReason -> Text
renderChildExit = \case
  CerCompleted     -> "completed"
  CerMaxIterations -> "max_iterations"
  CerTimeout       -> "timeout"
  CerInterrupted   -> "interrupted"
  CerError         -> "error"

-- | How the child was started or continued (part of the instance's origin).
renderOrigin :: SpawnOrigin -> Text
renderOrigin = \case
  SoStartForeground    -> "start/foreground"
  SoStartBackground    -> "start/background"
  SoContinueForeground -> "continue/foreground"
  SoContinueBackground -> "continue/background"

-- | How the parent continues this child again. One wording, every surface.
continueHint :: Text
continueHint =
  "Send another message with AGENT_MANAGE continue and the same subagent_id \
  \to continue the conversation."

-- | Scoped to THIS request: the global "you already answered" wording licensed
-- throwing away a fresh reply in a multi-turn exchange.
noReplyClause :: Text
noReplyClause =
  "If you already sent your answer for this request, reply with NO_REPLY."

-- | The default message for a continue with no @prompt@. Framed like the
-- harness's own injected prompt so the child distinguishes a nudge from a
-- parent instruction.
continueNudge :: Text
continueNudge =
  "[System: the harness is resuming you. Continue your previous task from \
  \where you left off. Pick up whatever is unfinished; do not start over.]"

-- | Shown when a child produced neither a summary nor an error.
noFinalTextPlaceholder :: Text
noFinalTextPlaceholder = "(no final text from the child)"

-- | Appended for @status=timeout@: the child's conversation survives, so a
-- continue resumes rather than restarts it.
timeoutContinuationClause :: Text
timeoutContinuationClause =
  "the child was cut off at its time limit; continuing resumes it rather than \
  \restarting it."

-- | @[subagent <sid> completed] status=… exit=… child_session=…@ (or
-- @replied (continue #n)@). @child_session@ is stable across continues and is
-- not a correlation key — only the run number is.
outcomeHeader :: Text -> ChildResult -> Text
outcomeHeader title r =
  "[subagent " <> subagentIdText (crSubagentId r) <> " " <> title <> "] status="
    <> renderChildStatus (crStatus r) <> " exit=" <> renderChildExit (crExitReason r)
    <> maybe "" ((" child_session=" <>) . sessionIdText) (crChildSession r)

-- | The reply body: summary, else @crError@, else a placeholder — every
-- failure path sets the summary to 'Nothing' and puts the diagnosis in
-- @crError@, so a summary-only render would silently drop it.
outcomeBody :: ChildResult -> Text
outcomeBody r = body <> timeoutClause
  where
    body = fromMaybe noFinalTextPlaceholder (crSummary r <|> crError r)
    timeoutClause
      | crStatus r == CsTimeout = "\n" <> timeoutContinuationClause
      | otherwise = ""

-- | Render an 'Int' as 'Text' (no 'show'-through-'pack' sprinkled around).
tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Starting or running — the states @AGENT_INSTANCES@ lists.
isLiveStatus :: AgentStatus -> Bool
isLiveStatus Starting = True
isLiveStatus Running  = True
isLiveStatus _        = False

-- | Retained and finished — the states @continue@ can claim.
isTerminalStatus :: AgentStatus -> Bool
isTerminalStatus Stopped     = True
isTerminalStatus Interrupted = True
isTerminalStatus (Crashed _) = True
isTerminalStatus _           = False

renderStatus :: AgentStatus -> Text
renderStatus = \case
  Starting     -> "starting"
  Running      -> "running"
  Idle         -> "idle"
  Stopped      -> "stopped"
  Interrupted  -> "interrupted"
  Crashed m    -> "crashed: " <> m

-- | Extract and validate the @subagent_id@ string field from a JSON object:
-- non-empty, at most 'subagentIdCap' characters, and free of control
-- characters. Validation happens here so no @AGENT_MANAGE@ action, no legacy
-- shim, and no debug line or @orRecorded@ payload can carry a forged id.
subagentIdField :: Value -> Maybe SubagentId
subagentIdField v = do
  t <- parseMaybe (withObject "in" (.: "subagent_id")) v
  if isValidSubagentIdText t then Just (SubagentId t) else Nothing

-- | Cap on a @subagent_id@ string: a def id (≤1024 is the def-name cap, but
-- ids are shorter) plus a 9-character suffix fits well inside this.
subagentIdCap :: Int
subagentIdCap = 256

isValidSubagentIdText :: Text -> Bool
isValidSubagentIdText t =
  not (T.null t) && T.length t <= subagentIdCap && not (T.any isControlChar t)

isControlChar :: Char -> Bool
isControlChar c = c < ' ' || c == '\DEL'

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
  <>
  "\n\nSub-agents are running in the background. Completion will be delivered to you automatically as a message — do NOT call AGENT_MANAGE status, sleep, or any polling tool. Track the expected child IDs and wait for completion events to arrive. Only send your final answer after ALL expected completions have arrived. If a completion event arrives AFTER your final answer, reply with NO_REPLY."
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

-- | Render the foreground ChildResult list as a text block for the model.
-- One block per child with status, exit reason, child session, and summary.
encodeForegroundResults :: [ChildResult] -> Text
encodeForegroundResults [] = "(no children spawned)"
encodeForegroundResults results = T.intercalate "\n\n" (map renderOne results)
  where
    -- A foreground-spawned child is retained, so this is the moment the
    -- parent holds a resumable handle: say how to continue.
    renderOne r =
      outcomeHeader "completed" r <> "\n" <> outcomeBody r <> "\n\n" <> continueHint

-- | Encode a 'ChildResult' as JSON for the 'orRecorded' payload.
toJSONChildResult :: ChildResult -> Value
toJSONChildResult r = object
  [ "subagent_id"   .= subagentIdText (crSubagentId r)
  , "status"        .= T.pack (show (crStatus r))
  , "exit_reason"   .= T.pack (show (crExitReason r))
  , "summary"       .= crSummary r
  , "child_session" .= fmap sessionIdText (crChildSession r)
  , "duration_seconds" .= crDurationSeconds r
  ]

-- | Build the user-role harness message appended to the parent's
-- @conversation.jsonl@ when a child completes. The parent's next turn sees
-- this as a user message, so the model learns the child finished without
-- polling 'AGENT_STATUS'. The message is secret-free (only the summary,
-- status, child session, and exit reason — never @crParts@).
completionMessage :: ChildResult -> Text
completionMessage r =
  outcomeHeader "completed" r <> "\n" <> outcomeBody r <> "\n\n" <> noReplyClause
