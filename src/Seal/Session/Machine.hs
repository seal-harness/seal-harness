{-# LANGUAGE OverloadedStrings #-}
-- | The session-machine resolver and the operator-facing config-error renderer
-- (design §5.1, §5.5 row 4).
--
-- Two responsibilities, both pure:
--
-- * 'machineForSession' turns "what the session recorded, if anything" plus the
--   resolved 'MachineRegistry' into the machine the session runs on, or the
--   typed reason it cannot.
-- * 'renderMachineConfigError' renders a 'RejectReason' for a /human/ — the
--   operator reading a boot report or @/machine list@, never the model.
--
-- The model-facing renderer is 'Seal.ISA.Ops.Machine.renderMachineError', which
-- takes a 'MachineError' and may name only the machine. The split is why
-- 'RejectReason' and 'UnusableReason' are two types: this renderer may print the
-- host the operator wrote, and the other one structurally cannot.
--
-- __This module is the reason @Config@ does not own it.__ It needs
-- 'SessionMeta', which is a leaf; putting it in 'Seal.Config.Machines' would make
-- config depend on session state.
module Seal.Session.Machine
  ( machineForSession
  , renderMachineConfigError
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Seal.Config.Machines
  ( MachineName, MachineRegistry (..), MachineTarget, MissingField (..)
  , RejectReason (..), machineNameText )
import Seal.Session.Meta (SessionMeta, smMachine)
import Seal.Tools.Exec.Machine
  ( MachineError (..), UnusableReason (..), resolveRegistryTarget )

-- | Which machine does this session run on?
--
-- The ordered table from design §5.1. The order is the whole content of the
-- function: each case is a different user-facing reason, and collapsing any two
-- of them produces either an unreachable constructor or the wrong message.
--
-- @
--   1  Just n, n in regMachines      -> that target
--   2  Just n, n in regRejected      -> MachineUnusable n reason
--   3  Just "local", flag false      -> MachineNotPermitted "local"
--   4  Just n, otherwise             -> MachineGone n
--   5a Nothing, regDefault = Just d  -> d
--   5b Nothing, no default, flag off, regMachines empty
--                                    -> NoMachineSelected
--   5c Nothing, no default, else     -> MachineDefaultUnset
-- @
--
-- Cases 2 and 3 are why this is not just 'resolveRegistryTarget': a /named/
-- machine can be present-but-unusable, or known-but-forbidden, and the operator
-- needs to be told which. Case 5b is why 'NoMachineSelected' is not redundant
-- with 'MachineDefaultUnset' — it is the only state that produces the
-- requirements' @allow_localhost is false and no execution machine is
-- configured@ text.
--
-- __When the failure surfaces:__ at the start of every turn and every dispatch,
-- so a session whose machine is gone still resumes and reads, and the error
-- appears at its first untrusted call. Stated because the requirements do not
-- pin the timing.
machineForSession
  :: MachineRegistry
  -> SessionMeta
  -> Either MachineError (MachineName, MachineTarget)
machineForSession reg meta = case smMachine meta of
  Just name
    | Map.member name (regMachines reg) -> resolveRegistryTarget reg (Just name)
    | Map.member name (regRejected reg) ->
        Left (MachineUnusable name (unusableReasonOf name))
    -- A named `local` under allow_localhost = false. `local` is not in
    -- regRejected (it is never a file entry), so this must be its own case.
    | machineNameText name == "local" -> Left (MachineNotPermitted name)
    | otherwise -> Left (MachineGone name)
  Nothing -> case regDefault reg of
    Just d  -> resolveRegistryTarget reg (Just d)
    Nothing
      | Map.null (regMachines reg) -> Left NoMachineSelected
      | otherwise                  -> Left MachineDefaultUnset
  where
    -- The registry stores the /config-side/ reason, which may carry the
    -- operator's text; the model-facing projection is 'MachineError''s job, so
    -- the conversion happens in 'Seal.Tools.Exec.Machine'. Here we only need to
    -- know that the machine is rejected, and hand the reason along.
    unusableReasonOf name =
      maybe UrrInvalidName rejectToUnusable (Map.lookup name (regRejected reg))
    rejectToUnusable = \case
      RrMissingField MissingHost      -> UrrMissingHost
      RrMissingField MissingUser      -> UrrMissingUser
      RrMissingField MissingWorkspace -> UrrMissingWorkspace
      RrLoopbackHost _                -> UrrLoopbackHost
      RrInvalidHost _                 -> UrrInvalidHost
      RrInvalidWorkspace _            -> UrrInvalidWorkspace
      RrInvalidPort                   -> UrrInvalidPort
      RrReservedName                  -> UrrReservedName
      RrInvalidName _                 -> UrrInvalidName

-- | Render a rejection for a human, with the @machines.toml:@ prefix.
--
-- Unlike the model-facing renderer this one /does/ name the configured value —
-- that is the point of a boot report. @RrLoopbackHost@ carries the host exactly
-- as written, so an operator who typed @127.0.0.1@ is told about @127.0.0.1@,
-- not about a hardcoded @localhost@.
renderMachineConfigError :: MachineName -> RejectReason -> Text
renderMachineConfigError name reason =
  "machines.toml: machine \"" <> machineNameText name <> "\" is unusable: "
    <> body reason
  where
    body = \case
      RrMissingField MissingHost      -> "host is not configured."
      RrMissingField MissingUser      -> "user is not configured."
      RrMissingField MissingWorkspace -> "workspace not configured."
      RrLoopbackHost host ->
        "host \"" <> host <> "\" is this machine. A remote execution machine "
          <> "must be a separate machine."
      RrInvalidHost why      -> "host is not usable: " <> why
      RrInvalidWorkspace why -> "workspace is not usable: " <> why
      RrInvalidPort ->
        "port must be between 1 and 65535."
      RrReservedName ->
        "\"local\" is reserved for the harness machine; it is implicit and "
          <> "cannot be declared."
      RrInvalidName why -> "the name is not usable: " <> why
