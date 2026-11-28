{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Subprocess primitives shared by __both__ execution arms.
--
-- This module exists because of the hardened build. @-f remote-only-untrusted@
-- removes 'Seal.Tools.Exec.Local' from the library's @exposed-modules@, so
-- anything that imports that module disappears from the hardened artifact — and
-- the whole library fails to link. Three modules imported it for these
-- primitives alone:
--
--   * 'Seal.Tools.Exec.Remote' — @withManagedProcess@ / @readBounded@ to drive
--     the local @ssh@ child process.
--   * 'Seal.Tools.Exec.UntrustedIO' — the same, for the remote arm's local
--     subprocesses.
--   * 'Seal.Session.AgentMetaCache' — @withManagedProcess@ for @rsync@.
--
-- None of those is local execution. @ssh@ and @rsync@ are ordinary child
-- processes on the control plane, and process-group killing and bounded reads
-- are what makes cancelling them safe. So the primitives live here instead,
-- and 'Seal.Tools.Exec.Local' re-exports them for its existing callers. What
-- stays in that module is the thing the flag actually means to remove: the
-- local executor handle, 'mkLocalExecHandle'.
--
-- __The invariant, asserted by @HardenedBuildSpec@:__ this module must not
-- import 'Seal.Tools.Exec.Local'. Adding such an import puts the link failure
-- straight back.
module Seal.Tools.Exec.Proc
  ( withManagedProcess
  , killProcessGroup
  , readBounded
  , readBoundedBytes
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, catch, try)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.IO (Handle, hClose, hIsEOF)
import System.Process
  ( CreateProcess (..), ProcessHandle, createProcess, getProcessExitCode )
import System.Process.Internals (ProcessHandle__ (..), withProcessHandle)
import qualified System.Posix.Signals as Posix
import qualified System.Posix.Types as Posix

-- | The default SIGTERM→SIGKILL grace period (5s). Matches
-- 'Seal.Tools.Timeout.ttcKillGraceMicros'.
defaultKillGraceMicros :: Int
defaultKillGraceMicros = 5_000_000

-- | Spawn a process in its own process group (@create_group = True@) and run
-- an action with the process handle + stdin/stdout/stderr handles. On cleanup
-- (normal exit OR async-exception cancellation), kill the whole process
-- group: SIGTERM → grace period → SIGKILL. Then close handles and reap the
-- zombie with a BOUNDED wait (non-blocking 'getProcessExitCode' poll with a
-- 1s deadline) so cleanup never hangs.
--
-- When the dispatch wrapper
-- ('Seal.Tools.Exec.Timeout.runWithTimeoutAbortRetry') cancels the Haskell
-- worker thread via 'async'\'s 'cancel', the bracket cleanup runs (bracket
-- is mask-on-cleanup) and kills the OS process group — no orphans. This is
-- the key mechanism: killing the Haskell thread cascades to killing the OS
-- process group.
--
-- The stdin handle is 'Maybe Handle' — 'Nothing' if @std_in = NoStream@,
-- 'Just' if @std_in = CreatePipe@. The caller is responsible for writing
-- the payload and closing the stdin handle (so the child sees EOF).
withManagedProcess
  :: CreateProcess
  -> (ProcessHandle -> Maybe Handle -> Handle -> Handle -> IO a)
  -> IO a
withManagedProcess cp action = bracket create cleanup runAction
  where
    -- The cp MUST have create_group=True (we re-set it here too for safety).
    cp' = cp { create_group = True }
    create = do
      (mIn, mOut, mErr, ph) <- createProcess cp'
      pidRef <- newIORef Nothing
      -- Capture the PID while the process is open.
      withProcessHandle ph $ \case
        OpenHandle pid -> writeIORef pidRef (Just (fromIntegral pid :: Int))
        _              -> pure ()
      mPid <- readIORef pidRef
      case (mOut, mErr) of
        (Just hOut, Just hErr) -> pure (ph, mIn, hOut, hErr, mPid)
        _                      -> error "withManagedProcess: pipe creation failed (unreachable)"
    cleanup (ph, mIn, hOut, hErr, mPid) = do
      -- Fast path: if the child ALREADY exited (the common success path),
      -- there is nothing to kill. Killing here would (a) tax every
      -- successful exec with the full SIGTERM→SIGKILL grace wait and
      -- (b) signal the backgrounded @ssh@ ControlMaster that shares the
      -- child's process group on the remote arm — destroying connection
      -- multiplexing (every subsequent remote op would pay a fresh
      -- TCP+key-exchange+auth handshake).
      mec <- getProcessExitCode ph
      case mec of
        Just _  -> pure ()
        Nothing -> case mPid of
          Nothing   -> pure ()
          Just pid  -> killProcessGroup ph pid defaultKillGraceMicros
      -- Close the stdin (if open), stdout, stderr handles.
      case mIn of
        Nothing -> pure ()
        Just hIn -> hClose hIn `catch` \(_ :: IOException) -> pure ()
      hClose hOut `catch` \(_ :: IOException) -> pure ()
      hClose hErr `catch` \(_ :: IOException) -> pure ()
      -- Reap the zombie with a BOUNDED wait (non-blocking poll, 1s deadline).
      -- If the child is stuck in an uninterruptible state, don't hang
      -- cleanup forever — the OS init process reaps it eventually.
      reapBounded ph
    -- Run the action with (ph, mIn, hOut, hErr).
    runAction (ph, mIn, hOut, hErr, _) = action ph mIn hOut hErr

