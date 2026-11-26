{-# LANGUAGE OverloadedStrings #-}
module Seal.Execution.ResolveSpec (spec) where

import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec

import Seal.Config.Execution (ExecutionConfig (..))
import Seal.Execution.Resolve
import Seal.Execution.Types
import Seal.Tools.Exec.Types
  ( SshConfig (..), getSshHost, mkRemotePath, mkSshHost, mkSshUser )

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------

emptyEc :: ExecutionConfig
emptyEc = ExecutionConfig Nothing Map.empty

oneMachineEc :: ExecutionConfig
oneMachineEc = ExecutionConfig Nothing (Map.fromList [(mn "builder", specOf "b")])

twoMachineEc :: Maybe MachineName -> ExecutionConfig
twoMachineEc dflt = ExecutionConfig dflt (Map.fromList
  [ (mn "builder", specOf "b")
  , (mn "tester",  specOf "t")
  ])

mn :: Text -> MachineName
mn = either (error "fixture: MachineName") id . mkMachineName

specOf :: Text -> SshMachineSpec
specOf tag = SshMachineSpec
  { smsHost       = either (error "fixture: SshHost") id (mkSshHost (tag <> ".example.com"))
  , smsUser       = either (error "fixture: SshUser") id (mkSshUser "seal")
  , smsPort       = 22
  , smsIdentity   = Nothing
  , smsKnownHosts = either (error "fixture: SshLocalPath") id
                      (mkSshLocalPath "/home/op/.ssh/known_hosts")
  , smsWorkspace  = either (error "fixture: RemotePath") id (mkRemotePath "/srv/w")
  }

-- | Which machine a resolved target points at, for compact assertions.
label :: Either TargetError ResolvedTarget -> Either TargetError Text
label = fmap targetLabel

spec :: Spec
spec = describe "Seal.Execution.Resolve" $ do

  describe "row 0 — a pin that does not resolve" $ do

    it "an unknown pin is TargetUnknownMachine naming it and the available set" $
      case resolveTarget oneMachineEc True (Just (mn "ghost")) of
        Left (TargetUnknownMachine n avail) -> do
          machineNameText n `shouldBe` "ghost"
          map machineNameText avail `shouldBe` ["builder"]
        other -> expectationFailure ("expected TargetUnknownMachine, got " <> show other)

    it "an unknown pin never falls through to the effective default" $
      resolveTarget (twoMachineEc (Just (mn "tester"))) True (Just (mn "ghost"))
        `shouldSatisfy` isLeft

    it "a pin to local while allow_localhost = false is TargetLocalNotAllowed" $
      resolveTarget oneMachineEc False (Just (mn "local"))
        `shouldBe` Left (TargetLocalNotAllowed (mn "local"))

    it "a dead pin fails closed even when row 3 would otherwise allow local" $
      -- one machine, no explicit default, allow_localhost = true: a fallback
      -- would land on row 3 = WhereLocal. It must not.
      resolveTarget oneMachineEc True (Just (mn "removed")) `shouldSatisfy` isLeft

  describe "row 1 — a pin that resolves" $ do

    it "an ssh pin resolves to that machine" $
      label (resolveTarget (twoMachineEc (Just (mn "builder"))) True (Just (mn "tester")))
        `shouldBe` Right "tester"

    it "a local pin resolves to WhereLocal when allow_localhost" $
      resolveTarget (twoMachineEc (Just (mn "builder"))) True (Just (mn "local"))
        `shouldBe` Right WhereLocal

    it "the pinned machine's full config is carried, not just its name" $
      case resolveTarget (twoMachineEc (Just (mn "builder"))) True (Just (mn "tester")) of
        Right (WhereSsh _ c) -> getSshHost (scHost c) `shouldBe` "t.example.com"
        other -> expectationFailure ("expected WhereSsh, got " <> show other)

  describe "row 1a — the effective default names local under allow_localhost = false" $
    it "is TargetLocalNotAllowed, not WhereLocal" $
      resolveTarget (oneMachineEc { ecDefault = Just (mn "local") }) False Nothing
        `shouldBe` Left (TargetLocalNotAllowed (mn "local"))

  describe "row 1b — a dangling default" $
    it "is a config-load error, not WhereLocal" $
      resolveTarget (oneMachineEc { ecDefault = Just (mn "ghost") }) True Nothing
        `shouldSatisfy` isLeft

  describe "row 2 — the effective default" $ do

    it "an explicit default names an ssh machine" $
      label (resolveTarget (twoMachineEc (Just (mn "builder"))) True Nothing)
        `shouldBe` Right "builder"

    it "an explicit default wins even with a single machine" $
      label (resolveTarget (oneMachineEc { ecDefault = Just (mn "builder") }) True Nothing)
        `shouldBe` Right "builder"

    it "absent default + one machine + allow_localhost = false is that machine" $
      label (resolveTarget oneMachineEc False Nothing) `shouldBe` Right "builder"

    it "absent default + one machine + allow_localhost = true keeps local" $
      resolveTarget oneMachineEc True Nothing `shouldBe` Right WhereLocal

    it "absent default + two machines is a config-load error" $
      resolveTarget (twoMachineEc Nothing) True Nothing `shouldSatisfy` isLeft

    it "local does not count toward the >= 2 rule" $
      -- default = "local" with two ssh machines is still ambiguous, but a
      -- default naming local is *stated*, so this must not be the >= 2 error.
      resolveTarget (twoMachineEc (Just (mn "local"))) True Nothing
        `shouldBe` Right WhereLocal

  describe "row 3 — the fallback" $
    it "is WhereLocal when allow_localhost = true and nothing else applies" $
      resolveTarget emptyEc True Nothing `shouldBe` Right WhereLocal

  describe "row 4 — nothing may run" $
    it "is TargetNoMachine when allow_localhost = false and nothing applies" $
      resolveTarget emptyEc False Nothing `shouldBe` Left TargetNoMachine

  describe "the invariant the design rests on" $
    it "no inventory or pin can produce WhereLocal unless allow_localhost" $
      and
        [ resolveTarget ec False pin /= Right WhereLocal
        | ec <- [ emptyEc
                , oneMachineEc
                , twoMachineEc (Just (mn "builder"))
                , twoMachineEc Nothing
                , oneMachineEc { ecDefault = Just (mn "local") }
                ]
        , pin <- [ Nothing, Just (mn "builder"), Just (mn "local"), Just (mn "ghost") ]
        ]
        `shouldBe` True

  describe "transition: adding the first machine" $
    it "does not move an unpinned session under allow_localhost = true" $
      resolveTarget oneMachineEc True Nothing `shouldBe` Right WhereLocal
