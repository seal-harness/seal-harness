{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
-- | Tests for 'Seal.SourceControl.AgentRegistry' — the persistent
-- ssh-agent registry (#88). Agents survive seal restarts; dead agents are
-- GC'd at the next startup probe.
module Seal.SourceControl.AgentRegistrySpec (spec) where

import Control.Exception (try)
import Data.Map.Strict qualified as Map
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Process (readCreateProcessWithExitCode, proc)
import Test.Hspec
import Text.Read (readMaybe)

import Seal.SourceControl.AgentRegistry
import Seal.TestHelpers.SshAgentGuard (waitPidGone)
import Seal.Tools.Ssh.Agent (SshAgentEnv (..))

spec :: Spec
spec = describe "Seal.SourceControl.AgentRegistry" $ do
  describe "persist + load round-trip" $ do
    it "saves and reloads an agent entry" $
      withSystemTempDirectory "seal-agentreg" $ \dir -> do
        h <- mkAgentRegistryHandle dir
        let env = SshAgentEnv { saeAuthSock = "/tmp/agent-123", saeAgentPid = "12345" }
        arUpsert h "repo-key-A" env
        loaded <- arLoad h
        loaded `shouldBe` Map.fromList [("repo-key-A", env)]

    it "absent dir loads as empty" $
      withSystemTempDirectory "seal-agentreg" $ \dir -> do
        h <- mkAgentRegistryHandle dir
        loaded <- arLoad h
        loaded `shouldBe` Map.empty

    it "overwrites an existing entry on re-upsert" $
      withSystemTempDirectory "seal-agentreg" $ \dir -> do
        h <- mkAgentRegistryHandle dir
        let env1 = SshAgentEnv { saeAuthSock = "/tmp/agent-1", saeAgentPid = "111" }
            env2 = SshAgentEnv { saeAuthSock = "/tmp/agent-2", saeAgentPid = "222" }
        arUpsert h "repo-key-A" env1
        arUpsert h "repo-key-A" env2
        loaded <- arLoad h
        loaded `shouldBe` Map.fromList [("repo-key-A", env2)]

    it "removes an entry" $
      withSystemTempDirectory "seal-agentreg" $ \dir -> do
        h <- mkAgentRegistryHandle dir
        let env = SshAgentEnv { saeAuthSock = "/tmp/agent-1", saeAgentPid = "111" }
        arUpsert h "repo-key-A" env
        arRemove h "repo-key-A"
        loaded <- arLoad h
        loaded `shouldBe` Map.empty

  describe "probe (liveness check)" $ do
    it "reports Dead for a non-existent socket" $ do
      let env = SshAgentEnv { saeAuthSock = "/tmp/nonexistent-sock-xyz", saeAgentPid = "99999" }
      status <- probeAgent env
      status `shouldBe` AgentDead

    it "reports Alive for a real running ssh-agent" $ do
        -- Start a real ssh-agent to probe.
        (_ec, out, _err) <- readCreateProcessWithExitCode (proc "ssh-agent" ["-s"]) ""
        case parseAgentEnv out of
          Nothing -> pendingWith "ssh-agent not available or unparseable in this env"
          Just env -> do
            status <- probeAgent env
            status `shouldBe` AgentAlive
            -- Clean up: terminate the agent we started. ssh-agent -k
            -- without SSH_AUTH_SOCK/SSH_AGENT_PID in the environment
            -- silently no-ops on macOS (exits 0 doing nothing), so we
            -- SIGTERM the parsed SSH_AGENT_PID directly and assert death.
            case readMaybe @Int (saeAgentPid env) of
              Nothing -> pure ()
              Just pid -> do
                _ <- try @IOError (signalProcess sigTERM (fromIntegral pid))
                gone <- waitPidGone pid
                gone `shouldBe` True

  describe "probeAndSweep" $ do
    it "removes dead entries and keeps alive ones" $
      withSystemTempDirectory "seal-agentreg" $ \dir -> do
        h <- mkAgentRegistryHandle dir
        -- A dead entry (non-existent socket).
        let deadEnv = SshAgentEnv { saeAuthSock = "/tmp/nonexistent-sock-xyz", saeAgentPid = "99999" }
        arUpsert h "dead-key" deadEnv
        -- Start a real agent for the alive entry.
        (_ec, out, _err) <- readCreateProcessWithExitCode (proc "ssh-agent" ["-s"]) ""
        case parseAgentEnv out of
          Nothing -> pendingWith "ssh-agent not available or unparseable in this env"
          Just aliveEnv -> do
            arUpsert h "alive-key" aliveEnv
            arProbeAndSweep h
            loaded <- arLoad h
            -- The dead entry should be gone; the alive entry should remain.
            Map.lookup "dead-key" loaded `shouldBe` Nothing
            Map.lookup "alive-key" loaded `shouldBe` Just aliveEnv
            -- Clean up: SIGTERM the parsed SSH_AGENT_PID and assert
            -- death (ssh-agent -k silently no-ops without the env vars).
            case readMaybe @Int (saeAgentPid aliveEnv) of
              Nothing -> pure ()
              Just pid -> do
                _ <- try @IOError (signalProcess sigTERM (fromIntegral pid))
                gone <- waitPidGone pid
                gone `shouldBe` True

  describe "reuse-on-restart (the core invariant)" $ do
    it "a second handle reuses the persisted agent (no new agent needed)" $
      withSystemTempDirectory "seal-agentreg" $ \dir -> do
        let env = SshAgentEnv { saeAuthSock = "/tmp/agent-reuse", saeAgentPid = "44444" }
        -- First "seal process" writes the registry.
        h1 <- mkAgentRegistryHandle dir
        arUpsert h1 "repo-key-X" env
        -- Second "seal process" loads it.
        h2 <- mkAgentRegistryHandle dir
        loaded <- arLoad h2
        loaded `shouldBe` Map.fromList [("repo-key-X", env)]