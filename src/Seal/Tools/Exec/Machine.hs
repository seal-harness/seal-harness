{-# LANGUAGE OverloadedStrings #-}
-- | The per-call execution-machine routing seam.
--
-- This module is the /capability/ side of the machines feature: it holds the
-- 'MachineRouting' carried inside 'UIOEnv', the per-machine handle cache
-- ('MachineSlot'), and the typed 'MachineError' the dispatcher renders.
--
-- __Export discipline matters here.__ 'MachineRouting'\'s constructor is not
-- exported, so a caller can read the routing (@rtResolve@, @rtSession@,
-- @rtSelectable@) and cannot forge one. That keeps @src\/Seal\/ISA\/Ops\/@
-- modules from obtaining a raw 'UntrustedIO' — the
-- @CapabilityScopingWorkdirFsFailSpec@ guard asserts no opcode module imports
-- the internal env module at all.
--
-- == Why the slot carries 'CloneDeps'
--
-- 'CloneDeps' is transport-bound: 'Seal.SourceControl.Clone.cdIsRemote' and
-- 'cdPinnedKnownHosts' describe /how to reach a machine/. A call routed to
-- machine B must get B's clone deps or @SETUP_REPO@ would run B's commands over
-- A's transport. The slot therefore caches both capabilities together, and
-- 'rtResolve' returns both.
--
-- == Why failures are cached
--
-- A dead machine must cost one bootstrap attempt per session, not one per tool
-- call. 'SlotFailed' memoizes the error, so a model that keeps naming an
-- unreachable machine gets an immediate answer rather than a fresh SSH attempt
-- every time.
module Seal.Tools.Exec.Machine
  ( MachineRouting
  , mkMachineRouting
  , rtResolve
  , rtSession
  , rtSelectable
  , seedRouting
  , MachineSlot (..)
  , MachineError (..)
  , UnreachableReason (..)
  , renderUnreachableReason
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Seal.Config.Machines (MachineName, Selectable)
import Seal.SourceControl.Clone (CloneDeps)
import Seal.Tools.Exec.UntrustedIO (UntrustedIO)

-- ---------------------------------------------------------------------------
-- The per-machine handle cache
-- ---------------------------------------------------------------------------

-- | One machine's resolved capabilities, or the error that stopped them being
-- resolved.
data MachineSlot
  = SlotReady !UntrustedIO !CloneDeps
  | SlotFailed !MachineError

-- | 'UntrustedIO' holds closures with no 'Show', so the instance is written out
-- rather than derived. It never renders the handle.
instance Show MachineSlot where
  show (SlotReady _ _) = "SlotReady <handle> <deps>"
  show (SlotFailed e)  = "SlotFailed " <> show e

instance Eq MachineSlot where
  SlotReady _ _ == SlotReady _ _ = True
  SlotFailed a  == SlotFailed b  = a == b
  _             == _             = False

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Why a machine could not be executed against. Every constructor either
-- carries only the machine name or is nullary — none carries a host, user,
-- path, or key, because these values are rendered to the model.
--
-- The one text payload is 'MachineUnknown'\'s requested name, which is the
-- model's own echoed input.
data MachineError
  = MachineUnknown !Text ![MachineName]
    -- ^ The name the model asked for (echoed verbatim) and the valid choices.
  | MachineUnusable !MachineName !UnusableReason
  | MachineGone !MachineName
  | MachineNotPermitted !MachineName
  | MachineDefaultUnset
  | NoMachineSelected
  | MachineUnreachable !MachineName !UnreachableReason
  | MachineHostKeyChanged !MachineName
  deriving stock (Eq, Show)

-- | Why a configured machine is not usable, as far as the /model/ is concerned.
-- Deliberately distinct from 'Seal.Config.Machines.RejectReason': that one may
-- carry the configured value for the operator's boot report, whereas this one
-- names only the condition, so a host or path can never reach the model. The
-- projection is mechanical, not two hand-written strings.
data UnusableReason
  = UrrMissingHost
  | UrrMissingUser
  | UrrMissingWorkspace
  | UrrLoopbackHost
  | UrrInvalidHost
  | UrrInvalidWorkspace
  | UrrInvalidPort
  | UrrReservedName
  | UrrInvalidName
  deriving stock (Eq, Show)

-- | Why a connection or bootstrap did not complete. Nullary by construction: a
-- free-text reason would be the drift hazard typed payloads exist to kill.
data UnreachableReason
  = UrConnectFailed
  | UrBootstrapFailed
  | UrHostKeyUnknown
  deriving stock (Eq, Show)

renderUnreachableReason :: UnreachableReason -> Text
renderUnreachableReason = \case
  UrConnectFailed   -> "could not connect"
  UrBootstrapFailed -> "could not prepare the workspace"
  UrHostKeyUnknown  -> "its host key is not yet known"

-- ---------------------------------------------------------------------------
-- Routing
-- ---------------------------------------------------------------------------

-- | The routing table carried inside 'UIOEnv'. The constructor is not exported;
-- obtain one from 'mkMachineRouting'.
data MachineRouting = MachineRouting
  { _mrResolve    :: !(MachineName -> IO (Either MachineError (UntrustedIO, CloneDeps)))
  , _mrSession    :: !MachineName
  , _mrSelectable :: ![Selectable]
  , _mrSeed       :: !(MachineName -> MachineSlot -> IO ())
    -- ^ test seam: pre-populate a slot so a seeded machine behaves exactly like
    -- one resolved on first use
  }

-- | Build a routing table over a per-machine cache.
--
-- @bootstrap@ is called at most once per machine per session (successes and
-- failures are both memoized). @baseDeps@ is the session machine's deps, used
-- as the template for a newly reached machine's transport settings.
mkMachineRouting
  :: MachineName
  -- ^ the session's machine — the fallback for a call that names none
  -> [Selectable]
  -- ^ what may be chosen (for the prompt and the schema enum)
  -> (MachineName -> CloneDeps -> IO (Either MachineError (UntrustedIO, CloneDeps)))
  -- ^ bootstrap one machine
  -> CloneDeps
  -- ^ the session machine's deps
  -> IO MachineRouting
mkMachineRouting session selectable bootstrap baseDeps = do
  cache <- newIORef (Map.empty :: Map MachineName MachineSlot)
  pure MachineRouting
    { _mrResolve = \name -> resolveVia cache name bootstrap baseDeps
    , _mrSession = session
    , _mrSelectable = selectable
    , _mrSeed = \name slot ->
        atomicModifyIORef' cache (\m -> (Map.insert name slot m, ()))
    }

-- | Fetch-or-bootstrap one machine's capabilities.
resolveVia
  :: IORef (Map MachineName MachineSlot)
  -> MachineName
  -> (MachineName -> CloneDeps -> IO (Either MachineError (UntrustedIO, CloneDeps)))
  -> CloneDeps
  -> IO (Either MachineError (UntrustedIO, CloneDeps))
resolveVia cache name bootstrap baseDeps = do
  existing <- atomicModifyIORef' cache (\m -> (m, Map.lookup name m))
  case existing of
    Just (SlotReady uio deps) -> pure (Right (uio, deps))
    Just (SlotFailed err)     -> pure (Left err)
    Nothing -> do
      outcome <- bootstrap name baseDeps
      case outcome of
        Right (uio, deps) -> do
          atomicModifyIORef' cache (\m -> (Map.insert name (SlotReady uio deps) m, ()))
          pure (Right (uio, deps))
        Left err -> do
          atomicModifyIORef' cache (\m -> (Map.insert name (SlotFailed err) m, ()))
          pure (Left err)

-- | The session's machine — the default for a call that names none.
rtSession :: MachineRouting -> MachineName
rtSession = _mrSession

-- | What may be chosen. Used for the tool-schema enum and the TUI prompt.
rtSelectable :: MachineRouting -> [Selectable]
rtSelectable = _mrSelectable

-- | Resolve a machine to its capabilities, bootstrapping on first use.
rtResolve
  :: MachineRouting
  -> MachineName
  -> IO (Either MachineError (UntrustedIO, CloneDeps))
rtResolve = _mrResolve

-- | Seed a routing table with pre-resolved machines. Test seam: no bootstrap,
-- no SSH. A seeded slot is indistinguishable from one resolved on first use, so
-- a test that seeds two machines exercises the real lookup path.
seedRouting
  :: MachineRouting
  -> [(MachineName, UntrustedIO, CloneDeps)]
  -> IO MachineRouting
seedRouting routing entries = do
  mapM_ (\(n, uio, deps) -> _mrSeed routing n (SlotReady uio deps)) entries
  pure routing
