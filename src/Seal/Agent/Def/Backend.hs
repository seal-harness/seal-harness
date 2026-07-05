{-# LANGUAGE OverloadedStrings #-}
-- | The agent-definition store backend. A capability record
-- ('AgentDefBackend') with one in-memory implementation ('noneBackend') for
-- M4; the Markdown backend follows the same shape. The backend materializes by
-- Audited-log replay at startup ('materializeAgentDefs').
--
-- The Audited log is canonical; the backend is a materialized view. Opcode
-- writes go through the backend (which mutates the in-memory/Markdown store)
-- AND through the dispatcher's Audited-log write (which is canonical). On a
-- cold start, 'materializeAgentDefs' folds the Audited log into the backend so
-- the two stay in sync.
module Seal.Agent.Def.Backend
  ( AgentDefBackend (..)
  , noneBackend
  , materializeAgentDefs
  , AgentDefEvent (..)
  ) where

import Control.Monad (forM_)
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Value (..))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

import Seal.Audited.Replay (AuditedEvent (..))
import Seal.Audited.Types (AuditedKind (..))
import Seal.Core.Types (ModelId (..), OpName (..))
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId)
import Seal.Security.Policy (AllowList (..))

-- | The agent-definition store capability. Each operation is IO (a Markdown
-- backend writes to disk); 'adbList' returns all defs.
data AgentDefBackend = AgentDefBackend
  { adbRead   :: AgentDefId -> IO (Maybe AgentDef)
  -- ^ Fetch one def by id.
  , adbUpdate :: AgentDef -> IO ()
  -- ^ Insert or replace a def by id (CREATE and UPDATE both go through here).
  , adbList   :: IO [AgentDef]
  -- ^ All defs, in Map key order (deterministic for tests).
  }

-- | A store-agnostic mutation event derived from an 'AuditedEvent' whose
-- 'aeEvKind' is 'AKAgentDef'. The materializer dispatches on the opcode name to
-- produce one of these; the backend applies it.
newtype AgentDefEvent = DefUpdate AgentDef

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests and by
-- the @none@ config option. The map is keyed by 'AgentDefId'.
noneBackend :: IO AgentDefBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map AgentDefId AgentDef)
  pure AgentDefBackend
    { adbRead   = \aid -> Map.lookup aid <$> readIORef ref
    , adbUpdate = \d -> modifyIORef' ref (Map.insert (adId d) d)
    , adbList   = Map.elems <$> readIORef ref
    }

-- | Fold the Audited log into an agent-def backend, populating it from scratch.
-- Each 'AKAgentDef' event is routed to 'adbUpdate' based on its opcode. Events
-- for other kinds are ignored. Idempotent: replaying the same log twice yields
-- the same backend state (Update is upsert).
materializeAgentDefs :: [AuditedEvent] -> AgentDefBackend -> IO ()
materializeAgentDefs events backend =
  forM_ events $ \ev ->
    case (aeEvKind ev, toAgentDefEvent ev) of
      (AKAgentDef, Just de) -> applyAgentDefEvent backend de
      _                     -> pure ()

-- | Decode an 'AuditedEvent' into an 'AgentDefEvent' based on its opcode name.
-- The payload is the opcode INPUT (id/name/provider/model/system/tools for
-- create/update); the 'aeEvTs' and 'aeEvSession' fields of the event supply the
-- timestamps and provenance the input lacks, so the reconstructed 'AgentDef'
-- is complete.
toAgentDefEvent :: AuditedEvent -> Maybe AgentDefEvent
toAgentDefEvent ev =
  case T.unpack (unOpName (aeEvOpcode ev)) of
    "AGENT_DEF_CREATE" -> DefUpdate <$> decodeDefPayload ev
    "AGENT_DEF_UPDATE" -> DefUpdate <$> decodeDefPayload ev
    _                   -> Nothing
  where
    unOpName (OpName t) = t

-- | Decode a create/update payload (the opcode input) into an 'AgentDef',
-- filling in 'adCreatedAt'/'adUpdatedAt' from the event's timestamp and
-- 'adSession' from the event's session id. The input carries
-- id/name/provider/model/system/tools.
decodeDefPayload :: AuditedEvent -> Maybe AgentDef
decodeDefPayload ev = do
  aid  <- idFromPayload (aeEvPayload ev)
  let name     = textFromPayload "name" (aeEvPayload ev)
      provider = textFromPayload "provider" (aeEvPayload ev)
      model    = ModelId (textFromPayload "model" (aeEvPayload ev))
      system   = textMaybeFromPayload "system" (aeEvPayload ev)
      tools = toolsFromPayload (aeEvPayload ev)
  pure AgentDef
    { adId = aid
    , adName = name
    , adProvider = provider
    , adModel = model
    , adSystem = system
    , adTools = tools
    , adCreatedAt = aeEvTs ev
    , adUpdatedAt = aeEvTs ev
    , adSession = aeEvSession ev
    }

-- | Extract the @id@ field from a payload object.
idFromPayload :: Value -> Maybe AgentDefId
idFromPayload (Object o) = case KeyMap.lookup (fromString "id") o of
  Just (String t) -> either (const Nothing) Just (mkAgentDefId t)
  _               -> Nothing
idFromPayload _ = Nothing

-- | Extract a text field by name (defaults to empty when absent).
textFromPayload :: Text -> Value -> Text
textFromPayload field (Object o) = case KeyMap.lookup (fromString (T.unpack field)) o of
  Just (String t) -> t
  _               -> ""
textFromPayload _ _ = ""

-- | Extract an optional text field by name.
textMaybeFromPayload :: Text -> Value -> Maybe Text
textMaybeFromPayload field (Object o) = case KeyMap.lookup (fromString (T.unpack field)) o of
  Just (String t) -> Just t
  _               -> Nothing
textMaybeFromPayload _ _ = Nothing

-- | Decode the @tools@ field: @\"all\"@ for 'AllowAll', an array of opcode-name
-- strings for 'AllowOnly' (defaults to 'AllowAll' when absent or unrecognized).
toolsFromPayload :: Value -> AllowList OpName
toolsFromPayload (Object o) = case KeyMap.lookup (fromString "tools") o of
  Just (String "all") -> AllowAll
  Just (Array xs)     -> AllowOnly (decodeOpNameSet (V.toList xs))
  _                   -> AllowAll
toolsFromPayload _ = AllowAll

-- | Decode a JSON array of opcode-name strings into a 'Set' of 'OpName'.
decodeOpNameSet :: [Value] -> Set OpName
decodeOpNameSet = foldr step Set.empty
  where
    step (String t) acc = Set.insert (OpName t) acc
    step _          acc = acc

-- | Apply one mutation to the backend.
applyAgentDefEvent :: AgentDefBackend -> AgentDefEvent -> IO ()
applyAgentDefEvent backend = \case
  DefUpdate d -> adbUpdate backend d