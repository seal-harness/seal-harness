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
module Seal.Channels.Cursor
  ( CursorStore
  , newCursorStore
  , cursorLookup
  , cursorSet
  , cursorClear
  , cursorMigrateAll
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Seal.Tabs.Types (TabRef)

-- | The live cursor store. Backed by a 'TVar' so concurrent reads/writes
-- are race-safe (each operation is one STM transaction).
newtype CursorStore = CursorStore (TVar (Map ConversationKey TabRef))

-- | A conversation identity: 'ChannelKind' × 'ConversationId'.
-- Re-exported here for convenience; the key type is 'ConversationKey'.
type ConversationKey = (Text, Text)
  -- ^ (channel-kind-text, conversation-id-text). We use the text forms
  -- rather than the structured types so the store doesn't depend on
  -- 'ChannelKind' or 'ConversationId' directly (keeping the module
  -- lightweight). Callers mint the key from 'MessageSource'.

-- | Build a new empty cursor store.
newCursorStore :: IO CursorStore
newCursorStore = CursorStore <$> newTVarIO Map.empty

-- | Look up the tab a conversation is focused on. 'Nothing' when the
-- conversation has no cursor yet (first message — the caller should create
-- a new tab and set the cursor).
cursorLookup :: CursorStore -> ConversationKey -> IO (Maybe TabRef)
cursorLookup (CursorStore tv) key =
  Map.lookup key <$> readTVarIO tv

-- | Set (or replace) a conversation's focused tab. Called when the
-- conversation sends its first message (new tab created) or when the user
-- runs @/tab focus N@.
cursorSet :: CursorStore -> ConversationKey -> TabRef -> IO ()
cursorSet (CursorStore tv) key ref = atomically $ do
  m <- readTVar tv
  writeTVar tv (Map.insert key ref m)

-- | Clear a conversation's cursor (e.g. when the channel disconnects).
-- Harmless if the key was never set.
cursorClear :: CursorStore -> ConversationKey -> IO ()
cursorClear (CursorStore tv) key = atomically $ do
  m <- readTVar tv
  writeTVar tv (Map.delete key m)

-- | Migrate every conversation whose cursor equals @oldRef@ to @newRef@.
-- Used by @\/new@ on inbox channels: when a tab is rebound to a fresh
-- session, every conversation focused on that tab follows the rebind (per
-- the user's model: a tab has one session at a time; all channels focused
-- on the tab follow it to the new session). Returns the count of migrated
-- cursors (for the confirmation line / observability). Single STM
-- transaction — race-safe vs concurrent cursorLookup/cursorSet.
cursorMigrateAll :: CursorStore -> TabRef -> TabRef -> IO Int
cursorMigrateAll (CursorStore tv) oldRef newRef = atomically $ do
  m <- readTVar tv
  let (matched, rest) = Map.partition (== oldRef) m
      m' = Map.map (const newRef) matched <> rest
  writeTVar tv m'
  pure (Map.size matched)