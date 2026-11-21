{-# LANGUAGE OverloadedStrings #-}
-- | WU1 RED tests (plan rev 3, tests 1–22): the provisioning core.
--
-- Tests 1–6 pin 'mkVaultIdentityPath' (the module lives in
-- "Seal.Vault.IdentityPath" so the graph stays acyclic), test 7 pins
-- 'mkAgeRecipient', tests 8–9 pin the JSON 'VaultSpec' parser, and 10–22 pin
-- 'provisionVault' — in particular its ORDER (nothing is written before the
-- round-trip passes, the vault file is never created when the config write
-- fails) and its no-leak renderer.
module Seal.Vault.ProvisionSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode, setFileTimes)
import System.Posix.Types (EpochTime)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (ioProperty)

import Seal.Config.Paths
  ( SealPaths (..), securityFilePath, vaultFilePath )
import Seal.Config.Security
  ( SecurityConfig (..), defaultSecurityConfig
  , loadSecurityConfig, saveSecurityConfig, updateVaultKeySection
  , WriteMode (..) )
import Seal.Security.Vault.Age
  ( AgeRecipient (..), VaultEncryptor (..), VaultError (..), mkAgeRecipient
  , mkMockEncryptor )
import Seal.Vault.Backend (ResolvedKey (..))
import Seal.Vault.IdentityPath
  ( mkVaultIdentityPath, vaultIdentityPathDisplay, vaultIdentityPathText )
import Seal.Vault.Provision
  ( ProvisionDeps (..), ProvisionError (..), ProvisionOutcome (..)
  , SetupEncryptor (..), SetupKeygen (..), VaultSpec (..), parseVaultSpec
  , provisionVault, renderProvisionError )

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- A well-formed x25519-shaped recipient. It has no valid bech32 checksum, but
-- 'mkAgeRecipient' only checks shape; the round-trip is what checks the rest.
testRecipient :: Text
testRecipient = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqysq0"

testKey :: ResolvedKey
testKey = ResolvedKey
  { rkRecipient = testRecipient
  , rkIdentity  = "/home/user/.seal/keys/default.identity"
  , rkKeyType   = "x25519"
  }

-- | Build an isolated seal home under a temp directory.
withInstall :: (SealPaths -> FilePath -> IO a) -> IO a
withInstall k = withSystemTempDirectory "seal-provision" $ \dir -> do
  let paths = SealPaths
        { spHome   = dir
        , spConfig = dir </> "config"
        , spState  = dir </> "state"
        , spKeys   = dir </> "keys"
        , spCache  = dir </> "cache"
        }
  createDirectoryIfMissing True (spConfig paths)
  createDirectoryIfMissing True (spKeys paths)
  createDirectoryIfMissing True (dir </> "config" </> "vault")
  k paths (securityFilePath paths)

-- | A keygen that fails the test if it is ever invoked.
forbiddenKeygen :: SetupKeygen
forbiddenKeygen = SetupKeygen
  { skLocal = error "skLocal must not be called"
  , skYubi  = \_ _ _ -> error "skYubi must not be called"
  , skUser  = \_ _ -> error "skUser must not be called"
  }

fixedKeygen :: ResolvedKey -> SetupKeygen
fixedKeygen rk = SetupKeygen
  { skLocal = pure (Right rk)
  , skYubi  = \_ _ _ -> pure (Right rk)
  , skUser  = \_ _ -> Right rk
  }

-- | The mock encryptor as the setup seam: always builds, always round-trips.
mockEncryptorDeps :: SetupEncryptor
mockEncryptorDeps = SetupEncryptor
  { seMk     = \_ _ -> pure (Right mkMockEncryptor)
  , seVerify = \_ -> pure (Right ())
  }

-- | A config writer that fails the test if it is ever invoked (the resume
-- carve-out must skip the CAS write entirely).
forbiddenWriter
  :: (SecurityConfig -> Either ProvisionError a)
  -> IO (Either Text (Either ProvisionError a))
forbiddenWriter _ = error "pdWriteConfig must not be called"

