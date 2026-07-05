{-# LANGUAGE OverloadedStrings #-}
-- | The memory store backend. A capability record ('MemoryBackend') with one
-- in-memory implementation ('noneBackend') for M2; SQLite and Markdown
-- backends follow the same shape. All backends materialize by Audited-log
-- replay at startup ('materializeMemory').
--
-- The Audited log is canonical; the backend is a materialized view. Opcode
-- writes go through the backend (which mutates the in-memory/SQLite/Markdown
-- store) AND through the dispatcher's Audited-log write (which is canonical).
-- On a cold start, 'materializeMemory' folds the Audited log into the backend
-- so the two stay in sync.
module Seal.Memory.Backend
  ( MemoryBackend (..)
  , noneBackend
  , materializeMemory
  , MemEvent (..)
  ) where

import Control.Monad (forM_)
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Value (..))
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Audited.Replay (AuditedEvent (..))
import Seal.Audited.Types (AuditedKind (..))
import Seal.Core.Types (OpName (..))
import Seal.Memory.Types (MemoryEntry (..), MemoryId (..), mkMemoryId)

-- | The memory store capability. Each operation is IO (the backends may be
-- SQLite/Markdown on disk); 'mbList' supports the dynamic-retrieval pager.
data MemoryBackend = MemoryBackend
  { mbStore  :: MemoryEntry -> IO ()
  -- ^ Insert or replace a memory by id.
  , mbRecall :: MemoryId -> IO (Maybe MemoryEntry)
  -- ^ Fetch one memory by id.
  , mbList   :: IO [MemoryEntry]
  -- ^ All memories, in insertion order.
  , mbUpdate :: MemoryEntry -> IO ()
  -- ^ Update an existing memory (same as 'mbStore' for the in-memory backend;
  -- a SQLite backend may use an UPDATE vs INSERT distinction).
  , mbDelete :: MemoryId -> IO ()
  -- ^ Remove a memory by id.
  }

-- | A store-agnostic mutation event derived from an 'AuditedEvent' whose
-- 'aeEvKind' is 'AKMemory'. The materializer dispatches on the opcode name to
-- produce one of these; the backend applies it.
data MemEvent
  = MemStore MemoryEntry
  | MemDelete MemoryId

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests and by
-- the @none@ config option (opt-out of persistent memory). The map is keyed by
-- 'MemoryId'; 'mbList' returns entries in Map key order (deterministic for
-- tests).
noneBackend :: IO MemoryBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map MemoryId MemoryEntry)
  pure MemoryBackend
    { mbStore  = \e -> modifyIORef' ref (Map.insert (meId e) e)
    , mbRecall = \mid -> Map.lookup mid <$> readIORef ref
    , mbList   = Map.elems <$> readIORef ref
    , mbUpdate = \e -> modifyIORef' ref (Map.insert (meId e) e)
    , mbDelete = modifyIORef' ref . Map.delete
    }

-- | Fold the Audited log into a memory backend, populating it from scratch.
-- Each 'AKMemory' event is routed to 'mbStore' or 'mbDelete' based on its
-- opcode. Events for other kinds are ignored. Idempotent: replaying the same
-- log twice yields the same backend state (Store is upsert, Delete is
-- idempotent).
materializeMemory :: [AuditedEvent] -> MemoryBackend -> IO ()
materializeMemory events backend =
  forM_ events $ \ev ->
    case (aeEvKind ev, toMemEvent ev) of
      (AKMemory, Just me) -> applyMemEvent backend me
      _                   -> pure ()

-- | Decode an 'AuditedEvent' into a 'MemEvent' based on its opcode name. The
-- payload is the opcode INPUT (id/content/tags for store, id for delete); the
-- 'aeEvTs' and 'aeEvSession' fields of the event supply the timestamps and
-- provenance the input lacks, so the reconstructed 'MemoryEntry' is complete.
toMemEvent :: AuditedEvent -> Maybe MemEvent
toMemEvent ev =
  case T.unpack (unOpName (aeEvOpcode ev)) of
    "MEMORY_STORE"  -> MemStore <$> decodeStorePayload ev
    "MEMORY_UPDATE" -> MemStore <$> decodeStorePayload ev
    "MEMORY_DELETE" -> MemDelete <$> decodeDeletePayload ev
    _               -> Nothing
  where
    unOpName (OpName t) = t

-- | Decode a store/update payload (the opcode input) into a 'MemoryEntry',
-- filling in 'meCreatedAt'/'meUpdatedAt' from the event's timestamp and
-- 'meSession' from the event's session id. The input carries id/content/tags.
decodeStorePayload :: AuditedEvent -> Maybe MemoryEntry
decodeStorePayload ev = do
  mid   <- idFromPayload (aeEvPayload ev)
  content <- contentFromPayload (aeEvPayload ev)
  let tags = tagsFromPayload (aeEvPayload ev)
  pure MemoryEntry
    { meId = mid
    , meContent = content
    , meTags = tags
    , meCreatedAt = aeEvTs ev
    , meUpdatedAt = aeEvTs ev
    , meSession = aeEvSession ev
    }

-- | Decode a delete payload's id field.
decodeDeletePayload :: AuditedEvent -> Maybe MemoryId
decodeDeletePayload ev = idFromPayload (aeEvPayload ev)

-- | Extract the @id@ field from a payload object.
idFromPayload :: Value -> Maybe MemoryId
idFromPayload (Object o) = case KeyMap.lookup (fromString "id") o of
  Just (String t) -> either (const Nothing) Just (mkMemoryId t)
  _               -> Nothing
idFromPayload _ = Nothing

-- | Extract the @content@ field (defaults to empty when absent).
contentFromPayload :: Value -> Maybe Text
contentFromPayload (Object o) = case KeyMap.lookup (fromString "content") o of
  Just (String t) -> Just t
  _               -> Just ""
contentFromPayload _ = Just ""

-- | Extract the @tags@ array field (defaults to [] when absent).
tagsFromPayload :: Value -> [Text]
tagsFromPayload (Object o) = case KeyMap.lookup (fromString "tags") o of
  Just (Array xs) -> [t | String t <- toList xs]
  _               -> []
tagsFromPayload _ = []

-- | Apply one mutation to the backend.
applyMemEvent :: MemoryBackend -> MemEvent -> IO ()
applyMemEvent backend = \case
  MemStore e  -> mbStore backend e
  MemDelete i -> mbDelete backend i