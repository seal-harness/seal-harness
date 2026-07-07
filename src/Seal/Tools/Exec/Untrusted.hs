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