depsFor :: SetupKeygen -> SetupEncryptor -> FilePath -> ProvisionDeps
depsFor keygen encryptor lockPath = ProvisionDeps
  { pdKeygen    = keygen
  , pdEncryptor = encryptor
  , pdWriteConfig = \_ -> pure (Left "pdWriteConfig must not be called")
  , pdLockPath  = lockPath
  }

-- | The deps the happy path uses, with the config write pointed at the real
-- narrow writer (so test 10 can assert what actually lands on disk).
happyDeps :: FilePath -> FilePath -> ProvisionDeps
happyDeps secPath lockPath = (depsFor (fixedKeygen testKey) mockEncryptorDeps lockPath)
  { pdWriteConfig = updateVaultKeySection secPath }

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Vault.Provision" $ do

  describe "mkVaultIdentityPath" $ do

    it "mkVaultIdentityPath rejects relative paths" $ do
      result <- mkVaultIdentityPath "relative/identity.txt"
      result `shouldSatisfy` isLeft

    it "mkVaultIdentityPath rejects a missing file" $ do
      result <- mkVaultIdentityPath "/nonexistent/seal/identity.txt"
      result `shouldSatisfy` isLeft

    it "mkVaultIdentityPath rejects a directory" $
      withSystemTempDirectory "seal-identity" $ \dir -> do
        result <- mkVaultIdentityPath dir
        result `shouldSatisfy` isLeft

    it "mkVaultIdentityPath rejects a leading-dash path" $ do
      -- Option injection: age would read this as a flag.
      result <- mkVaultIdentityPath "-/tmp/identity.txt"
      result `shouldSatisfy` isLeft

    it "mkVaultIdentityPath rejects empty and control characters" $ do
      empty <- mkVaultIdentityPath ""
      empty `shouldSatisfy` isLeft
      nul <- mkVaultIdentityPath "/tmp/a\0b"
      nul `shouldSatisfy` isLeft
      nl <- mkVaultIdentityPath "/tmp/a\nb"
      nl `shouldSatisfy` isLeft

    prop "mkVaultIdentityPath is total" $
      \(s :: String) -> ioProperty $ do
        -- Never throws, whatever the string; and a Right is always a path to
        -- an existing file.
        result <- mkVaultIdentityPath s
        case result of
          Left _   -> pure True
          Right vp -> doesFileExist (vaultIdentityPathText vp)

  describe "mkAgeRecipient" $ do

    it "mkAgeRecipient rejects malformed recipients" $ do
      -- empty, uppercase, bad charset, leading '-', whitespace, over-length
      mkAgeRecipient "" `shouldSatisfy` isLeft
      mkAgeRecipient "AGE1QQQQ" `shouldSatisfy` isLeft
      mkAgeRecipient "age1UPPER" `shouldSatisfy` isLeft
      mkAgeRecipient "age1qq!qq" `shouldSatisfy` isLeft
      mkAgeRecipient "-age1qqqq" `shouldSatisfy` isLeft
      mkAgeRecipient "age1qq qq" `shouldSatisfy` isLeft
      mkAgeRecipient ("age1" <> T.replicate 600 "q") `shouldSatisfy` isLeft
      mkAgeRecipient testRecipient `shouldSatisfy` either (const False) (const True)

  describe "parseVaultSpec" $ do

    it "VaultSpec parses each backend" $
      withSystemTempDirectory "seal-spec-parse" $ \dir -> do
        let identFile = dir </> "keys.txt"
        BS.writeFile identFile "AGE-SECRET-KEY-1TEST"
        parseVaultSpec (object ["backend" .= ("local" :: Text)])
          `shouldReturn` Right VaultSpecLocal
        parseVaultSpec (object ["backend" .= ("yubikey" :: Text)])
          `shouldReturn` Right (VaultSpecYubiKey { vsTouch = True, vsPin = True })
        parseVaultSpec (object
            [ "backend" .= ("yubikey" :: Text)
            , "touch" .= False
            , "pin" .= False ])
          `shouldReturn` Right (VaultSpecYubiKey { vsTouch = False, vsPin = False })
        parseVaultSpec (object ["backend" .= ("resume" :: Text)])
          `shouldReturn` Right VaultSpecResume
        user <- parseVaultSpec (object
          [ "backend" .= ("user" :: Text)
          , "recipient" .= testRecipient
          , "identity_path" .= identFile ])
        case user of
          Right (VaultSpecUser (AgeRecipient r) vp) -> do
            r `shouldBe` testRecipient
            vaultIdentityPathText vp `shouldBe` identFile
            vaultIdentityPathDisplay vp `shouldBe` "keys.txt"
          other -> expectationFailure ("expected VaultSpecUser, got " <> show other)

    it "VaultSpec rejects an unknown backend" $ do
      unknown <- parseVaultSpec (object ["backend" .= ("floppy" :: Text)])
      unknown `shouldSatisfy` isLeft
      missing <- parseVaultSpec (object ["nope" .= (1 :: Int)])
      missing `shouldSatisfy` isLeft
      relative <- parseVaultSpec (object
        [ "backend" .= ("user" :: Text)
        , "recipient" .= testRecipient
        , "identity_path" .= ("relative/keys.txt" :: Text) ])
      relative `shouldSatisfy` isLeft
      badRecipient <- parseVaultSpec (object
        [ "backend" .= ("user" :: Text)
        , "recipient" .= ("nope" :: Text)
        , "identity_path" .= ("/tmp/x" :: Text) ])
      badRecipient `shouldSatisfy` isLeft

  describe "provisionVault" $ do

    it "provisionVault writes exactly the three vault fields, the vault file, and the handle" $
      withInstall $ \paths secPath -> do
        -- Seed unrelated fields so the "only the three" claim has teeth.
        saveSecurityConfig secPath
          (defaultSecurityConfig { scVaultUnlock = Just "startup" })
          PreserveCredentials `shouldReturn` Right ()
        ref <- newIORef Nothing
        outcome <- provisionVault paths ref (happyDeps secPath (secPath <> ".lock")) VaultSpecLocal
        outcome `shouldBe` Right (ProvisionOutcome testRecipient "x25519")
        cfg <- loadSecurityConfig secPath
        case cfg of
          Left err -> expectationFailure ("config did not parse: " <> T.unpack err)
          Right sc -> do
            scVaultRecipient sc `shouldBe` Just testRecipient
            scVaultIdentity  sc `shouldBe` Just (rkIdentity testKey)
            scVaultKeyType   sc `shouldBe` Just "x25519"
            -- Exactly the vault-key triple: nothing else moved.
            scVaultPath     sc `shouldBe` Nothing
            scVaultUnlock   sc `shouldBe` Just "startup"
            scAccessControl sc `shouldBe` Nothing
            scUntrustedExec sc `shouldBe` Nothing
        vaultExists <- doesFileExist (vaultFilePath paths)
        vaultExists `shouldBe` True
        (isJust <$> readIORef ref) `shouldReturn` True

    it "provisionVault reports AlreadyExists without calling the keygen" $
      withInstall $ \paths secPath -> do
        saveSecurityConfig secPath
          (defaultSecurityConfig { scVaultRecipient = Just testRecipient })
          PreserveCredentials `shouldReturn` Right ()
        ref <- newIORef Nothing
        let deps = depsFor forbiddenKeygen mockEncryptorDeps (secPath <> ".lock")
        outcome <- provisionVault paths ref deps VaultSpecLocal
        outcome `shouldBe` Left ProvisionAlreadyExists
        -- ...and it left the recorded key alone.
        fmap scVaultRecipient <$> loadSecurityConfig secPath
          `shouldReturn` Right (Just testRecipient)

    it "provisionVault refuses an orphan vault file without touching it" $
      withInstall $ \paths secPath -> do
        let vaultPath = vaultFilePath paths
        BS.writeFile vaultPath "orphaned-ciphertext"
        ref <- newIORef Nothing
        let deps = depsFor forbiddenKeygen mockEncryptorDeps (secPath <> ".lock")
        outcome <- provisionVault paths ref deps VaultSpecLocal
        outcome `shouldBe` Left ProvisionAlreadyExists
        BS.readFile vaultPath `shouldReturn` "orphaned-ciphertext"

    it "provisionVault resume creates the vault and skips the config write" $
      withInstall $ \paths secPath -> do
        saveSecurityConfig secPath
          (defaultSecurityConfig
             { scVaultRecipient = Just testRecipient
             , scVaultIdentity  = Just (rkIdentity testKey)
             , scVaultKeyType   = Just "x25519" })
          PreserveCredentials `shouldReturn` Right ()
        ref <- newIORef Nothing
        let deps = ProvisionDeps
              { pdKeygen      = forbiddenKeygen
              , pdEncryptor   = mockEncryptorDeps
              , pdWriteConfig = forbiddenWriter
              , pdLockPath    = secPath <> ".lock"
              }
        outcome <- provisionVault paths ref deps VaultSpecResume
        outcome `shouldBe` Right (ProvisionOutcome testRecipient "x25519")
        vaultExists <- doesFileExist (vaultFilePath paths)
        vaultExists `shouldBe` True
        (isJust <$> readIORef ref) `shouldReturn` True

    it "provisionVault maps a config-writer rejection to AlreadyExists" $
      withInstall $ \paths secPath -> do
        ref <- newIORef Nothing
        let deps = (depsFor (fixedKeygen testKey) mockEncryptorDeps (secPath <> ".lock"))
              { pdWriteConfig = \_ -> pure (Right (Left ProvisionAlreadyExists)) }
        outcome <- provisionVault paths ref deps VaultSpecLocal
        outcome `shouldBe` Left ProvisionAlreadyExists

    it "provisionVault maps an outer config-write failure to ConfigWriteFailed" $
      withInstall $ \paths secPath -> do
        ref <- newIORef Nothing
        let deps = (depsFor (fixedKeygen testKey) mockEncryptorDeps (secPath <> ".lock"))
              { pdWriteConfig = \_ -> pure (Left "unparseable security.toml") }
        outcome <- provisionVault paths ref deps VaultSpecLocal
        outcome `shouldBe` Left (ProvisionConfigWriteFailed "unparseable security.toml")

    it "provisionVault does not create the vault file when the config write fails" $
      withInstall $ \paths secPath -> do
        ref <- newIORef Nothing
        let deps = (depsFor (fixedKeygen testKey) mockEncryptorDeps (secPath <> ".lock"))
              { pdWriteConfig = \_ -> pure (Left "boom") }
        _ <- provisionVault paths ref deps VaultSpecLocal
        vaultExists <- doesFileExist (vaultFilePath paths)
        vaultExists `shouldBe` False

    it "provisionVault stops when the round-trip check fails" $
      withInstall $ \paths secPath -> do
        ref <- newIORef Nothing
        let deps = (depsFor (fixedKeygen testKey) mockEncryptorDeps (secPath <> ".lock"))
              { pdEncryptor = mockEncryptorDeps
                  { seVerify = \_ -> pure (Left "nonce mismatch") } }
        outcome <- provisionVault paths ref deps VaultSpecLocal
        case outcome of
          Left (ProvisionRoundTripFailed _) -> pure ()
          other ->
            expectationFailure ("expected ProvisionRoundTripFailed, got " <> show other)
        cfgExists <- doesFileExist secPath
        cfgExists `shouldBe` False
        vaultExists <- doesFileExist (vaultFilePath paths)
        vaultExists `shouldBe` False

    it "provisionVault reports InProgress when the lock file is held" $
      withInstall $ \paths secPath -> do
        let lockPath = secPath <> ".lock"
        BS.writeFile lockPath ""
        setFileMode lockPath 0o600
        ref <- newIORef Nothing
        let deps = depsFor forbiddenKeygen mockEncryptorDeps lockPath
        outcome <- provisionVault paths ref deps VaultSpecLocal
        outcome `shouldBe` Left ProvisionInProgress

    it "provisionVault reclaims a stale lock" $
      withInstall $ \paths secPath -> do
        let lockPath = secPath <> ".lock"
        BS.writeFile lockPath ""
        setFileMode lockPath 0o600
        now <- getPOSIXTime
        -- 60 s in the past: past the 30 s stale window.
        let stale = fromIntegral (round (now - 60) :: Integer) :: EpochTime
        setFileTimes lockPath stale stale
        ref <- newIORef Nothing
        outcome <- provisionVault paths ref (happyDeps secPath lockPath) VaultSpecLocal
        outcome `shouldSatisfy` either (const False) (const True)
        -- The lock is released on the way out.
        lockExists <- doesFileExist lockPath
        lockExists `shouldBe` False

    it "provisionVault refuses to report success when the vault is unreadable" $
      withInstall $ \paths secPath -> do
        ref <- newIORef Nothing
        -- Encrypt succeeds (so vhInit writes a file) but decrypt always fails,
        -- while the round-trip seam is stubbed out: only step 7 can catch it.
        let badEncryptor = VaultEncryptor
              { veEncrypt = \_ -> pure (Right "ciphertext")
              , veDecrypt = \_ -> pure (Left (VaultBackendError "cannot decrypt"))
              }
            deps = (happyDeps secPath (secPath <> ".lock"))
              { pdEncryptor = SetupEncryptor
                  { seMk     = \_ _ -> pure (Right badEncryptor)
                  , seVerify = \_ -> pure (Right ()) } }
        outcome <- provisionVault paths ref deps VaultSpecLocal
        outcome `shouldBe` Left ProvisionVaultUnreadable
        (isNothing <$> readIORef ref) `shouldReturn` True

    it "two concurrent provisionVault calls yield one success" $
      withInstall $ \paths secPath -> do
        ref <- newIORef Nothing
        let slowKeygen = SetupKeygen
              { skLocal = threadDelay 150000 >> pure (Right testKey)
              , skYubi  = \_ _ _ -> pure (Right testKey)
              , skUser  = \_ _ -> Right testKey
              }
            deps = (happyDeps secPath (secPath <> ".lock")) { pdKeygen = slowKeygen }
        (a, b) <- concurrently
          (provisionVault paths ref deps VaultSpecLocal)
          (provisionVault paths ref deps VaultSpecLocal)
        let successes = length (filter (either (const False) (const True)) [a, b])
        successes `shouldBe` 1
        -- One key, one vault: the config records a single recipient.
        fmap scVaultRecipient <$> loadSecurityConfig secPath
          `shouldReturn` Right (Just testRecipient)

    it "renderProvisionError never leaks secrets" $ do
      let identPath = "/home/alice/.seal/keys/default.identity"
          vaultPath = "/home/alice/.seal/config/vault/vault.age"
          poisoned  = "failed for " <> T.pack identPath <> " and age1secretsauce"
          cases =
            [ ProvisionAlreadyExists
            , ProvisionInProgress
            , ProvisionKeygenMissing "age-keygen"
            , ProvisionKeygenMissing (T.pack identPath)
            , ProvisionNeedsTty "age-plugin-yubikey --generate --touch-policy always --pin-policy once > '~/.seal/keys/default.yubikey.txt'"
            , ProvisionInvalidInput poisoned
            , ProvisionRoundTripFailed poisoned
            , ProvisionKeygenFailed poisoned
            , ProvisionVaultInitFailed
            , ProvisionVaultUnreadable
            , ProvisionConfigWriteFailed poisoned
            ]
          rendered = map renderProvisionError cases
          allText = concatMap (\(err, mh) -> err : maybe [] pure mh) rendered
      mapM_ (\t -> do
          t `shouldNotSatisfy` T.isInfixOf (T.pack identPath)
          t `shouldNotSatisfy` T.isInfixOf (T.pack vaultPath)
          t `shouldNotSatisfy` T.isInfixOf "age1"
          t `shouldSatisfy` (not . T.null)) allText
      -- The one permitted exception: the NeedsTTY hint is a runnable command
      -- with a TILDE path and the chosen policies, and nothing else.
      let (reason, mHint) = renderProvisionError
            (ProvisionNeedsTty "age-plugin-yubikey --generate --touch-policy always --pin-policy once > ~/.seal/keys/default.yubikey.txt")
      reason `shouldSatisfy` (not . T.null)
      mHint `shouldSatisfy` maybe False (T.isInfixOf "~/.seal/keys")
      mHint `shouldSatisfy` maybe False (T.isInfixOf "--touch-policy always")
      mHint `shouldSatisfy` maybe False (T.isInfixOf "--pin-policy once")
