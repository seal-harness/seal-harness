{-# LANGUAGE OverloadedStrings #-}
-- | The Agent opcode group: three Audited definition opcodes
-- (@AGENT_DEF_WRITE@, @AGENT_DEF_READ@, @AGENT_DEF_LIST@, @AGENT_DEF_DELETE@)
-- and four Trusted lifecycle opcodes (@AGENT_INSTANCES@, @AGENT_START@,
-- @AGENT_STATUS@, @AGENT_STOP@). Only the *definition* mutations are Audited —
-- running an instance is harness-internal, not an evolutionary mutation, so
-- the lifecycle ops are Trusted.
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
-- @AGENT_START@ forks a worker via the wiring layer's worker-builder: the
-- opcode is decoupled from 'Seal.Agent.Loop' / 'Seal.Types.Env' so it stays
-- testable. The worker-builder resolves the def's provider+model, builds a
-- fresh 'AgentEnv' bound to a fresh session, and runs the loop.
module Seal.ISA.Ops.Agent
  ( agentDefWriteOp
  , agentDefReadOp
  , agentDefListOp
  , agentDefDeleteOp
  , agentInstancesOp
  , agentStartOp
  , agentStatusOp
  , agentStopOp
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
import Seal.Agent.Runtime.Registry
  ( AgentInstance (..), AgentRuntime, AgentStatus (..), agentStatus, listAgents
  , startAgent, stopAgent )
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..), TrustLevel (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AllowList (..))

-- | A worker-builder: given a def and a fresh session id, produce the @IO ()@
-- loop the runtime should fork. The wiring layer resolves the def's
-- provider+model, builds a fresh 'AgentEnv', and runs the turn loop. Keeping
-- this as a parameter decouples the opcode from 'Seal.Agent.Loop' / provider
-- resolution so the opcode is unit-testable with a fake worker.
type AgentWorkerBuilder = AgentDef -> SessionId -> IO ()

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

-- | AGENT_DEF_READ: return one agent definition by id. Audited — the agent
-- reading its own agent defs is an evolutionary event worth logging, with
-- secret-free metadata. The def fields are returned to the model (agent-visible)
-- and recorded in full.
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

-- | AGENT_DEF_LIST: list all agent definitions (id + name + provider/model).
-- Mirrors the @/agent list@ slash command which already calls 'adbList'.
-- Trusted — listing definitions is an evolutionary event worth logging, with
-- secret-free metadata (no system prompts in the recorded payload; the model
-- sees only the id+name+provider+model summary).
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

-- | AGENT_DEF_DELETE: remove an agent definition by id. Idempotent (deleting
-- a missing id is a success with a "not present" message, not an error).
-- Mirrors 'Seal.ISA.Ops.Memory.memoryDeleteOp'.
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

-- | AGENT_INSTANCES: snapshot the in-process agent runtime (running
-- instances). Trusted — listing running instances is harness-internal, not an
-- evolutionary mutation. Renamed from AGENT_LIST to stop the confusion with
-- AGENT_DEF_LIST (which lists definitions, not running instances).
agentInstancesOp :: AgentRuntime -> Opcode
agentInstancesOp runtime = TrustedOpcode
  { toName = OpName "AGENT_INSTANCES"
  , toTrust = Trusted
  , toDesc = "List running agent instances (id + status)."
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
                    [ agentDefIdText (aiId i) <> ": " <> renderStatus (aiStatus i)
                    | i <- insts ]
          recorded = object
            [ "count" .= length insts
            , "ids" .= fmap (agentDefIdText . aiId) insts
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }

-- | AGENT_START: fork a worker bound to the def's provider/model/system/tools
-- in a fresh session. Returns the new 'SessionId'. Trusted — running an
-- instance is harness-internal, not an evolutionary mutation. The
-- worker-builder resolves the def's provider+model and runs the turn loop; the
-- session-minter produces a fresh 'SessionId' for the new instance.
agentStartOp
  :: AgentDefBackend -> AgentRuntime -> IO SessionId -> AgentWorkerBuilder -> Opcode
agentStartOp backend runtime mintSession mkWorker = TrustedOpcode
  { toName = OpName "AGENT_START"
  , toTrust = Trusted
  , toDesc = "Start a running agent instance bound to a definition."
  , toInSchema = singleStringSchema "id" "The agent def id to start."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_START requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          mDef <- liftIO (adbRead backend aid)
          case mDef of
            Nothing -> pure (OpResult [TrpText "agent def not found"] True (object ["id" .= agentDefIdText aid]))
            Just def -> do
              freshSession <- liftIO mintSession
              res <- liftIO (startAgent runtime aid freshSession (mkWorker def freshSession))
              case res of
                Left err -> pure (OpResult [TrpText err] True (object ["id" .= agentDefIdText aid]))
                Right _  -> pure (OpResult [TrpText ("started: session " <> sessionIdText freshSession)] False (object ["id" .= agentDefIdText aid, "session" .= freshSession]))
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)
    sessionIdText (SessionId s) = s

-- | AGENT_STATUS: read one running agent's status. Trusted.
agentStatusOp :: AgentRuntime -> Opcode
agentStatusOp runtime = TrustedOpcode
  { toName = OpName "AGENT_STATUS"
  , toTrust = Trusted
  , toDesc = "Read one running agent's status."
  , toInSchema = singleStringSchema "id" "The agent def id."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STATUS requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          mStatus <- liftIO (agentStatus runtime aid)
          case mStatus of
            Nothing -> pure (OpResult [TrpText "not running"] False (object ["id" .= agentDefIdText aid, "status" .= ("stopped" :: Text)]))
            Just s  -> pure (OpResult [TrpText (renderStatus s)] False (object ["id" .= agentDefIdText aid, "status" .= renderStatus s]))
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- | AGENT_STOP: stop a running agent instance (kill the thread, deregister).
-- Trusted. Idempotent (stopping a non-running def id is a success with a
-- \"not running\" message).
agentStopOp :: AgentRuntime -> Opcode
agentStopOp runtime = TrustedOpcode
  { toName = OpName "AGENT_STOP"
  , toTrust = Trusted
  , toDesc = "Stop a running agent instance (idempotent)."
  , toInSchema = singleStringSchema "id" "The agent def id to stop."
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_STOP requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          _ <- liftIO (stopAgent runtime aid)
          pure (OpResult [TrpText "stopped"] False (object ["id" .= agentDefIdText aid]))
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- ---- helpers ----

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

-- | Render an 'AgentStatus' for display.
renderStatus :: AgentStatus -> Text
renderStatus = \case
  Starting  -> "starting"
  Running   -> "running"
  Idle      -> "idle"
  Stopped   -> "stopped"
  Crashed m -> "crashed: " <> m