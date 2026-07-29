{-# LANGUAGE OverloadedStrings #-}
-- | The thin TVar-backed handle that mutates a 'TabList' — the live state a
-- tab command reads/writes. House style: a record of IO actions so the type
-- is uniform between real and fake variants.
module Seal.Tabs
  ( TabsHandle (..)
  , newTabsHandle
  , newPersistingTabsHandle
  , seedTabsHandle
  , snapshotTabs
  , insertTabH
  , removeTabH
  , renameTabH
  , rebindTabH
  , focusTabH
  , ensureTabForSession
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, catch)
import Data.Text (Text)
import Data.Text qualified as T

import Katip (Severity (..), ls)
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Handles.Tab (TabIndex, TabKind)
import Seal.Logging.Global (globalLogIO)
import Seal.Tabs.Persist (saveTabList)
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef (..), emptyTabList, insertTab
  , removeTab, renameTab, rebindTab, tabCount )

-- | The live tab-list handle. Backed by a 'TVar' so concurrent tab commands
-- are race-safe (each operation is one STM transaction). The optional
-- @thSave@ action is invoked after a successful mutation so the tab list
-- persists to disk (W5); it's 'Nothing' for a plain 'newTabsHandle' and
-- @Just (saveTabList path h)@ for 'newPersistingTabsHandle'.
data TabsHandle = TabsHandle
  { thVar  :: TVar TabList
  , thSave :: Maybe (IO ())
  }

newTabsHandle :: IO TabsHandle
newTabsHandle = TabsHandle <$> newTVarIO emptyTabList <*> pure Nothing

-- | Create a 'TabsHandle' that persists every mutation to @path@ (atomic
-- write, 0600, MVar-serialized — see 'Seal.Tabs.Persist.saveTabList'). Used
-- by 'Seal.Command.Serve.runServeMain' so the tab list survives a restart.
newPersistingTabsHandle :: FilePath -> IO TabsHandle
newPersistingTabsHandle path = do
  tv <- newTVarIO emptyTabList
  let h = TabsHandle { thVar = tv, thSave = Just (snapshotTabs h >>= saveTabList path) }
  pure h

snapshotTabs :: TabsHandle -> IO TabList
snapshotTabs h = readTVarIO (thVar h)

-- | Replace the handle's 'TabList' in one STM transaction. Used at boot to
-- seed the in-memory handle from the persisted @tabs.json@ (after the
-- caller has dropped stale tabs + renumbered). Does NOT persist (the caller
-- is loading FROM disk — writing back would be a redundant no-op).
seedTabsHandle :: TabsHandle -> TabList -> IO ()
seedTabsHandle h tl = atomically (writeTVar (thVar h) tl)

-- | Insert a tab at the lowest free slot. 'Right' the new index; 'Left' on
-- I2 (duplicate ref) or full. Persists via 'thSave' after a successful STM
-- commit (W5).
insertTabH :: TabsHandle -> TabRef -> TabKind -> Maybe Text -> IO (Either Text TabIndex)
insertTabH h ref kind label = do
  r <- atomically $ do
    let tv = thVar h
    tl <- readTVar tv
    case insertTab ref kind label tl of
      Left e        -> pure (Left e)
      Right tl' -> do
        writeTVar tv tl'
        case tlTabs tl' of
          []     -> pure (Left "insert succeeded but list is empty (unreachable)")
          (t:_)  -> pure (Right (tIndex t))
  persistIf h r

-- | Remove a tab (compacts; I1). 'Left' if out of range. Persists on success.
removeTabH :: TabsHandle -> TabIndex -> IO (Either Text ())
removeTabH h idx = do
  r <- atomically $ do
    let tv = thVar h
    tl <- readTVar tv
    case removeTab tl idx of
      Left e       -> pure (Left e)
      Right tl' -> writeTVar tv tl' >> pure (Right ())
  persistIf h r

-- | Rename a tab. 'Left' if the index is out of range. Persists on success.
renameTabH :: TabsHandle -> TabIndex -> Text -> IO (Either Text ())
renameTabH h idx name = do
  r <- atomically $ do
    let tv = thVar h
    tl <- readTVar tv
    case renameTab tl idx name of
      Left e       -> pure (Left e)
      Right tl' -> writeTVar tv tl' >> pure (Right ())
  persistIf h r

-- | Rebind a tab's 'TabRef' in place (preserves index/kind/label/status;
-- used by @\/new@). 'Left' on out-of-range index or I2 violation (the new
-- ref is already bound to a different tab). Rebind-to-same-ref is a no-op
-- 'Right'. Single STM transaction — race-safe vs concurrent tab ops.
-- Persists on success (W5).
rebindTabH :: TabsHandle -> TabIndex -> TabRef -> IO (Either Text ())
rebindTabH h idx newRef = do
  r <- atomically $ do
    let tv = thVar h
    tl <- readTVar tv
    case rebindTab idx newRef tl of
      Left e       -> pure (Left e)
      Right tl' -> writeTVar tv tl' >> pure (Right ())
  persistIf h r

-- | Focus a tab: validates the index is in range. 'Right ()' on success;
-- 'Left' if out of range. (The actual cursor state is per-conversation and
-- tracked by the relay/wiring; this just validates the index.) No persist
-- (focus is a pure validation — no state change).
focusTabH :: TabsHandle -> TabIndex -> IO (Either Text ())
focusTabH h idx = atomically $ do
  let tv = thVar h
  tl <- readTVar tv
  if tabCount tl > 0 && idx `elem` map tIndex (tlTabs tl)
    then pure (Right ())
    else pure (Left "tab index out of range")

-- | Run the persist action (if any) after a successful mutation, returning
-- the original result. A 'Left' outcome (mutation rejected) is a no-op for
-- the save. A save failure is logged to stderr (ids + error only — no
-- session content) and swallowed — the in-memory handle stays authoritative
-- within the session; the next successful mutation will retry the save
-- (writing the full current list, so a missed save self-heals).
persistIf :: TabsHandle -> Either a b -> IO (Either a b)
persistIf h r = do
  case r of
    Left _  -> pure ()
    Right _ -> case thSave h of
      Nothing  -> pure ()
      Just act -> act `catch` \e -> globalLogIO WarningS ("[persist] tabs.json save failed: " <> ls (T.pack (show (e :: SomeException))))
  pure r

-- | Idempotent: if no tab binds @sid@, insert a @'BoundSession' sid@ tab of
-- the given kind at the lowest free slot. Sources the 'SessionId' only from
-- server-validated contexts (the caller passes @smId meta@ from a
-- 'SessionMeta' loaded by 'loadSessionMeta' / minted by 'newSession' — never
-- a raw client string). Failure (@Left "tab list full (36 slots)"@ or
-- @Left "tab ref already bound"@ from a concurrent insert) is logged to
-- stderr (ids + error only — no session content) and does NOT propagate;
-- the tab is a UI affordance, not a correctness requirement. Shared by the
-- web 'handleSend' (W2) and the channel/CLI 'plainTurn' paths (W3).
ensureTabForSession :: TabsHandle -> TabKind -> SessionId -> IO ()
ensureTabForSession tabsH kind sid = do
  tl <- snapshotTabs tabsH
  let alreadyBound = any (\t -> tRef t == BoundSession sid) (tlTabs tl)
  if alreadyBound
    then pure ()
    else do
      r <- insertTabH tabsH (BoundSession sid) kind Nothing
      case r of
        Left e -> globalLogIO WarningS ("[auto-tab] could not insert tab for " <> ls (sessionIdText sid) <> ": " <> ls e)
        Right _ -> pure ()