{-# LANGUAGE OverloadedStrings #-}
-- | The Agent opcode group: three Audited definition opcodes
-- (@AGENT_DEF_CREATE@, @AGENT_DEF_READ@, @AGENT_DEF_UPDATE@) and four Trusted
-- lifecycle opcodes (@AGENT_LIST@, @AGENT_START@, @AGENT_STATUS@,
-- @AGENT_STOP@). Only the *definition* mutations are Audited — running an
-- instance is harness-internal, not an evolutionary mutation, so the lifecycle
-- ops are Trusted.
--
-- The Audited def ops write to both the session transcript and the Audited log
-- via the dispatcher's Audited branch; the opcodes mutate the in-memory/Markdown
-- def backend (the materialized view). 'orRecorded' carries the secret-free
-- 'AgentDefId' + op name; the system prompt and tool list are agent-visible
-- data (not vault secrets) and are recorded in full in both logs.
--
-- @AGENT_START@ forks a worker via the wiring layer's worker-builder: the
-- opcode is decoupled from 'Seal.Agent.Loop' / 'Seal.Types.Env' so it stays
-- testable. The worker-builder resolves the def's provider+model, builds a
-- fresh 'AgentEnv' bound to a fresh session, and runs the loop.
module Seal.ISA.Ops.Agent
  ( agentDefCreateOp
  , agentDefReadOp
  , agentDefUpdateOp
  , agentListOp
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

-- | AGENT_DEF_CREATE: insert or replace an agent definition by id. The name,
-- provider, model, system prompt, and tool list are recorded in full
-- (agent-visible data); 'orRecorded' carries the id + op name + fields.
agentDefCreateOp :: AgentDefBackend -> SessionId -> Opcode
agentDefCreateOp backend session = TrustedOpcode
  { toName = OpName "AGENT_DEF_CREATE"
  , toTrust = Trusted
  , toDesc = "Define an agent by id (insert or replace)."
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
  , toAuthorize = maybe (Left "AGENT_DEF_CREATE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          now <- liftIO getCurrentTime
          let def = AgentDef
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
          liftIO (adbUpdate backend def)
          let recorded = encodeDefRecorded def
          pure (OpResult [TrpText "defined"] False recorded)
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
                  recorded = encodeDefRecorded d
              pure (OpResult [TrpText rendered] False recorded)
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- | AGENT_DEF_UPDATE: update an existing agent definition's name/system/tools.
-- The updated_at timestamp is bumped. If the def does not exist, returns an
-- error result (the model should use AGENT_DEF_CREATE to define). The original
-- 'adSession' (provenance) and 'adCreatedAt' are preserved.
agentDefUpdateOp :: AgentDefBackend -> Opcode
agentDefUpdateOp backend = TrustedOpcode
  { toName = OpName "AGENT_DEF_UPDATE"
  , toTrust = Trusted
  , toDesc = "Update an existing agent definition's name/system/tools."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The agent def id to update." :: Text)
              ]
          , fromText "name" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("New name (optional)." :: Text)
              ]
          , fromText "system" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("New system prompt (optional)." :: Text)
              ]
          , fromText "tools" .= object
              [ "type" .= ("array" :: Text)
              , "description" .= ("New allowed opcode names, or \"all\" (optional)." :: Text)
              ]
          ]
      , "required" .= (["id"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = maybe (Left "AGENT_DEF_UPDATE requires {id:string}") checkId . idField
  , toRun = \_ v -> do
      let mId = idField v >>= either (const Nothing) Just . mkAgentDefId
      case mId of
        Nothing -> pure (OpResult [TrpText "invalid agent def id"] True (object []))
        Just aid -> do
          mExisting <- liftIO (adbRead backend aid)
          case mExisting of
            Nothing -> pure (OpResult [TrpText "agent def not found"] True (object ["id" .= agentDefIdText aid]))
            Just existing -> do
              now <- liftIO getCurrentTime
              let newName   = case textFieldMaybe "name" v of
                    Just n  -> n
                    Nothing -> adName existing
                  newSystem = case textFieldMaybe "system" v of
                    Just s  -> Just s
                    Nothing -> adSystem existing
                  newTools  = case parseMaybe (withObject "in" (.:? "tools")) v :: Maybe (Maybe Value) of
                    Just (Just _) -> toolsField v
                    _             -> adTools existing
                  updated = existing
                    { adName = newName
                    , adSystem = newSystem
                    , adTools = newTools
                    , adUpdatedAt = now
                    }
              liftIO (adbUpdate backend updated)
              let recorded = encodeDefRecorded updated
              pure (OpResult [TrpText "updated"] False recorded)
  }
  where
    checkId t = either (Left . ("invalid agent def id: " <>)) (const (Right ())) (mkAgentDefId t)

-- | AGENT_LIST: snapshot the in-process agent runtime (running instances).
-- Trusted — listing running instances is harness-internal, not an evolutionary
-- mutation.
agentListOp :: AgentRuntime -> Opcode
agentListOp runtime = TrustedOpcode
  { toName = OpName "AGENT_LIST"
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
encodeDefRecorded :: AgentDef -> Value
encodeDefRecorded d = object
  [ "id"         .= agentDefIdText (adId d)
  , "name"       .= adName d
  , "provider"   .= adProvider d
  , "model"      .= adModel d
  , "system"     .= adSystem d
  , "tools"      .= encodeTools (adTools d)
  , "created_at" .= adCreatedAt d
  , "updated_at" .= adUpdatedAt d
  , "session"    .= adSession d
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