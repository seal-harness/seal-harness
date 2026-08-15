{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | The restricted monad for untrusted opcode execution. Carries an
-- 'UntrustedIO' handle (+ the Git 'CloneDeps' surface) internally; the only
-- IO an opcode can perform is the lifted 'UntrustedIO'/'CloneDeps' surface.
-- NO 'MonadIO' — a bare 'liftIO'\/'IO' action in an opcode body typed
-- @UIO OpResult@ won't compile. Constructed ONLY by 'mkLocalUIO'/
-- 'mkRemoteUIO'\/'mkUIOStub'; the constructor + 'unUIO' + 'runUIO' +
-- 'UIOEnv' are unexported. 'runUIOWithEnv' is exported to the dispatcher +
-- 'WorkdirFs' (NOT to opcode modules — W6 grep check).
--
-- This turns the \"don't import 'System.Directory'\/don't shell out in
-- opcodes\" convention into a **type-level guarantee**, categorically
-- eliminating future local\/remote parity gaps: there is one construction
-- path per mode, and the only IO an untrusted opcode can perform is the
-- 'UIO'-lifted 'UntrustedIO' (+ 'CloneDeps') surface.
-- | Internal module: exports the 'UIO' constructor, 'unUIO', 'UIOEnv', and
-- all internals. Imported ONLY by 'Seal.Tools.Exec.UIO' (the restricted
-- re-export) and 'Seal.Tools.Exec.UIOGit' (the Git 'CloneDeps' surface).
-- NEVER imported by opcode modules — the W6 grep check asserts no
-- @Seal.Tools.Exec.UIO.Internal@ reference in @src\/Seal\/ISA\/Ops\/@.
module Seal.Tools.Exec.UIO.Internal
  ( UIO (..)
  , UIOEnv (..)
  , mkLocalUIO
  , mkRemoteUIO
  , mkUIOStub
  , runUIOWithEnv
  , mkTestUIOEnv
  , uioRead
  , uioWrite
  , uioPatch
  , uioShellExec
  , uioBinExec
  , uioProcessList
  , uioProcessKill
  , uioSearchFiles
  , uioShellExecEnv
  , uioShellExecGitEnv
  , uioBinExecEnv
  , WriteMode (..)
  , UntrustedErr (..)
  , renderUntrustedErr
  , mkLocalUntrustedIO
  , mkRemoteUntrustedIO
  , mkRemoteUntrustedIOStub
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Data.ByteString (ByteString)
import Data.Text (Text)

import Seal.Security.Path (WorkspaceRoot)
import Seal.SourceControl.Clone (CloneDeps)
import Seal.Text.LineFile (LineWindow)
import Seal.Tools.Args (BinArg, BinName, SearchPattern, ShellCommand)
import Seal.Tools.Exec.Remote (RemoteRunner)
import Seal.Tools.Exec.Types (RemotePath, SshConfig)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO  -- the type only; record fields accessed via UIORec.*
  , WriteMode (..)
  , UntrustedErr (..)
  , renderUntrustedErr
  , mkLocalUntrustedIO
  , mkRemoteUntrustedIO
  , mkRemoteUntrustedIOStub
  )
import Seal.Tools.Exec.UntrustedIO qualified as UIORec
  ( uioReadFile, uioWriteFile, uioPatchFile, uioShellExec, uioBinExec
  , uioProcessList, uioProcessKill, uioSearchFiles
  , uioShellExecEnv, uioShellExecGitEnv, uioBinExecEnv )

-- | The restricted monad. Exposes 'Functor', 'Applicative', 'Monad' — and
-- deliberately **no** 'MonadIO', no 'MonadReader', no 'MonadThrow', no
-- 'Katip'. An opcode body typed @UIO OpResult@ literally cannot call
-- 'liftIO', 'ask', 'throwM', or import 'System.Directory' (compile error).
-- The only IO is the module-level 'uio*' functions below.
newtype UIO a = UIO { unUIO :: ReaderT UIOEnv IO a }
  deriving newtype (Functor, Applicative, Monad)
  -- deliberately NOT: MonadIO, MonadReader, MonadThrow

-- | The environment carried by 'UIO'. Holds the 'UntrustedIO' handle + the
-- Git 'CloneDeps' surface. NOT exported (opaque — no caller can forge
-- one); only 'mkLocalUIO'\/'mkRemoteUIO'\/'mkUIOStub'\/'mkTestUIOEnv'
-- construct it.
data UIOEnv = UIOEnv
  { uieUntrustedIO :: !UntrustedIO
  , uieCloneDeps   :: !CloneDeps
  }

-- | Run a 'UIO' action with a pre-built 'UIOEnv'. Exported to the
-- dispatcher + 'WorkdirFs' (NOT to opcode modules — W6 grep check). The
-- 'UIOEnv' is opaque; callers obtain one from 'mkSessionExec'
-- ('seUIOEnv') or 'mkTestUIOEnv'.
runUIOWithEnv :: UIOEnv -> UIO a -> IO a
runUIOWithEnv env (UIO action) = runReaderT action env

-- | Build a 'UIOEnv' from an 'UntrustedIO' + 'CloneDeps'. Exported with
-- the 'Test' prefix as the naming gate (matching
-- 'mkFakeRemoteRunnerRecording' — the @Fake@\/@Test@ prefix is the
-- convention; no @#ifdef TESTING@). Used by the 'uoRunLegacy' back-compat
-- wrapper (W-A3) + tests (Git specs seed a stub 'CloneDeps' into the
-- 'UIOEnv' via this helper).
mkTestUIOEnv :: UntrustedIO -> CloneDeps -> UIOEnv
mkTestUIOEnv = UIOEnv

-- ---------------------------------------------------------------------------
-- Smart constructors (the only way to obtain a 'UIO' execution context)
-- ---------------------------------------------------------------------------

-- | @mode=local@: the workdir is a local path; 'UntrustedIO' is local.
-- Builds a local 'UntrustedIO' + a local 'CloneDeps' internally, runs the
-- action via 'runUIOWithEnv'.
mkLocalUIO :: WorkspaceRoot -> CloneDeps -> UIO a -> IO a
mkLocalUIO wsRoot cloneDeps action =
  let uio = mkLocalUntrustedIO wsRoot
      env = UIOEnv uio cloneDeps
  in runUIOWithEnv env action

-- | @mode=remote@: the workdir is a remote workspace path; 'UntrustedIO'
-- is remote (SSH via the 'RemoteRunner'). The runner is shared with
-- 'WorkdirFs' (§3.12, via 'runUIOWithEnv').
mkRemoteUIO :: SshConfig -> RemoteRunner -> WorkspaceRoot -> CloneDeps
            -> UIO a -> IO a
mkRemoteUIO sshCfg runner _wsRoot cloneDeps action =
  let uio = mkRemoteUntrustedIO sshCfg runner
      env = UIOEnv uio cloneDeps
  in runUIOWithEnv env action

-- | Fail-closed: every operation returns 'Left'\/stub. For misconfigured
-- or unreachable remotes; mirrors 'mkRemoteUntrustedIOStub'.
mkUIOStub :: CloneDeps -> UIO a -> IO a
mkUIOStub cloneDeps action =
  let env = UIOEnv mkRemoteUntrustedIOStub cloneDeps
  in runUIOWithEnv env action

-- ---------------------------------------------------------------------------
-- Lifted 'UntrustedIO' operations (module-level 'UIO'-typed functions)
-- ---------------------------------------------------------------------------

-- | Read a workspace-relative file as a 'LineWindow' (paged, bounded).
uioRead :: RemotePath -> Int -> UIO (Either UntrustedErr LineWindow)
uioRead rp scanBytes = UIO $ do
  env <- ask
  liftIO' (UIORec.uioReadFile (uieUntrustedIO env) rp scanBytes)

-- | Write or append content to a workspace-relative file (bounded).
uioWrite :: RemotePath -> Text -> WriteMode -> Int
         -> UIO (Either UntrustedErr Int)
uioWrite rp content mode ceiling' = UIO $ do
  env <- ask
  liftIO' (UIORec.uioWriteFile (uieUntrustedIO env) rp content mode ceiling')

-- | Apply a unified diff to a workspace-relative file (atomic write).
uioPatch :: RemotePath -> Text -> UIO (Either UntrustedErr ())
uioPatch rp patch = UIO $ do
  env <- ask
  liftIO' (UIORec.uioPatchFile (uieUntrustedIO env) rp patch)

-- | Run a validated shell command (single arg to @/bin/sh -c@), with an
-- optional SafePath-confined cwd.
uioShellExec :: ShellCommand -> Maybe RemotePath
             -> UIO (Either UntrustedErr Text)
uioShellExec cmd mCwd = UIO $ do
  env <- ask
  liftIO' (UIORec.uioShellExec (uieUntrustedIO env) cmd mCwd)

-- | Run a named binary (no shell, fixed argv) with an optional cwd.
uioBinExec :: BinName -> [BinArg] -> Maybe RemotePath
           -> UIO (Either UntrustedErr Text)
uioBinExec bin bargs mCwd = UIO $ do
  env <- ask
  liftIO' (UIORec.uioBinExec (uieUntrustedIO env) bin bargs mCwd)

-- | List processes on the untrusted plane (bounded output).
uioProcessList :: UIO (Either UntrustedErr Text)
uioProcessList = UIO $ do
  env <- ask
  liftIO' (UIORec.uioProcessList (uieUntrustedIO env))

-- | Kill a process by PID (validated positive integer) on the untrusted plane.
uioProcessKill :: Int -> UIO (Either UntrustedErr ())
uioProcessKill pid = UIO $ do
  env <- ask
  liftIO' (UIORec.uioProcessKill (uieUntrustedIO env) pid)

-- | Search workspace files for a pattern (@rg -n -- <pattern> <path>@).
uioSearchFiles :: SearchPattern -> Maybe RemotePath -> Int
               -> UIO (Either UntrustedErr Text)
uioSearchFiles pat mPath limit = UIO $ do
  env <- ask
  liftIO' (UIORec.uioSearchFiles (uieUntrustedIO env) pat mPath limit)

-- | Like 'uioShellExec' but with env overrides MERGED over the inherited
-- environment (local arm) / @env VAR=val@-prefixed (remote arm). Used by
-- the git-credential opcodes.
uioShellExecEnv :: [(String, String)] -> ShellCommand -> Maybe RemotePath
                -> UIO (Either UntrustedErr Text)
uioShellExecEnv extras cmd mCwd = UIO $ do
  env <- ask
  liftIO' (UIORec.uioShellExecEnv (uieUntrustedIO env) extras cmd mCwd)

-- | Like 'uioShellExecEnv' but with an optional @known_hosts@ content
-- payload for the REMOTE deploy-key path. Used by 'cloneWithCredential'
-- + 'runGitCommand' for deploy-key ops.
uioShellExecGitEnv :: [(String, String)] -> Maybe ByteString -> ShellCommand
                   -> Maybe RemotePath -> UIO (Either UntrustedErr Text)
uioShellExecGitEnv extras mKnownHosts cmd mCwd = UIO $ do
  env <- ask
  liftIO' (UIORec.uioShellExecGitEnv (uieUntrustedIO env) extras mKnownHosts cmd mCwd)

-- | Like 'uioBinExec' but with env overrides + an optional cwd. Used by
-- the PAT clone path.
uioBinExecEnv :: [(String, String)] -> BinName -> [BinArg] -> Maybe RemotePath
              -> UIO (Either UntrustedErr Text)
uioBinExecEnv extras bin bargs mCwd = UIO $ do
  env <- ask
  liftIO' (UIORec.uioBinExecEnv (uieUntrustedIO env) extras bin bargs mCwd)

-- | Internal: lift an 'IO' action into the 'ReaderT' carrier. This is the
-- ONE place 'liftIO' is used in this module — it is NOT exposed to opcode
-- modules (the 'UIO' newtype hides 'ReaderT' and its 'MonadIO' instance).
-- Opcode bodies call the 'uio*' functions above, never 'liftIO' directly.
liftIO' :: IO a -> ReaderT UIOEnv IO a
liftIO' = liftIO