{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
-- | The vault provisioning core: one place that turns a backend choice into a
-- recorded key, a fresh vault file, and a live 'VaultHandle'.
--
-- == What this module is
--
-- The CLI's @\/vault setup@ and the web setup wizard's @POST \/api\/setup\/vault@
-- both end up here. It performs the eight ordered steps of design §7.4:
--
-- 1. pre-check (config parses, no key recorded, no vault file) — no lock held;
-- 2. take the @O_CREAT|O_EXCL@ setup lock next to @security.toml@ (0600, stale
--    after 30 s);
-- 3. obtain the key from the injected 'SetupKeygen' seam;
-- 4. build the encryptor and round-trip a nonce (under 'timeout': a YubiKey
--    can sit waiting for a touch or a PIN);
-- 5. record the three vault fields through the narrow CAS writer;
-- 6. @vhInit@ the vault at the configured path;
-- 7. @vhList@ it, so success is never reported for a file this key cannot read;
-- 8. publish the handle in the runtime's 'IORef'.
--
-- Every partial state the ordering can produce is benign and resumable
-- (@resume@ is the one-click recovery for "key recorded, no vault file"),
-- which is why @VaultSpecResume@ is carved out of both the CAS write and the
-- "key already recorded" refusal.
--
-- == What this module is not
--
-- It does not authenticate the caller and it does not read key material back
-- out. @~\/.seal\/@ is writable by the operator's own processes, so a same-UID
-- local process that could call this could already edit @security.toml@
-- directly; this endpoint adds no capability for that class. Cross-UID and
-- LAN peers are covered by the gateway's passkey middleware, not here. See
-- design §7.3 and the PR body's residual-threat paragraph.
--
-- == Leakage rule
--
-- 'renderProvisionError' is the only rendering of a 'ProvisionError' that may
-- reach a response body, and it never echoes the constructor's detail text:
-- the detail can contain an identity path, a vault path, or @age@'s stderr.
-- The one permitted path-bearing field is the 'ProvisionNeedsTty' hint, which
-- is a runnable command built by 'defaultProvisionDeps' from the tilde form of
-- the keys directory (design §7.2 permits an absolute form for mutation errors
-- when @SEAL_HOME@ is non-default).
module Seal.Vault.Provision
  ( VaultSpec (..)
  , ProvisionError (..)
  , ProvisionOutcome (..)
  , SetupKeygen (..)
  , SetupEncryptor (..)
  , ProvisionDeps (..)
  , parseVaultSpec
  , provisionVault
  , renderProvisionError
  , defaultProvisionDeps
  ) where

import Control.Exception (IOException, finally, try)
import Control.Monad (void)
import Data.Aeson (Value, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseMaybe, (.!=))
import Data.ByteString (ByteString)
import Data.IORef (IORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, findExecutable, removeFile )
import System.FilePath (takeDirectory)
import System.Posix.Files (getFileStatus, modificationTimeHiRes)
import System.Posix.IO
  ( OpenFileFlags (exclusive, creat), OpenMode (WriteOnly), closeFd
  , defaultFileFlags, openFd )
import System.Timeout (timeout)

import Seal.Config.Paths (SealPaths, securityFilePath, vaultFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), VaultKeyFields (..), loadSecurityConfig
  , updateVaultKeySection )
import Seal.Security.Vault
  ( UnlockMode (UnlockOnDemand), VaultConfig (..)
  , VaultHandle (..), openVault )
import Seal.Security.Vault.Age
  ( AgeIdentity (..), AgeRecipient (..), VaultEncryptor (..), VaultError (..)
  , mkAgeEncryptor, mkAgeRecipient )
import Seal.Vault.Backend
  ( KeySetupFailure (..), ResolvedKey (..), setupLocalAgeKey
  , setupUserSuppliedFrom, setupYubiKeyCore )
import Seal.Vault.IdentityPath
  ( VaultIdentityPath, mkVaultIdentityPath )

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | What the caller asked for. Mirrors the wire shapes in design §9.2.
data VaultSpec
  = VaultSpecLocal
  | VaultSpecYubiKey { vsTouch :: Bool, vsPin :: Bool }
  | VaultSpecUser { vsRecipient :: AgeRecipient, vsIdentity :: VaultIdentityPath }
  | VaultSpecResume
  deriving stock (Eq, Show)

