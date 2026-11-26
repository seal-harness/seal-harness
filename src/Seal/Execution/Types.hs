{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @multiple execution machines@ vocabulary: a validated machine name,
-- the validated coordinates of an SSH machine, the resolution result and the
-- errors resolution can produce.
--
-- Pure and leaf-like by design (design rev 10 §6.5): it imports
-- 'Seal.Tools.Exec.Types' for 'SshConfig' and nothing from
-- @Seal.Config.Security@ — a signature naming a type /is/ an import, so
-- 'resolveTarget' takes a resolved 'Bool' and an 'ExecutionConfig' rather than
-- a 'SecurityConfig'.
--
-- 'MachineName' is the one name a session can be pinned to. Its constructor is
-- not exported: every consumer takes the validated form, so no code path can
-- carry an unvalidated name into an argv (AGENTS.md invariant 2).
module Seal.Execution.Types
  ( MachineName
  , mkMachineName
  , machineNameText
  , SshMachineSpec (..)
  , SshLocalPath
  , mkSshLocalPath
  , getSshLocalPath
  , ResolvedTarget (..)
  , TargetPaths (..)
  , TargetError (..)
  , renderTargetError
  , targetLabel
  , targetSshConfig
  , sshConfigFromMachine
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (isAbsolute, splitDirectories)

import Seal.Security.Path (blockedNames)
import Seal.Tools.Exec.Types
  ( RemotePath, SshConfig (..), SshHost, SshUser )

-- ---------------------------------------------------------------------------
-- MachineName
-- ---------------------------------------------------------------------------

-- | The name a session is pinned to. Charset @[A-Za-z0-9_-]@, non-empty,
-- first character alphanumeric, at most 64 characters.
--
-- @local@ / @default@ are /valid/ names here: @local@ is pinnable (§5 row 1)
-- and appears as the effective default, and defaultSessionMeta carries it. The
-- reservation is on the /TOML keys/ @[machines.local]@ / @[machines.default]@,
-- which is the codec's job (WU-2), not the newtype's.
newtype MachineName = MachineName Text
  deriving stock (Eq, Ord, Show)

mkMachineName :: Text -> Either Text MachineName
mkMachineName t
  | T.null t               = Left "machine name is empty"
  | T.length t > 64        = Left "machine name is longer than 64 characters"
  | not (isNameStart (T.head t)) =
      Left "machine name must start with a letter or digit"
  | T.any (not . isNameChar) t =
      Left "machine name may contain only letters, digits, '-' and '_'"
  | otherwise              = Right (MachineName t)
  where
    isNameStart c = isAsciiLower c || isAsciiUpper c || isDigit c
    isNameChar c  = isNameStart c || c == '-' || c == '_'

machineNameText :: MachineName -> Text
machineNameText (MachineName t) = t

-- ---------------------------------------------------------------------------
-- SshLocalPath
-- ---------------------------------------------------------------------------

-- | An absolute local path used in the generated ssh argv (@identity@,
-- @known_hosts@). Smart-constructed for the reasons in design §3.2/§6.2:
--
--   * a POSIX-legal path containing a space smuggles a second @-o@ directive
--     into @UserKnownHostsFile=@ — so whitespace and @=@ are rejected. This is
--     an argv-injection guard, not tidiness;
--   * @..@ would escape the directory the operator named;
--   * 'blockedNames' segments are rejected /except/ @.ssh@ and @.seal@ — keys
--     legitimately live under both.
newtype SshLocalPath = SshLocalPath FilePath
  deriving stock (Eq, Ord, Show)

mkSshLocalPath :: Text -> Either Text SshLocalPath
mkSshLocalPath t
  | T.null t                     = Left "path is empty"
  | not (isAbsolute p)           = Left "path must be absolute"
  | ".." `elem` segments         = Left "path must not contain '..'"
  | T.any isSpace t              = Left "path must not contain whitespace"
  | T.any (== '=') t             = Left "path must not contain '='"
  | any isBlocked segments       = Left "path may not name a blocked directory"
  | otherwise                    = Right (SshLocalPath p)
  where
    p        = T.unpack t
    segments = splitDirectories p
    -- .ssh/.seal are where keys live, so they are explicitly allowed.
    isBlocked s = s `elem` blockedNames && s /= ".ssh" && s /= ".seal"

getSshLocalPath :: SshLocalPath -> FilePath
getSshLocalPath (SshLocalPath p) = p

-- ---------------------------------------------------------------------------
-- SshMachineSpec
-- ---------------------------------------------------------------------------

-- | One machine's validated coordinates. Every field is a validated newtype —
-- none is a bare 'FilePath' — so a decoded spec can reach argv without a
-- second check. Field prefix @sms@, matching @scHost@ / @naProvider@.
data SshMachineSpec = SshMachineSpec
  { smsHost       :: SshHost
  , smsUser       :: SshUser
  , smsPort       :: Int
  , smsIdentity   :: Maybe SshLocalPath  -- ^ 'Nothing' means ssh-agent.
  , smsKnownHosts :: SshLocalPath
  , smsWorkspace  :: RemotePath
  }
  deriving stock (Eq, Ord, Show)

-- | Total: every field is already validated.
sshConfigFromMachine :: SshMachineSpec -> SshConfig
sshConfigFromMachine m = SshConfig
  { scHost       = smsHost m
  , scUser       = smsUser m
  , scPort       = smsPort m
  , scIdentity   = getSshLocalPath <$> smsIdentity m
  , scKnownHosts = getSshLocalPath (smsKnownHosts m)
  , scWorkspace  = smsWorkspace m
  }

-- ---------------------------------------------------------------------------
-- ResolvedTarget
-- ---------------------------------------------------------------------------

-- | Where a session's untrusted code runs, resolved. The 'Ord' instance is
-- what a per-session exec cache keys on (WU-5) — it needs 'Ord' on
-- 'SshConfig', which WU-1 adds.
data ResolvedTarget
  = WhereLocal
  | WhereSsh MachineName SshConfig
  deriving stock (Eq, Ord, Show)

targetLabel :: ResolvedTarget -> Text
targetLabel = \case
  -- The browser may be on a different box than the gateway, so bare "Local"
  -- is ambiguous about whose local. Same string as the picker option (WU-7b).
  WhereLocal     -> "This machine (where Seal runs)"
  WhereSsh n _   -> machineNameText n

targetSshConfig :: ResolvedTarget -> Maybe SshConfig
targetSshConfig = \case
  WhereLocal   -> Nothing
  WhereSsh _ c -> Just c

-- ---------------------------------------------------------------------------
-- TargetError
-- ---------------------------------------------------------------------------

-- | Paths a rendering may name. Supplied by the caller from 'SealPaths' —
-- never literals, because everything else in this codebase honours
-- @SEAL_HOME@ and @TargetNoMachine@ is the only message a hardened install
-- ever sees.
data TargetPaths = TargetPaths
  { tpExecution :: Text   -- ^ from @executionFilePath@
  , tpSecurity  :: Text   -- ^ from @securityFilePath@
  }
  deriving stock (Eq, Show)

data TargetError
  = TargetUnknownMachine  MachineName [MachineName]
    -- ^ requested, available
  | TargetLocalNotAllowed MachineName
    -- ^ the name runs on this host, but @allow_localhost = false@
  | TargetConfigLoadError Text
    -- ^ bad TOML / validation failure; the payload is the codec's own @Left@
  | TargetNoMachine
    -- ^ nothing may run at all
  deriving stock (Eq, Show)

-- | Total. The four renderings are pinned verbatim in design rev 10 §5.
renderTargetError :: TargetPaths -> TargetError -> Text
renderTargetError paths = \case
  TargetUnknownMachine n avail ->
    "No execution machine named \"" <> machineNameText n
      <> "\"; available: " <> renderAvailable avail
      <> ". Start a new session pinned to one of them, or add one on the "
      <> "Machines screen."

  TargetLocalNotAllowed n ->
    "machine \"" <> machineNameText n <> "\" runs on this host, but "
      <> "allow_localhost = false in " <> tpSecurity paths
      <> ". Set allow_localhost = true, or start a new session pinned elsewhere."

  TargetConfigLoadError why ->
    tpExecution paths <> ": " <> why

  TargetNoMachine ->
    "No execution machine is configured. Add one on the Machines screen, or "
      <> "add a [machines.<name>] block to " <> tpExecution paths <> ", or set "
      <> "allow_localhost = true in " <> tpSecurity paths <> "."

renderAvailable :: [MachineName] -> Text
renderAvailable []    = "none"
renderAvailable avail = T.intercalate ", " (map machineNameText avail)
