{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.UntrustedSpec (spec) where

import Data.Either (isRight)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Arbitrary (..), Gen, elements, forAll)

import Seal.Config.Security
  ( defaultSecurityConfig, untrustedExecConfigFromSecurity )
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

  describe "selectUntrustedBackend" $ do

    it "yields the Ssh backend for a TbSsh, whatever allow_localhost says" $ do
      selectUntrustedBackend (UntrustedExecConfig True)  (TbSsh sshCfg)
        `shouldSatisfy` isRight
      selectUntrustedBackend (UntrustedExecConfig False) (TbSsh sshCfg)
        `shouldSatisfy` isRight

    it "never yields Local, even when allow_localhost is true" $ do
      -- This is the remote-only selector. `allow_localhost` decides whether
      -- `local` is *offered*, which is resolution's job; it never turns this
      -- function into one that hands out a local handle.
      selectUntrustedBackend (UntrustedExecConfig True) TbLocal
        `shouldBe` Left ExecLocalNotPermittedForUntrusted

    prop "only TbSsh yields Right; all other backends yield Left" $
      forAll genBackend $ \b ->
        let cfg = UntrustedExecConfig True
        in case selectUntrustedBackend cfg b of
             Right _ -> case b of TbSsh _ -> True; _ -> False
             Left _  -> case b of TbSsh _ -> False; _ -> True

  -- Design 8 step 2, the corrected truth table. The two properties below are
  -- the whole point of it: `allow_localhost` gates MtLocal and ONLY MtLocal.
  -- Revision 1 gated remote machines on the same flag and so refused every
  -- machine under the default configuration; these assertions fail against
  -- that table.
  describe "selectExecBackend (the corrected truth table)" $ do

    it "MtLocal + allow_localhost = true -> EbLocal" $
      selectExecBackend (UntrustedExecConfig True) TbLocal
        `shouldSatisfy` isRight

    it "MtLocal + allow_localhost = false -> Left (never EbLocal)" $
      selectExecBackend (UntrustedExecConfig False) TbLocal
        `shouldBe` Left ExecLocalNotPermittedForUntrusted

    it "MtSsh is selectable under the default (allow_localhost = true)" $
      case selectExecBackend (UntrustedExecConfig True) (TbSsh sshCfg) of
        Right (EbRemote s) -> scHost s `shouldBe` scHost sshCfg
        other -> expectationFailure
          ("expected Right (EbRemote ...) under allow_localhost = true, got "
            <> show other)

    it "MtSsh is selectable with allow_localhost = false too" $
      case selectExecBackend (UntrustedExecConfig False) (TbSsh sshCfg) of
        Right (EbRemote s) -> scHost s `shouldBe` scHost sshCfg
        other -> expectationFailure
          ("expected Right (EbRemote ...) under allow_localhost = false, got "
            <> show other)

    prop "prop_mtLocalFalseIsNeverEbLocal: MtLocal under a false flag never runs locally" $
      let cfg = UntrustedExecConfig False
      in case selectExecBackend cfg TbLocal of
           Right (EbLocal _) -> False
           _                 -> True

    prop "prop_mtSshIsNeverEbLocal: a remote machine never becomes a local handle" $
      forAll (elements [True, False]) $ \allow ->
        case selectExecBackend (UntrustedExecConfig allow) (TbSsh sshCfg) of
          Right (EbLocal _) -> False
          _                 -> True

    prop "the flag changes exactly one cell of the table" $
      forAll genBackend $ \b ->
        let withFlag = selectExecBackend (UntrustedExecConfig True) b
            noFlag   = selectExecBackend (UntrustedExecConfig False) b
        in case b of
             TbLocal -> withFlag /= noFlag
             _       -> withFlag == noFlag

  describe "enforceRemoteOnly (Cabal flag startup check)" $ do

    it "allow_localhost = false -> Right ()" $
      enforceRemoteOnly (UntrustedExecConfig False) `shouldBe` Right ()

    it "allow_localhost = true -> Left (startup error)" $
      enforceRemoteOnly (UntrustedExecConfig True) `shouldSatisfy` \case
        Left _ -> True
        Right _ -> False

    it "rejects the default, which is allow_localhost = true" $ do
      -- The state the check exists to reject: no [untrusted_execution] section
      -- at all. It used to resolve to `Nothing`, which the check could not see
      -- through, so a hardened build started and then failed every local call.
      let cfg = untrustedExecConfigFromSecurity defaultSecurityConfig
      enforceRemoteOnly cfg `shouldSatisfy` \case
        Left _ -> True
        Right _ -> False

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