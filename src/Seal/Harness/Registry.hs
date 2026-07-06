{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The harness registry — the ground truth a tab's 'BoundHarness'
-- references. STM-backed, keyed by 'HarnessId', with race-safe CRUD and a
-- 'mergeReconcile' that merges observed harnesses into entries **by key
-- inside one STM transaction** so concurrent inserts are never clobbered
-- (the lost-update-safe path).
module Seal.Harness.Registry
  ( HarnessOrigin (..)
  , Liveness (..)
  , HarnessEntry (..)
  , HarnessRegistry (..)
  , ObservedHarness (..)
  , newHarnessRegistry
  , insert
  , lookupById
  , lookupByLabel
  , modify
  , delete
  , snapshot
  , mergeReconcile
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)

import Seal.Harness.Id (HarnessId)

-- | How a harness came to be in the registry.
data HarnessOrigin = HoSpawned | HoDiscovered | HoAdopted
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The liveness states a harness can be in (mirrors 'HarnessStatus' but
-- as a pure registry-cache value, not the live IO query).
data Liveness = LvIdle | LvThinking | LvAwaitingInput | LvExited | LvOrphaned
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One registry entry: the durable identity + the reconciled
-- coordinate/health cache.
data HarnessEntry = HarnessEntry
  { heId          :: HarnessId
  , heLabel       :: Text              -- ^ human-facing label (mutable)
  , heOrigin      :: HarnessOrigin
  , heLiveness    :: Liveness
  , heTmuxCoord   :: Maybe Text        -- ^ "session:window.pane" when backed by tmux
  , heFlavour     :: Maybe Text        -- ^ the harness flavour (claude-code, codex, …)
  , heOrphanTicks :: Int               -- ^ consecutive Orphaned ticks (for grace eviction)
  } deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The observed-harness shape the reconcile loop produces (pure data; the
-- observer fills it from a screen capture + the tmux markers).
data ObservedHarness = ObservedHarness
  { ohId        :: HarnessId
  , ohLiveness  :: Liveness
  , ohTmuxCoord :: Maybe Text
  , ohFlavour   :: Maybe Text
  } deriving stock (Eq, Show)

-- | The STM-backed registry. The 'TVar' holds a map keyed by 'HarnessId'.
newtype HarnessRegistry = HarnessRegistry (TVar (Map HarnessId HarnessEntry))

newHarnessRegistry :: IO HarnessRegistry
newHarnessRegistry = HarnessRegistry <$> newTVarIO Map.empty

insert :: HarnessRegistry -> HarnessEntry -> STM ()
insert (HarnessRegistry tv) e = writeTVar tv . Map.insert (heId e) e =<< readTVar tv

lookupById :: HarnessRegistry -> HarnessId -> STM (Maybe HarnessEntry)
lookupById (HarnessRegistry tv) hid = Map.lookup hid <$> readTVar tv

lookupByLabel :: HarnessRegistry -> Text -> STM (Maybe HarnessEntry)
lookupByLabel (HarnessRegistry tv) label =
  Map.elems <$> readTVar tv >>= \es -> pure (es ? label)
  where
    es ? lbl = case filter (\e -> heLabel e == lbl) es of
      (e:_) -> Just e
      []    -> Nothing

modify :: HarnessRegistry -> HarnessId -> (HarnessEntry -> HarnessEntry) -> STM ()
modify (HarnessRegistry tv) hid f = do
  m <- readTVar tv
  case Map.lookup hid m of
    Just e  -> writeTVar tv (Map.insert hid (f e) m)
    Nothing -> pure ()  -- no-op when absent

delete :: HarnessRegistry -> HarnessId -> STM ()
delete (HarnessRegistry tv) hid = writeTVar tv . Map.delete hid =<< readTVar tv

-- | All entries, sorted by id (deterministic snapshot order).
snapshot :: HarnessRegistry -> IO [HarnessEntry]
snapshot (HarnessRegistry tv) =
  sortOn heId . Map.elems <$> atomically (readTVar tv)

-- | Merge a list of observed harnesses (from the reconcile sweep) into the
-- registry **inside one STM transaction**, so concurrent inserts never
-- clobber. Observed entries are merged by key: an existing entry keeps its
-- origin + label (a 'HoSpawned' stays 'HoSpawned', not overwritten to
-- 'HoDiscovered'), 'heLiveness' is updated, 'heOrphanTicks' is reset to 0
-- on a non-Orphan observation or incremented on an Orphan one. A new
-- observed id is inserted as 'HoDiscovered' with 'heOrphanTicks = 0'.
-- Returns the new entries (the merged + inserted ones).
mergeReconcile :: HarnessRegistry -> [ObservedHarness] -> STM [HarnessEntry]
mergeReconcile (HarnessRegistry tv) observed = do
  m0 <- readTVar tv
  let m1 = foldl applyObs m0 observed
  writeTVar tv m1
  pure [ e | e <- Map.elems m1, heId e `elem` (map ohId observed) ]
  where
    applyObs m oh =
      let hid = ohId oh
      in case Map.lookup hid m of
           Just e ->
             let ticks = if ohLiveness oh == LvOrphaned
                           then heOrphanTicks e + 1
                           else 0
                 e' = e { heLiveness    = ohLiveness oh
                        , heTmuxCoord   = ohTmuxCoord oh
                        , heFlavour     = ohFlavour oh <|> heFlavour e
                        , heOrphanTicks = ticks
                        }
             in Map.insert hid e' m
           Nothing ->
             Map.insert hid HarnessEntry
               { heId          = hid
               , heLabel       = "discovered"  -- placeholder; the caller may rename
               , heOrigin      = HoDiscovered
               , heLiveness    = ohLiveness oh
               , heTmuxCoord   = ohTmuxCoord oh
               , heFlavour     = ohFlavour oh
               , heOrphanTicks = 0
               } m