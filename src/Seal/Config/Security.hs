{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The security-critical, boot-only configuration that lives in
-- @~\/.seal\/security.toml@ — a separate file from @config.toml@ (which holds
-- the agent/operator-tunable 'RuntimeConfig'). This file is read once at boot
-- and never re-read; it is not exposed via any opcode or the HTTP Gateway.
--
-- Moving @untrusted_execution@ and the vault settings here means a future
-- @CONFIG_UPDATE@ opcode (which operates on 'RuntimeConfig') and the Gateway's
-- @updateRuntimeConfig@ caller physically cannot express a change to these
-- fields — the type split makes it a compile error (design §4 Approach E).
--
-- Every field is optional; a missing key decodes as 'Nothing' and a
-- 'Nothing' value is omitted from the encoded output.
module Seal.Config.Security
  ( SecurityConfig (..)
  , UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..)
  , defaultSecurityConfig
  , securityConfigCodec
  , loadSecurityConfig
  , saveSecurityConfig
  , updateSecurityConfig
  , untrustedExecConfigFromSecurity
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (setFileMode)
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified

import Seal.Tools.Exec.Types
  ( SshConfig (..), mkSshHost, mkSshUser, mkRemotePath )
import Seal.Tools.Exec.Untrusted
  ( UntrustedExecConfig (..), UntrustedExecMode (..) )

-- | The boot-only, agent-immutable security configuration. Carries the
-- @untrusted_execution@ section (remote-only enforcement) and the vault
-- settings. Loaded once at boot from @security.toml@; never passed to any
-- opcode or the Gateway.
data SecurityConfig = SecurityConfig
  { scVaultPath :: Maybe Text
    -- ^ Absolute path to the vault file (default: @~\/.seal\/config\/vault\/vault.age@).
  , scVaultRecipient :: Maybe Text
    -- ^ age public key: @age1…@ or @age1yubikey1…@.
  , scVaultIdentity :: Maybe Text
    -- ^ Path to the identity file under @keys\/@, or a user-supplied path.
  , scVaultUnlock :: Maybe Text
    -- ^ @\"startup\"@ | @\"on_demand\"@ | @\"per_access\"@.
  , scVaultKeyType :: Maybe Text
    -- ^ Display label: @\"x25519\"@ | @\"yubikey\"@ | @\"user\"@.
  , scUntrustedExec :: Maybe UntrustedExecFileConfig
    -- ^ Optional @[untrusted_execution]@ section (remote-only untrusted
    -- execution). Absent means @mode=local@ (default). @mode=remote@
    -- fail-closes at call time when the remote block is absent or
    -- unreachable (boot still succeeds).
  } deriving stock (Eq, Show)

-- | The @[untrusted_execution]@ section (spec §3 Layer A). @mode@ is
-- @\"local\"@ (default) or @\"remote\"@ (fail-closed). The optional
-- @[untrusted_execution.remote]@ sub-table carries the SSH coordinates;
-- absent under @mode=local@ (no remote needed), and @mode=remote@ parses
-- OK without it (fail-closed is at call time, not parse time — spec §7
-- row 1).
data UntrustedExecFileConfig = UntrustedExecFileConfig
  { uefcMode   :: Text
    -- ^ @\"local\"@ | @\"remote\"@
  , uefcRemote :: Maybe UntrustedExecRemoteFileConfig
  } deriving stock (Eq, Show)

-- | The @[untrusted_execution.remote]@ sub-table (spec §5). Every field is
-- optional at the TOML layer; the call site validates that the required
-- fields (@host@/@user@/@known_hosts@/@workspace@) are present when
-- @mode=remote@ (absent ⇒ fail-closed at call time).
data UntrustedExecRemoteFileConfig = UntrustedExecRemoteFileConfig
  { uerfcHost       :: Maybe Text
  , uerfcUser       :: Maybe Text
  , uerfcPort       :: Maybe Int
  , uerfcIdentity   :: Maybe FilePath
  , uerfcKnownHosts :: Maybe FilePath
  , uerfcWorkspace  :: Maybe Text
  } deriving stock (Eq, Show)

-- | Starting state: all fields absent.
defaultSecurityConfig :: SecurityConfig
defaultSecurityConfig = SecurityConfig
  { scVaultPath      = Nothing
  , scVaultRecipient = Nothing
  , scVaultIdentity  = Nothing
  , scVaultUnlock    = Nothing
  , scVaultKeyType   = Nothing
  , scUntrustedExec  = Nothing
  }

-- ---------------------------------------------------------------------------
-- Codec
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for 'SecurityConfig'.
securityConfigCodec :: Toml.TomlCodec SecurityConfig
securityConfigCodec = SecurityConfig
  <$> Toml.dioptional (Toml.text "vault_path")     .= scVaultPath
  <*> Toml.dioptional (Toml.text "vault_recipient") .= scVaultRecipient
  <*> Toml.dioptional (Toml.text "vault_identity")  .= scVaultIdentity
  <*> Toml.dioptional (Toml.text "vault_unlock")    .= scVaultUnlock
  <*> Toml.dioptional (Toml.text "vault_key_type")  .= scVaultKeyType
  <*> Toml.dioptional (Toml.table untrustedExecConfigCodec "untrusted_execution") .= scUntrustedExec

-- | Bidirectional tomland codec for the @[untrusted_execution]@ section.
untrustedExecConfigCodec :: Toml.TomlCodec UntrustedExecFileConfig
untrustedExecConfigCodec = UntrustedExecFileConfig
  <$> Toml.text "mode" .= uefcMode
  <*> Toml.dioptional (Toml.table untrustedExecRemoteConfigCodec "remote") .= uefcRemote

-- | Bidirectional tomland codec for the @[untrusted_execution.remote]@
-- sub-table. Every field is optional at the TOML layer.
untrustedExecRemoteConfigCodec :: Toml.TomlCodec UntrustedExecRemoteFileConfig
untrustedExecRemoteConfigCodec = UntrustedExecRemoteFileConfig
  <$> Toml.dioptional (Toml.text "host")        .= uerfcHost
  <*> Toml.dioptional (Toml.text "user")        .= uerfcUser
  <*> Toml.dioptional (Toml.int "port")         .= uerfcPort
  <*> Toml.dioptional (Toml.string "identity")  .= uerfcIdentity
  <*> Toml.dioptional (Toml.string "known_hosts") .= uerfcKnownHosts
  <*> Toml.dioptional (Toml.text "workspace")   .= uerfcWorkspace

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | Load the security config file at @path@.

-- | Load the security config file at @path@.
--
-- * File absent  → @Right 'defaultSecurityConfig'@
-- * Parse error  → @Left@ with the rendered tomland diagnostics
loadSecurityConfig :: FilePath -> IO (Either Text SecurityConfig)
loadSecurityConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right defaultSecurityConfig)
    else do
      contents <- TIO.readFile path
      pure $ case Toml.parse contents of
        Left err   -> Left (Toml.unTomlParseError err)
        Right toml -> case Toml.runTomlCodec securityConfigCodec toml of
          Success cfg  -> Right cfg
          Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | Save @cfg@ to @path@ atomically: write @.tmp@, chmod 0600, rename over
