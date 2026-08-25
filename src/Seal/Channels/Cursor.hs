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
-- The cursor store survives a @seal serve@ (or standalone
-- @seal telegram@ / @seal signal@) restart via the optional 'csSave' hook
-- (mirroring 'Seal.Tabs.TabsHandle.thSave'). A non-persisting store
-- ('newCursorStore', 'csSave' = 'Nothing') is used by tests; a persisting
-- store ('newPersistingCursorStore') writes the full current map to
-- @\<state\>\/cursors.json@ atomically (0600) after every mutation, and is
-- loaded + seeded at boot so an existing conversation re-resolves to its
-- prior session (carrying the user's @\/model use@ choice) instead of a
-- fresh default session. Without persistence, a restart loses every
-- conversation → tab binding and the loop mints a brand-new default-model
-- session on the next message — the "model change lost on restart" bug.
module Seal.Channels.Cursor
  ( CursorStore
  , newCursorStore
  , newPersistingCursorStore
  , seedCursorStore
  , cursorLookup
  , cursorSet
  , cursorClear
  , cursorClearAll
  , cursorMigrateAll
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
-- persists to disk; 'Nothing' for a plain 'newCursorStore' (tests,
-- non-persisting modes) and @Just (... saveCursorMap path ...)@ for
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

-- | Build a new empty non-persisting cursor store. Used by tests and any
-- mode that does not need cross-restart persistence.
newCursorStore :: IO CursorStore
newCursorStore = CursorStore <$> newTVarIO Map.empty <*> pure Nothing

-- | Create a 'CursorStore' that persists every mutation to @path@ (atomic
-- write, 0600, MVar-serialized via 'Seal.Util.AtomicJson.saveJsonAtomic').
-- Used by 'Seal.Command.Serve.runServeMain' and the standalone
-- @seal telegram@ / @seal signal@ entry points so the cursor map survives
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

-- | Snapshot the current map. Used by the save action and tests.
snapshotCursor :: CursorStore -> IO (Map ConversationKey TabRef)
snapshotCursor s = readTVarIO (csVar s)

-- | Look up the tab a conversation is focused on. 'Nothing' when the
-- conversation has no cursor yet (first message — the caller should create
-- a new tab and set the cursor).
cursorLookup :: CursorStore -> ConversationKey -> IO (Maybe TabRef)
cursorLookup s key =
  Map.lookup key <$> readTVarIO (csVar s)

-- | Set (or replace) a conversation's focused tab. Called when the
-- conversation sends its first message (new tab created) or when the user
-- runs @/tab focus N@. Persists via 'csSave' after the STM commit.
cursorSet :: CursorStore -> ConversationKey -> TabRef -> IO ()
cursorSet s key ref = do
  atomically $ do
    m <- readTVar (csVar s)
    writeTVar (csVar s) (Map.insert key ref m)
  persistCursor s

-- | Clear a conversation's cursor (e.g. when the channel disconnects).
-- Harmless if the key was never set. Persists via 'csSave'.
cursorClear :: CursorStore -> ConversationKey -> IO ()
cursorClear s key = do
  atomically $ do
    m <- readTVar (csVar s)
    writeTVar (csVar s) (Map.delete key m)
  persistCursor s

-- | Clear every conversation whose cursor points at @ref@. Used when a tab
-- is closed: the closed tab's 'TabRef' is stale, so any conversation still
-- focused on it should drop the cursor (the next message will create a
-- fresh tab). Single STM transaction — race-safe vs concurrent
-- cursorLookup/cursorSet. Persists via 'csSave'.
cursorClearAll :: CursorStore -> TabRef -> IO ()
cursorClearAll s ref = do
  atomically $ do
    m <- readTVar (csVar s)
    writeTVar (csVar s) (Map.filter (/= ref) m)
  persistCursor s

-- | Migrate every conversation whose cursor equals @oldRef@ to @newRef@.
-- Used by @\/new@ on inbox channels: when a tab is rebound to a fresh
-- session, every conversation focused on that tab follows the rebind (per
-- the user's model: a tab has one session at a time; all channels focused
-- on the tab follow it to the new session). Returns the count of migrated
-- cursors (for the confirmation line / observability). Single STM
-- transaction — race-safe vs concurrent cursorLookup/cursorSet. Persists
-- via 'csSave'.
cursorMigrateAll :: CursorStore -> TabRef -> TabRef -> IO Int
cursorMigrateAll s oldRef newRef = do
  count <- atomically $ do
    m <- readTVar (csVar s)
    let (matched, rest) = Map.partition (== oldRef) m
        m' = Map.map (const newRef) matched <> rest
    writeTVar (csVar s) m'
    pure (Map.size matched)
  persistCursor s
  pure count

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