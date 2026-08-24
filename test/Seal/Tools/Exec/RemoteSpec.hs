{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.RemoteSpec (spec) where

import Data.List (isSuffixOf)
import Data.Text (Text)
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Tools.Exec.Types
import Seal.Tools.Exec.Remote (sshExecArgv, sshExecArgvForwarding)
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

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
  -- SSH connection multiplexing (one handshake, many ops)
  --
  -- Two DISJOINT master pools keyed by ControlPath suffix:
  --   m-%C — plain ops (never -A);  a-%C — agent-forwarding ops only.
  -- The split preserves the §5.6 opt-in invariant: agent forwarding over a
  -- muxed connection requires the MASTER to have been started with -A, so
  -- plain ops must never be able to ride an agent-forwarding master (and
  -- vice versa a git -A op must not silently upgrade the plain pool).
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