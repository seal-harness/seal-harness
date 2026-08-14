{-# LANGUAGE OverloadedStrings #-}
-- | The untrusted LOCAL executor (the 'EbLocal' arm of 'ExecBackend').
-- Behind the 'BackendExec' seam, the Untrusted opcode implementations
-- call 'lehExecShell'/'lehExecBin' on this handle. The real
-- implementation uses 'System.Process' (mirrors
-- 'Seal.Harness.Tmux.readTmuxNoInput': fixed argv, no shell interpreter
-- for the program path; @/bin/sh -c@ ONLY for 'SHELL_EXEC' with a validated
-- 'ShellCommand'). 'SafePath' cwd confinement: the cwd is the workspace
-- root; @..@/absolute rejected at the call site.
--
-- This module imports the 'LocalExecHandle' TYPE+CONSTRUCTOR from
-- 'Seal.Tools.Exec.Types' (Haskell requires them co-located) and provides
-- the smart constructor 'mkLocalExecHandle' that wires the real
-- 'System.Process'-backed IO actions.
--
-- = Process-group killing + bounded output (Task 3 + Task 4)
--
-- 'runFixedArgv' uses 'withManagedProcess' instead of 'withCreateProcess'.
-- 'withManagedProcess' spawns the child with @create_group = True@ (so the
-- child is in its own POSIX process group), and on cleanup kills the whole
-- group: SIGTERM → grace period → SIGKILL. This ensures that when the
-- dispatch wrapper ('Seal.Tools.Exec.Timeout.runWithTimeoutAbortRetry')
-- cancels the Haskell worker thread (via 'async'\'s 'cancel'), the bracket
-- cleanup runs and kills the OS process group — no orphans. The zombie reap
-- is bounded (a non-blocking 'getProcessExitCode' poll with a 1s deadline)
-- so cleanup never hangs. Output capture is bounded via 'readBounded'
-- (default 50KB) with a truncation marker.
module Seal.Tools.Exec.Local
  ( mkLocalExecHandle
  , mkLocalExecHandleFromFns
  , LocalExecHandle (..)
  , withManagedProcess
  , killProcessGroup
  , readBounded
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, catch, try)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hIsEOF)
import System.Process
  ( CreateProcess (..), ProcessHandle, StdStream (..), createProcess
  , getProcessExitCode, proc, waitForProcess
  )
import System.Process.Internals (ProcessHandle__ (..), withProcessHandle)
import qualified System.Posix.Signals as Posix
import qualified System.Posix.Types as Posix

import Seal.Security.Path (WorkspaceRoot (..), mkSafePath, getSafePath)
import Seal.Tools.Args
  (BinName, BinArg, ShellCommand, textBinName, textBinArg, textShellCommand)
import Seal.Tools.Exec.Types

-- | The default bounded-output cap (50KB). Matches
-- 'Seal.Tools.Timeout.ttcMaxOutputBytes'.
defaultMaxOutputBytes :: Int
defaultMaxOutputBytes = 50_000

-- | The default SIGTERM→SIGKILL grace period (5s). Matches
-- 'Seal.Tools.Timeout.ttcKillGraceMicros'.
defaultKillGraceMicros :: Int
defaultKillGraceMicros = 5_000_000

-- | The real 'LocalExecHandle': wires 'System.Process' behind the two IO
-- actions. The 'WorkspaceRoot' anchors cwd confinement for the shell exec.
mkLocalExecHandle :: WorkspaceRoot -> LocalExecHandle
mkLocalExecHandle wsRoot = LocalExecHandle
  { lehExecShell = \cmd mCwd -> do
      let argv = ["/bin/sh", "-c", T.unpack (textShellCommand cmd)]
      case mCwd of
        Nothing -> runShell argv Nothing
        Just rp -> do
          e <- mkSafePath wsRoot (T.unpack (getRemotePath rp))
          case e of
            Left _err -> pure (Left ExecNotImplemented)
            Right sp  -> runShell argv (Just (getSafePath sp))
  , lehExecBin = \bin bargs mCwd ->
      let binName  = T.unpack (textBinName bin)
          argTexts = map (T.unpack . textBinArg) bargs
          argv     = binName : argTexts
      in case mCwd of
           Nothing  -> runProgram argv Nothing
           Just rp  -> do
             e <- mkSafePath wsRoot (T.unpack (getRemotePath rp))
             case e of
               Left _err -> pure (Left ExecNotImplemented)
               Right sp  -> runProgram argv (Just (getSafePath sp))
  }

-- | A 'LocalExecHandle' built from explicit IO action functions — the form
-- the opcode tests use (mirrors the 'TmuxRunner' fake pattern). Real
-- callers use 'mkLocalExecHandle'.
mkLocalExecHandleFromFns
  :: (ShellCommand -> Maybe RemotePath -> IO (Either ExecError Text))
  -> (BinName -> [BinArg] -> Maybe RemotePath -> IO (Either ExecError Text))
  -> LocalExecHandle
mkLocalExecHandleFromFns shellFn binFn = LocalExecHandle
  { lehExecShell = shellFn
  , lehExecBin = binFn
  }

-- | Run a shell command via @/bin/sh -c@. The shell itself always launches
-- (it's at a fixed path), so a non-zero exit — including 127 ("command not
-- found" inside the shell) — is a normal command failure, returned via
-- 'Right' with the output + exit code annotation. Only an IOError (the shell
-- binary itself couldn't launch) becomes 'Left ExecNotImplemented'.
runShell :: [String] -> Maybe String -> IO (Either ExecError Text)
runShell = runFixedArgv False

-- | Run a named binary (resolved on PATH or by path). A 127 exit
-- here means the binary itself is not on PATH, so it's mapped to
-- 'Left ExecNotImplemented' (the executor is not available). Other non-zero
-- exits are normal failures, returned via 'Right' with the output + exit code.
runProgram :: [String] -> Maybe String -> IO (Either ExecError Text)
runProgram = runFixedArgv True

-- | Run a fixed-argv program, capturing stdout and stderr as Text. An optional
-- cwd (already 'SafePath'-validated). When @treat127AsMissing@ is True, a 127
-- exit is mapped to 'Left ExecNotImplemented' (the binary is not on PATH).
-- Otherwise (shell mode), 127 is a normal command-not-found failure, returned
-- via 'Right' with the exit code annotation. Any IOError becomes 'Left
-- ExecNotImplemented'.
--
-- Uses 'withManagedProcess' (process-group spawning + kill-on-cleanup) and
-- 'readBounded' (bounded output capture, default 50KB).
runFixedArgv :: Bool -> [String] -> Maybe String -> IO (Either ExecError Text)
runFixedArgv treat127AsMissing argv mCwd = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "runFixedArgv: empty argv (unreachable)"
      cp = (proc program args)
             { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
             , cwd = mCwd
             , create_group = True
             }
      -- ^ @create_group = True@ puts the child in its own POSIX process
      -- group so 'withManagedProcess' can kill the whole group on cleanup
      -- (SIGTERM → grace → SIGKILL). This prevents orphans when the
      -- dispatch wrapper cancels the Haskell worker thread.
  res <- try @IOError
         (withManagedProcess cp $ \ph _mIn hOut hErr -> do
            out <- readBounded hOut defaultMaxOutputBytes
            err <- readBounded hErr defaultMaxOutputBytes
            ec  <- waitForProcess ph
            pure (ec, out, err))
  case res of
    Left _ioErr                     -> pure (Left ExecNotImplemented)  -- binary missing/launch fail
    Right (ExitSuccess, out, _)     -> pure (Right out)
    Right (ExitFailure 127, _, _)
      | treat127AsMissing            -> pure (Left ExecNotImplemented)  -- binary not on PATH
    Right (ExitFailure n, out, err)  -> pure (Right (formatExitResult n out err))

-- | Format a non-zero exit result for the tool-call consumer. Combines stdout
-- and stderr (if non-empty) and annotates the exit code so the frontend can
-- surface it. The result is returned via 'Right' (not an 'ExecError') so the
-- dispatcher records @is_error = False@ — the command ran successfully, it just
-- returned a non-zero exit code. The frontend treats the exit code annotation
-- as the success/failure signal.
formatExitResult :: Int -> Text -> Text -> Text
formatExitResult n out err =
  let parts = [ t | t <- [out, err], not (T.null (T.strip t)) ]
      body  = if null parts then "" else T.intercalate "\n" parts
  in body <> "\n[exit code: " <> T.pack (show n) <> "]"

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
    -- The cp MUST have create_group=True (asserted at the call site in
    -- runFixedArgv; we re-set it here too for safety).
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
      -- Kill the process group first (SIGTERM → grace → SIGKILL).
      case mPid of
        Nothing -> pure ()
        Just pid -> killProcessGroup pid defaultKillGraceMicros
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

-- | Kill a process group: SIGTERM → grace period → SIGKILL.
-- POSIX: 'signalProcessGroup' sends a signal to every process in the group.
-- The @graceMicros@ is the SIGTERM→SIGKILL grace period. Because the child
-- was spawned with @create_group = True@, its PGID equals its PID.
killProcessGroup :: Int -> Int -> IO ()
killProcessGroup pid graceMicros = do
  -- The child is in its own group (create_group=True), so its PGID == its PID.
  -- 'signalProcessGroup' takes a ProcessGroupID; a CPid and ProcessGroupID
  -- are both newtype'd Int, so we coerce via fromIntegral.
  let pgid = fromIntegral pid :: Posix.ProcessGroupID
  -- SIGTERM the whole group.
  _ <- try @IOException (Posix.signalProcessGroup Posix.sigTERM pgid)
  -- Wait the grace period.
  threadDelay graceMicros
  -- SIGKILL the whole group (idempotent on already-dead processes).
  _ <- try @IOException (Posix.signalProcessGroup Posix.sigKILL pgid)
  pure ()

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