-- | Reap a zombie with a bounded wait. Polls 'getProcessExitCode' every
-- 10ms for up to 1s; if the child hasn't exited, gives up (the OS init
-- process reaps it eventually). Never hangs.
reapBounded :: ProcessHandle -> IO ()
reapBounded ph = go (100 :: Int)  -- 100 polls × 10ms = 1s deadline
  where
    go :: Int -> IO ()
    go 0 = pure ()  -- give up; zombie reaped by init eventually
    go n = do
      mec <- getProcessExitCode ph
      case mec of
        Just _  -> pure ()  -- reaped
        Nothing -> do
          threadDelay 10_000  -- 10ms
          go (n - 1)

-- | Kill a process group: SIGTERM → bounded grace → SIGKILL.
-- POSIX: 'signalProcessGroup' sends a signal to every process in the group.
-- The @graceMicros@ is the SIGTERM→SIGKILL grace period. Because the child
-- was spawned with @create_group = True@, its PGID equals its PID.
--
-- The grace period POLLS for the child's exit (every 10ms) instead of
-- sleeping the full duration: a child that dies on SIGTERM — the normal
-- case — lets cleanup return within ~10ms, and only a stubborn child pays
-- the full grace before SIGKILL. The trailing SIGKILL is unconditional
-- (idempotent on already-dead processes) so no group member can outlive
-- the kill on the cancel path.
killProcessGroup :: ProcessHandle -> Int -> Int -> IO ()
killProcessGroup ph pid graceMicros = do
  -- The child is in its own group (create_group=True), so its PGID == its PID.
  -- 'signalProcessGroup' takes a ProcessGroupID; a CPid and ProcessGroupID
  -- are both newtype'd Int, so we coerce via fromIntegral.
  let pgid = fromIntegral pid :: Posix.ProcessGroupID
  -- SIGTERM the whole group.
  _ <- try @IOException (Posix.signalProcessGroup Posix.sigTERM pgid)
  -- Poll for exit within the grace budget (no blind sleep).
  _ <- pollExitBounded ph graceMicros
  -- SIGKILL the whole group (idempotent on already-dead processes).
  _ <- try @IOException (Posix.signalProcessGroup Posix.sigKILL pgid)
  pure ()

-- | Poll 'getProcessExitCode' every 10ms up to @budgetMicros@. Returns
-- 'True' if the child exited within budget.
pollExitBounded :: ProcessHandle -> Int -> IO Bool
pollExitBounded ph budgetMicros = go (budgetMicros `div` 10_000)
  where
    go :: Int -> IO Bool
    go 0 = pure False  -- out of budget; caller escalates to SIGKILL
    go n = do
      mec <- getProcessExitCode ph
      case mec of
        Just _  -> pure True
        Nothing -> do
          threadDelay 10_000
          go (n - 1)

-- | Read at most N bytes from a handle, returning the content. If the
-- stream has more than N bytes remaining, a truncation marker is appended:
-- @[output truncated at N bytes — redirect to a file and FILE_READ with
-- pagination for full output]@. The marker hints at the recovery workflow
-- so the model learns the pattern.
--
-- After reading the bounded amount (and detecting non-EOF), the handle is
-- CLOSED — this prevents a deadlock where the child blocks on a full pipe
-- buffer while 'waitForProcess' waits for the child. Closing the handle
-- causes the child's writes to fail (SIGPIPE/EPIPE), the child exits, and
-- 'waitForProcess' returns. The truncation marker is the signal that output
-- was lost.
readBounded :: Handle -> Int -> IO Text
readBounded h maxBytes = do
  bs <- BS.hGet h maxBytes
  eof <- hIsEOF h
  let content = TE.decodeUtf8 bs
  if eof
    then pure content
    else do
      -- There's more output. Close the handle so the child's writes fail
      -- (SIGPIPE), the child exits, and waitForProcess doesn't deadlock.
      hClose h
      pure (content <> "\n[output truncated at " <> T.pack (show maxBytes)
                     <> " bytes — redirect to a file and FILE_READ with pagination for full output]")

-- | Like 'readBounded' but returns raw 'ByteString' (no UTF-8 decode).
-- Used by the file explorer's download endpoint via 'runRemoteBytes' so
-- binary files are served without UTF-8 corruption. Truncation is
-- indicated by appending a marker (same as 'readBounded') — callers
-- that need to detect truncation should check the byte count.
readBoundedBytes :: Handle -> Int -> IO (BS.ByteString, Bool)
readBoundedBytes h maxBytes = do
  bs <- BS.hGet h maxBytes
  eof <- hIsEOF h
  if eof
    then pure (bs, False)
    else do
      hClose h
      pure (BS.take maxBytes bs, True)
