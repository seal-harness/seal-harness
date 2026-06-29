module Seal.Config.PathsSpec (spec) where

import Control.Exception (bracket)
import Data.Foldable (for_)
import System.Directory (doesDirectoryExist, getHomeDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import Test.Hspec

import Seal.Config.Paths

spec :: Spec
spec = describe "Seal.Config.Paths" $ do

  describe "resolveSealHome" $ do
    it "returns SEAL_HOME when the env var is set" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          result <- resolveSealHome
          result `shouldBe` tmp

    it "returns ~/.seal when SEAL_HOME is not set" $
      withoutSealHome $ do
        result   <- resolveSealHome
        expected <- fmap (</> ".seal") getHomeDirectory
        result `shouldBe` expected

  describe "getSealPaths" $ do
    it "derives config, state, and keys sub-paths from home" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          paths <- getSealPaths
          spHome   paths `shouldBe` tmp
          spConfig paths `shouldBe` tmp </> "config"
          spState  paths `shouldBe` tmp </> "state"
          spKeys   paths `shouldBe` tmp </> "keys"

  describe "ensureSealDirs" $ do
    it "creates config and state directories" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          paths <- getSealPaths
          ensureSealDirs paths
          doesDirectoryExist (spConfig paths) `shouldReturn` True
          doesDirectoryExist (spState  paths) `shouldReturn` True

    it "creates keys/ with mode 0700" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          paths <- getSealPaths
          ensureSealDirs paths
          st <- getFileStatus (spKeys paths)
          let mode = fileMode st `intersectFileModes` 0o777
          mode `shouldBe` 0o700

    it "is idempotent (calling twice does not throw)" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          paths <- getSealPaths
          ensureSealDirs paths
          ensureSealDirs paths
          doesDirectoryExist (spKeys paths) `shouldReturn` True

  describe "path helpers" $ do
    it "configFilePath returns config/config.toml" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          paths <- getSealPaths
          configFilePath paths `shouldBe` tmp </> "config" </> "config.toml"

    it "vaultFilePath returns config/vault/vault.age" $
      withSystemTempDirectory "seal-home" $ \tmp ->
        withSealHomeEnv tmp $ do
          paths <- getSealPaths
          vaultFilePath paths `shouldBe` tmp </> "config" </> "vault" </> "vault.age"

-- | Run an action with SEAL_HOME set to the given path, restoring the
-- previous value (or unsetting) on exit, even if the action throws.
withSealHomeEnv :: FilePath -> IO a -> IO a
withSealHomeEnv home act =
  bracket
    (do prev <- lookupEnv "SEAL_HOME"
        setEnv "SEAL_HOME" home
        pure prev)
    (\case
        Nothing -> unsetEnv "SEAL_HOME"
        Just v  -> setEnv "SEAL_HOME" v)
    (const act)

-- | Run an action with SEAL_HOME unset, restoring any previous value on exit.
withoutSealHome :: IO a -> IO a
withoutSealHome act =
  bracket
    (do prev <- lookupEnv "SEAL_HOME"
        maybe (pure ()) (const (unsetEnv "SEAL_HOME")) prev
        pure prev)
    (\prev -> for_ prev (setEnv "SEAL_HOME"))
    (const act)
