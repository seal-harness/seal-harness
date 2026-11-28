{-# LANGUAGE OverloadedStrings #-}
-- | @/machine@ — inspect and pin execution machines (WU-14).
--
-- __Operator-facing, never model-facing.__ Everything here is read by the human
-- typing the command, so it may name the machine and, for an unusable one, the
-- condition an operator has to fix in @~\/.seal\/machines.toml@. The
-- model-facing renderer ('Seal.ISA.Ops.Machine.renderMachineError') is a
-- different function with a different type, and structurally cannot print a
-- host. Keeping the two apart is the reason 'RejectReason' and
-- 'UnusableReason' are separate types rather than one with two renderings.
--
-- @/machine list@ deliberately REUSES
-- 'Seal.Session.Machine.renderMachineConfigError' rather than formatting the
-- reasons itself. A second renderer would drift from the boot report, and the
-- operator would see two different explanations of one broken machine.
module Seal.Command.Machine
  ( machineCommandSpec
  , renderMachineList
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
  ( Parser, ParserInfo, command, helper, info, progDesc, subparser, (<**>) )

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..), CommandName (..)
  , CommandSpec (..), commandAction )
import Seal.Config.Machines (MachineRegistry (..), machineNameText)
import Seal.Session.Machine (renderMachineConfigError)

-- | The @/machine@ command spec. Registered under 'GroupGeneral': a new
-- 'CommandGroup' constructor would renumber the @Enum@ and reorder @\/help@.
--
-- The registry is supplied by a reader rather than captured at construction,
-- because @machines.toml@ is re-read whenever it changes and a command bound to
-- a boot-time snapshot would report machines the operator has since removed.
machineCommandSpec :: IO MachineRegistry -> CommandSpec
machineCommandSpec loadReg = CommandSpec
  { csName         = CommandName "machine"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "List the execution machines and pin a host key"
  , csParserInfo   = machineParserInfo loadReg
  , csAvailability = AlwaysAvailable
  }

machineParserInfo :: IO MachineRegistry -> ParserInfo CommandAction
machineParserInfo loadReg =
  info (machineParser loadReg <**> helper)
    (progDesc "List the execution machines and pin a host key")

machineParser :: IO MachineRegistry -> Parser CommandAction
machineParser loadReg =
  subparser
    ( command "list"
        (info (pure listAction)
              (progDesc "List selectable, default and unusable machines"))
    )
  where
    listAction = commandAction $ \caps -> do
      reg <- loadReg
      ccSend caps =<< renderMachineList reg

-- | Render the registry for a human.
--
-- Three sections, each omitted when empty — an operator reading a clean install
-- should see one line, not three headers and nothing under them:
--
-- @
--   selectable: alpha, local
--   default: alpha
--   unusable: beta (machines.toml: machine "beta" is unusable: workspace not
--             configured.)
-- @
--
-- Coordinates are NOT rendered. 'MachineTarget' carries the host, user and
-- workspace; printing them would put the operator's SSH details in terminal
-- scrollback and in any transcript the channel records, for no diagnostic
-- value — the name is what a command takes back.
renderMachineList :: MachineRegistry -> IO Text
renderMachineList reg = pure $ T.intercalate "\n" (concat
  [ [ "selectable: " <> T.intercalate ", " (map machineNameText selectableNames) ]
      | not (null selectableNames) ]
  ++ [ "default: " <> machineNameText d | Just d <- [regDefault reg] ]
  ++ [ unusableSection | not (Map.null (regRejected reg)) ]
  )
  where
    -- Selectable = what resolution accepted, in name order. Sorted because
    -- Map.keys is already ordered and an operator scanning for a name should
    -- not have to read the whole list to find it.
    selectableNames = Map.keys (regMachines reg)

    unusableSection =
      "unusable:\n" <> T.intercalate "\n"
        [ "  " <> T.strip (renderMachineConfigError name reason)
        | (name, reason) <- Map.toList (regRejected reg) ]
