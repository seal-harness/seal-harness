{-# LANGUAGE OverloadedStrings #-}
-- | Unit tests for 'Seal.TestHelpers.SshAgentGuard' — the pure
-- classification logic (no process spawning). Regression tests for the
-- launchd-agent exemption: @\/usr\/bin\/ssh-agent -l@ (macOS
-- @com.openssh.ssh-agent.plist@) appears mid-suite when a subprocess
-- touches the ambient @SSH_AUTH_SOCK@ and must NOT count as a leak,
-- while suite-spawned @ssh-agent -s@ MUST count.
--
-- The first version of 'isLaunchdAgent' required the PID as the first
-- word but was fed the PID-stripped command field — the CI leak
-- (@\/usr\/bin\/ssh-agent -l@) still failed the suite. These tests feed
-- the matcher the exact shape 'sshAgentProcesses' produces (PID already
-- stripped) so that contract is pinned.
module Seal.TestHelpers.SshAgentGuardSpec (spec) where

import Test.Hspec

import Seal.TestHelpers.SshAgentGuard (isLaunchdAgent)

spec :: Spec
spec = describe "Seal.TestHelpers.SshAgentGuard" $
  describe "isLaunchdAgent (command field AFTER pid strip)" $ do
    -- The exact CI failure shape: /usr/bin/ssh-agent -l → exempt.
    it "exemps /usr/bin/ssh-agent -l (launchd plist argv)" $
      isLaunchdAgent "/usr/bin/ssh-agent -l" `shouldBe` True

    it "exemps a bare ssh-agent -l" $
      isLaunchdAgent "ssh-agent -l" `shouldBe` True

    -- Suite-spawned agents must still count as leaks.
    it "counts ssh-agent -s (suite-spawned)" $
      isLaunchdAgent "ssh-agent -s" `shouldBe` False

    it "counts /opt/homebrew/bin/ssh-agent -s" $
      isLaunchdAgent "/opt/homebrew/bin/ssh-agent -s" `shouldBe` False

    it "counts an agent with extra args (-l -x is not the launchd form)" $
      isLaunchdAgent "/usr/bin/ssh-agent -l -x" `shouldBe` False

    it "counts a bare ssh-agent with no flags" $
      isLaunchdAgent "/usr/bin/ssh-agent" `shouldBe` False

    it "counts non-agent executables" $ do
      isLaunchdAgent "ssh-add -l" `shouldBe` False
      isLaunchdAgent "-l" `shouldBe` False

    it "counts the empty command" $
      isLaunchdAgent "" `shouldBe` False