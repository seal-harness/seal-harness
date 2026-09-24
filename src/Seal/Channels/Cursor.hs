{-# LANGUAGE OverloadedStrings #-}
-- | The per-conversation tab cursor store. Each conversation (a Telegram
-- chat, a Signal conversation, a TUI session) has a cursor pointing at the
-- tab it's currently focused on. The tab list is shared (one
-- 'TabsHandle' in the gateway); the cursor is per-conversation so
-- @/tab focus N@ on Telegram only affects that Telegram conversation,
-- not other conversations or the TUI.
--
-- The store is a 'TVar' backed 'Map' from 'ConversationKey' to 'TabRef'.
-- 'ConversationKey' is 'ChannelKind' × 'ConversationId' — the
-- server-derived conversation identity (never user-supplied), so a sender
-- cannot forge a cursor key to hijack another conversation's tab.
--
-- == Persistence
--
-- The cursor store survives a @seal serve@ restart via the optional 'csSave'
-- hook (mirroring 'Seal.Tabs.TabsHandle.thSave'). A persisting store
-- ('newPersistingCursorStore') writes the full current map to
-- @\<state\>\/cursors.json@ atomically (0600) after every mutation, and is
-- loaded + seeded at boot so an existing conversation re-resolves to its
-- prior session (carrying the user's @\/model use@ choice) instead of a
-- fresh default session.
module Seal.Channels.Cursor
  ( CursorStore
  , newPersistingCursorStore
  , seedCursorStore
  , cursorClearAll
  , snapshotCursor
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, catch)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Katip (Severity (..), ls)
import Seal.Channels.Cursor.Persist (saveCursorMap)
import Seal.Logging.Global (globalLogIO)
import Seal.Tabs.Types (TabRef)

-- | The live cursor store. Backed by a 'TVar' so concurrent reads/writes
-- are race-safe (each STM operation is one transaction). The optional
-- 'csSave' action is invoked after a successful mutation so the map
-- persists to disk; @Just (... saveCursorMap path ...)@ for
-- 'newPersistingCursorStore'. Mirrors 'Seal.Tabs.TabsHandle'.
data CursorStore = CursorStore
  { csVar  :: TVar (Map ConversationKey TabRef)
  , csSave :: Maybe (IO ())
  }

-- | A conversation identity: 'ChannelKind' × 'ConversationId'.
-- Re-exported here for convenience; the key type is 'ConversationKey'.
type ConversationKey = (Text, Text)
  -- ^ (channel-kind-text, conversation-id-text). We use the text forms
  -- rather than the structured types so the store doesn't depend on
  -- 'ChannelKind' or 'ConversationId' directly (keeping the module
  -- lightweight). Callers mint the key from 'MessageSource'.

-- | Create a 'CursorStore' that persists every mutation to @path@ (atomic
-- write, 0600, MVar-serialized via 'Seal.Util.AtomicJson.saveJsonAtomic').
-- Used by 'Seal.Command.Serve.runServeMain' so the cursor map survives
-- a restart. The save action snapshots the current map inside itself
-- (so the last writer wins with a consistent view, even if mutations
-- interleave the save).
newPersistingCursorStore :: FilePath -> IO CursorStore
newPersistingCursorStore path = do
  tv <- newTVarIO Map.empty
  let store = CursorStore { csVar = tv, csSave = Just (saveAction store) }
      saveAction s = saveCursorMap path =<< snapshotCursor s
  pure store

-- | Replace the handle's map in one STM transaction. Used at boot to
-- seed the in-memory store from the persisted @cursors.json@ (after the
-- caller has dropped stale entries, if desired). Does NOT persist (the
-- caller is loading FROM disk — writing back would be a redundant no-op).
seedCursorStore :: CursorStore -> Map ConversationKey TabRef -> IO ()
seedCursorStore s m = atomically (writeTVar (csVar s) m)

-- | Snapshot the current map. Used by the save action.
snapshotCursor :: CursorStore -> IO (Map ConversationKey TabRef)
snapshotCursor s = readTVarIO (csVar s)

-- | Clear every conversation whose cursor points at @ref@. Used when a tab
-- is closed: the closed tab's 'TabRef' is stale, so any conversation still
-- focused on it should drop the cursor (the next message will create a
-- fresh tab). Single STM transaction — race-safe. Persists via 'csSave'.
cursorClearAll :: CursorStore -> TabRef -> IO ()
cursorClearAll s ref = do
  atomically $ do
    m <- readTVar (csVar s)
    writeTVar (csVar s) (Map.filter (/= ref) m)
  persistCursor s

-- | Run the persist action (if any) after a successful mutation. A save
-- failure is logged to stderr (ids + error only — no conversation content)
-- and swallowed — the in-memory store stays authoritative within the
-- session; the next successful mutation will retry the save (writing the
-- full current map, so a missed save self-heals). Mirrors
-- 'Seal.Tabs.persistIf'.
persistCursor :: CursorStore -> IO ()
persistCursor s =
  case csSave s of
    Nothing  -> pure ()
    Just act -> act `catch` \e ->
      globalLogIO WarningS ("[persist] cursors.json save failed: " <> ls (T.pack (show (e :: SomeException))))