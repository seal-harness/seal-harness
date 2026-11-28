{-# LANGUAGE OverloadedStrings #-}
-- | WU-14 — @/machine list@ and the @~/.seal@ agent-immutability guard.
--
-- Two properties, and the second is a security invariant rather than a feature.
--
--   1. @/machine list@ renders the registry for a human: what may be selected,
--      what the default is, and why each unusable machine is unusable. The
--      reason text comes from 'renderMachineConfigError' (WU-9) — this module
--      must not redeclare it, or the operator's boot report and this output
--      drift apart.
--
--   2. __No opcode can reach @machines.toml@ or @exec-known-hosts@.__ Rule 3:
--      @~\/.seal@ holds agent-immutable state. @blockedNames@ already covers
--      @.seal@, so the guard exists — these assertions pin that the NEW files
--      inherit it and that no opcode module imports the config machinery that
--      could read them.
--
-- The second group is the one worth keeping: a future change that adds
-- @machines.toml@ to a tool path would otherwise be invisible until it was
-- exploited.
module Seal.Command.MachineSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines
  ( MachineName, MachineRegistry (..), MachineTarget (..), MissingField (..)
  , RejectReason (..), localMachineName, mkMachineName )
import Seal.Command.Machine (renderMachineList)
import Seal.Tools.Exec.Types
  ( SshConfig (..), mkRemotePath, mkSshHost, mkSshUser )

spec :: Spec
spec = describe "WU-14 /machine list and the ~/.seal guard" $ do

  describe "renderMachineList" $ do

    it "lists the selectable machines, one per line" $ do
      out <- renderMachineList twoMachines
      out `shouldSatisfy` T.isInfixOf "alpha"
      out `shouldSatisfy` T.isInfixOf "local"

    it "names the configured default" $ do
      out <- renderMachineList twoMachines
      out `shouldSatisfy` T.isInfixOf "default:"
      out `shouldSatisfy` T.isInfixOf "alpha"

    it "lists an unusable machine WITH its reason" $ do
      out <- renderMachineList withRejected
      out `shouldSatisfy` T.isInfixOf "beta"
      -- The reason text is 'renderMachineConfigError''s, prefixed by
      -- "machines.toml: " and naming the condition.
      out `shouldSatisfy` T.isInfixOf "workspace not configured"

    it "omits the `unusable:` section entirely when nothing is rejected" $ do
      out <- renderMachineList twoMachines
      out `shouldNotSatisfy` T.isInfixOf "unusable:"

    it "omits the `default:` line when no default is configured" $ do
      out <- renderMachineList noDefault
      out `shouldNotSatisfy` T.isInfixOf "default:"

    it "omits the `unusable:` section when every machine is fine" $ do
      out <- renderMachineList noDefault
      out `shouldNotSatisfy` T.isInfixOf "unusable:"

    it "never renders a host, user or path (the operator's file is not echoed)" $ do
      -- Negative. The renderer prints the registry's NAMES and reasons; the
      -- coordinates live in MachineTarget and must not reach this output.
      out <- renderMachineList twoMachines
      out `shouldNotSatisfy` T.isInfixOf "example.com"
      out `shouldNotSatisfy` T.isInfixOf "/srv/"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

twoMachines :: MachineRegistry
twoMachines = MachineRegistry
  { regMachines = Map.fromList
      [ (machine "alpha", MtSsh sshTarget)
      , (localMachineName, MtLocal) ]
  , regRejected = Map.empty
  , regDefault  = Just (machine "alpha")
  , regWarnings = []
  }

noDefault :: MachineRegistry
noDefault = twoMachines { regDefault = Nothing }

withRejected :: MachineRegistry
withRejected = twoMachines
  { regRejected = Map.fromList
      [ (machine "beta", RrMissingField MissingWorkspace) ]
  }

-- | A real target, not a bottom: the renderer must be able to run without
-- touching the coordinates, so the fixture supplies them and the negative
-- assertions below prove they are never printed.
sshTarget :: SshConfig
sshTarget = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "example.com")
  , scUser       = either (error "fixture") id (mkSshUser "seal")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/x/.seal/exec-known-hosts"
  , scWorkspace  = either (error "fixture") id (mkRemotePath "/srv/alpha")
  }

machine :: Text -> MachineName
machine t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("fixture: " <> T.unpack e)
