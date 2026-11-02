{-# LANGUAGE OverloadedStrings #-}
-- | The daemon liveness lock: @\<state\>\/serve.lock@.
--
-- @seal serve@ takes an exclusive advisory lock on this file for its whole
-- lifetime; the commands that must not race a live daemon (@enroll --cancel@,
-- @disable@, @reset@, @migrate-credentials@) probe it with 'daemonHoldsLock'.
--
-- The lock is a POSIX @fcntl@ record lock, which the kernel holds on behalf of
-- the process and releases when the process exits, however it exits. That is
-- the property this module exists for: a daemon that crashed on Tuesday must
-- not make @reset@ refuse on Wednesday. The file's /existence/ therefore means
-- nothing; only the lock's state does.
--
-- Why not the @flock@-style @fileLock@: the @unix@ package shipped with GHC
-- 9.12 (2.8.8.0) exposes only the record-lock API ('getLock', 'setLock',
-- 'waitToSetLock'), and a record lock has the same released-on-death
-- behaviour. The one difference worth knowing: closing /any/ descriptor for
-- this file drops this process's lock on it, so nothing else in the daemon may
-- open @serve.lock@.
module Seal.Security.DaemonLock
  ( ServeLock
  , acquireServeLock
  , releaseServeLock
  , daemonHoldsLock
  ) where

import Control.Exception (IOException, try)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Device (SeekMode (AbsoluteSeek))
import System.Posix.IO
  ( FileLock, LockRequest (..), OpenFileFlags (creat), OpenMode (ReadWrite)
  , closeFd, defaultFileFlags, getLock, openFd, setLock )
import System.Posix.Types (Fd, ProcessID)

-- | A held lock. Keep it alive for as long as the daemon should look alive;
-- 'releaseServeLock' (or process exit) drops it.
newtype ServeLock = ServeLock Fd

-- | The whole-file, exclusive lock the daemon holds: lock byte 0 to EOF.
wholeFile :: FileLock
wholeFile = (WriteLock, AbsoluteSeek, 0, 0)

-- | Take the lock, or report that someone else holds it.
--
-- Non-blocking by design: a second @seal serve@ against the same
-- @SEAL_HOME@ is a mistake to report, not a process to queue behind.
acquireServeLock :: FilePath -> IO (Either Text ServeLock)
acquireServeLock path = do
  opened <- try (openFd path ReadWrite defaultFileFlags { creat = Just 0o600 })
  case opened of
    Left (err :: IOException) -> pure (Left (couldNotOpen path err))
    Right fd -> do
      locked <- try (setLock fd wholeFile)
      case locked of
        Right () -> pure (Right (ServeLock fd))
        Left (_ :: IOException) -> do
          closeFd fd
          pure (Left ("another `seal serve` is already running for this SEAL_HOME ("
                       <> T.pack path <> " is locked).\n"
                       <> "  Stop it first: a second daemon would fight it for the port."))

-- | Drop the lock early. Process exit does this too.
releaseServeLock :: ServeLock -> IO ()
releaseServeLock (ServeLock fd) = closeFd fd

-- | Is a live process holding the lock?
--
-- 'getLock' asks the kernel who holds the lock without taking it, which is
-- exactly the question here. A missing lock file, an unreadable one, or a file
-- left behind by a crashed daemon all answer @False@.
daemonHoldsLock :: FilePath -> IO Bool
daemonHoldsLock path = do
  opened <- try (openFd path ReadWrite defaultFileFlags { creat = Just 0o600 })
  case opened of
    -- If the file cannot be opened at all, no daemon can be holding a lock on
    -- it, and the command that probes is about to fail on its own write with a
    -- better message than "a daemon is running".
    Left (_ :: IOException) -> pure False
    Right fd -> do
      current <- try (getLock fd wholeFile)
              :: IO (Either IOException (Maybe (ProcessID, FileLock)))
      closeFd fd
      pure (either (const True) isJust current)

couldNotOpen :: FilePath -> IOException -> Text
couldNotOpen path err = T.pack path <> ": could not open the daemon lock: "
  <> T.pack (show err)
