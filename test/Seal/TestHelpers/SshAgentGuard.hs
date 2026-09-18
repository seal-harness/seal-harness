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
-- The launchd-managed macOS user agent (@\/usr\/bin\/ssh-agent -l@, from
-- @com.openssh.ssh-agent.plist@) is EXEMPT: it is OS infrastructure, not
-- suite-owned. Launchd spawns it lazily the first time a subprocess
-- connects to its socket-activated @SSH_AUTH_SOCK@ — e.g. a reachability
-- probe that inherits the ambient environment mid-suite — so it can appear
-- as a "new" process on macOS CI even though the suite neither started nor
-- owns it. Killing the operator's ambient agent would be actively harmful.
--
-- The guard never trusts a kill command's exit code: liveness is
-- determined by asking @ps@. Leaked agents are terminated with SIGTERM
-- before the suite reports failure, so iterating on a fix does not
-- accumulate new orphans.
module Seal.TestHelpers.SshAgentGuard
  ( withNoLeakedSshAgents
  , sshAgentProcesses
  , isLaunchdAgent
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
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Process (proc, readCreateProcessWithExitCode)
import Text.Read (readMaybe)

-- | Bracket the test suite: snapshot the running @ssh-agent@ processes
-- before the suite, run the suite, snapshot again. Any agent started (and
-- left running) by the suite is terminated with SIGTERM and the suite
-- FAILS with the leaked PIDs + command lines.
--
-- The differential baseline means pre-existing agents never trip the
-- guard — only NEW processes count, and launchd-managed agents (argv
-- ending in @ssh-agent -l@) are exempt entirely (see module docs).
withNoLeakedSshAgents :: IO () -> IO ()
withNoLeakedSshAgents action = do
  before <- Set.fromList . map fst <$> sshAgentProcesses
  action `finally` do
    after <- sshAgentProcesses
    let leaked =
          [ entry
          | entry@(pid, cmd) <- after
          , not (pid `Set.member` before)
          , not (isLaunchdAgent cmd)
          ]
    unless (null leaked) $ do
      mapM_ terminate leaked
      hPutStrLn stderr (renderLeak leaked)
      exitFailure
  where
    -- SIGTERM, then a bounded liveness-confirmed wait, then SIGKILL if
    -- the process ignored SIGTERM (the "small delay" made robust: death
    -- is verified by asking ps, never assumed from a kill's exit code).
    terminate (pid, _) = do
      _ <- try @IOError (signalProcess sigTERM (fromIntegral pid))
      gone <- waitPidGone pid
      unless gone $ do
        _ <- try @IOError (signalProcess sigKILL (fromIntegral pid))
        _ <- waitPidGone pid
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

-- | Is this the launchd-managed macOS user agent? Takes the COMMAND FIELD
-- from @ps@ with the leading PID REMOVED ('parseLine' strips it before
-- calling) — i.e. @\/usr\/bin\/ssh-agent -l@ for the launchd form. The
-- plist (@com.openssh.ssh-agent.plist@) runs exactly
-- @["\/usr\/bin\/ssh-agent", "-l"]@. Match on the executable basename +
-- flag — never the absolute path, which varies by platform — so a
-- suite-spawned @ssh-agent -s@ is still counted (its flag is @-s@).
isLaunchdAgent :: String -> Bool
isLaunchdAgent cmd = case words cmd of
  (exe : rest)
    | takeFileName exe == "ssh-agent"
    , rest == ["-l"]
    -> True
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
    <> [ "The leaked processes were terminated (SIGTERM, escalating to SIGKILL)."
       , "The offending test must terminate its agent (SIGTERM on the parsed SSH_AGENT_PID)"
       , "and ASSERT the pid is gone (waitPidGone) — ssh-agent -k needs SSH_AUTH_SOCK and"
       , "SSH_AGENT_PID in the environment and silently no-ops without them (exit 0 on macOS)."
       , "The launchd-managed macOS user agent (ssh-agent -l) is exempt — it is OS-owned."
       ]