{-# LANGUAGE OverloadedStrings #-}
-- | The seven-row resolver: given a decoded inventory, the single
-- @allow_localhost@ decision, and a session's pin, decide where that
-- session's untrusted code runs.
--
-- The rows are first-match-wins and copied from design rev 10 §5. Row order
-- is the whole specification; do not reorder without re-reading §5.
--
-- 'resolveTarget' takes a resolved 'Bool', never the @Maybe
-- UntrustedExecFileConfig@: @maybe True uefcAllowLocalhost@ type-checks,
-- passes every non-CPP test, and silently reintroduces the hardened-build
-- bug. The value has exactly one producer
-- ('Seal.Config.Security.allowLocalhostFrom').
--
-- There is **no address classifier** here. Design §4.1 deleted the loopback
-- denylist deliberately: an address denylist cannot bind the principal who
-- owns the file, and the real control is that no agent-reachable path can add
-- a machine. Do not reintroduce one.
module Seal.Execution.Resolve
  ( resolveTarget
  , loadAndResolveTargetIO
  , resolveBootTarget
  ) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text qualified as T

import Seal.Config.Execution (ExecutionConfig (..), loadExecutionConfigWith)
import Seal.Config.Paths (SealPaths, executionFilePath, securityFilePath)
import Seal.Config.Security (UntrustedExecFileConfig, allowLocalhostFrom)
import Seal.Logging.Global (globalLogIO)
import Katip (Severity (..))
import Seal.Execution.Types
  ( MachineName, ResolvedTarget (..), TargetError (..), TargetPaths (..)
  , machineNameText, renderTargetError, sshConfigFromMachine )

-- | Resolve a session's target. Seven rows, first match wins.
resolveTarget
  :: ExecutionConfig
  -> Bool                 -- ^ allow_localhost, from 'allowLocalhostFrom' ONLY
  -> Maybe MachineName    -- ^ the session's pin
  -> Either TargetError ResolvedTarget
resolveTarget ec allowLocalhost pin = case pin of
  -- Row 0 — the pin is validated BEFORE the default is consulted. A valid
  -- pin naming a since-removed machine decodes fine and would otherwise fall
  -- to row 2, silently changing authority.
  Just p
    | machineNameText p == "local" ->
        if allowLocalhost then Right WhereLocal else Left (TargetLocalNotAllowed p)
    | Just spec <- Map.lookup p (ecMachines ec) ->
        Right (WhereSsh p (sshConfigFromMachine spec))
    | otherwise ->
        Left (TargetUnknownMachine p (Map.keys (ecMachines ec)))

  -- Rows 1a / 1b / 2 — only reached when no pin resolved, and all three
  -- concern the *effective* default.
  Nothing -> case effectiveDefault of
    Left e    -> Left e
    Right Nothing -> fallback
    Right (Just d)
      | machineNameText d == "local" ->
          if allowLocalhost then fallback else Left (TargetLocalNotAllowed d)
      | Just spec <- Map.lookup d (ecMachines ec) ->
          Right (WhereSsh d (sshConfigFromMachine spec))
      -- Row 1b — a dangling default. Without this row, renaming or force-
      -- deleting the machine a `default` names would skip row 2 and fall to
      -- row 3, moving every unpinned session to WhereLocal.
      | otherwise ->
          Left (TargetConfigLoadError
            ("default names \"" <> machineNameText d
              <> "\", which is not in [machines]"))
  where
    -- The effective-default rule (§5): an explicit `default` always wins;
    -- absent with exactly one machine is that machine ONLY when localhost is
    -- disallowed — writing the first machine must move nobody; absent with
    -- two or more is a config-load error. `local` does not count as a peer.
    effectiveDefault :: Either TargetError (Maybe MachineName)
    effectiveDefault = case ecDefault ec of
      Just d -> Right (Just d)
      Nothing
        | Map.size (ecMachines ec) == 1 ->
            Right (if allowLocalhost then Nothing else listToMaybeMachine)
        | Map.size (ecMachines ec) > 1 ->
            Left (TargetConfigLoadError
              ("more than one machine is defined ("
                <> machineList <> "); set `default` to one of them"))
        | otherwise -> Right Nothing

    listToMaybeMachine = Set.lookupMin (Map.keysSet (ecMachines ec))

    machineList =
      T.intercalate ", " (map machineNameText (Map.keys (ecMachines ec)))

    -- Row 3 / row 4.
    fallback :: Either TargetError ResolvedTarget
    fallback
      | allowLocalhost = Right WhereLocal
      | otherwise      = Left TargetNoMachine

-- | Resolve a target for a BOOT-TIME surface — one that exists before (or
-- without) a session, so it has no pin to honour: the CLI's @isRemote@ flag,
-- the @serve@ file explorer.
--
-- Always called with 'Nothing' as the pin. A failure is logged at warn with
-- the full rendered message and then propagated, because the two callers want
-- different fallbacks: @serve@'s explorer fails closed, and CLI boot treats
-- "nothing may run" as "nothing is remote".
--
-- Takes a 'TargetPaths' so the warning names the operator's real files even
-- when @SEAL_HOME@ is not the default.
resolveBootTarget
  :: SealPaths
  -> Maybe UntrustedExecFileConfig
  -> IO (Either TargetError ResolvedTarget)
resolveBootTarget paths legacy = do
  e <- loadAndResolveTargetIO paths legacy Nothing
  case e of
    Left err -> globalLogIO WarningS
      (fromString (T.unpack (renderTargetError bootPaths err)))
    Right _  -> pure ()
  pure e
  where
    bootPaths = TargetPaths
      { tpExecution = T.pack (executionFilePath paths)
      , tpSecurity  = T.pack (securityFilePath paths)
      }

-- | Load the inventory and resolve in one step. The @Maybe
-- UntrustedExecFileConfig@ is threaded through so legacy synthesis can apply;
-- the @Bool@ is derived here from that same value and nowhere else.
loadAndResolveTargetIO
  :: SealPaths
  -> Maybe UntrustedExecFileConfig
  -> Maybe MachineName
  -> IO (Either TargetError ResolvedTarget)
loadAndResolveTargetIO paths legacy pin = do
  let allowLocalhost = allowLocalhostFrom legacy
  loaded <- loadExecutionConfigWith allowLocalhost legacy paths
  pure (loaded >>= \(ec, _) -> resolveTarget ec allowLocalhost pin)
