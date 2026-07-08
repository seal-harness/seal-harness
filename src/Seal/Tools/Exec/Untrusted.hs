-- | 'UntrustedExecBackend' — a smart-constructed type that can ONLY be
-- built from an 'Ssh' backend (spec §4). A local container/VM shares the
-- harness kernel and does NOT count as remote (spec §2 sharpening), so
-- 'Container' cannot produce this type either.
--
-- This is the type the remote-only arm of 'selectUntrustedBackend' returns;
-- the dispatcher's full-sum selection is 'selectExecBackend' (4a-T2), which
-- also yields the 'EbLocal' arm. 'UntrustedExecBackend' is the
-- type-guaranteed "this came from SSH" proof.
module Seal.Tools.Exec.Untrusted
  ( UntrustedExecBackend
  , mkUntrustedExecBackend
  , untrustedBackendSshConfig
  , UntrustedExecMode (..)
  , UntrustedExecConfig (..)
  , selectUntrustedBackend
  , selectExecBackend
  ) where

import Seal.Tools.Exec.Types

-- | A backend that untrusted dispatch is allowed to run through. Smart-
-- constructed so it can ONLY come from an 'Ssh' backend (spec §4). A local
-- container/VM shares the harness kernel and does NOT count as remote
-- (spec §2 sharpening), so 'Container' cannot produce this type either.
newtype UntrustedExecBackend = UntrustedExecBackend SshConfig
  deriving stock (Eq, Show)

-- | The only way to obtain an 'UntrustedExecBackend' is to hand in an
-- 'Ssh' 'TerminalBackend'. Local/Tmux/Container all fail with the
-- appropriate 'ExecError'.
mkUntrustedExecBackend :: TerminalBackend -> Either ExecError UntrustedExecBackend
mkUntrustedExecBackend = \case
  TbSsh cfg       -> Right (UntrustedExecBackend cfg)
  TbLocal         -> Left ExecLocalNotPermittedForUntrusted
  TbTmux _        -> Left ExecNotImplemented
  TbContainer _   -> Left ExecNotImplemented

-- | Recover the 'SshConfig' from an 'UntrustedExecBackend' (the remote
-- executor in 4g consumes this).
untrustedBackendSshConfig :: UntrustedExecBackend -> SshConfig
untrustedBackendSshConfig (UntrustedExecBackend cfg) = cfg

-- ---------------------------------------------------------------------------
-- UntrustedExecConfig + the two pure select functions (4a-T2)
-- ---------------------------------------------------------------------------

-- | The runtime mode (spec §3 Layer A): @local@ (default) or @remote@
-- (fail-closed). Forced @remote@ under the @-f remote-only-untrusted@
-- Cabal flag (4g-T2).
data UntrustedExecMode = UemLocal | UemRemote
  deriving stock (Eq, Show)

-- | The untrusted-execution configuration the pure select functions
-- consume. Carries the 'mode' and the remote 'SshConfig' (if configured).
-- The full TOML parsing lands in 4b-T2; 4a-T2 only needs the type.
data UntrustedExecConfig = UntrustedExecConfig
  { uecMode   :: UntrustedExecMode
  , uecRemote :: Maybe SshConfig
  }
  deriving stock (Eq, Show)

-- | The spec's @selectUntrustedBackend@, narrowed to the remote arm.
-- Returns 'Right' ONLY when the backend is 'Ssh' AND a remote 'SshConfig'
-- is configured AND the mode permits it. NEVER yields a local-capable
-- backend (the 'UntrustedExecBackend' type is Ssh-only by construction).
--
-- @mode=local@ always returns 'Left ExecLocalNotPermittedForUntrusted'
-- (this function is the remote-only selector; the full-sum selector is
-- 'selectExecBackend').
selectUntrustedBackend
  :: UntrustedExecConfig -> TerminalBackend -> Either ExecError UntrustedExecBackend
selectUntrustedBackend cfg = \case
  TbSsh _        -> case uecRemote cfg of
                      Just _  -> case uecMode cfg of
                                   UemRemote -> mkUntrustedExecBackend (TbSsh (sshFromCfg cfg))
                                   UemLocal -> Left ExecLocalNotPermittedForUntrusted
                      Nothing -> Left ExecRemoteRequired
  TbLocal        -> Left ExecLocalNotPermittedForUntrusted
  TbTmux _       -> Left ExecNotImplemented
  TbContainer _  -> Left ExecNotImplemented
  where
    -- Recover the configured SshConfig. (Only reached when uecRemote is Just.)
    sshFromCfg c = case uecRemote c of
      Just s  -> s
      Nothing -> error "selectUntrustedBackend: unreachable (guarded by uecRemote check)"

-- | The full-sum selector the dispatcher wires. Returns 'EbLocal' when
-- @mode=local@ + 'TbLocal'; 'EbRemote' when @mode=remote@ + 'TbSsh'
-- configured; 'Left' otherwise (fail-closed, no local fallback under
-- @mode=remote@).
selectExecBackend
  :: UntrustedExecConfig -> TerminalBackend -> Either ExecError ExecBackend
selectExecBackend cfg = \case
  TbLocal        -> case uecMode cfg of
                      UemLocal  -> Right (EbLocal mkLocalExecHandlePlaceholder)
                      UemRemote -> Left ExecLocalNotPermittedForUntrusted
  TbSsh _        -> case (uecMode cfg, uecRemote cfg) of
                      (UemLocal, _)       -> Left ExecLocalNotPermittedForUntrusted
                      (UemRemote, Just s) -> Right (EbRemote s)
                      (UemRemote, Nothing) -> Left ExecRemoteRequired
  TbTmux _       -> Left ExecNotImplemented
  TbContainer _  -> Left ExecNotImplemented