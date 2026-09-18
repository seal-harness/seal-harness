-- | Suite-wide ssh-agent leak guard (#88 follow-up): an assertion that
-- brackets the ENTIRE test suite — after the suite finishes, no
-- @ssh-agent@ process may exist that did not exist when the suite started.
--
-- Why this exists: tests that spawn a real @ssh-agent -s@ tried to clean
-- up with @ssh-agent -k@ WITHOUT @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ in the
-- environment. On macOS, @ssh-agent -k@ prints
-- @SSH_AGENT_PID not set, cannot kill agent@ and EXITS 0 — the cleanup
-- silently no-ops, the exit code looks fine, and every test run leaks two
-- orphan agents. Verified on a dev machine: 12 orphan @ssh-agent -s@
-- processes in 6 same-second pairs (one pair per test run), all with
-- sockets under the test runs' nix-shell TMPDIR, while the production
-- registry file was untouched — the harness itself was not leaking.
--
-- The guard never trusts a kill command's exit code: liveness is
-- determined by asking @ps@. Leaked agents are terminated with SIGTERM
-- before the suite reports failure, so iterating on a fix does not
-- accumulate new orphans.
module Seal.TestHelpers.SshAgentGuard
  ( withNoLeakedSshAgents
  , sshAgentProcesses
  , pidAlive
  , waitPidGone
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (finally, try)
import Control.Monad (unless)
import Data.Char (isSpace)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeFileName)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Process (proc, readCreateProcessWithExitCode)
import Text.Read (readMaybe)

-- | Bracket the test suite: snapshot the running @ssh-agent@ processes
-- before the suite, run the suite, snapshot again. Any agent started (and
-- left running) by the suite is terminated with SIGTERM and the suite
-- FAILS with the leaked PIDs + command lines.
--
-- The differential baseline means pre-existing agents (e.g. the ambient
-- macOS login agent) never trip the guard — only NEW processes count.
withNoLeakedSshAgents :: IO () -> IO ()
withNoLeakedSshAgents action = do
  before <- Set.fromList . map fst <$> sshAgentProcesses
  action `finally` do
    after <- sshAgentProcesses
    let leaked = [ entry | entry@(pid, _) <- after, not (pid `Set.member` before) ]
    unless (null leaked) $ do
      mapM_ terminate leaked
      hPutStrLn stderr (renderLeak leaked)
      exitFailure
  where
    terminate (pid, _) = do
      _ <- try @IOError (signalProcess sigTERM (fromIntegral pid))
      pure ()

-- | Every running @ssh-agent@ process right now: @(pid, full command
-- line)@. A process qualifies when the BASENAME of its executable is
-- @ssh-agent@ — so @ssh-add@, @ssh-keygen@, and coincidental log-file
-- names never match.
sshAgentProcesses :: IO [(Int, String)]
sshAgentProcesses = do
  eRes <- try @IOError
    (readCreateProcessWithExitCode (proc "ps" ["-axo", "pid=,command="]) "")
  pure $ case eRes of
    Left _ioErr -> []  -- no ps? the guard degrades to a no-op rather than failing the suite
    Right (ExitSuccess, out, _err) -> mapMaybe parseLine (lines out)
    Right _ -> []
  where
    parseLine l = case words l of
      (pidStr : argv@(_ : _))
        | Just pid <- readMaybe pidStr
        , cmd <- unwords argv
        , isAgentCmd cmd
        -> Just (pid, cmd)
      _ -> Nothing
    isAgentCmd cmd = case words cmd of
      (exe : _) -> takeFileName exe == "ssh-agent"
      _ -> False

-- | Is the PID still a live process? Asks @ps@ — never trusts a kill
-- command's exit code (on macOS @ssh-agent -k@ without @SSH_AGENT_PID@
-- exits 0 while doing nothing).
pidAlive :: Int -> IO Bool
pidAlive pid = do
  eRes <- try @IOError
    (readCreateProcessWithExitCode (proc "ps" ["-p", show pid, "-o", "pid="]) "")
  pure $ case eRes of
    Left _ioErr -> False
    Right (_ec, out, _err) -> not (all isSpace out)

-- | Poll until the PID is gone (bounded ~2s budget; SIGTERM death is
-- usually immediate). Returns 'True' iff the PID is gone.
waitPidGone :: Int -> IO Bool
waitPidGone pid = go (20 :: Int)
  where
    go n
      | n <= 0 = not <$> pidAlive pid
      | otherwise = do
          alive <- pidAlive pid
          if not alive
            then pure True
            else do
              threadDelay 100_000
              go (n - 1)

renderLeak :: [(Int, String)] -> String
renderLeak leaked = unlines $
  ( "ssh-agent leak: " <> show (length leaked)
      <> " new ssh-agent process(es) were started by the test suite and are still running:"
  )
    : [ "  " <> show pid <> "  " <> cmd | (pid, cmd) <- leaked ]
    <> [ "The leaked processes were terminated (SIGTERM)."
       , "The offending test must terminate its agent (SIGTERM on the parsed SSH_AGENT_PID)"
       , "and ASSERT the pid is gone (waitPidGone) — ssh-agent -k needs SSH_AUTH_SOCK and"
       , "SSH_AGENT_PID in the environment and silently no-ops without them (exit 0 on macOS)."
       ]