-- | Everything that can go wrong, as a value. The handler maps these to HTTP
-- statuses (design §9.2); nothing here carries a response-ready message — that
-- is 'renderProvisionError'\'s job.
data ProvisionError
  = ProvisionAlreadyExists
  | ProvisionInProgress
  | ProvisionKeygenMissing Text
    -- ^ @age-keygen@ \/ @age-plugin-yubikey@ is not on PATH.
  | ProvisionNeedsTty Text
    -- ^ The plugin needs a terminal; carries the runnable command.
  | ProvisionInvalidInput Text
  | ProvisionRoundTripFailed Text
    -- ^ Detail is for the log. The rendered reason is fixed.
  | ProvisionKeygenFailed Text
  | ProvisionVaultInitFailed
  | ProvisionVaultUnreadable
  | ProvisionConfigWriteFailed Text
  deriving stock (Eq, Show)

-- | What the caller gets to see: the public recipient and the display label.
-- Never the identity path, never the vault path, never any key material.
data ProvisionOutcome = ProvisionOutcome
  { poRecipient :: Text
  , poKeyType   :: Text
  } deriving stock (Eq, Show)

-- | How a key is obtained. Injected so the core is testable without
-- @age-keygen@ or a YubiKey on the machine.
data SetupKeygen = SetupKeygen
  { skLocal :: IO (Either ProvisionError ResolvedKey)
  , skYubi  :: Text -> Bool -> Bool -> IO (Either ProvisionError ResolvedKey)
    -- ^ name, touch, pin. The name is always the server-side literal
    -- @\"default\"@ (never request-derived).
  , skUser  :: AgeRecipient -> VaultIdentityPath -> Either Text ResolvedKey
  }

-- | How the encryptor is built and verified.
data SetupEncryptor = SetupEncryptor
  { seMk     :: AgeRecipient -> AgeIdentity -> IO (Either VaultError VaultEncryptor)
  , seVerify :: VaultEncryptor -> IO (Either Text ())
    -- ^ Encrypt/decrypt a nonce. This is the only real check of a recipient's
    -- bech32 checksum (a wrong-but-well-formed key fails here).
  }

data ProvisionDeps = ProvisionDeps
  { pdKeygen      :: SetupKeygen
  , pdEncryptor   :: SetupEncryptor
  , pdWriteConfig :: (SecurityConfig -> Either ProvisionError VaultKeyFields)
                  -> IO (Either Text (Either ProvisionError VaultKeyFields))
    -- ^ The narrow CAS writer. Its callback sees the current config inside the
    -- write lock, so "no key appeared between the pre-check and now" is a real
    -- compare-and-swap, not a read-then-write race.
  , pdLockPath    :: FilePath
  }

-- ---------------------------------------------------------------------------
-- Request parsing
-- ---------------------------------------------------------------------------

-- | Parse a setup request body. Pure shape checks happen here; the two
-- user-supplied credentials go through their smart constructors, so nothing
-- unvalidated can reach a 'VaultSpec'.
parseVaultSpec :: Value -> IO (Either ProvisionError VaultSpec)
parseVaultSpec v =
  case parseMaybe parseBackend v of
    Nothing -> pure (Left (ProvisionInvalidInput "request body must name a backend"))
    Just PBBackendLocal  -> pure (Right VaultSpecLocal)
    Just PBBackendResume -> pure (Right VaultSpecResume)
    Just (PBBackendYubi touch pin) -> pure (Right (VaultSpecYubiKey touch pin))
    Just (PBBackendUser rawRecipient rawIdentity) ->
      case mkAgeRecipient rawRecipient of
        Left err -> pure (Left (ProvisionInvalidInput ("recipient: " <> err)))
        Right recipient -> do
          identity <- mkVaultIdentityPath (T.unpack rawIdentity)
          pure $ case identity of
            Left err -> Left (ProvisionInvalidInput ("identity_path: " <> err))
            Right path -> Right (VaultSpecUser recipient path)

-- | The pure half of 'parseVaultSpec', kept separate so the 'IO' smart
-- constructors do not have to live inside a 'Parser'.
data ParsedBackend
  = PBBackendLocal
  | PBBackendResume
  | PBBackendYubi Bool Bool
  | PBBackendUser Text Text

parseBackend :: Value -> Parser ParsedBackend
parseBackend = withObject "vault setup request" $ \o -> do
  backend <- o .: "backend"
  case T.toLower backend of
    "local"   -> pure PBBackendLocal
    "resume"  -> pure PBBackendResume
    -- The CLI's default for both policies is "on", so an omitted field means
    -- "true" — the safe reading (a missing touch requirement would otherwise
    -- silently downgrade the token).
    "yubikey" -> PBBackendYubi
      <$> o .:? "touch" .!= True
      <*> o .:? "pin" .!= True
    "user"    -> PBBackendUser <$> o .: "recipient" <*> o .: "identity_path"
    other     -> fail ("unknown backend: " <> T.unpack other)

