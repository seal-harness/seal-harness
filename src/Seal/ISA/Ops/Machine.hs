{-# LANGUAGE OverloadedStrings #-}
-- | Pure helpers shared by the eight machine-selectable untrusted opcodes.
--
-- This module holds /only/ pure code: parsing the optional @machine@ property
-- out of a tool-call input 'Value', rendering a 'MachineError' for the model,
-- and rendering the machine property into a tool schema. Resolution and
-- execution live in 'Seal.ISA.Dispatch'.
--
-- == Why the error rendering is here and not in the dispatcher
--
-- The frozen requirement strings are @\<OP\> failed: \<body\>@, where @\<OP\>@ is
-- the opcode name. A renderer that takes an 'OpName' can produce them; one that
-- does not cannot. Keeping it pure and separate from the dispatch path also
-- makes every frozen string an exact-equality test with no IO in the way.
--
-- == Model-facing vs operator-facing
--
-- Everything this module emits is read by the model. It may therefore name the
-- machine and nothing else about it — no host, user, path, or key. The
-- operator's boot report is a different renderer
-- (@Seal.Session.Machine.renderMachineConfigError@), which may name the
-- configured value because only a human reads it. 'UnusableReason' exists
-- precisely so that split is mechanical rather than two hand-written strings.
module Seal.ISA.Ops.Machine
  ( machineField
  , renderMachineError
  , renderUnusableReason
  , renderSelectableNames
  , machinePropertySchema
  ) where

import Data.Aeson
  ( Value (..), object, withObject, (.:?), (.=) )
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Config.Machines (MachineName, Selectable (..), machineNameText)
import Seal.Core.Types (OpName (..))
import Seal.Tools.Exec.Machine
  ( MachineError (..), UnusableReason (..)
  , UnreachableReason, renderUnreachableReason )

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

-- | Read the optional @machine@ property from a tool-call input.
--
-- 'Nothing' means the model did not name one, which resolves to the session's
-- machine. A malformed value (not a string) is also 'Nothing' rather than an
-- error: the call then runs on the session machine, which is the
-- documented default, and the schema already narrows the type.
machineField :: Value -> Maybe Text
machineField v =
  case parseMaybe (withObject "machine" (.:? "machine")) v :: Maybe (Maybe Text) of
    Just (Just t) | not (T.null (T.strip t)) -> Just t
    _                                        -> Nothing

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- | The JSON-schema fragment for the @machine@ property, given what may be
-- chosen. Rendered as an enum so the model can see the valid names rather than
-- discovering them by failing.
machinePropertySchema :: [Selectable] -> Value
machinePropertySchema selectable =
  let desc = "Execution machine to run this call on. Omit to use the session's \
             \machine. Each machine has its own filesystem, so a path written \
             \on one machine is not present on another."
  in object
       [ "type" .= ("string" :: Text)
       , "enum" .= map selectableNameText selectable
       , "description" .= (desc :: Text)
       ]

selectableNameText :: Selectable -> Text
selectableNameText SelLocal         = "local"
selectableNameText (SelMachine nm)  = machineNameText nm

-- | Comma-separated machine names, @local@ first (it is the harness machine),
-- for the "Selectable machines:" tail of the unknown-machine error.
renderSelectableNames :: [MachineName] -> Text
renderSelectableNames [] = "none"
renderSelectableNames ns = T.intercalate ", " (map machineNameText ns)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Why a machine is unusable, in the model's terms. Payload-free: the operator
-- sees the configured value, the model sees only the condition.
renderUnusableReason :: UnusableReason -> Text
renderUnusableReason = \case
  UrrMissingHost      -> "host not configured"
  UrrMissingUser      -> "user not configured"
  UrrMissingWorkspace -> "workspace not configured"
  UrrLoopbackHost     -> "its host is this machine"
  UrrInvalidHost      -> "invalid host"
  UrrInvalidWorkspace -> "invalid workspace"
  UrrInvalidPort      -> "invalid port"
  UrrReservedName     -> "reserved name"
  UrrInvalidName      -> "invalid name"

-- | Render a machine error for the model as @\<OP\> failed: \<body\>@.
--
-- The separator is a single space after the opcode name — @SHELL_EXEC failed:@,
-- not @SHELL_EXEC: failed:@. The repo's own convention inside error bodies is
-- @\<OPNAME\>: \<msg\>@, but the frozen requirement text for these particular
-- messages was written as @\<OP\> failed: \<msg\>@, and a frozen user-facing
-- string is not something a renderer may paraphrase.
renderMachineError :: OpName -> MachineError -> Text
renderMachineError (OpName op) err = op <> " failed: " <> machineErrorBody err

machineErrorBody :: MachineError -> Text
machineErrorBody = \case
  MachineUnknown requested choices ->
    "unknown execution machine \"" <> requested <> "\". Selectable machines: "
      <> renderSelectableNames choices <> "."
  MachineUnusable nm reason ->
    "execution machine \"" <> machineNameText nm <> "\" is unusable: "
      <> renderUnusableReason reason
      <> ". Fix it in ~/.seal/machines.toml."
  MachineGone nm ->
    "this session runs on execution machine \"" <> machineNameText nm
      <> "\", which is no longer configured. Resuming it on another machine "
      <> "would run its work somewhere it never ran. Add \""
      <> machineNameText nm
      <> "\" back to ~/.seal/machines.toml, or start a new session."
  MachineNotPermitted nm ->
    "execution machine \"" <> machineNameText nm <> "\" is not permitted: "
      <> "allow_localhost is false. Set allow_localhost = true in "
      <> "~/.seal/security.toml to permit local execution."
  MachineDefaultUnset ->
    "no execution machine is configured and no default is set. Add one under "
      <> "[machines.<name>] in ~/.seal/machines.toml, or start a session with "
      <> "/new -x <machine>."
  NoMachineSelected ->
    "allow_localhost is false and no execution machine is configured. Add one "
      <> "under [machines.<name>] in ~/.seal/machines.toml."
  MachineUnreachable nm reason ->
    "execution machine \"" <> machineNameText nm <> "\" is not reachable: "
      <> renderUnreachable reason <> "."
  MachineHostKeyChanged nm ->
    "host key for \"" <> machineNameText nm <> "\" does not match the key "
      <> "recorded in ~/.seal/exec-known-hosts. This can mean the machine was "
      <> "rebuilt, or that something is intercepting the connection. Seal will "
      <> "not connect. If the machine was rebuilt, remove its entry from that "
      <> "file and confirm the new key."

-- 'renderUnreachableReason' is re-exported by Machine; referenced via the import
-- above so the dependency is visible without widening this module's surface.
renderUnreachable :: UnreachableReason -> Text
renderUnreachable = renderUnreachableReason
