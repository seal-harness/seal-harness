{-# LANGUAGE OverloadedStrings #-}
-- | The @machines.toml@ execution-machine registry: the named machines
-- untrusted opcodes may run on, plus the pure resolution from the file's
-- (mostly-optional) shape to a validated 'MachineRegistry'.
--
-- __Boot-only and agent-immutable.__ The file is a sibling of @security.toml@
-- under @~\/.seal/@, created @0600@, and no opcode may read or write it. This
-- module is therefore imported by boot, migration and the human-driven
-- @seal machine@ command — never by @Seal.ISA.Ops.*@. The
-- @CapabilityScopingWorkdirFsFailSpec@ guard asserts that mechanically.
--
-- == Why resolution is pure
--
-- 'resolveMachines' takes @allow_localhost@, the 'SealPaths' and the decoded
-- 'MachinesConfig' as arguments and performs no IO. That keeps two config files
-- ('security.toml' for the flag, 'machines.toml' for the machines) independently
-- testable, and makes every refusal directly assertable without a boot.
--
-- == "Configured but unusable"
--
-- A machine may be present in the file and still not selectable (a missing
-- field, a loopback host, a reserved name). Those land in 'regRejected' with a
-- typed reason rather than being dropped silently, because the operator must be
-- able to see why — and because the model-facing and operator-facing renderings
-- of that reason differ (model sees the field name only, operator sees the
-- value; see @Seal.ISA.Ops.Machine.renderMachineError@).
module Seal.Config.Machines
  ( MachineName
  , mkMachineName
  , machineNameText
  , MachinesConfig (..)
  , MachineFileConfig (..)
  , defaultMachinesConfig
  , MachinesConfigError (..)
  , decodeMachinesConfig
  , machinesConfigCodec
  , MachineTarget (..)
  , MissingField (..)
  , RejectReason (..)
  , MachineRegistry (..)
  , emptyRegistry
  , resolveMachines
  , isLoopbackHost
  , localMachineName
  ) where

import Data.Char (isAscii, isAlphaNum, isControl, isDigit)
import Data.Maybe (fromMaybe)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Validation (Validation (..))
import Data.Text (Text)
import Data.Text qualified as T
import Toml (TomlCodec, (.=))
import Toml qualified

import Seal.Config.Paths (SealPaths, execKnownHostsPath)
import Seal.Tools.Exec.Types
  ( SshConfig (..), mkSshHost, mkSshUser, mkRemotePath )

-- ---------------------------------------------------------------------------
-- MachineName
-- ---------------------------------------------------------------------------

-- | A validated execution-machine name. Smart-constructed: the constructor is
-- not exported, so a name from the model or from the TOML file can only become
-- a 'MachineName' by passing 'mkMachineName'.
--
-- The charset is deliberately conservative — ASCII alphanumerics plus @-@, @_@
-- and @.@ — because a name is simultaneously a TOML key, a @\/new -x@ value, a
-- JSON-schema enum member, transcript metadata and a field in @session.json@.
-- ASCII-only also removes any NFC-normalisation mismatch between the file and a
-- model-supplied string.
newtype MachineName = MachineName Text
  deriving stock (Eq, Ord, Show)

-- | The reserved name for the harness machine itself. Never constructible via
-- 'mkMachineName' — the implicit local machine is injected by resolution
-- ('resolveMachines'), so no file can shadow it.
localMachineName :: MachineName
localMachineName = MachineName "local"

machineNameText :: MachineName -> Text
machineNameText (MachineName t) = t

-- | Maximum name length. Long enough for any real host-derived label, short
-- enough that a name is unambiguous in a schema enum.
maxMachineNameLength :: Int
maxMachineNameLength = 64

mkMachineName :: Text -> Either Text MachineName
mkMachineName t
  | T.null t =
      Left "machine name is empty"
  | T.length t > maxMachineNameLength =
      Left ("machine name is longer than " <> T.pack (show maxMachineNameLength) <> " characters")
  | t == "local" =
      Left "machine name \"local\" is reserved for the harness machine"
  | t == "." || t == ".." =
      Left "machine name must not be \".\" or \"..\""
  | T.head t == '-' =
      Left "machine name must not start with '-'"
  | T.head t == '.' =
      Left "machine name must not start with '.'"
  | T.any isBad t =
      Left "machine name has invalid characters"
  | otherwise =
      Right (MachineName t)
  where
    -- Reject anything outside [A-Za-z0-9._-]. isControl covers \t,\n; the
    -- isAscii/isAlphaNum test plus the explicit punctuation set rejects spaces,
    -- slashes and non-ASCII.
    isBad c = isControl c || not (isAscii c) || not (ok c)
    ok c = isAlphaNum c || c == '-' || c == '_' || c == '.'

-- ---------------------------------------------------------------------------
-- The file's shape
-- ---------------------------------------------------------------------------

-- | The whole @machines.toml@ document. Both fields are optional, so an absent
-- or empty file decodes to an empty registry rather than an error.
data MachinesConfig = MachinesConfig
  { mcDefault  :: !(Maybe Text)
    -- ^ Name of the machine used when the operator does not choose one.
    -- Deliberately 'Text', not 'MachineName': validation happens during
    -- resolution so a bad default is a reported warning rather than a decode
    -- failure that would make the whole file unusable.
  , mcMachines :: !(Map Text MachineFileConfig)
    -- ^ Keyed by raw text for the same reason — 'mkMachineName' runs in
    -- resolution, so one bad key does not discard the other machines.
  } deriving stock (Eq, Show)

defaultMachinesConfig :: MachinesConfig
defaultMachinesConfig = MachinesConfig Nothing Map.empty

-- | One @[machines.\<name\>]@ table. Every field is optional at the TOML layer;
-- resolution reports which required ones are missing. Fields stay lazy 'Maybe's
-- to match the sibling codec records in this tree (e.g. the pre-split
-- @[untrusted_execution.remote]@ table).
data MachineFileConfig = MachineFileConfig
  { mfcHost      :: Maybe Text
  , mfcUser      :: Maybe Text
  , mfcPort      :: Maybe Int
  , mfcIdentity  :: Maybe FilePath
  , mfcWorkspace :: Maybe Text
  } deriving stock (Eq, Show)

-- | A decode failure. Kept as a small ADT so the caller can render the
-- tomland diagnostics verbatim (the security config does the same).
newtype MachinesConfigError
  = MceParse Text
  deriving stock (Eq, Show)

-- | Decode @machines.toml@ contents. An empty document yields
-- 'defaultMachinesConfig'.
decodeMachinesConfig :: Text -> Either MachinesConfigError MachinesConfig
decodeMachinesConfig input =
  case Toml.parse input of
    Left err -> Left (MceParse (T.pack (show err)))
    Right toml ->
      case Toml.runTomlCodec machinesConfigCodec toml of
        Failure errs -> Left (MceParse (T.pack (show errs)))
        Success cfg  -> Right cfg

machinesConfigCodec :: TomlCodec MachinesConfig
machinesConfigCodec = MachinesConfig
  <$> Toml.dioptional (Toml.text "default") .= mcDefault
  <*> Toml.tableMap Toml._KeyText (Toml.table machineFileCodec) "machines"
        .= mcMachines

machineFileCodec :: TomlCodec MachineFileConfig
machineFileCodec = MachineFileConfig
  <$> Toml.dioptional (Toml.text "host")       .= mfcHost
  <*> Toml.dioptional (Toml.text "user")       .= mfcUser
  <*> Toml.dioptional (Toml.int "port")        .= mfcPort
  <*> Toml.dioptional (Toml.string "identity") .= mfcIdentity
  <*> Toml.dioptional (Toml.text "workspace")  .= mfcWorkspace

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

-- | A selectable machine. 'MtSsh' carries no name — the name is the key of the
-- 'regMachines' map, so a target cannot disagree with the key it was found
-- under.
data MachineTarget
  = MtLocal
  | MtSsh !SshConfig
  deriving stock (Eq, Show)

-- | Which required field a machine is missing.
data MissingField
  = MissingHost
  | MissingUser
  | MissingWorkspace
  deriving stock (Eq, Show)

-- | Why a configured machine is not selectable. Typed rather than 'Text' so the
-- operator-facing rendering (which may name the value) and the model-facing
-- rendering (which may name only the field) are two mechanical projections of
-- one value instead of two hand-written strings that can drift.
data RejectReason
  = RrMissingField !MissingField
  | RrLoopbackHost !Text
    -- ^ Carries the host the operator actually wrote, so @127.0.0.1@ renders as
    -- @127.0.0.1@ rather than a hardcoded @localhost@.
  | RrInvalidHost !Text
  | RrInvalidWorkspace !Text
  | RrInvalidPort
  | RrReservedName
  | RrInvalidName !Text
  deriving stock (Eq, Show)

data MachineRegistry = MachineRegistry
  { regMachines :: !(Map MachineName MachineTarget)
    -- ^ Selectable machines. Includes the implicit local when permitted.
  , regRejected :: !(Map MachineName RejectReason)
    -- ^ Configured but unusable, with the reason.
  , regDefault  :: !(Maybe MachineName)
    -- ^ The configured default, only when it names a selectable machine.
  , regWarnings :: ![Text]
    -- ^ Diagnostics a pure resolver cannot log. The boot path prints them;
    -- tests assert on them.
  } deriving stock (Eq, Show)

emptyRegistry :: MachineRegistry
emptyRegistry = MachineRegistry Map.empty Map.empty Nothing []

-- | Resolve the decoded file plus @allow_localhost@ into the registry the
-- dispatcher and session layer consume. Pure.
--
-- Rules, in order (the order matters for the operator's error message):
--
--   1. Validate the name. A name that fails 'mkMachineName' — or that is the
--      reserved @local@ — is rejected with 'RrInvalidName' / 'RrReservedName'.
--   2. __Loopback guard before host validation.__ A loopback @host@ yields
--      'RrLoopbackHost' carrying the configured text, so the operator sees
--      "host \"localhost\" is this machine" rather than the generic
--      "invalid characters" that 'mkSshHost' would produce.
--   3. Field validation: required @host@/@user@/@workspace@, then @port@ range,
--      then the smart constructors.
--   4. Inject the implicit local machine iff @allow_localhost@.
--   5. Resolve @default@; a default naming no selectable machine is dropped with
--      a warning rather than failing the boot.
resolveMachines
  :: Bool               -- ^ @allow_localhost@
  -> SealPaths          -- ^ for the harness-owned @exec-known-hosts@ path
  -> MachinesConfig
  -> MachineRegistry
resolveMachines allowLocalhost paths cfg =
  let (machines, rejected) = foldl' step (Map.empty, Map.empty)
                               (Map.toList (mcMachines cfg))

      -- The implicit local machine. Injected AFTER the file's entries so a
      -- [machines.local] table cannot shadow it (it is rejected above).
      machinesWithLocal
        | allowLocalhost = Map.insert localMachineName MtLocal machines
        | otherwise      = machines

      localWarnings
        | Map.member localMachineName rejected =
            [ "machines.toml: the \"local\" machine is implicit; the "
                <> "[machines.local] table was ignored. Use allow_localhost in "
                <> "security.toml to permit local execution." ]
        | otherwise = []

      (mDef, defWarnings) = resolveDefault (mcDefault cfg) machinesWithLocal rejected

      step (ok, bad) (rawName, mfc) =
        case mkMachineName rawName of
          Left why -> (ok, Map.insert (MachineName rawName) (RrInvalidName why) bad)
          Right name ->
            case resolveMachine paths name mfc of
              Right target -> (Map.insert name target ok, bad)
              Left reason  -> (ok, Map.insert name reason bad)
  in MachineRegistry
       { regMachines = machinesWithLocal
       , regRejected = rejected
       , regDefault  = mDef
       , regWarnings = localWarnings <> defWarnings
       }

-- | Resolve one machine's fields. 'Left' is a rejection reason, not a failure.
resolveMachine :: SealPaths -> MachineName -> MachineFileConfig -> Either RejectReason MachineTarget
resolveMachine paths _name mfc =
  case mfcHost mfc of
    Nothing -> Left (RrMissingField MissingHost)
    Just hostText
      -- Rule 2: loopback BEFORE any host validation, so the message names the
      -- condition the operator can act on.
      | isLoopbackHost hostText -> Left (RrLoopbackHost hostText)
      | otherwise -> case mfcUser mfc of
          Nothing -> Left (RrMissingField MissingUser)
          Just userText -> case mfcWorkspace mfc of
            Nothing -> Left (RrMissingField MissingWorkspace)
            Just wsText ->
              let port = fromMaybe 22 (mfcPort mfc)
              in if port < 1 || port > 65535
                   then Left RrInvalidPort
                   else case (mkSshHost hostText, mkSshUser userText, mkRemotePath wsText) of
                     (Left why, _, _) -> Left (RrInvalidHost why)
                     (_, Left why, _) -> Left (RrInvalidHost why)
                     (_, _, Left why) -> Left (RrInvalidWorkspace why)
                     (Right host, Right user, Right ws) ->
                       Right (MtSsh SshConfig
                         { scHost       = host
                         , scUser       = user
                         , scPort       = port
                         , scIdentity   = mfcIdentity mfc
                         , scKnownHosts = execKnownHostsPath paths
                         , scWorkspace  = ws
                         })

-- | Resolve @default@. Only a name that is actually selectable survives;
-- anything else is dropped with a warning, because a broken default must not
-- stop the harness booting (the machines are still usable explicitly).
resolveDefault
  :: Maybe Text
  -> Map MachineName MachineTarget
  -> Map MachineName RejectReason
  -> (Maybe MachineName, [Text])
resolveDefault Nothing _ _ = (Nothing, [])
resolveDefault (Just rawName) machines rejected =
  case mkMachineName rawName of
    Left why ->
      (Nothing, ["machines.toml: default = \"" <> rawName <> "\" is not a valid machine name: " <> why])
    Right name
      | Map.member name machines -> (Just name, [])
      | Map.member name rejected ->
          (Nothing, ["machines.toml: default = \"" <> rawName
                       <> "\" names a machine that is not usable; no default selected."])
      | otherwise ->
          (Nothing, ["machines.toml: default = \"" <> rawName
                       <> "\" names no configured machine; no default selected."])

-- | Does this host text denote the harness machine? Used at config load for the
-- obvious cases; the connect-time host-key comparison is the authoritative
-- check for a name that merely resolves here.
--
-- Covers @localhost@, the whole @127.0.0.0\/8@ block, IPv6 loopback with and
-- without brackets, and the unspecified addresses (@0.0.0.0@, @::@), which are
-- refused because a wildcard is never a specific remote machine.
isLoopbackHost :: Text -> Bool
isLoopbackHost raw =
  let h = T.toLower (T.strip raw)
      unbracketed = T.dropAround (\c -> c == '[' || c == ']') h
  in h == "localhost"
     || h == "::1"
     || h == "::"
     || h == "0.0.0.0"
     || unbracketed == "::1"
     || unbracketed == "::"
     || isIpv4Loopback unbracketed
  where
    -- 127.x.y.z, including the shorthand 127.1
    isIpv4Loopback t =
      case T.splitOn "." t of
        ("127" : rest) -> not (null rest) && all isOctet rest
        _              -> False
    isOctet o = not (T.null o) && T.all isDigit o
