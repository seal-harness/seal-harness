{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | WU-4 — the model must SEE the machine names in its tool catalog.
--
-- 'machinePropertySchema' existed and was unit-tested, but had zero call sites:
-- no opcode advertised a @machine@ property. The consequence is not a crash —
-- 'resolveMachineForCall' accepts a supplied name happily — it is that the model
-- has no way to learn which names are valid except by guessing and reading the
-- error. The requirement is explicit: "The model sees the selectable machine
-- names in its tool catalog and can pick a different machine per call."
--
-- So these tests inspect the SCHEMAS the registry publishes, not the helper in
-- isolation.
module Seal.ISA.Ops.MachineSchemaSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, Selectable (..), mkMachineName)
import Seal.Gateway.Types.AllowList (AllowList (..))
import Seal.Security.Policy
  ( AutonomyLevel (..), CommandName, SecurityPolicy (..) )
import Seal.ISA.Opcode (Opcode (..), uoInSchema)
import Seal.ISA.Ops.Bin (binExecOp)
import Seal.ISA.Ops.File (filePatchOp, fileReadOp, fileWriteOp)
import Seal.ISA.Ops.Process (processManageOp)
import Seal.ISA.Ops.Repo (setupRepoOp)
import Seal.ISA.Ops.Search (searchFilesOp)
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Clone (stubCloneDeps)

spec :: Spec
spec = describe "WU-4 machine in the published opcode schemas" $ do

  describe "the eight machine-selectable opcodes advertise `machine`" $
    mapM_ advertisesMachine selectableOpNames

  describe "the advertised enum is the selectable set" $ do
    it "lists every machine name, local included when permitted" $
      machineEnum (inSchema (opFor "SHELL_EXEC" withLocal))
        `shouldBe` Just ["alpha", "local"]

    it "omits local when allow_localhost is false" $
      machineEnum (inSchema (opFor "SHELL_EXEC" withoutLocal))
        `shouldBe` Just ["alpha"]

  describe "the property is optional, never required" $ do
    it "`machine` is not in the required list of any selectable opcode" $
      [ nm | nm <- selectableOpNames
           , "machine" `elem` requiredList (inSchema (opFor nm withLocal)) ]
        `shouldBe` []

  describe "the description tells the model what omission means" $ do
    it "names the session machine as the default and warns about filesystems" $ do
      case machineDescription (inSchema (opFor "SHELL_EXEC" withLocal)) of
        Nothing -> expectationFailure "no description"
        Just d  -> do
          d `shouldSatisfy` T.isInfixOf "session"
          d `shouldSatisfy` T.isInfixOf "filesystem"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

selectableOpNames :: [Text]
selectableOpNames =
  [ "SHELL_EXEC", "BIN_EXEC", "FILE_READ", "FILE_WRITE"
  , "FILE_PATCH", "SEARCH_FILES", "PROCESS_MANAGE", "SETUP_REPO" ]

advertisesMachine :: Text -> Spec
advertisesMachine nm = it (T.unpack nm <> " has a `machine` property") $
  machineProperty (inSchema (opFor nm withLocal))
    `shouldSatisfy` (/= Nothing)

-- | Build the opcode of the given name for a two-machine selectable set.
opFor :: Text -> [Selectable] -> Opcode
opFor nm sel = case nm of
  "SHELL_EXEC"     -> shellExecOp (WorkspaceRoot ".") allowAll sel
  "BIN_EXEC"       -> binExecOp (WorkspaceRoot ".") allowAll Nothing sel
  "FILE_READ"      -> fileReadOp (WorkspaceRoot ".") 100000 sel
  "FILE_WRITE"     -> fileWriteOp (WorkspaceRoot ".") 100000 sel
  "FILE_PATCH"     -> filePatchOp (WorkspaceRoot ".") sel
  "SEARCH_FILES"   -> searchFilesOp (WorkspaceRoot ".") allowAll 1000 sel
  "PROCESS_MANAGE" -> processManageOp (WorkspaceRoot ".") allowAll sel
  "SETUP_REPO"     -> setupRepoOp stubCloneDeps Full sel
  other            -> error ("opFor: no fixture for " <> T.unpack other)

allowAll :: SecurityPolicy
allowAll = SecurityPolicy (AllowAll :: AllowList CommandName) Full

withLocal :: [Selectable]
withLocal = [SelMachine (machine "alpha"), SelLocal]

withoutLocal :: [Selectable]
withoutLocal = [SelMachine (machine "alpha")]

machine :: Text -> MachineName
machine t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("fixture: " <> T.unpack e)

properties :: Value -> Maybe Value
properties (Object o) = KeyMap.lookup (Key.fromText "properties") o
properties _          = Nothing

machineProperty :: Value -> Maybe Value
machineProperty schema = case properties schema of
  Just (Object o) -> KeyMap.lookup (Key.fromText "machine") o
  _               -> Nothing

machineEnum :: Value -> Maybe [Text]
machineEnum schema = case machineProperty schema of
  Just (Object o) -> case KeyMap.lookup (Key.fromText "enum") o of
    Just (Array xs) -> traverse (\case String t -> Just t; _ -> Nothing)
                          (foldr (:) [] xs)
    _               -> Nothing
  _               -> Nothing

machineDescription :: Value -> Maybe Text
machineDescription schema = case machineProperty schema of
  Just (Object o) -> case KeyMap.lookup (Key.fromText "description") o of
    Just (String d) -> Just d
    _               -> Nothing
  _               -> Nothing

requiredList :: Value -> [Text]
requiredList (Object o) = case KeyMap.lookup (Key.fromText "required") o of
  Just (Array xs) -> [ t | String t <- foldr (:) [] xs ]
  _               -> []
requiredList _ = []

inSchema :: Opcode -> Value
inSchema = uoInSchema