-- @path@. The file is chmod-restricted because @security.toml@ carries the
-- vault recipient/identity (security-critical, agent-immutable).
saveSecurityConfig :: FilePath -> SecurityConfig -> IO ()
saveSecurityConfig path cfg = do
  let encoded = Toml.encode securityConfigCodec cfg
      tmp     = path <> ".tmp"
  TIO.writeFile tmp encoded
  setFileMode tmp 0o600
  renameFile tmp path

-- | Process-wide lock serializing security config writes (design V7).
{-# NOINLINE securityWriteLock #-}
securityWriteLock :: MVar ()
securityWriteLock = unsafePerformIO (newMVar ())

-- | Load the security config at @path@, apply @f@, save. Propagates any load
-- error as @Left Text@ without writing. This is the admin/boot path (e.g.
-- @\/vault setup@); it is NEVER called by an opcode or the HTTP Gateway
-- (those operate on 'RuntimeConfig' and physically cannot reach
-- 'SecurityConfig' — design §4 E). Serialized behind 'securityWriteLock'
-- to prevent lost-update races (design V7).
updateSecurityConfig :: FilePath -> (SecurityConfig -> SecurityConfig) -> IO (Either Text ())
updateSecurityConfig path f = withMVar securityWriteLock $ \_ -> do
  result <- loadSecurityConfig path
  case result of
    Left err  -> pure (Left err)
    Right cfg -> saveSecurityConfig path (f cfg) >> pure (Right ())

-- | Resolve the 'SecurityConfig'\'s @[untrusted_execution]@ section to the
-- typed 'UntrustedExecConfig' the dispatcher consumes. Returns
-- 'Nothing' when the section is absent OR @mode=local@ (the default —
-- no remote needed, the local executor is wired by the call site).
-- Returns @Just (UemRemote, ...remote...)@ when @mode=remote@,
-- with the remote 'SshConfig' if the remote block is fully present
-- (host/user/known_hosts/workspace all set). A @mode=remote@ with a
-- missing/incomplete remote block returns @Just (UemRemote, Nothing)@
-- — fail-closed is at call time (spec §7 row 1), not at config resolution.
untrustedExecConfigFromSecurity :: SecurityConfig -> Maybe UntrustedExecConfig
untrustedExecConfigFromSecurity cfg =
  resolveByMode =<< scUntrustedExec cfg

resolveByMode :: UntrustedExecFileConfig -> Maybe UntrustedExecConfig
resolveByMode uec =
  let mode = if uefcMode uec == "remote" then UemRemote else UemLocal
  in case mode of
       UemRemote -> Just (UntrustedExecConfig UemRemote (resolveRemoteSsh uec))
       UemLocal  -> localModeResult uec

-- | Resolve the [untrusted_execution.remote] sub-table to an 'SshConfig'.
-- Shared by both the UemRemote branch and the hardened-build localModeResult.
resolveRemoteSsh :: UntrustedExecFileConfig -> Maybe SshConfig
resolveRemoteSsh uec = uefcRemote uec >>= \r ->
  uerfcHost r >>= \host ->
  uerfcUser r >>= \user ->
  uerfcKnownHosts r >>= \knownHosts ->
  uerfcWorkspace r >>= \workspace ->
  let port = fromMaybe 22 (uerfcPort r)
      identity = uerfcIdentity r
  in case ( mkSshHost host
          , mkSshUser user
          , mkRemotePath workspace
          ) of
       (Right h, Right u, Right w) -> Just SshConfig
         { scHost       = h
         , scUser       = u
         , scPort       = port
         , scIdentity   = identity
         , scKnownHosts = knownHosts
         , scWorkspace  = w
         }
       _ -> Nothing

#if defined(REMOTE_ONLY_UNTRUSTED)
localModeResult :: UntrustedExecFileConfig -> Maybe UntrustedExecConfig
localModeResult uec =
  Just (UntrustedExecConfig UemRemote (resolveRemoteSsh uec))
#else
localModeResult :: UntrustedExecFileConfig -> Maybe UntrustedExecConfig
localModeResult _ = Nothing
#endif