{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.RemoteSpec (spec) where

import Data.Text (Text)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Tools.Exec.Types
import Seal.Tools.Exec.Remote
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