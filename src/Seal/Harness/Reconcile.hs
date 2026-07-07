{-# LANGUAGE OverloadedStrings #-}
-- | The background reconcile loop: a server sweep ('readMarkers' + a screen
-- capture) per session, classified by a per-flavour observer into
-- 'Liveness', merged into the registry via 'mergeReconcile', then the
-- 'defaultOrphanGraceTicks' wall-clock-free grace policy auto-evicts an
-- entry after N consecutive Orphaned ticks (never touches @session.json@).
module Seal.Harness.Reconcile
  ( reconcileTick
  , tickOrphans
  , defaultOrphanGraceTicks
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, writeTVar)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Harness.Id (HarnessId, parseHarnessId)
import Seal.Harness.Observer (observeClaudeCode)
import Seal.Harness.Registry
  ( HarnessEntry (..), HarnessRegistry (..), Liveness (..), ObservedHarness (..)
  , mergeReconcile, snapshot )
import Seal.Harness.Tmux (TmuxIdent, TmuxRunner, captureWindowNamed, readMarkers)
import Seal.Session.Kind (HarnessFlavour (..))

-- | The default wall-clock-free grace policy: auto-evict an entry after
-- this many consecutive Orphaned ticks. Never touches @session.json@.
defaultOrphanGraceTicks :: Int
defaultOrphanGraceTicks = 3

-- | One reconcile tick: read markers for the session, classify via the
-- observer, merge into the registry, then tick orphans and evict those
-- over the grace limit. Returns the post-tick snapshot.
--
-- The observed list is built from the @seal_id@ marker (which carries the
-- 'HarnessId') + the classified liveness. In 6a's single-harness-per-session
-- model there's at most one observed harness per tick.
reconcileTick
  :: HarnessRegistry -> TmuxRunner -> TmuxIdent -> HarnessFlavour
  -> Int  -- ^ grace ticks (defaultOrphanGraceTicks)
  -> IO [HarnessEntry]
reconcileTick reg runner session flavour graceTicks = do
  markersR <- readMarkers runner session
  captureR <- captureWindowNamed runner session
  observed <- case (markersR, captureR) of
    (Right markers, Right screenLines) ->
      let screen = T.intercalate "\n" screenLines
      in pure (buildObserved flavour screen markers)
    _ -> pure []
  _ <- atomically (mergeReconcile reg observed)
  let observedIds = Set.fromList (map ohId observed)
  _evicted <- atomically (tickOrphans reg observedIds graceTicks)
  snapshot reg

-- | Build the observed-harness list from the marker map + the classified
-- liveness. The @seal_id@ marker carries the 'HarnessId'; the coord is the
-- session ident. Pure.
buildObserved :: HarnessFlavour -> Text -> Map.Map Text Text -> [ObservedHarness]
buildObserved flavour screen markers =
  case Map.lookup "seal_id" markers of
    Nothing -> []  -- no seal_id => nothing to observe (the observer's
                   -- LvOrphaned/LvExited classification is for entries that
                   -- ARE in the registry but lost their marker; that's
                   -- handled by the unobserved-tick path)
    Just sealIdText -> case parseHarnessId sealIdText of
      Right hid ->
        let liveness = classify flavour screen markers
        in [ ObservedHarness
               { ohId = hid
               , ohLiveness = liveness
               , ohTmuxCoord = Nothing
               , ohFlavour = Just (flavourText flavour)
               } ]
      Left _ -> []

-- | Increment orphan-ticks for entries NOT in the observed set, evict those
-- over the limit. STM. Returns the evicted entries.
tickOrphans :: HarnessRegistry -> Set HarnessId -> Int -> STM [HarnessEntry]
tickOrphans (HarnessRegistry tv) observedIds graceTicks = do
  m <- readTVar tv
  let (m', evicted) = foldr step (m, []) (Map.toList m)
  writeTVar tv m'
  pure evicted
  where
    step (hid, entry) (m', ev)
      | hid `Set.member` observedIds = (m', ev)  -- observed; untouched here
      | otherwise =
          let ticks = heOrphanTicks entry + 1
              entry' = entry { heLiveness = LvOrphaned, heOrphanTicks = ticks }
          in if ticks > graceTicks
               then (Map.delete hid m', entry' : ev)  -- evict
               else (Map.insert hid entry' m', ev)

classify :: HarnessFlavour -> Text -> Map.Map Text Text -> Liveness
classify HfClaudeCode screen markers = observeClaudeCode screen markers
classify _ _ _ = LvIdle

flavourText :: HarnessFlavour -> Text
flavourText HfClaudeCode = "claude-code"
flavourText HfCodex      = "codex"
flavourText HfGeneric    = "generic"
flavourText (HCustom t)  = t