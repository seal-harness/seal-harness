{-# LANGUAGE OverloadedStrings #-}
-- | No-progress repeat detection for session reads (session-read hardening
-- WU4).
--
-- The incident (session 20261022-174851-823): the agent re-issued
-- increasingly large IDENTICAL @SESSION_MANAGE@ reads, each embedding the
-- previous tool result verbatim — a no-progress feedback loop nothing
-- detected. This module gives the agent loop a per-session sliding window
-- of canonical call keys so a no-progress loop becomes observable and
-- interruptible:
--
-- * 1st occurrence — 'RvAllow' (unchanged behavior);
-- * 2nd–3rd — 'RvWarn' (dispatch proceeds; 'repeatWarnNote' is prepended
--   to the result parts so the model sees the signal);
-- * ≥4th — 'RvBlock' (the opcode is never dispatched; an actionable error
--   is synthesized).
--
-- Detection is call-order based (not wall-clock), scoped to 'repeatScope'
-- (@SESSION_MANAGE@ + @SESSION_GET@ only), and enabled by default. The
-- registry is process-lifetime: created once per process at the same
-- origination sites as 'Seal.Tools.Exec.Abort.SessionAbortRegistry' and
-- keyed by 'SessionId', so the window survives across turns and requests.
-- Bounded memory: each session's window holds at most
-- 'repeatWindowCapacity' canonical keys; the registry mirrors the abort
-- registry's map-growth policy (no cap — entries are per live session).
--
-- Security: the 'RepeatTrack' and 'SessionRepeatRegistry' constructors are
-- NOT exported (mirrors 'Seal.Tools.Exec.Abort'). Tracks are obtained from
-- 'newRepeatTrack' or 'lookupOrCreateRepeatTrack' only.
module Seal.ISA.RepeatDetect
  ( -- * Verdicts
    RepeatVerdict (..)
    -- * Per-session sliding window
  , RepeatTrack
  , newRepeatTrack
  , recordCall
    -- * Process-lifetime registry
  , SessionRepeatRegistry
  , newSessionRepeatRegistry
  , lookupOrCreateRepeatTrack
    -- * Scope + loop-facing messages
  , repeatScope
  , repeatWarnNote
  , repeatBlockedMessage
    -- * Pure core (property-testable)
  , repeatWindowCapacity
  , canonicalKey
  , stepWindow
  , windowVerdict
  ) where

import Control.Concurrent.STM
  ( TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar )
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)

import Seal.Core.Types (OpName (..), SessionId)

-- | The repeat detector's verdict for one in-scope call.
data RepeatVerdict
  = RvAllow
    -- ^ First occurrence of the canonical key within the window. Dispatch
    -- unchanged.
  | RvWarn
    -- ^ 2nd–3rd occurrence within the window. The call is dispatched
    -- normally; 'repeatWarnNote' is prepended to the result parts so the
    -- model sees the no-progress signal.
  | RvBlock
    -- ^ ≥4th occurrence within the window. The opcode is never dispatched;
    -- 'repeatBlockedMessage' is synthesized as an error result so the
    -- model can correct course.
  deriving (Eq, Show)

-- | Sliding-window capacity: the number of most-recent canonical call keys
-- retained per session. 'repeatWindowCapacity' intervening calls evict the
-- oldest entry, making an old key \"fresh\" again (detection is
-- call-order based, not permanent).
repeatWindowCapacity :: Int
repeatWindowCapacity = 16

-- | Opcodes subject to repeat detection: session reads only (the incident
-- loop was a session read). Ops outside this set are untracked — zero
-- behavior change.
repeatScope :: Set OpName
repeatScope = Set.fromList [OpName "SESSION_MANAGE", OpName "SESSION_GET"]

-- | The note prepended to a warned call's tool-result parts (model-visible
-- only; nothing content-bearing is added to recorded metadata).
repeatWarnNote :: Text
repeatWarnNote =
  "[note: repeated identical session read — no new information expected]"

-- | The synthesized error for a blocked call. Actionable: names the opcode
-- and tells the model what to do instead of re-issuing the identical call.
repeatBlockedMessage :: OpName -> Text
repeatBlockedMessage (OpName name) =
  "blocked: repeated identical " <> name
  <> " call — refine the request or move on; no new information is expected from repeating it"

