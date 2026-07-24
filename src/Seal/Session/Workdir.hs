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
  , mkSessionUntrustedIO
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
import Seal.Config.Security (SecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Tools.Exec.Untrusted (UntrustedExecConfig (..))
import Seal.Core.Types (SessionId, sessionIdText, isValidSessionId)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Exec.Remote (RemoteRunner (..), runRemoteShell, mkRealRemoteRunner)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (SshConfig (..), getRemotePath, mkRemotePath)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO, mkLocalUntrustedIO, mkRemoteUntrustedIO, mkRemoteUntrustedIOStub )

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

-- | Construct the per-session 'UntrustedIO' from the 'SecurityConfig':
--
--   * @mode=local@ (or absent): create the local workdir via
--     'ensureSessionWorkdir' and construct 'mkLocalUntrustedIO' with it
--     as the 'WorkspaceRoot'.
--
--   * @mode=remote@ + remote configured: create the remote workdir via
--     'ensureRemoteSessionWorkdir' (SSH @mkdir -p@), clone the
--     'SshConfig' with @scWorkspace@ = the per-session remote workdir,
--     and construct 'mkRemoteUntrustedIO' with the cloned config.
--
--   * @mode=remote@ + remote absent/incomplete: return the fail-closed
--     stub ('mkRemoteUntrustedIOStub').
--
-- This is the single entry point the wiring sites call — it handles
-- both local and remote, creates the workdir, and returns the handle.
-- On workdir creation failure, returns the fail-closed stub (the session
-- should surface the error and NOT proceed — the wiring site checks the
-- 'WorkdirError' via 'ensureSessionWorkdir' separately if it needs to
-- surface the error to the user).
mkSessionUntrustedIO
  :: SealPaths -> SecurityConfig -> SessionId -> IO UntrustedIO
mkSessionUntrustedIO paths secCfg sid =
  case untrustedExecConfigFromSecurity secCfg of
    -- mode=local (or absent section) → local workdir
    Nothing -> do
      eWd <- ensureSessionWorkdir paths sid
      case eWd of
        Right wd -> pure (mkLocalUntrustedIO (WorkspaceRoot wd))
        Left _err -> pure mkRemoteUntrustedIOStub  -- fail-closed

    -- mode=remote
    Just uec ->
      case uecRemote uec of
        -- remote not configured → fail-closed
        Nothing -> pure mkRemoteUntrustedIOStub

        -- remote configured → create remote workdir + clone SshConfig
        Just sshCfg -> do
          eRemoteWd <- ensureRemoteSessionWorkdir sshCfg mkRealRemoteRunner sid
          case eRemoteWd of
            Left _err -> pure mkRemoteUntrustedIOStub  -- fail-closed
            Right remoteWdText ->
              case mkRemotePath remoteWdText of
                Left _err -> pure mkRemoteUntrustedIOStub
                Right remotePath ->
                  let sshCfg' = sshCfg { scWorkspace = remotePath }
                  in pure (mkRemoteUntrustedIO sshCfg' mkRealRemoteRunner)