-- ---------------------------------------------------------------------------
-- Provisioning
-- ---------------------------------------------------------------------------

-- | Run the eight ordered steps of design §7.4.
provisionVault
  :: SealPaths
  -> IORef (Maybe VaultHandle)
  -> ProvisionDeps
  -> VaultSpec
  -> IO (Either ProvisionError ProvisionOutcome)
provisionVault paths handleRef deps spec = do
  loaded <- loadSecurityConfig (securityFilePath paths)
  case loaded of
    Left err -> pure (Left (ProvisionConfigWriteFailed err))
    Right cfg -> do
      checked <- precheck paths spec cfg
      case checked of
        Left err -> pure (Left err)
        Right () -> withSetupLock (pdLockPath deps) $ do
          keyResult <- obtainKey deps cfg spec
          case keyResult of
            Left err -> pure (Left err)
            Right key -> buildVerifyWriteInit key
  where
    buildVerifyWriteInit key = do
      built <- seMk (pdEncryptor deps)
        (AgeRecipient (rkRecipient key))
        (AgeIdentity (rkIdentity key))
      case built of
        Left verr -> pure (Left (ProvisionKeygenFailed (vaultErrorText verr)))
        Right encryptor -> do
          verified <- roundTrip (pdEncryptor deps) encryptor
          case verified of
            Left err -> pure (Left err)
            Right () -> do
              written <- recordKey deps spec key
              case written of
                Left err -> pure (Left err)
                Right () -> initAndPublish paths handleRef key encryptor

-- | Steps 5–8, plus the @resume@ carve-out: @resume@ writes no config (the key
-- is already there) but still creates and verifies the vault file.
recordKey
  :: ProvisionDeps -> VaultSpec -> ResolvedKey
  -> IO (Either ProvisionError ())
recordKey deps spec key = case spec of
  VaultSpecResume -> pure (Right ())
  _ -> do
    result <- pdWriteConfig deps $ \current ->
      -- The CAS: a recipient that appeared since the pre-check means another
      -- writer won; refuse rather than overwrite a live vault's key.
      case scVaultRecipient current of
        Just _  -> Left ProvisionAlreadyExists
        Nothing -> Right VaultKeyFields
          { vkfRecipient = rkRecipient key
          , vkfIdentity  = T.unpack (rkIdentity key)
          , vkfKeyType   = rkKeyType key
          }
    pure $ case result of
      Left err -> Left (ProvisionConfigWriteFailed err)
      Right (Left rejection) -> Left rejection
      Right (Right _) -> Right ()

initAndPublish
  :: SealPaths
  -> IORef (Maybe VaultHandle)
  -> ResolvedKey
  -> VaultEncryptor
  -> IO (Either ProvisionError ProvisionOutcome)
