{-# LANGUAGE OverloadedStrings #-}
-- | The thin TVar-backed handle that mutates a 'TabList' — the live state a
-- tab command reads/writes. House style: a record of IO actions so the type
-- is uniform between real and fake variants.
module Seal.Tabs
  ( TabsHandle (..)
  , newTabsHandle
  , snapshotTabs
  , insertTabH
  , removeTabH
  , renameTabH
  , focusTabH
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.Text (Text)

import Seal.Handles.Tab (TabIndex, TabKind)
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef, emptyTabList, insertTab
  , removeTab, renameTab, tabCount )

-- | The live tab-list handle. Backed by a 'TVar' so concurrent tab commands
-- are race-safe (each operation is one STM transaction).
newtype TabsHandle = TabsHandle (TVar TabList)

newTabsHandle :: IO TabsHandle
newTabsHandle = TabsHandle <$> newTVarIO emptyTabList

snapshotTabs :: TabsHandle -> IO TabList
snapshotTabs (TabsHandle tv) = readTVarIO tv

-- | Insert a tab at the lowest free slot. 'Right' the new index; 'Left' on
-- I2 (duplicate ref) or full.
insertTabH :: TabsHandle -> TabRef -> TabKind -> Maybe Text -> IO (Either Text TabIndex)
insertTabH (TabsHandle tv) ref kind label = atomically $ do
  tl <- readTVar tv
  case insertTab ref kind label tl of
    Left e        -> pure (Left e)
    Right tl' -> do
      writeTVar tv tl'
      case tlTabs tl' of
        []     -> pure (Left "insert succeeded but list is empty (unreachable)")
        (t:_)  -> pure (Right (tIndex t))

-- | Remove a tab (compacts; I1). 'Left' if out of range.
removeTabH :: TabsHandle -> TabIndex -> IO (Either Text ())
removeTabH (TabsHandle tv) idx = atomically $ do
  tl <- readTVar tv
  case removeTab tl idx of
    Left e       -> pure (Left e)
    Right tl' -> writeTVar tv tl' >> pure (Right ())

-- | Rename a tab. 'Left' if the index is out of range.
renameTabH :: TabsHandle -> TabIndex -> Text -> IO (Either Text ())
renameTabH (TabsHandle tv) idx name = atomically $ do
  tl <- readTVar tv
  case renameTab tl idx name of
    Left e       -> pure (Left e)
    Right tl' -> writeTVar tv tl' >> pure (Right ())

-- | Focus a tab: validates the index is in range. 'Right ()' on success;
-- 'Left' if out of range. (The actual cursor state is per-conversation and
-- tracked by the relay/wiring; this just validates the index.)
focusTabH :: TabsHandle -> TabIndex -> IO (Either Text ())
focusTabH (TabsHandle tv) idx = atomically $ do
  tl <- readTVar tv
  if tabCount tl > 0 && idx `elem` map tIndex (tlTabs tl)
    then pure (Right ())
    else pure (Left "tab index out of range")