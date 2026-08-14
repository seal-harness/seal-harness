-- | Session-scoped abort signals for tool-call cancellation.
--
-- Two layers:
--
-- 1. 'AbortFlag' — a per-session 'IORef' 'Bool'. The channel layer (Signal,
--    CLI, Web) calls 'setAbort' when the user sends a stop/interrupt; the
--    dispatch wrapper polls 'isAborted' during the three-way race (see
--    'Seal.Tools.Exec.Timeout.runWithTimeoutAbortRetry'). 'clearAbort' fires
--    once at 'runTurn' entry (before any tool call); a mid-turn abort keeps
--    the flag set until the next turn begins.
--
-- 2. 'SessionAbortRegistry' — a per-session map of 'AbortFlag's, keyed by
--    'SessionId'. Mirrors 'Seal.Session.Lock.SessionLocks' (a @TVar (Map
--    SessionId (MVar ()))@ lazily created per session). This registry is the
--    vehicle for the web @POST /api/sessions/:id/stop@ endpoint: 'ApiDeps'
--    has no 'AgentEnv' (it's constructed per-turn), so the abort flag must
--    be looked up by session id rather than threaded through 'AgentEnv'
--    alone. The CLI owns one session; the web gateway + inbox channels use
--    the registry.
--
-- Security: the 'AbortFlag' constructor is NOT exported (design Blocker
--    Resolution #6 — mirrors the 'UntrustedIO' capability-handle pattern at
--    'Seal.Tools.Exec.UntrustedIO'). Only the smart constructors and
--    accessors below are exported. This prevents an untrusted opcode from
--    forging an 'AbortFlag' or pattern-matching out the 'IORef' to write
--    directly, bypassing 'setAbort'. The 'SessionAbortRegistry' constructor
--    is likewise unexported.
module Seal.Tools.Exec.Abort
  ( AbortFlag
  , newAbortFlag
  , isAborted
  , setAbort
  , clearAbort
  , waitForAbort
  , SessionAbortRegistry
  , newSessionAbortRegistry
  , lookupOrCreateAbortFlag
  , setSessionAbort
  , clearSessionAbort
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar )
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)

import Seal.Core.Types (SessionId)

-- | A session-scoped abort flag. Set by the channel/user to cancel
-- in-flight tool calls. Checked by the dispatch wrapper during the
-- three-way race. The constructor is NOT exported (Blocker Resolution #6).
newtype AbortFlag = AbortFlag (IORef Bool)

-- | Per-session abort registry (mirrors 'SessionLocks' at
-- "Seal.Session.Lock"). Maps each 'SessionId' to its 'AbortFlag', lazily
-- created on first lookup. STM-backed so 'lookupOrCreateAbortFlag' is
-- race-safe (two concurrent lookups for a new session won't create two
-- flags — uses @modifyTVar'@ insert-if-absent semantics). The constructor
-- is NOT exported.
newtype SessionAbortRegistry = SessionAbortRegistry (TVar (Map SessionId AbortFlag))

-- | Build a fresh, non-aborted flag.
newAbortFlag :: IO AbortFlag
newAbortFlag = AbortFlag <$> newIORef False

-- | Check whether the flag has been set.
isAborted :: AbortFlag -> IO Bool
isAborted (AbortFlag ref) = readIORef ref

-- | Set the abort flag (idempotent).
setAbort :: AbortFlag -> IO ()
setAbort (AbortFlag ref) = writeIORef ref True

-- | Clear the abort flag (idempotent; a no-op on a fresh flag).
clearAbort :: AbortFlag -> IO ()
clearAbort (AbortFlag ref) = writeIORef ref False

-- | Poll 'isAborted' every @pollMicros@ microseconds. Returns 'True' as
-- soon as the flag is set. Used as the third participant in the three-way
-- race (worker vs timeout vs abort-poll). The poll interval is passed in
-- by the caller (defaults to @ttcAbortPollMicros@ = 100ms from
-- 'Seal.Tools.Timeout.ToolTimeoutConfig').
waitForAbort :: AbortFlag -> Int -> IO Bool
waitForAbort flag pollMicros = do
  aborted <- isAborted flag
  if aborted
    then pure True
    else do
      threadDelay pollMicros
      waitForAbort flag pollMicros

-- | Build a new empty registry.
newSessionAbortRegistry :: IO SessionAbortRegistry
newSessionAbortRegistry = SessionAbortRegistry <$> newTVarIO Map.empty

-- | Look up the 'AbortFlag' for a session, creating it on first use. The
-- insert-if-absent is atomic via STM, so two concurrent lookups for a new
-- session yield the same flag (no duplicate creation).
lookupOrCreateAbortFlag :: SessionAbortRegistry -> SessionId -> IO AbortFlag
lookupOrCreateAbortFlag (SessionAbortRegistry tv) sid = do
  m <- readTVarIO tv
  case Map.lookup sid m of
    Just flag -> pure flag
    Nothing -> do
      flag <- newAbortFlag
      atomically $ do
        m' <- readTVar tv
        -- insertIfAbsent semantics: if another thread won the race, use
        -- its flag; otherwise insert ours.
        let flag' = fromMaybe flag (Map.lookup sid m')
        writeTVar tv (Map.insert sid flag' m')
        pure flag'

-- | Set the abort flag for a session (creates the flag on first use).
setSessionAbort :: SessionAbortRegistry -> SessionId -> IO ()
setSessionAbort reg sid = do
  flag <- lookupOrCreateAbortFlag reg sid
  setAbort flag

-- | Clear the abort flag for a session (creates the flag on first use if
-- it doesn't exist, then clears it — equivalent to a no-op since a fresh
-- flag is already clear).
clearSessionAbort :: SessionAbortRegistry -> SessionId -> IO ()
clearSessionAbort reg sid = do
  flag <- lookupOrCreateAbortFlag reg sid
  clearAbort flag