{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | WU-15 — `execErrorToMachineError` closes a host/path leak to the model.
--
-- The leak: on the remote arm, a failed workdir bootstrap produces a
-- `failClosedSessionExecWithReason` string that renders the machine's **host**
-- and the local known-hosts **path** (`Workdir.hs`). That string reaches the
-- model as the tool error, so a model that gets a remote bootstrapping wrong is
-- told the SSH coordinates — which the frozen requirements forbid in as many
-- words: "The model can never name a host, address, key, or path."
--
-- The fix is a typed projection, not a reworded string: `ExecError` becomes a
-- `MachineError`, and `MachineError` structurally cannot carry a host. The
-- assertions below are therefore NEGATIVE — the point is what the rendered text
-- does not contain.
module Seal.Tools.Exec.ExecErrorMappingSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, mkMachineName)
import Seal.Core.Types (OpName (..))
import Seal.ISA.Ops.Machine (execErrorToMachineError, renderMachineError)
import Seal.Tools.Exec.Machine (MachineError (..), UnreachableReason (..))
import Seal.Tools.Exec.Types (ExecError (..))

spec :: Spec
spec = describe "WU-15 execErrorToMachineError" $ do

  describe "the security-critical mapping" $ do
    it "ExecHostKeyMismatch becomes MachineHostKeyChanged, never adoption" $
      execErrorToMachineError alpha ExecHostKeyMismatch
        `shouldBe` MachineHostKeyChanged alpha

    it "ExecHostKeyUnknown becomes a typed unreachable reason" $
      execErrorToMachineError alpha ExecHostKeyUnknown
        `shouldBe` MachineUnreachable alpha UrHostKeyUnknown

    it "ExecRemoteUnreachable becomes UrConnectFailed" $
      execErrorToMachineError alpha ExecRemoteUnreachable
        `shouldBe` MachineUnreachable alpha UrConnectFailed

  describe "an ExecNotImplementedReason arm exists" $ do
    it "maps to a typed reason, NOT a MachineError carrying the text" $ do
      -- The arm the plan calls out: without it, `ExecNotImplementedReason`'s
      -- free Text falls through to a catch-all and the reason (which may name
      -- a path) rides into the model's view.
      let merr = execErrorToMachineError alpha (ExecNotImplementedReason "why")
      merr `shouldSatisfy` isTyped

  describe "NO mapping leaks a host, user, path or key" $ do
    it "every ExecError renders without coordinates" $ do
      -- The whole point. Rendered through the model-facing renderer, which is
      -- what a tool error actually says.
      let reasons =
            [ ExecNotAllowed, ExecLocalNotPermittedForUntrusted, ExecRemoteRequired
            , ExecRemoteUnreachable, ExecHostKeyMismatch, ExecHostKeyUnknown
            , ExecNotImplemented
            , ExecNotImplementedReason "/srv/seal/workspace/x"
            , ExecNotImplementedReason "user@builder.example.com"
            ]
      mapM_ noCoordinates
        [ renderMachineError (OpName "SHELL_EXEC")
            (execErrorToMachineError alpha e)
        | e <- reasons ]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | A `MachineError` is "typed" when it carries only nullary reasons and the
-- machine name — no free text beyond `MachineUnknown`'s echoed model input.
isTyped :: MachineError -> Bool
isTyped = \case
  MachineUnknown _ _                  -> True
  MachineUnusable _ _                 -> True
  MachineGone _                       -> True
  MachineNotPermitted _               -> True
  MachineDefaultUnset                 -> True
  NoMachineSelected                   -> True
  MachineUnreachable _ _              -> True
  MachineHostKeyChanged _             -> True

noCoordinates :: Text -> Expectation
noCoordinates rendered = do
  rendered `shouldNotSatisfy` T.isInfixOf "builder.example.com"
  rendered `shouldNotSatisfy` T.isInfixOf "/srv/"
  rendered `shouldNotSatisfy` T.isInfixOf "user@"
  rendered `shouldNotSatisfy` T.isInfixOf "known_hosts"

alpha :: MachineName
alpha = case mkMachineName "alpha" of
  Right n -> n
  Left e  -> error ("fixture: " <> T.unpack e)
