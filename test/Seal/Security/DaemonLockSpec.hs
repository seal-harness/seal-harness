{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the daemon liveness lock.
--
-- The property under test is the one the design asks for: the lock is held by
-- a /process/, so a daemon that dies — normally or not — leaves no false
-- refusal behind. That cannot be shown in one process (POSIX record locks do
-- not conflict within a process), so the holder here is a forked child that the
-- parent kills by letting it exit.
module Seal.Security.DaemonLockSpec (spec) where

import Control.Concurrent (threadDelay)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import Test.Hspec
import System.Posix.Process
  ( ProcessStatus (..), exitImmediately, forkProcess, getProcessStatus )

import Seal.Security.DaemonLock
  ( acquireServeLock, daemonHoldsLock, releaseServeLock )

spec :: Spec
spec = describe "Seal.Security.DaemonLock" $ do
  it "reports no holder when the lock file does not exist" $
    withSystemTempDirectory "seal-dl" $ \dir -> do
      daemonHoldsLock (dir </> "serve.lock") `shouldReturn` False

  it "reports no holder for a lock file left behind by a dead process" $
    withSystemTempDirectory "seal-dl" $ \dir -> do
      let path = dir </> "serve.lock"
      -- The file exists — a crashed daemon leaves it behind — but no process
      -- holds the lock. Neither the probe nor a fresh acquisition may be
      -- refused on account of the file's existence.
      writeFile path ""
      daemonHoldsLock path `shouldReturn` False
      Right lock <- acquireServeLock path
      releaseServeLock lock
      daemonHoldsLock path `shouldReturn` False

  it "a held lock is visible to another process and released when it exits" $
    withSystemTempDirectory "seal-dl" $ \dir -> do
      let path = dir </> "serve.lock"
          ready = dir </> "ready"
          go = dir </> "go"
      daemonHoldsLock path `shouldReturn` False
      pid <- forkProcess $ do
        Right _held <- acquireServeLock path
        writeFile ready "held"
        waitFor go
        exitImmediately ExitSuccess
      waitFor ready
      -- The child is alive and holds it.
      daemonHoldsLock path `shouldReturn` True
      writeFile go "exit"
      status <- getProcessStatus True False pid
      status `shouldBe` Just (Exited ExitSuccess)
      -- The kernel dropped the lock when the process died: no stale refusal.
      daemonHoldsLock path `shouldReturn` False

-- Helpers ------------------------------------------------------------------


-- | Bounded wait for a marker file, so a forked child and its parent can hand
-- off without pipes (the child gets its own address space, so an MVar would not
-- be shared).
waitFor :: FilePath -> IO ()
waitFor marker = go (0 :: Int)
  where
    go n = do
      exists <- doesFileExist marker
      if exists
        then pure ()
        else if n > 500
          then fail ("timed out waiting for " <> marker)
          else threadDelay 10000 >> go (n + 1)
