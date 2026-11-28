{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.MachineSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, elements)

import Seal.Config.Machines
  ( MachineFileConfig (..), MachineName, MachineRegistry (..), MachinesConfig (..)
  , MissingField (..), RejectReason (..), localMachineName, mkMachineName
  , resolveMachines )
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSystemSessionId)
import Seal.Session.Machine (machineForSession, renderMachineConfigError)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tools.Exec.Machine (MachineError (..), UnusableReason (..))

spec :: Spec
spec = do
  describe "machineForSession" $ do
    it "case 1: a recorded machine that is selectable resolves to its target" $ do
      let reg = registryWithLocalAnd "builder"
      fst <$> machineForSession reg (metaWith "builder")
        `shouldBe` Right (machineNamed "builder")

    it "case 2: a recorded machine that is present but rejected is MachineUnusable, not MachineGone" $ do
      -- This is the round-1 bug the design records: revision 1 consulted only
      -- regMachines, so a misconfigured machine was reported with the
      -- deleted-machine text. Those are very different repairs for the operator:
      -- fix a field versus restore a machine.
      let reg = registryRejecting "broken" (RrMissingField MissingWorkspace)
      case machineForSession reg (metaWith "broken") of
        Left (MachineUnusable nm reason) -> do
          nm `shouldBe` machineNamed "broken"
          reason `shouldBe` UrrMissingWorkspace
        other -> expectationFailure ("expected MachineUnusable, got " <> show other)

    it "case 3: a recorded `local` under allow_localhost = false is MachineNotPermitted" $ do
      let reg = registryWithoutLocal [] -- local not injected
      case machineForSession reg (metaWith "local") of
        Left (MachineNotPermitted nm) -> nm `shouldBe` localMachineName
        other -> expectationFailure ("expected MachineNotPermitted, got " <> show other)

    it "case 4: a recorded machine that is in neither map is MachineGone" $ do
      let reg = registryWithLocalAnd "builder"
      case machineForSession reg (metaWith "deleted") of
        Left (MachineGone nm) -> nm `shouldBe` machineNamed "deleted"
        other -> expectationFailure ("expected MachineGone, got " <> show other)

    it "case 5a: no recorded machine takes the configured default" $ do
      let reg = registryWithLocalAnd "builder"
      fst <$> machineForSession reg metaWithNothing
        `shouldBe` Right (machineNamed "builder")

    it "case 5b: no default, allow_localhost = false, no machines is NoMachineSelected" $ do
      -- The only state that produces the requirements' "allow_localhost is
      -- false and no execution machine is configured" text. Collapsing it into
      -- MachineDefaultUnset (revision 2) orphaned that string.
      let reg = registryWithoutLocal []
      machineForSession reg metaWithNothing `shouldBe` Left NoMachineSelected

    it "case 5c: no default but a machine exists is MachineDefaultUnset" $ do
      let reg = registryWithoutLocal ["builder"]
      machineForSession reg metaWithNothing `shouldBe` Left MachineDefaultUnset

    it "case 5c': no default with only the implicit local is MachineDefaultUnset" $ do
      -- allow_localhost = true, no file, no default: `local` is selectable but
      -- nothing names it as the default. The operator is asked to choose.
      let reg = registryWithLocalAnd' Nothing []
      machineForSession reg metaWithNothing `shouldBe` Left MachineDefaultUnset

    prop "a rejected machine never reports as MachineGone" $
      forAll (elements allRejectReasons) $ \reason ->
        let reg = registryRejecting "m" reason
        in case machineForSession reg (metaWith "m") of
             Left (MachineGone _) -> False
             _                    -> True

    prop "a resolved machine is always a member of regMachines" $ do
      let reg = registryWithLocalAnd "builder"
          choices = [metaWith "builder", metaWith "local", metaWithNothing]
      forAll (elements choices) $ \meta ->
        case machineForSession reg meta of
          Right (nm, _) -> Map.member nm (regMachines reg)
          Left _        -> True

  describe "renderMachineConfigError" $ do
    it "T-STR-4: names the configured host exactly as written, for a loopback machine" $ do
      renderMachineConfigError (machineNamed "builder") (RrLoopbackHost "127.0.0.1")
        `shouldBe` "machines.toml: machine \"builder\" is unusable: host \
                   \\"127.0.0.1\" is this machine. A remote execution machine must \
                   \be a separate machine."

    it "does not hardcode localhost when the operator wrote something else" $ do
      let rendered = renderMachineConfigError (machineNamed "b") (RrLoopbackHost "::1")
      rendered `shouldSatisfy` Text.isInfixOf "::1"
      rendered `shouldSatisfy` not . Text.isInfixOf "localhost"

    it "renders a missing workspace" $
      renderMachineConfigError (machineNamed "b") (RrMissingField MissingWorkspace)
        `shouldBe` "machines.toml: machine \"b\" is unusable: workspace not configured."

    it "renders a missing host and a missing user distinctly" $ do
      renderMachineConfigError (machineNamed "b") (RrMissingField MissingHost)
        `shouldBe` "machines.toml: machine \"b\" is unusable: host is not configured."
      renderMachineConfigError (machineNamed "b") (RrMissingField MissingUser)
        `shouldBe` "machines.toml: machine \"b\" is unusable: user is not configured."

    it "renders an out-of-range port" $
      renderMachineConfigError (machineNamed "b") RrInvalidPort
        `shouldBe` "machines.toml: machine \"b\" is unusable: port must be between 1 and 65535."

    it "always carries the machines.toml: prefix" $
      forAll (elements allRejectReasons) $ \reason ->
        renderMachineConfigError (machineNamed "b") reason
          `shouldSatisfy` Text.isPrefixOf "machines.toml: "

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

