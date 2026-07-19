{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @TerminalBackend@ family — the typed selector for *where* a tool
-- call runs ('Local' / 'Tmux' / 'Ssh' / 'Container'). This is the
-- tool-call-execution counterpart to the tmux-only harness backend fixed
-- in Phase 6a: distinct concern, distinct type.
--
-- This module is the shared home of the executor-layer types that
-- 'Seal.Tools.Exec.Untrusted' and 'Seal.Tools.Exec.Local' both import
-- (breaking what would otherwise be a mutual-import cycle — see the Phase
-- 4 plan 4b-T1 "Import-cycle resolution"). It holds:
--
--   * 'TerminalBackend' — the selector ADT
--   * 'TmuxConfig' / 'SshConfig' / 'ContainerSpec' / 'ContainerTarget' —
--     the per-variant config
--   * 'SshHost' / 'SshUser' / 'RemotePath' — validated argv/path newtypes
--     (option-injection defense, Invariant 2)
--   * 'ExecError' — the executor-layer error ADT
--   * 'LocalExecHandle' — the local-executor handle (TYPE and CONSTRUCTOR,
--     both in this module per Haskell's rule that a type and its
--     constructors must be co-located). 4a ships an opaque placeholder
--     (no exported constructors); 4b-T1 widens this declaration to the real
--     record of IO actions. The constructor stays here; the smart
--     constructor 'mkLocalExecHandle' lands in 'Seal.Tools.Exec.Local'.
--   * 'ExecBackend' — the sum the dispatcher consumes. Added in 4a-T2.
module Seal.Tools.Exec.Types
  ( TerminalBackend (..)
  , TmuxConfig (..)
  , SshConfig (..)
  , ContainerSpec (..)
  , ContainerTarget
  , mkContainerTarget
  , getContainerTarget
  , SshHost
  , mkSshHost
  , getSshHost
  , SshUser
  , mkSshUser
  , getSshUser
  , RemotePath
  , mkRemotePath
  , getRemotePath
  , ExecError (..)
  , LocalExecHandle (..)
  , mkLocalExecHandlePlaceholder
  , ExecBackend (..)
  ) where

import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Seal.Tools.Args (BinName, BinArg, ShellCommand)

-- ---------------------------------------------------------------------------
-- TerminalBackend family
-- ---------------------------------------------------------------------------

-- | Where a tool call runs. 'TbLocal' is the untrusted local executor
-- (absent under the @-f remote-only-untrusted@ Cabal flag); 'TbTmux' is
-- the already-existing harness backend (Phase 6a); 'TbSsh' is the remote
-- SSH executor (Phase 4 4g); 'TbContainer' is forward-compat (stubbed).
data TerminalBackend
  = TbLocal
  | TbTmux TmuxConfig
  | TbSsh SshConfig
  | TbContainer ContainerSpec
  deriving stock (Eq, Show)

-- | The tmux coordinates for a 'TbTmux' tool call. Phase 4 leaves this as a
-- minimal placeholder — the harness backend ('Seal.Session.Kind.HarnessSpec')
-- is the load-bearing tmux consumer; 'TbTmux' as a *tool-call* backend is
-- forward-compat. Widened in a future phase if/when tool calls route
-- through tmux directly.
data TmuxConfig = TmuxConfig
  deriving stock (Eq, Show)

-- | SSH coordinates for a 'TbSsh' tool call (the remote-only untrusted
-- executor, spec §4-§5). The 'scWorkspace' anchors 'SafePath' on the
-- remote machine.
data SshConfig = SshConfig
  { scHost       :: SshHost
  , scUser       :: SshUser
  , scPort       :: Int            -- ^ 1..65535 (validated by the caller)
  , scIdentity   :: Maybe FilePath -- ^ SSH key file (or ssh-agent)
  , scKnownHosts :: FilePath       -- ^ pinned; StrictHostKeyChecking=yes
  , scWorkspace  :: RemotePath     -- ^ remote workspace root (validated)
  }
  deriving stock (Eq, Show)

data ContainerSpec = ContainerSpec
  { csTarget :: ContainerTarget
  , csImage  :: Text
  }
  deriving stock (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Validated newtypes (Invariant 2 — type-guaranteed argument sanitization)
-- ---------------------------------------------------------------------------

-- | A container target name (e.g. @ubuntu-22.04@). Smart-constructed: rejects
-- leading-dash (option injection), path separators (@/@ @\\@), colon
-- (option-injection / port-syntax defense), control chars, empty.
newtype ContainerTarget = ContainerTarget Text
  deriving stock (Eq, Show)

mkContainerTarget :: Text -> Either Text ContainerTarget
mkContainerTarget t
  | T.null t              = Left "container target is empty"
  | T.head t == '-'       = Left "container target must not start with '-'"
  | T.any isBad t         = Left "container target has invalid characters"
  | otherwise             = Right (ContainerTarget t)
  where
    isBad c = c == '/' || c == '\\' || c == ':' || isControl c

getContainerTarget :: ContainerTarget -> Text
getContainerTarget (ContainerTarget t) = t

-- | An SSH host. Smart-constructed: rejects control chars, space, colon
-- (the colon guards against @host:port@ being parsed as two argv tokens
-- by some tooling).
newtype SshHost = SshHost Text
  deriving stock (Eq, Show)

mkSshHost :: Text -> Either Text SshHost
mkSshHost t
  | T.null t        = Left "ssh host is empty"
  | T.any isBad t   = Left "ssh host has invalid characters"
  | otherwise       = Right (SshHost t)
  where
    isBad c = isControl c || c == ' ' || c == ':'

getSshHost :: SshHost -> Text
getSshHost (SshHost t) = t

-- | An SSH user. Same validation as 'SshHost'.
newtype SshUser = SshUser Text
  deriving stock (Eq, Show)

mkSshUser :: Text -> Either Text SshUser
mkSshUser t
  | T.null t        = Left "ssh user is empty"
  | T.any isBad t   = Left "ssh user has invalid characters"
  | otherwise       = Right (SshUser t)
  where
    isBad c = isControl c || c == ' ' || c == ':'

getSshUser :: SshUser -> Text
getSshUser (SshUser t) = t

-- | A workspace-relative path on the remote machine. Smart-constructed:
-- rejects leading-dash (option injection), and rejects a @..@ escape. 4a
-- ships a permissive validator (the lexical re-anchoring against the
-- remote root is the job of 'Seal.Security.Path.mkSafePathRemote' in 4g);
-- 4a only needs a validated newtype the 'SshConfig' can carry.
newtype RemotePath = RemotePath Text
  deriving stock (Eq, Show)

mkRemotePath :: Text -> Either Text RemotePath
mkRemotePath t
  | T.null t              = Left "remote path is empty"
  | T.head t == '-'       = Left "remote path must not start with '-'"
  | T.any isControl t     = Left "remote path has control characters"
  | otherwise             = Right (RemotePath t)

getRemotePath :: RemotePath -> Text
getRemotePath (RemotePath t) = t

-- ---------------------------------------------------------------------------
-- ExecError
-- ---------------------------------------------------------------------------

-- | The executor-layer error ADT. Lives here (not in
-- 'Seal.Tools.Exec.Untrusted') to break the import cycle with
-- 'Seal.Tools.Exec.Local'.
data ExecError
  = ExecNotAllowed                -- ^ the operator policy denies the call
  | ExecLocalNotPermittedForUntrusted -- ^ 'selectUntrustedBackend' got a non-Ssh backend
  | ExecRemoteRequired            -- ^ mode=remote but no remote configured/reachable
  | ExecRemoteUnreachable         -- ^ SSH connect failed (not a host-key mismatch)
  | ExecHostKeyMismatch           -- ^ hard security failure; never bypassed
  | ExecNotImplemented            -- ^ the backend is stubbed (e.g. TbContainer, TbTmux-as-tool-call)
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- LocalExecHandle (placeholder — widened in 4b-T1)
-- ---------------------------------------------------------------------------

-- | The local-executor handle. The TYPE and its CONSTRUCTOR both live here
-- (Haskell requires a type and its constructors in the same module — the
-- 4a placeholder was an opaque `data LocalExecHandle` with no constructors;
-- 4b-T1 widens it to the real handle). The smart constructor that wires
-- the real `System.Process`-backed IO actions lives in
-- 'Seal.Tools.Exec.Local' ('mkLocalExecHandle'); the tests also use the
-- placeholder constructor directly for fakes.
--
-- The fields are the IO actions the Untrusted opcodes call. Each returns
-- an 'Either ExecError' so the opcode can surface a structured error
-- (fail-closed) instead of throwing.
data LocalExecHandle = LocalExecHandle
  { lehExecShell :: ShellCommand -> Maybe RemotePath -> IO (Either ExecError Text)
    -- ^ run a validated 'ShellCommand' via @/bin/sh -c@ (single arg, fixed
    -- argv), with an optional cwd ('SafePath'-confined to the workspace root)
  , lehExecBin :: BinName -> [BinArg] -> IO (Either ExecError Text)
    -- ^ run a named binary (resolved on PATH or by absolute/relative path,
    -- via 'System.Process.proc' RawCommand — no shell) with validated argv
    -- args. Used by the BIN_EXEC opcode.
  }

-- | A placeholder constructor for tests that don't exercise the IO
-- (mirrors the 4a opaque form). Real callers use
-- 'Seal.Tools.Exec.Local.mkLocalExecHandle'.
mkLocalExecHandlePlaceholder :: LocalExecHandle
mkLocalExecHandlePlaceholder = LocalExecHandle
  { lehExecShell = \_ _ -> pure (Right "")
  , lehExecBin = \_ _ -> pure (Right "")
  }

-- ---------------------------------------------------------------------------
-- ExecBackend (added in 4a-T2)
-- ---------------------------------------------------------------------------

-- | The execution backend the dispatcher consumes. The 'EbLocal' arm is
-- the untrusted local executor (absent under @-f remote-only-untrusted@);
-- the 'EbRemote' arm is the SSH executor. 'selectExecBackend' (4a-T2)
-- returns this; 'selectUntrustedBackend' (4a-T2) returns ONLY the remote
-- arm (the spec's 'UntrustedExecBackend' is Ssh-only by construction).
--
-- No 'Eq' is derived: 'LocalExecHandle' carries IO actions which have no
-- 'Eq' instances. A custom 'Show' is provided (the 'LocalExecHandle' shows
-- as @<local>@, the 'SshConfig' via its own 'Show').
data ExecBackend
  = EbLocal LocalExecHandle
  | EbRemote SshConfig

instance Show ExecBackend where
  show (EbLocal _) = "EbLocal <local executor>"
  show (EbRemote c) = "EbRemote " <> show c

-- | Structural 'Eq'. Two 'EbLocal' handles are always 'equal' (they carry
-- opaque IO actions; no meaningful equality — used only by test `shouldBe`
-- on the 'Left' arms, where both sides are 'Left'). Two 'EbRemote' compare
-- by 'SshConfig'.
instance Eq ExecBackend where
  EbLocal _ == EbLocal _ = True
  EbRemote a == EbRemote b = a == b
  _ == _ = False