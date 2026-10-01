{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SecretSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths
import Seal.ISA.Opcode
import Seal.ISA.Ops.Secret
import Seal.Providers.Class
import Seal.Security.Vault
import Seal.Security.Vault.Age
import Seal.TestHelpers.FakeCaps
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)
import Seal.Vault.Commands

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

-- | Set up a vault with an optional initial secret, returning the
-- 'VaultRuntime' and the 'VaultHandle'.
withVaultRuntime
  :: FilePath
  -> Maybe (Text, ByteString)
  -> IO (VaultRuntime, VaultHandle)
withVaultRuntime tmpDir initialSecret = do
  let vaultDir  = tmpDir </> "config" </> "vault"
      vaultPath = vaultDir </> "vault.age"
      paths     = SealPaths
        { spHome   = tmpDir
        , spConfig = tmpDir </> "config"
        , spState  = tmpDir </> "state"
        , spKeys   = tmpDir </> "keys"
        , spCache  = tmpDir </> "cache"
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
  _ <- case initialSecret of
    Just (k, v) -> vhPut h k v
    Nothing     -> pure (Right ())
  ref <- newIORef (Just h)
  let rt = VaultRuntime
        { vrPaths      = paths
        , vrConfigPath = tmpDir </> "config" </> "config.toml"
        , vrHandleRef  = ref
        }
  pure (rt, h)

spec :: Spec
spec = describe "Seal.ISA.Ops.Secret" $ do

  -- -----------------------------------------------------------------------
  -- GET
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=get" $ do

    it "returns the secret value to the model but never serialises it into orRecorded" $
      withSystemTempDirectory "seal-secret-op" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orParts r `shouldBe` [TrpText "s3cr3t"]
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "s3cr3t" recorded `shouldBe` False
        orIsError r `shouldBe` False

    it "missing key sets orIsError=True and orRecorded contains only the key name" $
      withSystemTempDirectory "seal-secret-op-missing" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("NOPE" :: String)
          ]))
        orIsError r `shouldBe` True
        orRecorded r `shouldBe` object ["name" .= ("NOPE" :: String)]

  -- -----------------------------------------------------------------------
  -- PUT
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=put" $ do

    it "stores a new secret and never records the value in orRecorded" $
      withSystemTempDirectory "seal-secret-put" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("API_KEY" :: String)
          , "value"  .= ("sk-abc123" :: String)
          ]))
        orIsError r `shouldBe` False
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "sk-abc123" recorded `shouldBe` False
        stored <- vhGet h "API_KEY"
        stored `shouldBe` Right "sk-abc123"

    it "updates an existing secret (upsert semantics)" $
      withSystemTempDirectory "seal-secret-put-update" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "old-value"))
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        _ <- runTestApp (opRun op localBackend (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("TOKEN" :: String)
          , "value"  .= ("new-value" :: String)
          ]))
        stored <- vhGet h "TOKEN"
        stored `shouldBe` Right "new-value"

    it "rejects put with empty value at authorize gate" $
      withSystemTempDirectory "seal-secret-put-empty" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        case opAuthorize op (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("KEY" :: String)
          , "value"  .= ("" :: String)
          ]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject empty value"

  -- -----------------------------------------------------------------------
  -- DELETE
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=delete" $ do

    it "deletes the secret when the human approves" $
      withSystemTempDirectory "seal-secret-delete-yes" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps ["once"]
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` False
        result <- vhGet h "TOKEN"
        result `shouldSatisfy` isLeft

    it "does NOT delete the secret when the human denies" $
      withSystemTempDirectory "seal-secret-delete-no" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps ["rejected"]
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` True
        result <- vhGet h "TOKEN"
        result `shouldBe` Right "s3cr3t"

    it "is a blocking opcode (toBlocking = True)" $
      withSystemTempDirectory "seal-secret-delete-blocking" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps ["once"]
        let op = secretManageOp rt caps
        opBlocking op `shouldBe` True

    it "does NOT delete when the human sends an empty response" $
      withSystemTempDirectory "seal-secret-delete-empty" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps [""]
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` True
        result <- vhGet h "TOKEN"
        result `shouldBe` Right "s3cr3t"

  -- -----------------------------------------------------------------------
  -- LIST
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=list" $ do

    it "lists all secret names without revealing values" $
      withSystemTempDirectory "seal-secret-list" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        _ <- vhPut h "API_KEY" "sk-xyz"
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("list" :: String)
          ]))
        orIsError r `shouldBe` False
        let text = case orParts r of [TrpText t] -> t; _ -> ""
        T.isInfixOf "TOKEN" text `shouldBe` True
        T.isInfixOf "API_KEY" text `shouldBe` True
        T.isInfixOf "s3cr3t" text `shouldBe` False
        T.isInfixOf "sk-xyz" text `shouldBe` False

  -- -----------------------------------------------------------------------
  -- Authorization
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE authorize gate" $ do

    it "rejects unknown action" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        case opAuthorize op (object ["action" .= ("bogus" :: String)]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject unknown action"

    it "rejects get without name" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        case opAuthorize op (object ["action" .= ("get" :: String)]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject get without name"

    it "rejects put without value" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        case opAuthorize op (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("KEY" :: String)
          ]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject put without value"

    it "rejects delete without name" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        case opAuthorize op (object ["action" .= ("delete" :: String)]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject delete without name"

    it "accepts list with no extra fields" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt caps
        case opAuthorize op (object ["action" .= ("list" :: String)]) of
          Left e  -> expectationFailure ("expected authorize to accept list: " <> T.unpack e)
          Right _ -> pure ()