initAndPublish paths handleRef key encryptor = do
  loaded <- loadSecurityConfig (securityFilePath paths)
  let configuredPath = either (const Nothing) scVaultPath loaded
      vaultPath = maybe (vaultFilePath paths) T.unpack configuredPath
      vaultCfg = VaultConfig
        { vcPath    = vaultPath
        , vcKeyType = rkKeyType key
        -- 'UnlockOnDemand' (the CLI's choice): a freshly created vault has an
        -- empty cache, and 'vhList' below must reach the disk rather than
        -- report 'VaultLocked' for a vault that is perfectly readable.
        , vcUnlock  = UnlockOnDemand
        }
  h <- openVault vaultCfg encryptor
  initialized <- vhInit h
  case initialized of
    Left _ -> pure (Left ProvisionVaultInitFailed)
    Right () -> do
      -- Step 7: never report success for a file this key cannot read. The file
      -- is left in place (it may hold data a different key can open).
      readable <- vhList h
      case readable of
        Left _ -> pure (Left ProvisionVaultUnreadable)
        Right _ -> do
          writeIORef handleRef (Just h)
          pure (Right (ProvisionOutcome (rkRecipient key) (rkKeyType key)))

-- | Step 1: refuse before taking any lock or writing anything.
precheck :: SealPaths -> VaultSpec -> SecurityConfig -> IO (Either ProvisionError ())
precheck paths spec cfg = case spec of
  VaultSpecResume -> case (scVaultRecipient cfg, scVaultIdentity cfg) of
    (Just _, Just _) -> noVaultFile
    _ -> pure (Left (ProvisionInvalidInput
           "resume requires a recorded vault key; there is nothing to resume"))
  _ -> case scVaultRecipient cfg of
    Just _  -> pure (Left ProvisionAlreadyExists)
    Nothing -> noVaultFile
  where
    noVaultFile = do
      exists <- doesFileExist (vaultPathFor paths cfg)
      pure (if exists then Left ProvisionAlreadyExists else Right ())

vaultPathFor :: SealPaths -> SecurityConfig -> FilePath
vaultPathFor paths cfg = maybe (vaultFilePath paths) T.unpack (scVaultPath cfg)

-- | Step 3. @resume@ takes the recorded key: that is the whole point of the
-- state (V5: key recorded, vault file missing).
obtainKey
  :: ProvisionDeps -> SecurityConfig -> VaultSpec
  -> IO (Either ProvisionError ResolvedKey)
obtainKey deps cfg spec = case spec of
  VaultSpecLocal -> skLocal (pdKeygen deps)
  VaultSpecYubiKey touch pin -> skYubi (pdKeygen deps) "default" touch pin
  VaultSpecUser recipient identity ->
    pure (either (Left . ProvisionInvalidInput) Right
            (skUser (pdKeygen deps) recipient identity))
  VaultSpecResume -> case (scVaultRecipient cfg, scVaultIdentity cfg) of
    (Just recipient, Just identity) ->
      pure (Right (ResolvedKey recipient identity
                     (fromMaybe "unknown" (scVaultKeyType cfg))))
    _ -> pure (Left (ProvisionInvalidInput "no recorded vault key to resume"))

-- | Step 4, under a timeout: a YubiKey identity can block on a touch or a PIN.
roundTrip :: SetupEncryptor -> VaultEncryptor -> IO (Either ProvisionError ())
roundTrip encryptorDeps encryptor = do
  outcome <- timeout roundTripTimeoutMicros (seVerify encryptorDeps encryptor)
  pure $ case outcome of
    Nothing -> Left (ProvisionRoundTripFailed "round-trip verify timed out")
    Just (Left err) -> Left (ProvisionRoundTripFailed err)
    Just (Right ()) -> Right ()

-- | A touch plus a PIN prompt. Deliberately generous: this is a human-in-the-
-- loop path, and a timeout here is a failed setup, not a hung gateway.
roundTripTimeoutMicros :: Int
roundTripTimeoutMicros = 60 * 1000 * 1000

-- ---------------------------------------------------------------------------
-- Setup lock
-- ---------------------------------------------------------------------------

-- | Hold the setup lock for the duration of the action, or report that another
-- setup holds it. Released in a bracket, so an exception cannot leave the
-- operator locked out for the 30 s stale window.
withSetupLock
  :: FilePath
  -> IO (Either ProvisionError a)
  -> IO (Either ProvisionError a)
withSetupLock lockPath action = do
  acquired <- acquireSetupLock lockPath
  if acquired
    then action `finally` removeIfExists lockPath
    else pure (Left ProvisionInProgress)

-- | @O_CREAT|O_EXCL@ with mode 0600. A concurrent gateway gets @EEXIST@ from
-- the kernel — there is no check-then-create window. A lock older than
-- 'staleLockSeconds' is assumed to be debris from a crashed process and is
-- reclaimed once.
acquireSetupLock :: FilePath -> IO Bool
acquireSetupLock lockPath = do
  createDirectoryIfMissing True (takeDirectory lockPath)
  created <- tryCreate
  if created
    then pure True
    else do
      stale <- isStale
      if stale
        then removeIfExists lockPath >> tryCreate
        else pure False
  where
    tryCreate = do
      result <- try @IOException
        (openFd lockPath WriteOnly defaultFileFlags { exclusive = True, creat = Just 0o600 })
      case result of
        Left _   -> pure False
        Right fd -> closeFd fd >> pure True

    isStale = do
      result <- try @IOException (getFileStatus lockPath)
      case result of
        -- It vanished between the failed create and this stat: treat it as
        -- stale so the single retry below gets a fresh chance.
        Left _   -> pure True
        Right st -> do
          now <- getPOSIXTime
          pure (now - modificationTimeHiRes st > staleLockSeconds)

staleLockSeconds :: POSIXTime
staleLockSeconds = 30

removeIfExists :: FilePath -> IO ()
removeIfExists path = void (try @IOException (removeFile path))

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- | The only rendering of a 'ProvisionError' allowed into a response body:
-- a fixed reason plus (sometimes) a copy-pasteable next step.
--
-- The detail text of every constructor is deliberately dropped here — it is
-- the caller's job to log it. Details can contain an identity path, a vault
-- path, or @age@'s stderr.
renderProvisionError :: ProvisionError -> (Text, Maybe Text)
renderProvisionError = \case
  ProvisionAlreadyExists ->
    ( "a vault key is already recorded; nothing was changed"
    , Just "use the \"resume\" backend to finish an interrupted setup" )
  ProvisionInProgress ->
    ( "another vault setup is already running"
    , Just "wait a few seconds and retry" )
  ProvisionKeygenMissing _ ->
    ( "a required key-generation tool is not installed"
    , Just "install age-keygen or age-plugin-yubikey, then retry" )
  ProvisionNeedsTty command ->
    ( "this vault backend needs an interactive terminal"
    , Just command )
  ProvisionInvalidInput _ ->
    ( "the request is not a valid vault setup request"
    , Just "send {\"backend\":\"local\"}, \"yubikey\", \"user\" or \"resume\"" )
  ProvisionRoundTripFailed _ ->
    ( "the new key failed its encrypt/decrypt round-trip; nothing was written"
    , Just "check that the identity file belongs to the recipient, then retry" )
  ProvisionKeygenFailed _ ->
    ( "key generation failed; nothing was written"
    , Just "see the gateway log for the tool's output" )
  ProvisionVaultInitFailed ->
    ( "the vault file could not be created"
    , Just "check permissions on the seal config directory" )
  ProvisionVaultUnreadable ->
    ( "the vault file could not be opened with the new key; it was left in place"
    , Just "remove the vault file if it is a leftover from an interrupted setup" )
  ProvisionConfigWriteFailed _ ->
    ( "the vault key could not be recorded in security.toml"
    , Just "check permissions on the seal home directory" )

vaultErrorText :: VaultError -> Text
vaultErrorText err = case err of
  VaultBackendError msg -> msg
  VaultLocked -> "vault is locked"
  VaultNotFound -> "vault file not found"
  VaultAlreadyExists -> "vault already exists"
  VaultKeyNotFound key -> "secret not found: " <> key

-- ---------------------------------------------------------------------------
-- Production wiring
-- ---------------------------------------------------------------------------

-- | The real seams: @age-keygen@, the non-interactive @age-plugin-yubikey@
-- core, the narrow CAS writer, and the @age@ round-trip.
defaultProvisionDeps :: SealPaths -> ProvisionDeps
defaultProvisionDeps paths = ProvisionDeps
  { pdKeygen = SetupKeygen
      { skLocal = do
          found <- findExecutable "age-keygen"
          case found of
            Nothing -> pure (Left (ProvisionKeygenMissing "age-keygen"))
            Just _  -> either (Left . ProvisionKeygenFailed) Right
                         <$> setupLocalAgeKey paths "default"
      , skYubi = \name touch pin ->
          mapKeygenFailure <$> setupYubiKeyCore paths name touch pin
      , skUser = setupUserSuppliedFrom
      }
  , pdEncryptor = SetupEncryptor
      { seMk     = mkAgeEncryptor
      , seVerify = roundTripVerify
      }
  , pdWriteConfig = updateVaultKeySection (securityFilePath paths)
  , pdLockPath    = securityFilePath paths <> ".lock"
  }
  where
    mapKeygenFailure failure = case failure of
      Left (KeySetupMissing binary) -> Left (ProvisionKeygenMissing binary)
      Left (KeySetupNeedsTty command) -> Left (ProvisionNeedsTty command)
      Left (KeySetupFailed detail) -> Left (ProvisionKeygenFailed detail)
      Right key -> Right key

-- | The nonce is fixed on purpose: this checks that the key can encrypt and
-- decrypt *something*, and a fixed value makes a failure reproducible.
roundTripNonce :: ByteString
roundTripNonce = "seal-vault-round-trip"

roundTripVerify :: VaultEncryptor -> IO (Either Text ())
roundTripVerify encryptor = do
  encrypted <- veEncrypt encryptor roundTripNonce
  case encrypted of
    Left err -> pure (Left ("encrypt failed: " <> vaultErrorText err))
    Right ciphertext -> do
      decrypted <- veDecrypt encryptor ciphertext
      pure $ case decrypted of
        Left err -> Left ("decrypt failed: " <> vaultErrorText err)
        Right plain
          | plain == roundTripNonce -> Right ()
          | otherwise -> Left "decrypt returned different bytes"
