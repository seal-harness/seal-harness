{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SecretSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef)
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
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Vault.Commands

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

spec :: Spec
spec = describe "Seal.ISA.Ops.Secret" $ do

  it "returns the secret value to the model but never serialises it into orRecorded" $
    withSystemTempDirectory "seal-secret-op" $ \tmpDir -> do
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
      _ <- vhPut h "TOKEN" "s3cr3t"
      ref <- newIORef (Just h)
      let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = tmpDir </> "config" </> "config.toml"
            , vrHandleRef  = ref
            }
          op = secretGetOp rt
      r <- runTestApp (opRun op localBackend (object ["name" .= ("TOKEN" :: String)]))
      -- 1) The secret value reaches the model via orParts:
      orParts r `shouldBe` [TrpText "s3cr3t"]
      -- 2) The secret value is NEVER present in the recorded transcript payload:
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "s3cr3t" recorded `shouldBe` False

  it "missing key sets orIsError=True and orRecorded still contains only the key name" $
    withSystemTempDirectory "seal-secret-op-missing" $ \tmpDir -> do
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
      ref <- newIORef (Just h)
      let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = tmpDir </> "config" </> "config.toml"
            , vrHandleRef  = ref
            }
          op = secretGetOp rt
      r <- runTestApp (opRun op localBackend (object ["name" .= ("NOPE" :: String)]))
      -- Missing key is an error result:
      orIsError r `shouldBe` True
      -- Recorded payload contains only the key name (no error detail leaked):
      orRecorded r `shouldBe` object ["name" .= ("NOPE" :: String)]
