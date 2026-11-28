{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | 'UntrustedExecBackend' — a smart-constructed type that can ONLY be
-- built from an 'Ssh' backend (spec 4). A local container/VM shares the
-- harness kernel and does NOT count as remote (spec 2 sharpening), so
-- 'Container' cannot produce this type either.
--
-- This is the type the remote-only arm of 'selectUntrustedBackend' returns;
-- the dispatcher's full-sum selection is 'selectExecBackend' (4a-T2), which
-- also yields the 'EbLocal' arm. 'UntrustedExecBackend' is the
-- type-guaranteed "this came from SSH" proof.
--
-- == What moved out of this module
--
-- 'UntrustedExecConfig' used to carry both the mode /and/ the resolved remote
-- 'SshConfig'. The coordinates now live in @machines.toml@ as named machines
-- ('Seal.Config.Machines'), so all that is left here is the mode — which is
-- what 'allow_localhost' resolves to ('Seal.Config.Security').
module Seal.Tools.Exec.Untrusted
  ( UntrustedExecBackend
  , mkUntrustedExecBackend
  , untrustedBackendSshConfig
  , UntrustedExecConfig (..)
  , selectUntrustedBackend
  , selectExecBackend
  , enforceRemoteOnly
  ) where

import Data.Text (Text)
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
  TbTmux _       -> Left ExecNotImplemented
  TbContainer _  -> Left ExecNotImplemented

-- | The startup check for the @remote-only-untrusted@ Cabal flag (spec 3
-- Layer B). A hardened binary has no local untrusted executor, so
-- @allow_localhost = true@ is a configuration it cannot honour: boot must
-- refuse rather than start and then fail every local call.
--
-- __The input is the resolved, total config — not a @Maybe@.__ The previous
-- shape took a @Maybe@-collapsed 'UntrustedExecConfig' that was 'Nothing' in
-- exactly the state this check exists to reject: an absent
-- @[untrusted_execution]@ section, which defaults to @allow_localhost =
-- true@. A check whose input cannot express the forbidden state cannot fire,
-- which is why this had no call site. 'untrustedExecConfigFromSecurity' is
-- now total ('Seal.Config.Security'), so the forbidden state is representable
-- here and the check can do its job.
--
-- Pure, so the startup check is testable without booting.
enforceRemoteOnly :: UntrustedExecConfig -> Either Text ()
enforceRemoteOnly cfg
  | uecAllowLocalhost cfg = Left hardenedBuildMessage
  | otherwise             = Right ()
  where
    hardenedBuildMessage =
      "remote-only-untrusted build: allow_localhost = true is rejected "
        <> "(the local executor is absent from this binary). Set "
        <> "allow_localhost = false in ~/.seal/security.toml, or use a "
        <> "default build."

-- | Recover the 'SshConfig' from an 'UntrustedExecBackend' (the remote
-- executor in 4g consumes this).
untrustedBackendSshConfig :: UntrustedExecBackend -> SshConfig
untrustedBackendSshConfig (UntrustedExecBackend cfg) = cfg

-- ---------------------------------------------------------------------------
-- UntrustedExecConfig + the two pure select functions (4a-T2)
-- ---------------------------------------------------------------------------

-- | The untrusted-execution configuration the pure select functions consume.
-- Exactly one field, and it is the operator's @allow_localhost@ decision.
--
-- There is no separate @local@/@remote@ mode any more: the two were the same
-- fact spelled two ways, and the @Bool@ is the one the config file actually
-- holds. Keeping both invited the bug design 8 records — a selector that read
-- the mode as "may this target run at all", refusing every remote machine
-- under the default. @allow_localhost@ gates @local@ and nothing else.
--
-- It also no longer carries a remote 'SshConfig'. With named machines there is
-- no single remote, so a field claiming to be /the/ remote could only be wrong;
-- per-call machine resolution ('Seal.Tools.Exec.Machine') picks a target now.
newtype UntrustedExecConfig = UntrustedExecConfig
  { uecAllowLocalhost :: Bool
  }
  deriving stock (Eq, Show)

-- | The spec's @selectUntrustedBackend@, narrowed to the remote arm.
-- Returns 'Right' ONLY when the backend is an 'Ssh' one. NEVER yields a
-- local-capable backend — the 'UntrustedExecBackend' type is Ssh-only by
-- construction.
--
-- @allow_localhost@ does not gate this function. It is the remote-only
-- selector, so a local handle is never its answer regardless of the flag; the
-- flag's job is to decide whether @MtLocal@ is offered at all, which happens
-- in resolution ('Seal.Config.Machines.resolveMachines') and in the
-- full-sum selector below.
selectUntrustedBackend
  :: UntrustedExecConfig -> TerminalBackend -> Either ExecError UntrustedExecBackend
selectUntrustedBackend _cfg = \case
  TbSsh cfg'     -> mkUntrustedExecBackend (TbSsh cfg')
  TbLocal        -> Left ExecLocalNotPermittedForUntrusted
  TbTmux _       -> Left ExecNotImplemented
  TbContainer _  -> Left ExecNotImplemented

-- | The full-sum selector: what does this target become?
--
-- __The corrected truth table__ (design 8 step 2). Revision 1's table gated
-- remote machines on the local/remote mode, which refused *every* machine
-- under the default configuration. @allow_localhost@ gates @MtLocal@ and
-- nothing else:
--
-- @
--   target    | allow_localhost = true | false
--   ----------+------------------------+--------------------------------------
--   MtLocal   | EbLocal                | Left ExecLocalNotPermittedForUntrusted
--   MtSsh c   | EbRemote c             | EbRemote c
-- @
--
-- The property this gives: 'MtLocal' under a false flag is never 'EbLocal',
-- and 'MtSsh' is never 'EbLocal'. Both are asserted in
-- @Seal.Tools.Exec.UntrustedSpec@.
selectExecBackend
  :: UntrustedExecConfig -> TerminalBackend -> Either ExecError ExecBackend
selectExecBackend cfg = \case
  TbLocal        | uecAllowLocalhost cfg -> Right (EbLocal mkLocalExecHandlePlaceholder)
                 | otherwise             -> Left ExecLocalNotPermittedForUntrusted
  TbSsh sshCfg   -> Right (EbRemote sshCfg)
  TbTmux _       -> Left ExecNotImplemented
  TbContainer _  -> Left ExecNotImplemented

