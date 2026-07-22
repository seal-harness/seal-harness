{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.CommandsSpec (spec) where

import Data.Functor (($>))
import Data.IORef (newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative (defaultPrefs, execParserPure, renderFailure, ParserResult (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec (CommandSpec (..), CommandAction (..))
import Seal.Config.Security (SecurityConfig (..), defaultSecurityConfig, loadSecurityConfig, saveSecurityConfig)
import Seal.Config.Paths (SealPaths (..), securityFilePath, vaultFilePath)
import Seal.Security.Vault (VaultConfig (..), VaultHandle (..), VaultStatus (..), UnlockMode (..), openVault)
import Seal.Security.Vault.Age (VaultError (..), mkMockEncryptor)
import Seal.TestHelpers.FakeCaps (FakeCaps, makeFakeCaps, getSent)
import Seal.Vault.Backend (detectAgePlugins, readProcessNoInput)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Set up a fresh mock vault + runtime in a temp dir.
-- The VaultHandle is pre-populated (init + unlock) with mkMockEncryptor.
withTestEnv
  :: [Text]
  -> (FakeCaps -> ChannelCaps -> VaultRuntime -> VaultHandle -> IO ())
  -> IO ()
withTestEnv inputs k =
  withSystemTempDirectory "seal-vault-cmd" $ \tmpDir -> do
    let vaultDir  = tmpDir </> "config" </> "vault"
        vaultPath = vaultDir </> "vault.age"
        cfgPath   = tmpDir </> "config" </> "config.toml"
        paths     = SealPaths
          { spHome   = tmpDir
          , spConfig = tmpDir </> "config"
          , spState  = tmpDir </> "state"
          , spKeys   = tmpDir </> "keys"
          }
    createDirectoryIfMissing True vaultDir
    let vaultCfg = VaultConfig
          { vcPath    = vaultPath
          , vcKeyType = "mock"
          , vcUnlock  = UnlockOnDemand
          }
    h <- openVault vaultCfg mkMockEncryptor
    _ <- vhInit h
    _ <- vhUnlock h
    ref <- newIORef (Just h)
    let rt = VaultRuntime
          { vrPaths      = paths
          , vrConfigPath = cfgPath
          , vrHandleRef  = ref
          }
    (fc, caps) <- makeFakeCaps inputs
    k fc caps rt h

-- | Parse and run a vault subcommand through the real optparse parser.
-- Returns Left with the optparse error text on parse failure.
runVaultCmd :: VaultRuntime -> ChannelCaps -> [String] -> IO (Either String ())
runVaultCmd rt caps args =
  let cmdSpec = vaultCommandSpec rt
      result  = execParserPure defaultPrefs (csParserInfo cmdSpec) args
  in case result of
    Success action ->
      runCommandAction action caps $> Right ()
    Failure failure ->
      let (msg, _) = renderFailure failure "vault"
      in pure (Left msg)
    CompletionInvoked _ ->
      pure (Left "completion not supported in tests")

-- | Run a vault command and assert it succeeds (parse + IO).
runVaultCmd_ :: VaultRuntime -> ChannelCaps -> [String] -> IO ()
runVaultCmd_ rt caps args = do
  result <- runVaultCmd rt caps args
  case result of
    Right () -> pure ()
    Left msg -> expectationFailure $ "vault command parse failed: " ++ msg

-- | The vault identity path currently recorded in security config (empty if absent).
identityFromConfig :: SealPaths -> IO FilePath
identityFromConfig paths = do
  c <- loadSecurityConfig (securityFilePath paths)
  pure $ case c of
    Right sc -> maybe "" T.unpack (scVaultIdentity sc)
    Left _   -> ""

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Vault.Commands" $ do

  describe "unconfigured runtime" $ do
    it "list sends 'vault not configured' when handle is Nothing" $ do
      withSystemTempDirectory "seal-cmd-uncfg" $ \tmpDir -> do
        let paths = SealPaths tmpDir (tmpDir </> "config")
                               (tmpDir </> "state") (tmpDir </> "keys")
        ref <- newIORef Nothing
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["list"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "vault not configured")

    it "status sends 'vault not configured' when handle is Nothing" $ do
      withSystemTempDirectory "seal-cmd-uncfg" $ \tmpDir -> do
        let paths = SealPaths tmpDir (tmpDir </> "config")
                               (tmpDir </> "state") (tmpDir </> "keys")
        ref <- newIORef Nothing
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "vault not configured")

  describe "list" $ do
    it "returns empty list on fresh vault" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["list"]
        sent <- getSent fc
        sent `shouldBe` []

    it "sends each secret name on its own line" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "alpha" "v1"
        _ <- vhPut h "beta"  "v2"
        runVaultCmd_ rt caps ["list"]
        sent <- getSent fc
        sent `shouldSatisfy` elem "alpha"
        sent `shouldSatisfy` elem "beta"
        length sent `shouldBe` 2

  describe "add" $ do
    it "stores the secret entered via ccPromptSecret" $
      withTestEnv ["s3cr3t!"] $ \_fc caps rt h -> do
        runVaultCmd_ rt caps ["add", "mykey"]
        result <- vhGet h "mykey"
        result `shouldBe` Right (TE.encodeUtf8 "s3cr3t!")

    it "sends a confirmation message after adding" $
      withTestEnv ["my-value"] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["add", "tok"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "tok")
        sent `shouldSatisfy` (not . any (T.isInfixOf "my-value"))

    it "returns 'vault not configured' message when handle is Nothing" $
      withTestEnv ["val"] $ \fc caps rt _h -> do
        ref2 <- newIORef Nothing
        let rt2 = rt { vrHandleRef = ref2 }
        runVaultCmd_ rt2 caps ["add", "k"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "vault not configured")

  describe "get" $ do
    it "reveals the stored secret value" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "api-key" (TE.encodeUtf8 "sk-123")
        runVaultCmd_ rt caps ["get", "api-key"]
        sent <- getSent fc
        sent `shouldSatisfy` elem "sk-123"

    it "sends VaultKeyNotFound message for missing key" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["get", "nosuchkey"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "no such secret")

    it "VaultKeyNotFound message includes the key name" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["get", "missingkey"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "missingkey")

  describe "delete" $ do
    it "removes the secret from the vault" $
      withTestEnv [] $ \_fc caps rt h -> do
        _ <- vhPut h "tok" (TE.encodeUtf8 "abc")
        runVaultCmd_ rt caps ["delete", "tok"]
        result <- vhGet h "tok"
        result `shouldBe` Left (VaultKeyNotFound "tok")

    it "sends a confirmation message" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "gone" "x"
        runVaultCmd_ rt caps ["delete", "gone"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "gone")

    it "sends 'no such secret' for a missing key" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["delete", "phantom"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "no such secret")

  describe "lock / unlock" $ do
    it "lock leaves vault inaccessible without re-unlock (UnlockStartup mode)" $ do
      withSystemTempDirectory "seal-cmd-lock" $ \tmpDir -> do
        let vaultDir  = tmpDir </> "config" </> "vault"
            vaultPath = vaultDir </> "vault.age"
            paths     = SealPaths tmpDir (tmpDir </> "config")
                                   (tmpDir </> "state") (tmpDir </> "keys")
        createDirectoryIfMissing True vaultDir
        let vaultCfg = VaultConfig vaultPath "mock" UnlockStartup
        h <- openVault vaultCfg mkMockEncryptor
        _ <- vhInit h
        _ <- vhUnlock h
        _ <- vhPut h "k" "v"
        ref <- newIORef (Just h)
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["lock"]
        st <- vhStatus h
        vsLocked st `shouldBe` True
        runVaultCmd_ rt caps ["unlock"]
        st2 <- vhStatus h
        vsLocked st2 `shouldBe` False
        -- suppress unused fc warning
        _ <- getSent fc
        pure ()

    it "lock sends a confirmation" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["lock"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "lock")

  describe "status" $ do
    it "reports locked=no, zero secrets on freshly unlocked vault" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        let out = T.unlines sent
        out `shouldSatisfy` T.isInfixOf "no"
        out `shouldSatisfy` T.isInfixOf "0"

    it "reports the key type from VaultConfig" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` T.isInfixOf "mock"

    it "reports correct secret count after additions" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "a" "1"
        _ <- vhPut h "b" "2"
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` T.isInfixOf "2"

  describe "setup" $ do
    it "setup with LocalAgeKey creates vault and populates vrHandleRef" $ do
      ageExe       <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-setup" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") (tmpDir </> "keys")
                cfgPath  = tmpDir </> "config" </> "config.toml"
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            createDirectoryIfMissing True (tmpDir </> "keys")
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            (fc, caps) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps ["setup"]
            mh <- readIORef ref
            isJust mh `shouldBe` True
            sent <- getSent fc
            sent `shouldSatisfy` any (T.isInfixOf "created")

    it "setup on existing vault triggers rekey flow" $ do
      ageExe       <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-rekey" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                keysDir  = tmpDir </> "keys"
                cfgPath  = tmpDir </> "config" </> "config.toml"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") keysDir
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            createDirectoryIfMissing True keysDir
            -- Step 1: first setup with LocalAgeKey backend.
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            (fc1, caps1) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps1 ["setup"]
            _ <- getSent fc1
            -- Step 2: store a secret before the rekey so we can verify survival.
            mh1 <- readIORef ref
            case mh1 of
              Nothing -> expectationFailure "first setup did not populate vrHandleRef"
              Just h1 -> do
                _ <- vhPut h1 "pre-rekey" (TE.encodeUtf8 "value-before-rekey")
                -- Step 3: generate a second age identity for the rekey.
                let ident2Path = tmpDir </> "second.identity"
                (ec2, _out2, stderr2) <-
                  readProcessNoInput "age-keygen" ["-o", ident2Path]
                case ec2 of
                  ExitFailure _ ->
                    expectationFailure "age-keygen failed to generate second identity"
                  ExitSuccess -> do
                    let stderrText = TE.decodeUtf8Lenient stderr2
                        recipient2 = case filter (T.isPrefixOf "Public key: ") (T.lines stderrText) of
                          (l:_) -> T.strip (T.drop (T.length "Public key: ") l)
                          []    -> ""
                    -- Detect yubikey plugin so we pick the right backend number
                    -- for UserSupplied (shifts from "2" to "3" when yubikey is present).
                    hasYubi <- elem "yubikey" <$> detectAgePlugins
                    let userBackend = if hasYubi then "3" else "2"
                    -- Step 4: second setup with UserSupplied → hits rekeyExisting.
                    -- "y" confirms the up-front rotation prompt; the inner rekey
                    -- confirmation is now implicit, so no trailing "y".
                    (fc2, caps2) <- makeFakeCaps
                      ["y", userBackend, recipient2, T.pack ident2Path]
                    runVaultCmd_ rt caps2 ["setup"]
                    sent2 <- getSent fc2
                    sent2 `shouldSatisfy` any (T.isInfixOf "rekey")
                    -- Step 5: verify the pre-rekey secret survives the rekey.
                    mh2 <- readIORef ref
                    case mh2 of
                      Nothing -> expectationFailure "rekey did not update vrHandleRef"
                      Just h2 -> do
                        result <- vhGet h2 "pre-rekey"
                        result `shouldBe` Right (TE.encodeUtf8 "value-before-rekey")

    it "setup on orphaned vault file emits delete-and-retry message" $ do
      ageExe       <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-orphan" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                keysDir  = tmpDir </> "keys"
                cfgPath  = tmpDir </> "config" </> "config.toml"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") keysDir
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            createDirectoryIfMissing True keysDir
            -- Create an orphaned vault file: vault exists, but no config written.
            let vaultPath = vaultDir </> "vault.age"
            h <- openVault (VaultConfig vaultPath "mock" UnlockOnDemand) mkMockEncryptor
            _ <- vhInit h
            -- Run setup; rekeyExisting should detect the empty config and emit
            -- the "delete that file" recovery message rather than a confusing error.
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            (fc, caps) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps ["setup"]
            sent <- getSent fc
            sent `shouldSatisfy` any (T.isInfixOf "Delete that file")

    it "setup creates vault at scVaultPath when set in security.toml" $ do
      ageExe       <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-setup-custom" $ \tmpDir -> do
            let customVaultDir  = tmpDir </> "custom-vault-dir"
                customVaultPath = customVaultDir </> "custom.age"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") (tmpDir </> "keys")
                cfgPath  = tmpDir </> "config" </> "config.toml"
            createDirectoryIfMissing True (tmpDir </> "config")
            createDirectoryIfMissing True (tmpDir </> "keys")
            createDirectoryIfMissing True customVaultDir
            -- Pre-populate security.toml with a custom vault_path.
            saveSecurityConfig (securityFilePath paths)
              (defaultSecurityConfig { scVaultPath = Just (T.pack customVaultPath) })
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            (fc, caps) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps ["setup"]
            -- Vault must be at the custom path, not the default path.
            doesFileExist customVaultPath `shouldReturn` True
            doesFileExist (vaultFilePath paths) `shouldReturn` False
            sent <- getSent fc
            sent `shouldSatisfy` any (T.isInfixOf "created")

    -- Regression: re-running setup must never overwrite the in-use identity
    -- file, or the existing vault becomes undecryptable and its secrets are
    -- lost. A local-age rotation writes a brand-new key file; the old one must
    -- survive so rekey can decrypt the current vault first.
    it "rotation keeps the old key file and preserves secrets (no clobber)" $ do
      ageExe       <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-rotate" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                keysDir  = tmpDir </> "keys"
                cfgPath  = tmpDir </> "config" </> "config.toml"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") keysDir
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            createDirectoryIfMissing True keysDir
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            -- First setup (local age) and store a secret.
            (_, caps1) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps1 ["setup"]
            mh1 <- readIORef ref
            case mh1 of
              Nothing -> expectationFailure "first setup did not populate vrHandleRef"
              Just h1 -> do
                _ <- vhPut h1 "k" (TE.encodeUtf8 "v")
                ident1 <- identityFromConfig (vrPaths rt)
                ident1 `shouldSatisfy` (not . null)
                -- Second setup (local age) → rotation: "y" up front, backend "1".
                (_, caps2) <- makeFakeCaps ["y", "1"]
                runVaultCmd_ rt caps2 ["setup"]
                -- The OLD identity file is never overwritten.
                doesFileExist ident1 `shouldReturn` True
                -- Config now points at a fresh, different identity file.
                ident2 <- identityFromConfig (vrPaths rt)
                ident2 `shouldNotBe` ident1
                doesFileExist ident2 `shouldReturn` True
                -- The pre-rotation secret survives the rotation.
                mh2 <- readIORef ref
                case mh2 of
                  Nothing -> expectationFailure "rotation did not update vrHandleRef"
                  Just h2 -> vhGet h2 "k" `shouldReturn` Right (TE.encodeUtf8 "v")

    it "declining rotation on an existing vault leaves it unchanged" $ do
      ageExe       <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-decline" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                keysDir  = tmpDir </> "keys"
                cfgPath  = tmpDir </> "config" </> "config.toml"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") keysDir
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            createDirectoryIfMissing True keysDir
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            (_, caps1) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps1 ["setup"]
            ident1 <- identityFromConfig (vrPaths rt)
            mh1 <- readIORef ref
            case mh1 of
              Nothing -> expectationFailure "first setup did not populate vrHandleRef"
              Just h1 -> do
                _ <- vhPut h1 "k" (TE.encodeUtf8 "v")
                -- Second setup, decline the rotation prompt with "n".
                (fc2, caps2) <- makeFakeCaps ["n"]
                runVaultCmd_ rt caps2 ["setup"]
                sent2 <- getSent fc2
                sent2 `shouldSatisfy` any (T.isInfixOf "cancelled")
                -- Config key unchanged; the secret is still readable.
                ident2 <- identityFromConfig (vrPaths rt)
                ident2 `shouldBe` ident1
                vhGet h1 "k" `shouldReturn` Right (TE.encodeUtf8 "v")

  describe "full sequence (mock encryptor)" $ do
    it "add -> get -> list -> delete -> status flow" $
      withTestEnv ["my-secret-value"] $ \fc caps rt h -> do
        runVaultCmd_ rt caps ["add", "MYKEY"]
        addSent <- getSent fc
        -- Secret value must never appear in command output.
        addSent `shouldSatisfy` (not . any (T.isInfixOf "my-secret-value"))
        (fc2, caps2) <- makeFakeCaps []
        runVaultCmd_ rt caps2 ["get", "MYKEY"]
        sent2 <- getSent fc2
        sent2 `shouldSatisfy` elem "my-secret-value"
        (fc3, caps3) <- makeFakeCaps []
        runVaultCmd_ rt caps3 ["list"]
        sent3 <- getSent fc3
        sent3 `shouldSatisfy` elem "MYKEY"
        (fc4, caps4) <- makeFakeCaps []
        runVaultCmd_ rt caps4 ["delete", "MYKEY"]
        r <- vhGet h "MYKEY"
        r `shouldBe` Left (VaultKeyNotFound "MYKEY")
        (fc5, caps5) <- makeFakeCaps []
        runVaultCmd_ rt caps5 ["status"]
        sent5 <- getSent fc5
        T.unlines sent5 `shouldSatisfy` T.isInfixOf "0"
        -- suppress unused warning for fc4 (delete confirmation not asserted here)
        _ <- getSent fc4
        pure ()

    it "VaultKeyNotFound error message includes the key name" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["get", "xyzzy"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "xyzzy")

    it "VaultLocked message when vault is locked and mode is UnlockStartup" $ do
      withSystemTempDirectory "seal-locked" $ \tmpDir -> do
        let vaultDir  = tmpDir </> "config" </> "vault"
            vaultPath = vaultDir </> "vault.age"
            paths     = SealPaths tmpDir (tmpDir </> "config")
                                   (tmpDir </> "state") (tmpDir </> "keys")
        createDirectoryIfMissing True vaultDir
        let vaultCfg = VaultConfig vaultPath "mock" UnlockStartup
        h <- openVault vaultCfg mkMockEncryptor
        _ <- vhInit h
        ref <- newIORef (Just h)
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["get", "anything"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "locked")
