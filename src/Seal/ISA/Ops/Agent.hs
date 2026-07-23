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
  ( AgentDef (..), mkAgentDefId, agentDefIdText )
import Seal.Agent.Runtime.Delegation
  ( AgentWorkerBuilder
  , ChildResult (..)
  , ChildTask (..)
  , DelegationConfig
  , DelegateInput (..)
  , SpawnPauseFlag
  , ParentActivity
  , SubagentId (..)
  , runDelegate
  , subagentIdText
  )
import Seal.Agent.Runtime.Registry
  ( AgentInstance (..), AgentRuntime, AgentStatus (..), agentStatus
  , interruptAgent, listAgents, stopAgent )
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, TrustLevel (..))
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

-- ---------------------------------------------------------------------------
-- AGENT_DEF_WRITE
-- ---------------------------------------------------------------------------

-- | AGENT_DEF_WRITE: upsert an agent definition by id. If the def already
-- exists, its name/system/tools are updated (the original 'adSession'
-- provenance and 'adCreatedAt' are preserved; only 'adUpdatedAt' is bumped);
-- if not, a fresh def is created. The name, provider, model, system prompt,
-- and tool list are recorded in full (agent-visible data); 'orRecorded'
-- carries the id + op name + fields + @was_new@.
agentDefWriteOp :: AgentDefBackend -> SessionId -> Opcode
agentDefWriteOp backend session = TrustedOpcode
  { toName = OpName "AGENT_DEF_WRITE"
  , toTrust = Trusted
  , toDesc = "Create or update an agent definition by id (upsert; preserves provenance on update)."
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
          ]
      , "required" .= (["id", "name", "provider", "model"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_DEF_WRITE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          mExisting <- liftIO (adbRead backend aid)
          now <- liftIO getCurrentTime
          let (def, wasNew) = case mExisting of
                Just existing ->
                  ( existing
                      { adName = textField "name" v
                      , adSystem = textFieldMaybe "system" v
                      , adTools = toolsField v
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
                      , adCreatedAt = now
                      , adUpdatedAt = now
                      , adSession = session
                      }
                  , True
                  )
          liftIO (adbUpdate backend def)
          let recorded = encodeDefRecorded def wasNew
          pure (OpResult [TrpText (if wasNew then "defined" else "updated")] False recorded)
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- ---------------------------------------------------------------------------
-- AGENT_DEF_READ
-- ---------------------------------------------------------------------------

agentDefReadOp :: AgentDefBackend -> Opcode
agentDefReadOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_READ"
  , toTrust = Trusted
  , toDesc = "Read one agent definition by id."
  , toInSchema = singleStringSchema "id" "The agent def id to read."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_DEF_READ requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          mDef <- liftIO (adbRead backend aid)
          case mDef of
            Nothing -> pure (OpResult [TrpText "agent def not found"] True (object ["id" .= agentDefIdText aid]))
            Just d  -> do
              let rendered = renderDef d
                  recorded = encodeDefRecorded d False
              pure (OpResult [TrpText rendered] False recorded)
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- ---------------------------------------------------------------------------
-- AGENT_DEF_LIST
-- ---------------------------------------------------------------------------

agentDefListOp :: AgentDefBackend -> Opcode
agentDefListOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_LIST"
  , toTrust = Trusted
  , toDesc = "List all agent definitions (id + name + provider/model)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toRun = \_ _ -> do
      defs <- liftIO (adbList backend)
      let rendered = case defs of
            [] -> "(no agent definitions)"
            _  -> T.intercalate "\n"
                    [ agentDefIdText (adId d) <> ": " <> adName d
                        <> " (" <> adProvider d <> "/" <> modelName <> ")"
                    | d <- defs, let ModelId modelName = adModel d ]
          recorded = object
            [ "count" .= length defs
            , "ids" .= fmap (agentDefIdText . adId) defs
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }

-- ---------------------------------------------------------------------------
-- AGENT_DEF_DELETE
-- ---------------------------------------------------------------------------

agentDefDeleteOp :: AgentDefBackend -> Opcode
agentDefDeleteOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_DELETE"
  , toTrust = Trusted
  , toDesc = "Delete an agent definition by id (idempotent)."
  , toInSchema = singleStringSchema "id" "The agent def id to delete."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_DEF_DELETE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
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
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- ---------------------------------------------------------------------------
-- AGENT_INSTANCES
-- ---------------------------------------------------------------------------

-- | AGENT_INSTANCES: snapshot the in-process agent runtime (running
-- instances). Trusted — listing running instances is harness-internal, not an
-- evolutionary mutation.
agentInstancesOp :: AgentRuntime -> Opcode
agentInstancesOp runtime = TrustedOpcode
  { toName = OpName "AGENT_INSTANCES"
  , toTrust = Trusted
  , toDesc = "List running agent instances (subagent_id + def id + status)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toRun = \_ _ -> do
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
  }

-- ---------------------------------------------------------------------------
-- AGENT_START (synchronous goal-driven delegation)
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
    -- ^ Re-read the [delegation] config per AGENT_START call (so config
    -- changes take effect without a restart). The IO action reads
    -- @config.toml@ and returns the resolved 'DelegationConfig'.
  , aswPauseFlag    :: SpawnPauseFlag
  , aswParentActivity :: Maybe ParentActivity
  , aswMintSession  :: IO SessionId
    -- ^ Mint a fresh 'SessionId' for a child.
  , aswParentDepth  :: Int
    -- ^ The parent's delegation depth (0 for a top-level turn).
  , aswWorker       :: AgentWorkerBuilder
    -- ^ The worker-builder (closes over per-turn 'AgentEnv' deps).
  }

-- | AGENT_START: spawn one or more child agents, run each against a goal to
-- completion, return a JSON result per child. Input is either
-- @{id, goal, context?, role?}@ (single mode) or @{tasks: [{id, goal, context?, role?}, ...]}@
-- (batch mode). Returns JSON with a @results@ array, one entry per task.
agentStartOp :: AgentStartWiring -> Opcode
agentStartOp wiring = TrustedOpcode
  { toName = OpName "AGENT_START"
  , toTrust = Trusted
  , toDesc = "Spawn one or more child agents, run each against a goal to completion, return a JSON result per child. Single mode: {id, goal, context?, role?}. Batch mode: {tasks: [{id, goal, context?, role?}, ...]}."
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
              , "description" .= ("\"leaf\" (default) or \"orchestrator\". Orchestrators may spawn their own subagents, bounded by max_spawn_depth." :: Text)
              ]
          , fromText "tasks" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("Batch mode: array of {id, goal, context?, role?}. Cap on parallelism is delegation.max_concurrent_children." :: Text)
              ]
          ]
      , "required" .= (["goal"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = \v ->
      -- Require either a top-level goal (single) or a tasks array (batch).
      let hasGoal = case textFieldMaybe "goal" v of { Just _ -> True; Nothing -> False }
          hasTasks = case parseMaybe (withObject "in" (.:? "tasks")) v :: Maybe (Maybe Value) of { Just (Just _) -> True; _ -> False }
      in if hasGoal || hasTasks
           then Right ()
           else Left "AGENT_START requires {goal:string} (single) or {tasks:array} (batch)."
  , toRun = \_ v -> do
      input <- liftIO (parseInput v)
      case input of
        Left err -> pure (OpResult [TrpText err] True (object []))
        Right di -> do
          cfg <- liftIO (aswConfig wiring)
          eResults <- liftIO (runDelegate
                                cfg
                                (aswPauseFlag wiring)
                                (aswParentActivity wiring)
                                (aswParentDepth wiring)
                                di
                                (resolveTask (aswDefBackend wiring)
                                             (aswRuntime wiring)
                                             (aswMintSession wiring)
                                             (aswParentDepth wiring)
                                             (aswWorker wiring)))
          case eResults of
            Left err -> pure (OpResult [TrpText err] True (object []))
            Right results -> do
              -- Register each finished child (no-op in the synchronous
              -- model; the 'ChildResult' payload IS the post-hoc record).
              -- Kept for a future enhancement that registers before the run
              -- (requires a fork-based model).
              mapM_ (liftIO . registerChild (aswRuntime wiring)) results
              let rendered = encodeResultsJson results
              pure (OpResult [TrpText rendered] False (object ["results" .= results]))
  }

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
-- the def id is invalid or the def doesn't exist.
resolveTask
  :: AgentDefBackend
  -> AgentRuntime
  -> IO SessionId
  -> Int
  -> AgentWorkerBuilder
  -> ChildTask
  -> IO (Either Text (AgentDef, AgentWorkerBuilder, SessionId))
resolveTask defBackend _runtime mintSession _parentDepth worker task = do
  case mkAgentDefId (ctDefId task) of
    Left err -> pure (Left err)
    Right aid -> do
      mDef <- adbRead defBackend aid
      case mDef of
        Nothing  -> pure (Left ("agent def not found: " <> ctDefId task))
        Just def -> do
          sid <- mintSession
          pure (Right (def, worker, sid))

-- | Register a finished child in the runtime registry (post-hoc; the worker
-- ran synchronously). No-op in the synchronous model — the 'ChildResult'
-- payload IS the post-hoc record. Kept for a future enhancement that
-- registers before the run (requires a fork-based model).
registerChild :: AgentRuntime -> ChildResult -> IO ()
registerChild _ _ = pure ()

-- ---------------------------------------------------------------------------
-- AGENT_STATUS
-- ---------------------------------------------------------------------------

agentStatusOp :: AgentRuntime -> Opcode
agentStatusOp runtime = TrustedOpcode
  { toName = OpName "AGENT_STATUS"
  , toTrust = Trusted
  , toDesc = "Read one running agent's status by subagent_id."
  , toInSchema = singleStringSchema "subagent_id" "The subagent id (from AGENT_START's result)."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STATUS requires {subagent_id:string}") checkSubagentId . subagentIdField
  , toRun = \_ v -> do
      let mSid = subagentIdField v
      case mSid of
        Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
        Just sid -> do
          mStatus <- liftIO (agentStatus runtime sid)
          case mStatus of
            Nothing -> pure (OpResult [TrpText "not running"] False (object ["subagent_id" .= subagentIdText sid, "status" .= ("stopped" :: Text)]))
            Just s  -> pure (OpResult [TrpText (renderStatus s)] False (object ["subagent_id" .= subagentIdText sid, "status" .= renderStatus s]))
  }
  where
    checkSubagentId _ = Right ()

-- ---------------------------------------------------------------------------
-- AGENT_STOP
-- ---------------------------------------------------------------------------

-- | AGENT_STOP: stop a running agent instance (kill the thread, deregister).
-- Idempotent. Now keyed by @subagent_id@ (the new AGENT_START returns
-- subagent ids, not def ids).
agentStopOp :: AgentRuntime -> Opcode
agentStopOp runtime = TrustedOpcode
  { toName = OpName "AGENT_STOP"
  , toTrust = Trusted
  , toDesc = "Stop a running agent instance by subagent_id (idempotent)."
  , toInSchema = singleStringSchema "subagent_id" "The subagent id to stop."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STOP requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toRun = \_ v -> do
      let mSid = subagentIdField v
      case mSid of
        Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
        Just sid -> do
          _ <- liftIO (stopAgent runtime sid)
          pure (OpResult [TrpText "stopped"] False (object ["subagent_id" .= subagentIdText sid]))
  }

-- ---------------------------------------------------------------------------
-- AGENT_INTERRUPT
-- ---------------------------------------------------------------------------

-- | AGENT_INTERRUPT: request that a single running subagent stop at its next
-- iteration boundary. Unlike AGENT_STOP (which hard-kills the thread),
-- AGENT_INTERRUPT sets a flag the worker polls between turns, letting it
-- exit cleanly. Trusted.
agentInterruptOp :: AgentRuntime -> Opcode
agentInterruptOp runtime = TrustedOpcode
  { toName = OpName "AGENT_INTERRUPT"
  , toTrust = Trusted
  , toDesc = "Request that a running subagent stop at its next iteration boundary (cooperative; the worker polls an interrupt flag between turns)."
  , toInSchema = singleStringSchema "subagent_id" "The subagent id to interrupt."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_INTERRUPT requires {subagent_id:string}") (const (Right ())) . subagentIdField
  , toRun = \_ v -> do
      let mSid = subagentIdField v
      case mSid of
        Nothing -> pure (OpResult [TrpText "invalid subagent id"] True (object []))
        Just sid -> do
          found <- liftIO (interruptAgent runtime sid)
          let msg = if found then "interrupt requested" else "subagent not running"
          pure (OpResult [TrpText msg] False (object ["subagent_id" .= subagentIdText sid, "found" .= found]))
  }

-- ---------------------------------------------------------------------------
-- JSON encoding of ChildResult
-- ---------------------------------------------------------------------------

-- | Render the results list as a JSON string for the model (the @orParts@
-- text the model sees). One line per result:
-- @subagent_id | status | summary-or-error@. The full structured JSON goes
-- into 'orRecorded' via the 'ToJSON ChildResult' instance defined in
-- 'Seal.Agent.Runtime.Delegation'.
encodeResultsJson :: [ChildResult] -> Text
encodeResultsJson [] = "(no results)"
encodeResultsJson rs = T.intercalate "\n" (map renderOne rs)
  where
    renderOne r =
      subagentIdText (crSubagentId r) <> " | " <>
      T.pack (show (crStatus r)) <> " | " <>
      maybe "(no summary)" (T.take 200) (summaryOrError r)
    summaryOrError r = case crSummary r of
      Just s  -> Just s
      Nothing -> crError r

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
encodeDefRecorded :: AgentDef -> Bool -> Value
encodeDefRecorded d wasNew = object
  [ "id"         .= agentDefIdText (adId d)
  , "name"       .= adName d
  , "provider"   .= adProvider d
  , "model"      .= adModel d
  , "system"     .= adSystem d
  , "tools"      .= encodeTools (adTools d)
  , "created_at" .= adCreatedAt d
  , "updated_at" .= adUpdatedAt d
  , "session"    .= adSession d
  , "was_new"    .= wasNew
  ]

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