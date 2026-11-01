{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the @seal access-control@ command surface.
--
-- The command returns an 'ExitCode' rather than exiting (design §12), so every
-- code is assertable here without spawning a process.
module Seal.Command.AccessControlSpec (spec) where

import Data.Maybe (isNothing)
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Command.AccessControl (runAccessControlWith)
import Seal.Config.Paths (SealPaths (..), securityFilePath)
import Seal.Config.Security
  ( AccessControlFileConfig (..), SecurityConfig (..), defaultSecurityConfig
  , loadSecurityConfig, saveSecurityConfig, WriteMode (PreserveCredentials) )
import Seal.Types.Command (AccessControlAction (..))

spec :: Spec
spec = describe "seal access-control" $ do
  describe "status" $ do
    it "exits 0 for a readable configuration" $ withHome $ \paths -> do
      writeSection paths passkeySection
      runAccessControlWith paths AcStatus `shouldReturn` ExitSuccess

    it "exits 1 when security.toml does not parse" $ withHome $ \paths -> do
      createDirectoryIfMissing True (spConfig paths)
      TIO.writeFile (securityFilePath paths) "this is not TOML = = ="
      result <- runAccessControlWith paths AcStatus
      result `shouldSatisfy` isFailure

  describe "reset" $ do
    it "exits 0 and removes the section" $ withHome $ \paths -> do
      writeSection paths passkeySection
      runAccessControlWith paths AcReset `shouldReturn` ExitSuccess
      loaded <- loadSecurityConfig (securityFilePath paths)
      (scAccessControl <$> loaded) `shouldSatisfy` either (const True) isNothing

  describe "migrate-credentials" $ do
    it "exits 0 when there is nothing to migrate" $ withHome $ \paths ->
      runAccessControlWith paths (AcMigrateCredentials False)
        `shouldReturn` ExitSuccess

-- Helpers ------------------------------------------------------------------

isFailure :: ExitCode -> Bool
isFailure ExitSuccess       = False
isFailure (ExitFailure _)   = True

withHome :: (SealPaths -> IO a) -> IO a
withHome action = withSystemTempDirectory "seal-ac-cli" $ \dir ->
  action SealPaths { spHome = dir
                   , spState = dir </> "state"
                   , spConfig = dir </> "config"
                   , spKeys = dir </> "keys"
                   , spCache = dir </> "cache"
                   }

writeSection :: SealPaths -> AccessControlFileConfig -> IO ()
writeSection paths section = do
  createDirectoryIfMissing True (spConfig paths)
  saveSecurityConfig (securityFilePath paths)
    defaultSecurityConfig { scAccessControl = Just section } PreserveCredentials
    `shouldReturn` Right ()

passkeySection :: AccessControlFileConfig
passkeySection = AccessControlFileConfig
  { acfcMode = Just "passkey"
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  }
