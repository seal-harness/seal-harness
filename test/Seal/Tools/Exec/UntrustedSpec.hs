{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.UntrustedSpec (spec) where

import Data.Either (isRight)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Arbitrary (..), Gen, elements, forAll)

import Seal.Tools.Exec.Types
import Seal.Tools.Exec.Untrusted

spec :: Spec
spec = describe "Seal.Tools.Exec.Untrusted" $ do

  describe "mkUntrustedExecBackend" $ do

    it "accepts TbSsh" $
      mkUntrustedExecBackend (TbSsh sshCfg) `shouldSatisfy` isRight

    it "rejects TbLocal (Local not permitted for untrusted)" $
      mkUntrustedExecBackend TbLocal `shouldBe` Left ExecLocalNotPermittedForUntrusted

    it "rejects TbTmux (not implemented)" $
      mkUntrustedExecBackend (TbTmux TmuxConfig) `shouldBe` Left ExecNotImplemented

    it "rejects TbContainer (not implemented)" $
      mkUntrustedExecBackend (TbContainer containerSpec) `shouldBe` Left ExecNotImplemented

    prop "only TbSsh yields Right; all other backends yield Left" $
      forAll genBackend $ \b ->
        case mkUntrustedExecBackend b of
          Right _ -> case b of TbSsh _ -> True; _ -> False
          Left _  -> case b of TbSsh _ -> False; _ -> True

-- | A generator covering all four 'TerminalBackend' constructors. Kept
-- local (no global Arbitrary instance) so the spec stays self-contained.
genBackend :: Gen TerminalBackend
genBackend = elements
  [ TbLocal
  , TbTmux TmuxConfig
  , TbSsh sshCfg
  , TbContainer containerSpec
  ]

sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = either (error "fixture") id (mkRemotePath "/srv/agent-workspace")
  }

containerSpec :: ContainerSpec
containerSpec = ContainerSpec
  { csTarget = either (error "fixture") id (mkContainerTarget "ubuntu-22.04")
  , csImage  = "ubuntu:22.04"
  }

-- | Unused now; retained for future props that want an Arbitrary wrapper.
newtype ArbBackend = ArbBackend TerminalBackend
instance Arbitrary ArbBackend where
  arbitrary = ArbBackend <$> genBackend