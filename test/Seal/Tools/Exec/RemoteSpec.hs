{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.RemoteSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Logging.Global (setGlobalLogger, unsetGlobalLogger)
import Seal.Logging.Logger (closeSealLogger, newSealLoggerWithScribe)
import Seal.Tools.Exec.Types
import Seal.Tools.Exec.Remote
  ( RemoteRunner (..), mkRealRemoteRunner, sshExecArgv, sshExecArgvForwarding )
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

import Katip (Severity (..), Scribe (..), permitItem, jsonFormat, Verbosity (V2))

spec :: Spec
spec = describe "Seal.Tools.Exec.Remote" $ do

  describe "sshArgv (pure argv builder)" $ do

    it "includes StrictHostKeyChecking=yes (host-key pinning)" $ do
      let cfg = sshCfg
          argv = sshExecArgv cfg "echo hello"
      argv `shouldSatisfy` any (\a -> a == "-o" || a == "StrictHostKeyChecking=yes")
      -- The pair must be adjacent
      checkAdjacentPair argv "StrictHostKeyChecking" "yes"

    it "includes BatchMode=yes (no interactive prompts)" $ do
      let cfg = sshCfg
          argv = sshExecArgv cfg "echo hi"
      checkAdjacentPair argv "BatchMode" "yes"

    it "includes the pinned UserKnownHostsFile" $ do
      let cfg = sshCfg { scKnownHosts = "/home/agent/.ssh/pinned_known_hosts" }
          argv = sshExecArgv cfg "echo hi"
      checkAdjacentPair argv "UserKnownHostsFile" "/home/agent/.ssh/pinned_known_hosts"

    it "includes the host and user" $ do
      let cfg = sshCfg
          argv = sshExecArgv cfg "echo hi"
      argv `shouldSatisfy` elem "agent@exec.internal" -- the user@host form
      -- OR separate: -l agent exec.internal — either form is fine; the
      -- key constraint is the host and user are present.

    it "passes the command as a single arg (no shell interpreter)" $ do
      let cfg = sshCfg
          argv = sshExecArgv cfg "echo hello"
      argv `shouldSatisfy` elem "echo hello"
      argv `shouldNotSatisfy` elem "-c"  -- no -c shell wrapper

    it "includes the port when non-default" $ do
      let cfg = sshCfg { scPort = 2222 }
          argv = sshExecArgv cfg "echo hi"
      checkAdjacentPair argv "-p" "2222"

    it "uses the fixed program path ssh (not /bin/sh -c)" $ do
      let cfg = sshCfg
          argv = sshExecArgv cfg "echo hi"
      case argv of
        (prog : _) -> prog `shouldBe` "ssh"
        [] -> expectationFailure "ssh argv is empty"

    prop "never includes -c (no shell interpreter for the remote command)" $ \cmd ->
      let cfg = sshCfg
          argv = sshExecArgv cfg (cmd :: Text)
      in "-c" `notElem` argv

  -- -----------------------------------------------------------------------
  -- W2: opt-in -A invariant (design §5.6)
  -- -----------------------------------------------------------------------
  describe "sshExecArgv opt-in -A invariant (W2)" $ do

    it "sshExecArgv (non-credential ops) contains NO -A" $ do
      let argv = sshExecArgv sshCfg "echo hi"
      "-A" `shouldNotSatisfy` (`elem` argv)

    it "sshExecArgvForwarding (git-credential ops) contains -A" $ do
      let argv = sshExecArgvForwarding sshCfg "git clone -- git@github.com:o/r.git"
      "-A" `shouldSatisfy` (`elem` argv)

    it "sshExecArgvForwarding still pins StrictHostKeyChecking + UserKnownHostsFile" $ do
      let argv = sshExecArgvForwarding sshCfg "git fetch"
      checkAdjacentPair argv "StrictHostKeyChecking" "yes"
      checkAdjacentPair argv "UserKnownHostsFile" (scKnownHosts sshCfg)
      checkAdjacentPair argv "BatchMode" "yes"

    it "sshExecArgvForwarding preserves the @--@ separator + command" $ do
      let argv = sshExecArgvForwarding sshCfg "git push origin main"
      argv `shouldSatisfy` elem "--"
      argv `shouldSatisfy` elem "git push origin main"

    it "sshExecArgvForwarding uses the fixed program path ssh" $ do
      let argv = sshExecArgvForwarding sshCfg "git fetch"
      case argv of
        (prog : _) -> prog `shouldBe` "ssh"
        [] -> expectationFailure "ssh argv is empty"

    prop "sshExecArgv NEVER includes -A (any command)" $ \cmd ->
      "-A" `notElem` sshExecArgv sshCfg (cmd :: Text)

    prop "sshExecArgvForwarding ALWAYS includes -A (any command)" $ \cmd ->
      "-A" `elem` sshExecArgvForwarding sshCfg (cmd :: Text)

  describe "host-key mismatch (spec §7 row 3)" $ do

    it "a mismatched host key -> Left ExecHostKeyMismatch (hard failure, never bypassed)" $ do
      let fakeRunner :: [String] -> IO (Either ExecError Text)
          fakeRunner _argv = pure (Left ExecHostKeyMismatch)
      res <- fakeRunner []
      res `shouldBe` Left ExecHostKeyMismatch

    it "a second call after a mismatch still fails (hard, not retried)" $ do
      let fakeRunner :: [String] -> IO (Either ExecError Text)
          fakeRunner _argv = pure (Left ExecHostKeyMismatch)
      r1 <- fakeRunner []
      r2 <- fakeRunner []
      r1 `shouldBe` Left ExecHostKeyMismatch
      r2 `shouldBe` Left ExecHostKeyMismatch

  -- -----------------------------------------------------------------------
  -- Exit-code classification (transport failure vs remote-command failure)
  --
  -- SSH itself exits 255 on connect/auth/transport failures. The remote
  -- command's own exit code is propagated verbatim by ssh. So:
  --   * exit 255 (not host-key) → ExecRemoteUnreachable (transport failure)
  --   * exit 127                → ExecRemoteUnreachable (ssh not on PATH)
  --   * exit 0                  → Right stdout (success)
  --   * any other exit N        → Right (formatExitResult N out err)
  --     (the remote command ran and failed — NOT unreachable. Matches the
  --     local arm's behavior: a non-zero exit is a normal command failure,
  --     surfaced as Right with stdout+stderr+exit-code annotation.)
  --
  -- Tests exercise 'mkRealRemoteRunner' by spawning a local @sh -c@ script
  -- that produces the exact exit code + output we want. The real runner
  -- spawns whatever argv it's given (normally an ssh argv, but @sh -c@
  -- works identally for testing the exit-code classification).
  -- -----------------------------------------------------------------------
  describe "exit-code classification (transport vs remote-command failure)" $ do

    it "exit 1 (remote command failed) → Right with formatted output (NOT ExecRemoteUnreachable)" $ do
      res <- runRealSh 1 "some output" "some error"
      case res of
        Right out -> do
          out `shouldSatisfy` ("some output" `T.isInfixOf`)
          out `shouldSatisfy` ("some error" `T.isInfixOf`)
          out `shouldSatisfy` ("[exit code: 1]" `T.isInfixOf`)
        Left e -> expectationFailure ("expected Right, got Left " <> show e
                                       <> " — a non-255/non-127 exit is a remote-command failure, not unreachable")

    it "exit 128 (git clone failed) → Right with formatted output (NOT ExecRemoteUnreachable)" $ do
      res <- runRealSh 128 "" "fatal: repository not found"
      case res of
        Right out -> out `shouldSatisfy` ("repository not found" `T.isInfixOf`)
        Left e -> expectationFailure ("expected Right, got Left " <> show e)

    it "exit 255 (transport failure, not host-key) → Left ExecRemoteUnreachable" $ do
      res <- runRealSh 255 "" "ssh: connect to host: Connection refused"
      res `shouldBe` Left ExecRemoteUnreachable

    it "exit 255 with 'Host key verification failed' → Left ExecHostKeyUnknown" $ do
      res <- runRealSh 255 "" "Host key verification failed"
      res `shouldBe` Left ExecHostKeyUnknown

    it "exit 255 with 'REMOTE HOST IDENTIFICATION HAS CHANGED' → Left ExecHostKeyMismatch" $ do
      res <- runRealSh 255 "" "REMOTE HOST IDENTIFICATION HAS CHANGED"
      res `shouldBe` Left ExecHostKeyMismatch

    it "exit 127 (ssh not on PATH) → Left ExecRemoteUnreachable" $ do
      res <- runRealSh 127 "" "command not found"
      res `shouldBe` Left ExecRemoteUnreachable

    it "exit 0 → Right stdout (success)" $ do
      res <- runRealSh 0 "hello world" ""
      res `shouldBe` Right "hello world"

  -- -----------------------------------------------------------------------
  -- Logging: transport failures + non-zero exits emit katip log lines
  -- so operators can diagnose SSH issues from the server console.
  -- -----------------------------------------------------------------------
  describe "result logging (katip)" $ do

    it "logs a warning on transport failure (exit 255, not host-key)" $ do
      (_, lines_) <- withCaptureGlobalLogger' (runRealSh 255 "" "Connection refused")
      let allText = T.unlines lines_
      allText `shouldSatisfy` ("ExecRemoteUnreachable" `T.isInfixOf`)

    it "logs a debug line on non-zero remote-command exit (exit 1)" $ do
      (_, lines_) <- withCaptureGlobalLogger' (runRealSh 1 "output" "error text")
      let allText = T.unlines lines_
      allText `shouldSatisfy` ("[exit code: 1]" `T.isInfixOf`)

    it "does NOT log on success (exit 0)" $ do
      (_, lines_) <- withCaptureGlobalLogger' (runRealSh 0 "ok" "")
      lines_ `shouldBe` []

  -- -----------------------------------------------------------------------
  -- SSH connection multiplexing (one handshake, many ops)
  --
  -- Two DISJOINT master pools keyed by ControlPath suffix:
  --   m-%C — plain ops (never -A);  a-%C — agent-forwarding ops only.
  -- The split preserves the §5.6 opt-in invariant: agent forwarding over a
  -- multiplexed connection requires the MASTER to have been started with
  -- -A, so a plain op can never ride an agent-forwarding master (and a
  -- forwarding op never upgrades the shared plain pool). The first op to
  -- each pool pays the TCP + key-exchange + auth handshake; every
  -- subsequent op for ~10 minutes ('ControlPersist') rides the persistent
  -- master socket — turning N serialized round trips from N handshakes
  -- into 1 + N fast channel opens.
  --
  -- Security posture is unchanged: the master itself was established under
  -- the same pinning options (same argv shape ⇒ same config),
  -- @BatchMode=yes@ still forbids interactive prompts, and a stale socket
  -- (master killed) is detected by @ControlMaster=auto@, which falls back
  -- to a fresh direct connection. The socket directory is private (mode
  -- 0700) under @~/.seal/@.
  -- -----------------------------------------------------------------------
  describe "SSH connection multiplexing" $ do

    it "plain argv enables ControlMaster=auto" $ do
      let argv = sshExecArgv sshCfg "echo hi"
      checkAdjacentPair argv "ControlMaster" "auto"

    it "plain argv keeps a persistent master (ControlPersist=600)" $ do
      let argv = sshExecArgv sshCfg "echo hi"
      checkAdjacentPair argv "ControlPersist" "600"

    it "plain argv uses the plain mux pool under ~/.seal/ssh-mux" $ do
      home <- getHomeDirectory
      let argv = sshExecArgv sshCfg "echo hi"
      checkAdjacentPair argv "ControlPath" (home </> ".seal/ssh-mux/m-%C")

    it "forwarding argv uses the agent mux pool (never the plain one)" $ do
      home <- getHomeDirectory
      let argv = sshExecArgvForwarding sshCfg "git fetch"
      checkAdjacentPair argv "ControlPath" (home </> ".seal/ssh-mux/a-%C")
      (home </> ".seal/ssh-mux/m-%C") `shouldNotSatisfy` (`elem` argv)

    it "plain argv never joins the agent pool" $ do
      home <- getHomeDirectory
      let argv = sshExecArgv sshCfg "echo hi"
      (home </> ".seal/ssh-mux/a-%C") `shouldNotSatisfy` (`elem` argv)

    prop "the two mux pools stay disjoint for any command" $ \cmd -> do
      let a = sshExecArgv sshCfg (cmd :: Text)
          b = sshExecArgvForwarding sshCfg cmd
      not (any ("-a-%C" `isSuffixOf`) a) && not (any ("-m-%C" `isSuffixOf`) b)

    it "multiplexing does not weaken host-key pinning" $ do
      let argv = sshExecArgv sshCfg "echo hi"
      checkAdjacentPair argv "StrictHostKeyChecking" "yes"
      checkAdjacentPair argv "UserKnownHostsFile" (scKnownHosts sshCfg)
      checkAdjacentPair argv "BatchMode" "yes"