allRejectReasons :: [RejectReason]
allRejectReasons =
  [ RrMissingField MissingHost
  , RrMissingField MissingUser
  , RrMissingField MissingWorkspace
  , RrLoopbackHost "127.0.0.1"
  , RrInvalidHost "bad host"
  , RrInvalidWorkspace "bad ws"
  , RrInvalidPort
  , RrReservedName
  , RrInvalidName "bad name"
  ]

testPaths :: SealPaths
testPaths = SealPaths
  { spHome = "/home/_testseal"
  , spConfig = "/home/_testseal/config"
  , spState = "/home/_testseal/state"
  , spKeys = "/home/_testseal/keys"
  , spCache = "/home/_testseal/cache"
  }

machineNamed :: Text -> MachineName
machineNamed t = case mkMachineName t of
  Right n  -> n
  Left why -> error ("MachineSpec fixture: " <> Text.unpack why)

goodFile :: MachineFileConfig
goodFile = MachineFileConfig
  { mfcHost = Just "builder.example.com"
  , mfcUser = Just "seal"
  , mfcPort = Just 22
  , mfcIdentity = Nothing
  , mfcWorkspace = Just "/srv/seal/workspace"
  }

-- | A local-permitting registry with one named machine, which is also the default.
registryWithLocalAnd :: Text -> MachineRegistry
registryWithLocalAnd name =
  resolveMachines True testPaths MachinesConfig
    { mcDefault = Just name
    , mcMachines = Map.fromList [(name, goodFile)]
    }

registryWithLocalAnd' :: Maybe Text -> [Text] -> MachineRegistry
registryWithLocalAnd' def names =
  resolveMachines True testPaths MachinesConfig
    { mcDefault = def
    , mcMachines = Map.fromList [(n, goodFile) | n <- names]
    }

-- | allow_localhost = false, so `local` is absent from the registry.
registryWithoutLocal :: [Text] -> MachineRegistry
registryWithoutLocal names =
  resolveMachines False testPaths MachinesConfig
    { mcDefault = Nothing
    , mcMachines = Map.fromList [(n, goodFile) | n <- names]
    }

-- | A registry where one machine is present but rejected, and local is allowed.
--
-- The machine is removed from 'regMachines': that is what "rejected" means, and
-- leaving it in both maps would make the fixture assert a state the resolver
-- cannot produce.
registryRejecting :: Text -> RejectReason -> MachineRegistry
registryRejecting name reason =
  let base = resolveMachines True testPaths MachinesConfig
               { mcDefault = Nothing
               , mcMachines = Map.fromList [(name, goodFile)]
               }
  in base { regMachines = Map.delete (nameToMachine name) (regMachines base)
          , regRejected = Map.fromList [(nameToMachine name, reason)]
          }

-- | The session records a machine by name. `local` cannot go through
-- 'mkMachineName' — it is reserved, which is the whole point of the constructor
-- — so the reserved name comes from 'localMachineName'.
metaWith :: Text -> SessionMeta
metaWith name = metaWithNothing { smMachine = Just (nameToMachine name) }

nameToMachine :: Text -> MachineName
nameToMachine name
  | name == "local" = localMachineName
  | otherwise       = machineNamed name

metaWithNothing :: SessionMeta
metaWithNothing = SessionMeta
  { smId         = mkSystemSessionId "machine-spec"
  , smProvider   = "anthropic"
  , smModel      = "claude-opus-4-8"
  , smChannel    = "cli"
  , smParent     = Nothing
  , smAgent      = Nothing
  , smSystemOverride = Nothing
  , smAgentName  = Nothing
  , smDescription = Nothing
  , smSealFrontMatter = True
  , smRepoUrl    = Nothing
  , smRepoBranch = Nothing
  , smMachine    = Nothing
  , smCreatedAt  = fixtureTime
  , smLastActive = fixtureTime
  }

fixtureTime :: UTCTime
fixtureTime = UTCTime (fromGregorian 2026 11 27) (secondsToDiffTime 0)
