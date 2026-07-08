{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.UntrustedSpec (spec) where

import Data.Either (isLeft, isRight)
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

  describe "selectUntrustedBackend" $ do

    it "mode=remote + TbSsh configured -> Right (the Ssh backend)" $ do
      let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
      selectUntrustedBackend cfg (TbSsh sshCfg) `shouldSatisfy` isRight

    it "mode=remote + no remote configured -> Left ExecRemoteRequired" $ do
      let cfg = UntrustedExecConfig UemRemote Nothing
      selectUntrustedBackend cfg (TbSsh sshCfg) `shouldBe` Left ExecRemoteRequired

    it "mode=remote + TbLocal -> Left ExecLocalNotPermittedForUntrusted (never Local)" $ do
      let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
      selectUntrustedBackend cfg TbLocal `shouldBe` Left ExecLocalNotPermittedForUntrusted

    it "mode=local + anything -> Left ExecLocalNotPermittedForUntrusted (never yields Local)" $ do
      let cfg = UntrustedExecConfig UemLocal (Just sshCfg)
      selectUntrustedBackend cfg TbLocal `shouldBe` Left ExecLocalNotPermittedForUntrusted

    prop "mode=remote never yields a Local-capable backend (always Ssh-or-Left)" $
      forAll genBackend $ \b ->
        let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
        in case selectUntrustedBackend cfg b of
             Right _ -> case b of TbSsh _ -> True; _ -> False
             Left _  -> True

    prop "mode=local never yields Right (always Left, never Local)" $
      forAll genBackend $ \b ->
        let cfg = UntrustedExecConfig UemLocal (Just sshCfg)
        in selectUntrustedBackend cfg b `shouldSatisfy` isLeft

  describe "selectExecBackend" $ do

    it "mode=local + TbLocal -> Right (EbLocal ...)" $ do
      let cfg = UntrustedExecConfig UemLocal Nothing
      selectExecBackend cfg TbLocal `shouldSatisfy` isRight

    it "mode=remote + TbSsh configured -> Right (EbRemote ...)" $ do
      let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
      selectExecBackend cfg (TbSsh sshCfg) `shouldSatisfy` isRight

    it "mode=remote + TbLocal -> Left (no local fallback)" $ do
      let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
      selectExecBackend cfg TbLocal `shouldBe` Left ExecLocalNotPermittedForUntrusted

    it "mode=remote + no remote configured + TbSsh -> Left ExecRemoteRequired" $ do
      let cfg = UntrustedExecConfig UemRemote Nothing
      selectExecBackend cfg (TbSsh sshCfg) `shouldBe` Left ExecRemoteRequired

    prop "mode=remote never yields EbLocal (no local fallback)" $
      forAll genBackend $ \b ->
        let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
        in case selectExecBackend cfg b of
             Right (EbLocal _) -> False
             _                 -> True

  describe "fail-closed integration (spec §7 row 1+2)" $ do

    it "mode=remote, no remote configured + TbLocal -> Left ExecLocalNotPermittedForUntrusted (no local fallback)" $ do
      let cfg = UntrustedExecConfig UemRemote Nothing
      selectExecBackend cfg TbLocal `shouldBe` Left ExecLocalNotPermittedForUntrusted

    it "mode=remote, no remote configured + TbSsh -> Left ExecRemoteRequired (fail-closed at call time)" $ do
      let cfg = UntrustedExecConfig UemRemote Nothing
      selectExecBackend cfg (TbSsh sshCfg) `shouldBe` Left ExecRemoteRequired

    it "mode=remote, remote configured + TbSsh -> Right (EbRemote sshCfg)" $ do
      let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
      case selectExecBackend cfg (TbSsh sshCfg) of
        Right (EbRemote s) -> scHost s `shouldBe` scHost sshCfg
        _ -> expectationFailure "expected Right (EbRemote ...)"

  describe "enforceRemoteOnly (Cabal flag startup check)" $ do

    it "mode=remote -> Right ()" $ do
      let cfg = UntrustedExecConfig UemRemote (Just sshCfg)
      enforceRemoteOnly cfg `shouldBe` Right ()

    it "mode=local -> Left (startup error)" $ do
      let cfg = UntrustedExecConfig UemLocal Nothing
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