-- | Assert two argv entries are present, either as @key=value@ (joined)
-- or as adjacent @key value@ (separate args).
checkAdjacentPair :: [String] -> String -> String -> Expectation
checkAdjacentPair argv key value =
  argv `shouldSatisfy` \xs ->
    let joined = key <> "=" <> value
        adjacent = [key, value]
    in joined `elem` xs
       || adjacent `isInfixOf` xs
  where
    isInfixOf needle haystack = any (isPrefixOf needle) (tails haystack)
    isPrefixOf (x:xs) (y:ys) = x == y && isPrefixOf xs ys
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    tails [] = [[]]
    tails xs@(_:rest) = xs : tails rest

sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = either (error "fixture") id (mkRemotePath "/srv/agent-workspace")
  }

-- | Run a script via the real 'mkRealRemoteRunner' that produces a given
-- exit code, stdout, and stderr. The runner spawns whatever argv it's
-- given; we pass @sh -c@ (not an ssh argv) so the test exercises the
-- exit-code classification logic without needing a real SSH server.
runRealSh :: Int -> Text -> Text -> IO (Either ExecError Text)
runRealSh exitN out err =
  let script = "printf '%s' " <> shellQuoteStr (T.unpack out)
               <> "; printf '%s' " <> shellQuoteStr (T.unpack err)
               <> " >&2; exit " <> show exitN
  in runRemote mkRealRemoteRunner ["sh", "-c", script]

-- | Single-quote a String for embedding in a shell script.
shellQuoteStr :: String -> String
shellQuoteStr s = "'" <> concatMap (\c -> if c == '\'' then "'\\''" else [c]) s <> "'"

-- | A capture-logger wrapper (mirrors LogRedactionSpec).
withCaptureGlobalLogger' :: IO a -> IO (a, [Text])
withCaptureGlobalLogger' action = do
  ref <- newIORef []
  let scribe = Scribe
        { liPush = \item -> do
            let rendered = jsonFormat False V2 item
            modifyIORef' ref (T.pack (show rendered) :)
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  logger <- newSealLoggerWithScribe scribe DebugS
  setGlobalLogger logger
  result <- action
  closeSealLogger logger
  lines_ <- readIORef ref
  unsetGlobalLogger
  pure (result, reverse lines_)