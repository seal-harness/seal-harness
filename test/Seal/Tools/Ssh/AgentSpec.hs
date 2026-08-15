{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Tools.Ssh.Agent' — the SSH-agent capability seam.
--
-- The FD-leak regression test (#88): 'mkRealSshAgentHandle' must build its
-- 'CreateProcess' records with @close_fds = True@ so ssh-agent does NOT
-- inherit seal's TCP sockets (the WS stream port) + transcript file
-- handles. Without this, a crashed seal leaves ssh-agent holding the
-- gateway's ports hostage (the root cause of the original
-- "Address already in use" bug).
module Seal.Tools.Ssh.AgentSpec (spec) where

import Test.Hspec

import Seal.Tools.Ssh.Agent

spec :: Spec
spec = describe "Seal.Tools.Ssh.Agent" $ do
  describe "mkRealSshAgentHandle (FD-leak regression — #88)" $ do
    it "ssh-agent CreateProcess has close_fds = True" $
      agentCreateProcessCloseFds `shouldBe` True

    it "ssh-add CreateProcess has close_fds = True" $
      addKeyCreateProcessCloseFds `shouldBe` True

    it "ssh-agent -k CreateProcess has close_fds = True" $
      killCreateProcessCloseFds `shouldBe` True
