-- | The Git-specific 'UIO' operations — the 'CloneDeps' surface lifted into
-- the 'UIO' monad. This is a SEPARATE module from 'Seal.Tools.Exec.UIO'
-- (which holds the general 'UntrustedIO' 'uio*' surface) because the
-- 'CloneDeps' capability must be lexically scoped to Git opcodes ONLY
-- (restoring the round-3 property that non-Git opcodes cannot name these
-- functions). A non-Git opcode that wants 'uioCdRepoRegList' must add an
-- import of this module — caught at review + enforced by the W-A3 CI grep
-- guard (asserts 'Seal.Tools.Exec.UIOGit' is referenced only from
-- @src\/Seal\/ISA\/Ops\/Git.hs@ + this definition site).
--
-- The 'uioCd*' functions take the 'CloneDeps' from 'UIOEnv' via the internal
-- 'ReaderT' (no 'MonadIO' — the 'UIO' newtype hides it). Opcode bodies call
-- these directly: @uioCdRepoRegList@, @uioResolveClone@, @uioWithClone@ —
-- never @liftIO (rrhList (cdRepoReg deps))@.
module Seal.Tools.Exec.UIOGit
  ( uioCdRepoRegList
  , uioResolveClone
  , uioWithClone
  , uioCdCloneDeps
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks, runReaderT)
import Data.Text (Text)

import Seal.SourceControl.Clone
  ( CloneDeps (..), CloneEnv, CloneError, CloneTarget, resolveCloneTarget
  , withCloneTarget )
import Seal.SourceControl.Repo (SourceRepo)
import Seal.SourceControl.Registry (RepoRegistryHandle (rrhList))
import Seal.Tools.Exec.UIO.Internal (UIO (..), UIOEnv (..))

-- | List the repo registry entries (the @cdRepoReg@ surface). Returns the
-- 'Either' 'Text' error from a corrupt @repos.toml@ (surfaced to the opcode
-- as-is).
uioCdRepoRegList :: UIO (Either Text [SourceRepo])
uioCdRepoRegList = UIO $ do
  env <- ask
  liftIO (rrhList (cdRepoReg (uieCloneDeps env)))

-- | Resolve a 'SourceRepo' to a 'CloneTarget' (the credential-resolution
-- surface — fetches the secret from the vault, runs the per-op ssh-agent
-- lifecycle for deploy keys). Returns 'Either' 'CloneError' so the opcode
-- can surface a structured error (vault-locked vs. no-credential vs.
-- agent-failed).
uioResolveClone :: SourceRepo -> UIO (Either CloneError CloneTarget)
uioResolveClone repo = UIO $ do
  env <- ask
  liftIO (resolveCloneTarget (uieCloneDeps env) repo)

-- | Scope the authenticated 'CloneEnv' to a continuation (CPS — mirrors
-- 'withCloneTarget' / 'Seal.Security.Secrets.withApiKey'). The cleanup
-- ALWAYS runs, even if the continuation throws — bracket semantics. The
-- 'UIOEnv' is threaded from the outer context, so 'CloneDeps' +
-- 'UntrustedIO' are preserved across the CPS boundary.
uioWithClone :: CloneTarget -> (CloneEnv -> UIO a) -> UIO a
uioWithClone target k = UIO $ do
  env <- ask
  let runInner cloneEnv = runReaderT (unUIO (k cloneEnv)) env
  liftIO (withCloneTarget target runInner)

-- | Read the 'CloneDeps' from the 'UIOEnv' (for Git opcodes that need
-- direct access to a field not covered by the 'uioCd*' functions above).
uioCdCloneDeps :: UIO CloneDeps
uioCdCloneDeps = UIO $ asks uieCloneDeps