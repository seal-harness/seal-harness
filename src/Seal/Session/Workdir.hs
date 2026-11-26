{-# LANGUAGE OverloadedStrings #-}
-- | Per-session workdir lifecycle: creation, cleanup, and validation.
-- Each session gets a fresh working directory at
-- @~/.seal/cache/workdirs/<session-id>@. The untrusted opcodes' workspace
-- root is this directory, not the cwd.
module Seal.Session.Workdir
  ( WorkdirError (..)
  , ensureSessionWorkdir
  , cleanupSessionWorkdir
  , remoteSessionWorkdirPath
  , ensureRemoteSessionWorkdir
  , SessionExec (..)
  , mkSessionExec
  , failClosedSessionExec
  , isFailClosedSessionExec
  ) where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( canonicalizePath, createDirectoryIfMissing, doesDirectoryExist
  , removeDirectoryRecursive )
import System.FilePath (splitDirectories)

import Seal.Config.Paths (SealPaths (..), sessionWorkdir, workdirsRoot)
import Seal.Execution.Types (ResolvedTarget (..))
import Seal.Core.Types (SessionId, sessionIdText, isValidSessionId)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Clone (CloneDeps)
import Seal.Text.LineFile (maxScanBytes)
import Seal.Tools.Exec.HostKeyAdoption (HostKeyAdoption (..))
import Seal.Tools.Exec.Remote
  (RemoteRunner (..), runRemoteShell)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (SshConfig (..), getRemotePath, mkRemotePath)
import Seal.Tools.Exec.UIO.Internal (UIOEnv (..), mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO
  ( mkLocalUntrustedIO, mkRemoteUntrustedIO
  , mkRemoteUntrustedIOStub, mkRemoteUntrustedIOStubWithReason )
import Seal.Tools.Exec.WorkdirFs
  ( WorkdirFs, mkLocalWorkdirFs, mkRemoteWorkdirFs, mkWorkdirFsStub )

-- | The error type for workdir lifecycle operations.
data WorkdirError
  = WdMkdirFailed FilePath Text      -- ^ local mkdir failed (path, reason)
  | WdRemoteMkdirFailed Text          -- ^ remote SSH mkdir failed (reason)
  | WdInvalidSessionId Text           -- ^ SessionId failed validation
  | WdNotUnderWorkdirsRoot FilePath    -- ^ cleanup path escaped workdirsRoot
  deriving stock (Eq, Show)

-- | Create the per-session workdir at @<cache>/workdirs/<sid>@.
-- Idempotent: if the workdir already exists, it is reused (NOT cleared —
-- the operator may want to resume or inspect). Returns the workdir path
-- on success. Fails closed on permission errors (does NOT fall back to
-- the cwd — that would reintroduce the cross-session clobber bug).
ensureSessionWorkdir :: SealPaths -> SessionId -> IO (Either WorkdirError FilePath)
ensureSessionWorkdir paths sid = do
  let sidText = sessionIdText sid
  if not (isValidSessionId sidText)
    then pure (Left (WdInvalidSessionId sidText))
    else do
      let wdPath = sessionWorkdir paths sid
      eResult <- try (createDirectoryIfMissing True wdPath) :: IO (Either IOException ())
      pure $ case eResult of
        Left ioErr -> Left (WdMkdirFailed wdPath (T.pack (show ioErr)))
        Right _   -> Right wdPath

-- | Remove the per-session workdir. Asserts the path is under
-- 'workdirsRoot' (canonicalize + prefix check — defeats symlink swap).
-- Idempotent: no error if the workdir is already gone. Returns
-- 'Either WorkdirError ()' so cleanup failures are not silently
-- swallowed.
cleanupSessionWorkdir :: SealPaths -> SessionId -> IO (Either WorkdirError ())
cleanupSessionWorkdir paths sid = do
  let sidText = sessionIdText sid
  if not (isValidSessionId sidText)
    then pure (Left (WdInvalidSessionId sidText))
    else do
      let wdPath = sessionWorkdir paths sid
          wdRoot = workdirsRoot paths
      exists <- doesDirectoryExist wdPath
      if not exists
        then pure (Right ())  -- already gone — idempotent
        else do
          -- Defense-in-depth: canonicalize and verify the path is under
          -- workdirsRoot before rm -rf (defeats symlink swap).
          canonWd <- canonicalizePath wdPath
          canonRoot <- canonicalizePath wdRoot
          if not (splitDirectories canonRoot `isPrefixOf` splitDirectories canonWd)
            then pure (Left (WdNotUnderWorkdirsRoot canonWd))
            else do
              eResult <- try (removeDirectoryRecursive canonWd) :: IO (Either IOException ())
              pure $ case eResult of
                Left ioErr -> Left (WdMkdirFailed canonWd (T.pack (show ioErr)))
                Right _   -> Right ()

-- ---------------------------------------------------------------------------
-- Remote workdir (mode=remote)
-- ---------------------------------------------------------------------------

-- | Compute the remote per-session workdir path:
-- @<scWorkspace>/workdirs/<sid>@. Pure — no IO, no SSH.
remoteSessionWorkdirPath :: SshConfig -> SessionId -> Text
remoteSessionWorkdirPath sshCfg sid =
  getRemotePath (scWorkspace sshCfg) <> "/workdirs/" <> sessionIdText sid

-- | Create the per-session workdir on the REMOTE machine via SSH
-- @mkdir -p@. Validates the 'SessionId' before the SSH call. Idempotent
-- (mkdir -p is a no-op if the dir exists). Returns the remote workdir
-- path (as 'Text') on success. Fails closed on SSH errors (does NOT
-- fall back to the shared scWorkspace — that would reintroduce the
-- cross-session clobber bug).
ensureRemoteSessionWorkdir
  :: SshConfig -> RemoteRunner -> SessionId
  -> IO (Either WorkdirError Text)
ensureRemoteSessionWorkdir sshCfg runner sid = do
  let sidText = sessionIdText sid
  if not (isValidSessionId sidText)
    then pure (Left (WdInvalidSessionId sidText))
    else do
      let remoteWd = remoteSessionWorkdirPath sshCfg sid
          cmdText = "mkdir -p '" <> T.unpack remoteWd <> "'"
      case mkShellCommand (T.pack cmdText) of
        Left _err -> pure (Left (WdRemoteMkdirFailed "invalid mkdir command"))
        Right cmd -> do
          res <- runRemoteShell runner sshCfg cmd
          pure $ case res of
            Left e   -> Left (WdRemoteMkdirFailed (T.pack (show e)))
            Right _  -> Right remoteWd

-- ---------------------------------------------------------------------------
-- Unified session UntrustedIO construction (local + remote)
-- ---------------------------------------------------------------------------

-- | The fail-closed 'WorkspaceRoot' returned when workdir creation fails.
-- Matches the convention used at the wiring sites (e.g. @Cli.hs@).
failClosedRoot :: WorkspaceRoot
failClosedRoot = WorkspaceRoot "/nonexistent-workdir-fail-closed"

-- | The per-session execution bundle: the 'UIOEnv' (carrying 'UntrustedIO'
-- + 'CloneDeps'), the 'WorkdirFs' for discovery, and the shared
-- 'WorkspaceRoot' used by UIO + WorkdirFs + the ISA registry. Constructed
-- by 'mkSessionExec' from a 'ResolvedTarget'; the single 'RemoteRunner'
-- is shared between 'seUIOEnv' (UIO's 'UntrustedIO') and 'seWorkdirFs'
-- (via 'runUIOWithEnv') — one SSH connection, not two. On ANY workdir-
-- creation failure, ALL three fields are stubs (fail-closed) — never a
-- mix of real + stub.
data SessionExec = SessionExec
  { seUIOEnv        :: UIOEnv
  , seWorkdirFs     :: WorkdirFs
  , seWorkspaceRoot :: WorkspaceRoot
  }

-- | Construct the per-session 'SessionExec' from an already-resolved target.
-- Takes 'ResolvedTarget' and not 'SecurityConfig': naming a type in a
-- signature /is/ importing it, and the whole point of WU-5 is that exactly one
-- place decides where code runs. Additionally
-- builds the 'WorkdirFs' and the shared 'WorkspaceRoot'. The
-- 'RemoteRunner' is passed explicitly so tests can inject
-- 'mkFakeRemoteRunnerRecording' (no real SSH); production wiring passes
-- 'mkRealRemoteRunner'. The single runner is shared between 'seUIOEnv'
-- and 'seWorkdirFs'.
--
-- When @mAdoption = Just hka@ and the remote workdir bootstrap fails with
-- 'ExecHostKeyUnknown' (the host key is not in @known_hosts@), the harness
-- attempts TOFU adoption: probes the host via @ssh-keyscan@, asks the human
-- for confirmation, and appends the key on approval. On approval, the
-- workdir bootstrap is retried. On rejection or when @mAdoption = Nothing@,
-- the session fail-closes with a descriptive error (not the content-free
-- 'ExecNotImplemented').
--
-- On ANY workdir-creation failure, returns a 'SessionExec' with both
-- handles as stubs and 'seWorkspaceRoot' as 'failClosedRoot' — never mixed.
mkSessionExec
  :: SealPaths -> ResolvedTarget -> SessionId
  -> CloneDeps -> RemoteRunner -> Maybe HostKeyAdoption
  -> IO SessionExec
mkSessionExec paths target sid cloneDeps runner mAdoption =
  case target of
    WhereLocal -> do
      eWd <- ensureSessionWorkdir paths sid
      case eWd of
        Right wd ->
          let wsRoot  = WorkspaceRoot wd
              uio     = mkLocalUntrustedIO wsRoot
              uioEnv  = mkTestUIOEnv uio cloneDeps
              wfs     = mkLocalWorkdirFs wsRoot maxScanBytes
          in pure SessionExec
               { seUIOEnv        = uioEnv
               , seWorkdirFs     = wfs
               , seWorkspaceRoot = wsRoot
               }
        Left err -> pure (failClosedSessionExecWithReason cloneDeps
                            ("local workdir creation failed: " <> T.pack (show err)))

    WhereSsh _ sshCfg -> do
      -- No "remote but unconfigured" arm is reachable any more: 'WhereSsh' can
      -- only be constructed from a machine that already carries every field,
      -- so the old fail-closed branch has no input.
      eRemoteWd <- ensureRemoteSessionWorkdir sshCfg runner sid
      case eRemoteWd of
        Left (WdRemoteMkdirFailed errText)
          | "ExecHostKeyUnknown" `T.isInfixOf` errText
            -> case mAdoption of
              Nothing ->
                pure (failClosedSessionExecWithReason cloneDeps
                       ("remote host key not in known_hosts (TOFU adoption not available). "
                        <> "Host: " <> T.pack (show (scHost sshCfg))
                        <> ". Add the key manually with: ssh-keyscan -H "
                        <> hostText sshCfg
                        <> " >> " <> T.pack (scKnownHosts sshCfg)))
              Just hka -> do
                eAdopt <- hkaAdopt hka sshCfg
                case eAdopt of
                  Left adoptErr -> pure (failClosedSessionExecWithReason cloneDeps
                                          ("host-key adoption failed: " <> adoptErr))
                  Right _ -> do
                    -- Retry the workdir bootstrap after adoption.
                    eRetry <- ensureRemoteSessionWorkdir sshCfg runner sid
                    case eRetry of
                      Left retryErr -> pure (failClosedSessionExecWithReason cloneDeps
                                              ("remote workdir creation failed after host-key adoption: "
                                               <> T.pack (show retryErr)))
                      Right remoteWdText -> buildRemoteExec sshCfg remoteWdText cloneDeps runner
        Left err -> pure (failClosedSessionExecWithReason cloneDeps
                           ("remote workdir creation failed: " <> T.pack (show err)))
        Right remoteWdText -> buildRemoteExec sshCfg remoteWdText cloneDeps runner

  where
    hostText cfg = case scHost cfg of
      h -> T.pack (show h)

-- | Build the 'SessionExec' for a successful remote workdir bootstrap.
buildRemoteExec :: SshConfig -> Text -> CloneDeps -> RemoteRunner
                -> IO SessionExec
buildRemoteExec sshCfg remoteWdText cloneDeps runner =
  case mkRemotePath remoteWdText of
    Left err -> pure (failClosedSessionExecWithReason cloneDeps
                       ("invalid remote workdir path: " <> err))
    Right remotePath ->
      let sshCfg' = sshCfg { scWorkspace = remotePath }
          wsRoot  = WorkspaceRoot (T.unpack (getRemotePath remotePath))
          uio     = mkRemoteUntrustedIO sshCfg' runner
          uioEnv  = mkTestUIOEnv uio cloneDeps
          wfs     = mkRemoteWorkdirFs uioEnv sshCfg' wsRoot maxScanBytes
      in pure SessionExec
           { seUIOEnv        = uioEnv
           , seWorkdirFs     = wfs
           , seWorkspaceRoot = wsRoot
           }

-- | The fail-closed 'SessionExec': both handles are stubs, the root is
-- 'failClosedRoot'. Used on ANY workdir-creation failure. Returns
-- 'ExecNotImplemented' (no reason) — use 'failClosedSessionExecWithReason'
-- when a descriptive error is available.
failClosedSessionExec :: CloneDeps -> SessionExec
failClosedSessionExec cloneDeps = SessionExec
  { seUIOEnv        = mkTestUIOEnv mkRemoteUntrustedIOStub cloneDeps
  , seWorkdirFs     = mkWorkdirFsStub
  , seWorkspaceRoot = failClosedRoot
  }

-- | Like 'failClosedSessionExec' but the 'UntrustedIO' stub carries a
-- descriptive reason (via 'mkRemoteUntrustedIOStubWithReason'). The model
-- sees *why* every untrusted opcode is failing, not just
-- 'ExecNotImplemented'.
failClosedSessionExecWithReason :: CloneDeps -> Text -> SessionExec
failClosedSessionExecWithReason cloneDeps reason = SessionExec
  { seUIOEnv        = mkTestUIOEnv (mkRemoteUntrustedIOStubWithReason reason) cloneDeps
  , seWorkdirFs     = mkWorkdirFsStub
  , seWorkspaceRoot = failClosedRoot
  }

-- | Did this exec fail closed? (The workdir bootstrap failed and every
-- handle is a stub.) The exec cache uses this to avoid memoizing failures.
isFailClosedSessionExec :: SessionExec -> Bool
isFailClosedSessionExec e = seWorkspaceRoot e == failClosedRoot