-- | Canonical identity of a call: the opcode name, a NUL separator, and the
-- aeson-encoded input as 'Text'. JSON output escapes control characters, so
-- a raw NUL cannot appear in either half — the pair injectively encodes as
-- one 'Text'. The decode is lenient so the function is total
-- (aeson output is always valid UTF-8; leniency is belt-and-braces).
canonicalKey :: OpName -> Value -> Text
canonicalKey (OpName name) input =
  name <> "\0"
       <> TE.decodeUtf8With lenientDecode (BL.toStrict (A.encode input))

-- | Push a canonical key onto the window (most recent first), evicting
-- beyond 'repeatWindowCapacity'. Bounded: the result holds at most
-- 'repeatWindowCapacity' entries, so 'recordCall' is O(window) per call.
stepWindow :: Text -> [Text] -> [Text]
stepWindow key window = take repeatWindowCapacity (key : window)

-- | Verdict for a canonical key against the window AFTER the push (the
-- key itself included): 1 occurrence → 'RvAllow', 2–3 → 'RvWarn', ≥4 →
-- 'RvBlock' (maintainer-confirmed thresholds, 2026-10-22).
windowVerdict :: Text -> [Text] -> RepeatVerdict
windowVerdict key windowAfterPush = case countIn key windowAfterPush of
  n | n >= 4    -> RvBlock
    | n >= 2    -> RvWarn
    | otherwise -> RvAllow

-- | Count a key's occurrences in a window (bounded: callers pass windows
-- of at most 'repeatWindowCapacity' entries).
countIn :: Text -> [Text] -> Int
countIn key = length . filter (== key)

-- | Per-session sliding window of the last 'repeatWindowCapacity' canonical
-- call keys (most recent first). The constructor is NOT exported — tracks
-- are obtained from 'newRepeatTrack' or 'lookupOrCreateRepeatTrack'.
newtype RepeatTrack = RepeatTrack (TVar [Text])

-- | Build a fresh, empty track.
newRepeatTrack :: IO RepeatTrack
newRepeatTrack = RepeatTrack <$> newTVarIO []

-- | Record a call and return its verdict. Pushes the canonical key onto the
-- session's sliding window (evicting beyond 'repeatWindowCapacity'), then
-- counts the key's occurrences in the updated window. O(window) per call,
-- exception-free (the window is bounded; the JSON encoding is total). The
-- agent loop calls this for opcodes in 'repeatScope' only — out-of-scope
-- opcodes are never recorded.
recordCall :: RepeatTrack -> OpName -> Value -> IO RepeatVerdict
recordCall (RepeatTrack tv) name input = do
  let key = canonicalKey name input
  window <- atomically $ do
    old <- readTVar tv
    let new = stepWindow key old
    writeTVar tv new
    pure new
  pure (windowVerdict key window)

-- | Process-lifetime repeat registry (mirrors
-- 'Seal.Tools.Exec.Abort.SessionAbortRegistry'). Maps each 'SessionId' to
-- its 'RepeatTrack', lazily created on first lookup via atomic
-- insert-if-absent STM. Created ONCE per process at the same origination
-- sites as the abort registry — a per-request registry would silently
-- reset the cross-turn window. The constructor is NOT exported.
newtype SessionRepeatRegistry = SessionRepeatRegistry (TVar (Map SessionId RepeatTrack))

-- | Build a new empty registry.
newSessionRepeatRegistry :: IO SessionRepeatRegistry
newSessionRepeatRegistry = SessionRepeatRegistry <$> newTVarIO Map.empty

-- | Look up the 'RepeatTrack' for a session, creating it on first use. The
-- insert-if-absent is atomic via STM, so two concurrent lookups for a new
-- session yield the same track (no duplicate creation). The SAME track is
-- returned for the same sid across calls and turns — this is what makes
-- the window process-lifetime state.
lookupOrCreateRepeatTrack :: SessionRepeatRegistry -> SessionId -> IO RepeatTrack
lookupOrCreateRepeatTrack (SessionRepeatRegistry tv) sid = do
  m <- readTVarIO tv
  case Map.lookup sid m of
    Just track -> pure track
    Nothing -> do
      track <- newRepeatTrack
      atomically $ do
        m' <- readTVar tv
        -- insertIfAbsent semantics: if another thread won the race, use
        -- its track; otherwise insert ours.
        let track' = fromMaybe track (Map.lookup sid m')
        writeTVar tv (Map.insert sid track' m')
        pure track'