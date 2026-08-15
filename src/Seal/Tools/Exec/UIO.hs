-- | The restricted monad for untrusted opcode execution. Carries an
-- 'UntrustedIO' handle (+ the Git 'CloneDeps' surface) internally; the only
-- IO an opcode can perform is the lifted 'UntrustedIO'/'CloneDeps' surface.
-- NO 'MonadIO' — a bare 'liftIO'\/'IO' action in an opcode body typed
-- @UIO OpResult@ won't compile. Constructed ONLY by 'mkLocalUIO'/
-- 'mkRemoteUIO'\/'mkUIOStub'; the constructor + 'unUIO' + 'UIOEnv' are NOT
-- exported from this module (they live in 'Seal.Tools.Exec.UIO.Internal',
-- imported only by this module + 'Seal.Tools.Exec.UIOGit'). 'runUIOWithEnv'
-- is exported to the dispatcher + 'WorkdirFs' (NOT to opcode modules — W6
-- grep check).
--
-- This turns the \"don't import 'System.Directory'\/don't shell out in
-- opcodes\" convention into a **type-level guarantee**, categorically
-- eliminating future local\/remote parity gaps: there is one construction
-- path per mode, and the only IO an untrusted opcode can perform is the
-- 'UIO'-lifted 'UntrustedIO' (+ 'CloneDeps') surface.
module Seal.Tools.Exec.UIO
  ( UIO
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
  , uioLiftIO
  , uioUntrustedIO
  , WriteMode (..)
  , UntrustedErr (..)
  , renderUntrustedErr
  ) where

import Seal.Tools.Exec.UIO.Internal