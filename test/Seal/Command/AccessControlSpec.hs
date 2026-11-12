{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the @seal access-control@ command surface.
--
-- The command returns an 'ExitCode' rather than exiting (design §12), so every
-- code is assertable here without spawning a process.
module Seal.Command.AccessControlSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Bits ((.&.))
import Data.Maybe (isJust, isNothing)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, listDirectory )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import System.Posix.Process
  ( ProcessStatus (..), exitImmediately, forkProcess, getProcessStatus )
import Test.Hspec

import Seal.Command.AccessControl
  ( ConfigureError (..), Outputs (..), configureWith, planConfigure
  , runAccessControlWith )
import Data.IORef (modifyIORef', newIORef, readIORef)
import Seal.Config.BootPlan (CredentialsPresence (CredentialsAbsent))
import Seal.Config.Credentials
  ( CredentialsFile (..), credentialsVersion, saveCredentials )
import Seal.Config.Paths
  ( SealPaths (..), configFilePath, credentialsFilePath, enrollmentGrantPath
  , enrollmentTokenPath, securityFilePath, serveLockPath )
import Seal.Config.Security
  ( AccessControlFileConfig (..), CredentialFileConfig (..), SecurityConfig (..)
  , defaultSecurityConfig, gatewayConfigFromSecurity, loadSecurityConfig
  , saveSecurityConfig, WriteMode (PreserveCredentials) )
import Seal.Security.EnrollmentGrant
  ( Grant (..), loadGrantFile, tokenDigest )
import Seal.Gateway.Config
  ( GatewayConfig (..), PartialGatewayConfig (..), tlsEnabled )
import Seal.Setup.State
  ( SetupInputs (..), SetupState (..), deriveSetupState, emptySetupInputs )
import Seal.Types.Command
  ( AccessControlAction (..), ConfigureOptions (..), EnrollOptions (..) )
import Seal.Security.DaemonLock (acquireServeLock)

spec :: Spec
spec = describe "seal access-control" $ do
  describe "status" $ do
    it "exits 0 for a readable configuration" $ withHome $ \paths -> do
      writeSection paths passkeySection
      runAccessControlWith paths AcStatus `shouldReturn` ExitSuccess

    it "exits 1 when security.toml does not parse" $ withHome $ \paths -> do
      TIO.writeFile (securityFilePath paths) "this is not TOML = = ="
      result <- runAccessControlWith paths AcStatus
      result `shouldSatisfy` isFailure

  describe "reset" $ do
    it "exits 0 and removes the section" $ withHome $ \paths -> do
      writeSection paths passkeySection
      runAccessControlWith paths AcReset `shouldReturn` ExitSuccess
      loaded <- loadSecurityConfig (securityFilePath paths)
      (scAccessControl <$> loaded) `shouldSatisfy` either (const True) isNothing

    it "deletes the credential store and the outstanding grant" $ withHome $ \paths -> do
      writeSection paths passkeySection
      writeStore paths
      runAccessControlWith paths (AcEnroll enrollToken) `shouldReturn` ExitSuccess
      runAccessControlWith paths AcReset `shouldReturn` ExitSuccess
      doesFileExist (credentialsFilePath paths) `shouldReturn` False
      doesFileExist (enrollmentGrantPath paths) `shouldReturn` False
      doesFileExist (enrollmentTokenPath paths) `shouldReturn` False

  describe "migrate-credentials" $ do
    it "exits 0 when there is nothing to migrate" $ withHome $ \paths ->
      runAccessControlWith paths (AcMigrateCredentials False)
        `shouldReturn` ExitSuccess

  describe "enroll" $ do
    it "mints a grant, prints the token to stdout and stores only its digest" $
      withHome $ \paths -> do
        runAccessControlWith paths (AcEnroll enrollToken) `shouldReturn` ExitSuccess
        grant <- loadGrantFile (enrollmentGrantPath paths)
        grant `shouldSatisfy` isJust
        -- stderr is not a TTY under the test runner, so the plaintext token is
        -- also on disk at 0600 — and the grant file holds only its digest.
        token <- T.strip <$> TIO.readFile (enrollmentTokenPath paths)
        T.length token `shouldSatisfy` (> 0)
        mode <- fileMode <$> getFileStatus (enrollmentTokenPath paths)
        (mode .&. 0o777) `shouldBe` 0o600
        (grTokenSha <$> grant) `shouldBe` Just (Just (tokenDigest token))

    it "refuses a second grant without --force and names the remaining time" $
      withHome $ \paths -> do
        runAccessControlWith paths (AcEnroll enrollToken) `shouldReturn` ExitSuccess
        priorGrant <- loadGrantFile (enrollmentGrantPath paths)
        result <- runAccessControlWith paths (AcEnroll enrollToken)
        result `shouldSatisfy` isFailure
        nextGrant <- loadGrantFile (enrollmentGrantPath paths)
        (grId <$> nextGrant) `shouldBe` (grId <$> priorGrant)

    it "replaces the outstanding grant with --force" $ withHome $ \paths -> do
      runAccessControlWith paths (AcEnroll enrollToken) `shouldReturn` ExitSuccess
      priorGrant <- loadGrantFile (enrollmentGrantPath paths)
      runAccessControlWith paths (AcEnroll enrollToken { eoForce = True })
        `shouldReturn` ExitSuccess
      nextGrant <- loadGrantFile (enrollmentGrantPath paths)
      case nextGrant of
        Nothing -> expectationFailure "no grant after --force"
        Just grant -> (grId <$> priorGrant) `shouldSatisfy` (/= Just (grId grant))

    it "--ttl clamps to the 24 h ceiling and the 30 s floor" $ withHome $ \paths -> do
      now <- getCurrentTime
      runAccessControlWith paths (AcEnroll enrollToken { eoTtl = Just "99h" })
        `shouldReturn` ExitSuccess
      long <- loadGrantFile (enrollmentGrantPath paths)
      case long of
        Nothing -> expectationFailure "no grant"
        Just grant -> diffUTCTime (grExpiresAt grant) now `shouldSatisfy` nearSeconds 86400
      runAccessControlWith paths (AcEnroll enrollToken { eoTtl = Just "1s", eoForce = True })
        `shouldReturn` ExitSuccess
      short <- loadGrantFile (enrollmentGrantPath paths)
      case short of
        Nothing -> expectationFailure "no grant"
        Just grant -> diffUTCTime (grExpiresAt grant) now `shouldSatisfy` nearSeconds 30

    it "rejects a bare --ttl number as a usage error" $ withHome $ \paths -> do
      runAccessControlWith paths (AcEnroll enrollToken { eoTtl = Just "600" })
        `shouldReturn` ExitFailure 2
      doesFileExist (enrollmentGrantPath paths) `shouldReturn` False

    it "rejects --cancel combined with --ttl as a usage error" $ withHome $ \paths -> do
      runAccessControlWith paths
        (AcEnroll enrollToken { eoCancel = True, eoTtl = Just "10m" })
        `shouldReturn` ExitFailure 2

    it "--cancel removes the grant, its claims and the token file" $ withHome $ \paths -> do
      runAccessControlWith paths (AcEnroll enrollToken) `shouldReturn` ExitSuccess
      TIO.writeFile (claimFile paths) "{}"
      runAccessControlWith paths (AcEnroll enrollToken { eoCancel = True })
        `shouldReturn` ExitSuccess
      doesFileExist (enrollmentGrantPath paths) `shouldReturn` False
      doesFileExist (enrollmentTokenPath paths) `shouldReturn` False
      entries <- listDirectory (spState paths)
      entries `shouldSatisfy` (not . any (("enrollment-grant.claimed-" `T.isPrefixOf`) . T.pack))

    it "--cancel with nothing outstanding is a success" $ withHome $ \paths ->
      runAccessControlWith paths (AcEnroll enrollToken { eoCancel = True })
        `shouldReturn` ExitSuccess

  describe "enroll --no-token" $ do
    it "mints a window grant with no token and no token file" $ withHome $ \paths -> do
      runAccessControlWith paths (AcEnroll enrollWindow) `shouldReturn` ExitSuccess
      grant <- loadGrantFile (enrollmentGrantPath paths)
      doesFileExist (enrollmentTokenPath paths) `shouldReturn` False

      (grTokenSha <$> grant) `shouldBe` Just Nothing
    it "refuses when credentials are already enrolled" $ withHome $ \paths -> do
      writeSection paths passkeySection
      writeStore paths
      runAccessControlWith paths (AcEnroll enrollWindow) `shouldReturn` ExitFailure 1
      doesFileExist (enrollmentGrantPath paths) `shouldReturn` False

    it "refuses on a non-loopback bind" $ withHome $ \paths -> do
      TIO.writeFile (configFilePath paths) "[gateway]\nhost = \"0.0.0.0\"\n"
      runAccessControlWith paths (AcEnroll enrollWindow) `shouldReturn` ExitFailure 1
      doesFileExist (enrollmentGrantPath paths) `shouldReturn` False

    -- After the [gateway] move, the bind lives in security.toml. The old
    -- fixture above keeps working through the read-only upgrade fallback; this
    -- one is the post-migration shape and must refuse for the same reason.
    it "refuses on a non-loopback bind configured in security.toml" $ withHome $ \paths -> do
      writeGateway paths (PartialGatewayConfig
        { pgcPort = Just 8443, pgcHost = Just "0.0.0.0"
        , pgcStaticDir = Nothing, pgcAllowedOrigins = []
        , pgcTlsCert = Nothing, pgcTlsKey = Nothing, pgcTls = Nothing
        , pgcTlsHosts = [] })
      runAccessControlWith paths (AcEnroll enrollWindow) `shouldReturn` ExitFailure 1
      doesFileExist (enrollmentGrantPath paths) `shouldReturn` False

    it "lets security.toml win over a stale table left in config.toml" $ withHome $ \paths -> do
      TIO.writeFile (configFilePath paths) "[gateway]\nhost = \"0.0.0.0\"\n"
      writeGateway paths (PartialGatewayConfig
        { pgcPort = Nothing, pgcHost = Just "localhost"
        , pgcStaticDir = Nothing, pgcAllowedOrigins = []
        , pgcTlsCert = Nothing, pgcTlsKey = Nothing, pgcTls = Nothing
        , pgcTlsHosts = [] })
      runAccessControlWith paths (AcEnroll enrollWindow) `shouldReturn` ExitSuccess

    -- The fallback exists so `status`/`enroll` stay correct during the upgrade
    -- window. It must stay read-only: those verbs did not write here before,
    -- and a pre-upgrade `seal serve` may be running (the security write lock is
    -- process-local).
    it "writes neither config file on status or enroll" $ withHome $ \paths -> do
      let cfg = "default_provider = \"ollama\"\n"
      TIO.writeFile (configFilePath paths) cfg
      runAccessControlWith paths AcStatus `shouldReturn` ExitSuccess
      runAccessControlWith paths (AcEnroll enrollWindow) `shouldReturn` ExitSuccess
      doesFileExist (securityFilePath paths) `shouldReturn` False
      TIO.readFile (configFilePath paths) `shouldReturn` cfg

  describe "disable" $ do
    it "refuses without --yes, as a usage error" $ withHome $ \paths -> do
      writeSection paths passkeySection
      runAccessControlWith paths (AcDisable False) `shouldReturn` ExitFailure 2
      sectionMode paths `shouldReturn` Just "passkey"

    it "writes mode = none and keeps the credential store" $ withHome $ \paths -> do
      writeSection paths passkeySection
      writeStore paths
      runAccessControlWith paths (AcDisable True) `shouldReturn` ExitSuccess
      sectionMode paths `shouldReturn` Just "none"
      doesFileExist (credentialsFilePath paths) `shouldReturn` True

    it "refuses while a daemon holds the serve lock" $ withHome $ \paths -> do
      writeSection paths passkeySection
      withHeldServeLock paths $ do
        runAccessControlWith paths (AcDisable True) `shouldReturn` ExitFailure 1
      sectionMode paths `shouldReturn` Just "passkey"

  describe "configure" $ do
    it "writes host, port, TLS, origin and rp_id without setting mode" $ withHome $ \paths -> do
      _ <- configureWith quiet (const (pure True)) paths
             configureOpts { coHost = Just "seal.example.com"
                           , coPort = Just "8443"
                           , coTls = True
                           , coOrigin = Just "https://seal.example.com:8443"
                           , coRpId = Just "seal.example.com" }
      Right cfg <- loadSecurityConfig (securityFilePath paths)
      let gw = gatewayConfigFromSecurity cfg
      gcHost gw `shouldBe` "seal.example.com"
      gcPort gw `shouldBe` 8443
      tlsEnabled gw `shouldBe` True
      (scAccessControl cfg >>= acfcOrigin) `shouldBe` Just "https://seal.example.com:8443"
      (scAccessControl cfg >>= acfcRpId) `shouldBe` Just "seal.example.com"
      (scAccessControl cfg >>= acfcMode) `shouldBe` Nothing

    it "leaves the first-run setup wizard incomplete" $ withHome $ \paths -> do
      _ <- configureWith quiet (const (pure True)) paths
             configureOpts { coHost = Just "localhost", coPort = Just "9090" }
      Right cfg <- loadSecurityConfig (securityFilePath paths)
      state <- deriveSetupState (emptySetupInputs paths) { siSecurity = cfg }
      ssRequiredComplete state `shouldBe` False

    it "replaces the previously managed origin in allowed_origins" $ withHome $ \paths -> do
      saveSecurityConfig (securityFilePath paths)
        defaultSecurityConfig
          { scGateway = Just (PartialGatewayConfig Nothing Nothing Nothing
                               ["https://old.example.com"] Nothing Nothing Nothing [])
          , scAccessControl = Just (AccessControlFileConfig Nothing
                                     (Just "https://old.example.com")
                                     (Just "old.example.com"))
          } PreserveCredentials
        `shouldReturn` Right ()
      _ <- configureWith quiet (const (pure True)) paths
             configureOpts { coOrigin = Just "https://new.example.com"
                           , coRpId = Just "new.example.com" }
      Right cfg <- loadSecurityConfig (securityFilePath paths)
      let origins = gcAllowedOrigins (gatewayConfigFromSecurity cfg)
      origins `shouldContain` ["https://new.example.com"]
      origins `shouldNotContain` ["https://old.example.com"]

    it "derives a loopback https origin for --tls" $ withHome $ \paths -> do
      _ <- configureWith quiet (const (pure True)) paths
             configureOpts { coHost = Just "127.0.0.1"
                           , coPort = Just "8443"
                           , coTls = True }
      Right cfg <- loadSecurityConfig (securityFilePath paths)
      (scAccessControl cfg >>= acfcOrigin) `shouldBe` Just "https://localhost:8443"

    it "clears the TLS pair and SANs with --no-tls" $ withHome $ \paths -> do
      saveSecurityConfig (securityFilePath paths)
        defaultSecurityConfig
          { scGateway = Just (PartialGatewayConfig (Just 443) (Just "localhost") Nothing
                               [] (Just "/tmp/cert.pem") (Just "/tmp/key.pem")
                               (Just True) ["seal.example.com"])
          } PreserveCredentials
        `shouldReturn` Right ()
      _ <- configureWith quiet (const (pure True)) paths
             configureOpts { coNoTls = True }
      Right cfg <- loadSecurityConfig (securityFilePath paths)
      let gw = gatewayConfigFromSecurity cfg
      tlsEnabled gw `shouldBe` False
      gcTlsCert gw `shouldBe` Nothing
      gcTlsKey gw `shouldBe` Nothing
      gcTlsHosts gw `shouldBe` []

    it "rejects no coordinate options as a usage error" $ withHome $ \paths ->
      configureWith quiet (const (pure True)) paths configureOpts
        `shouldReturn` ExitFailure 2

    it "rejects an out-of-range port as a usage error" $ withHome $ \paths ->
      configureWith quiet (const (pure True)) paths
        configureOpts { coPort = Just "70000" }
        `shouldReturn` ExitFailure 2

    it "rejects --tls together with --no-tls" $ withHome $ \paths ->
      configureWith quiet (const (pure True)) paths
        configureOpts { coTls = True, coNoTls = True }
        `shouldReturn` ExitFailure 2

    it "rejects an http origin when TLS is enabled" $ withHome $ \paths ->
      configureWith quiet (const (pure True)) paths
        configureOpts { coTls = True, coOrigin = Just "http://localhost:8080" }
        `shouldReturn` ExitFailure 1

    it "refuses to orphan an enrolled passkey" $ withHome $ \paths -> do
      writeStore paths
      configureWith quiet (const (pure True)) paths
        configureOpts { coOrigin = Just "https://seal.example.com"
                      , coRpId = Just "seal.example.com" }
        `shouldReturn` ExitFailure 1
      doesFileExist (securityFilePath paths) `shouldReturn` False

    it "refuses while a daemon holds the serve lock" $ withHome $ \paths ->
      withHeldServeLock paths $
        runAccessControlWith paths
          (AcConfigure configureOpts { coHost = Just "localhost" })
          `shouldReturn` ExitFailure 1

    it "refuses when config.toml still carries legacy security fields" $ withHome $ \paths -> do
      TIO.writeFile (configFilePath paths) "[gateway]\nhost = \"localhost\"\n"
      configureWith quiet (const (pure True)) paths
        configureOpts { coHost = Just "localhost" }
        `shouldReturn` ExitFailure 1
      doesFileExist (securityFilePath paths) `shouldReturn` False

    it "prints the resolved coordinates on stdout" $ withHome $ \paths -> do
      captured <- newIORef []
      let capture = Outputs (\t -> modifyIORef' captured (t :)) (\_ -> pure ())
      _ <- configureWith capture (const (pure True)) paths
             configureOpts { coHost = Just "localhost", coPort = Just "9191" }
      out <- reverse <$> readIORef captured
      out `shouldContain` ["bind_host: localhost", "bind_port: 9191"]

    it "prints certificate-trust guidance for generated TLS" $ withHome $ \paths -> do
      errs <- newIORef []
      let capture = Outputs (\_ -> pure ()) (\t -> modifyIORef' errs (t :))
      _ <- configureWith capture (const (pure True)) paths
             configureOpts { coHost = Just "127.0.0.1", coPort = Just "8443", coTls = True }
      captured <- readIORef errs
      captured `shouldSatisfy` any (T.isInfixOf "WebAuthn")
      captured `shouldSatisfy` any (T.isInfixOf "ssh -L")

    it "planConfigure rejects conflicting TLS flags" $
      planConfigure defaultSecurityConfig CredentialsAbsent
        configureOpts { coTls = True, coNoTls = True }
        `shouldSatisfy` isConfigureUsage

-- Helpers ------------------------------------------------------------------

quiet :: Outputs
quiet = Outputs (\_ -> pure ()) (\_ -> pure ())

configureOpts :: ConfigureOptions
configureOpts = ConfigureOptions
  { coHost = Nothing
  , coPort = Nothing
  , coTls = False
  , coNoTls = False
  , coTlsCert = Nothing
  , coTlsKey = Nothing
  , coTlsHosts = []
  , coOrigin = Nothing
  , coRpId = Nothing
  }

isConfigureUsage :: Either ConfigureError a -> Bool
isConfigureUsage (Left (ConfigureUsage _)) = True
isConfigureUsage _                         = False

isFailure :: ExitCode -> Bool
isFailure ExitSuccess     = False
isFailure (ExitFailure _) = True


enrollToken :: EnrollOptions
enrollToken = EnrollOptions
  { eoTtl = Nothing, eoNoToken = False, eoForce = False, eoCancel = False }

enrollWindow :: EnrollOptions
enrollWindow = enrollToken { eoNoToken = True }

withHome :: (SealPaths -> IO a) -> IO a
withHome action = withSystemTempDirectory "seal-ac-cli" $ \dir -> do
  let paths = SealPaths { spHome = dir
                        , spState = dir </> "state"
                        , spConfig = dir </> "config"
                        , spKeys = dir </> "keys"
                        , spCache = dir </> "cache"
                        }
  createDirectoryIfMissing True (spState paths)
  createDirectoryIfMissing True (spConfig paths)
  action paths

writeSection :: SealPaths -> AccessControlFileConfig -> IO ()
writeSection paths section =
  saveSecurityConfig (securityFilePath paths)
    defaultSecurityConfig { scAccessControl = Just section } PreserveCredentials
    `shouldReturn` Right ()

writeGateway :: SealPaths -> PartialGatewayConfig -> IO ()
writeGateway paths gateway =
  saveSecurityConfig (securityFilePath paths)
    defaultSecurityConfig { scGateway = Just gateway } PreserveCredentials
    `shouldReturn` Right ()

sectionMode paths = do
  loaded <- loadSecurityConfig (securityFilePath paths)
  pure $ case loaded of
    Left _   -> Nothing
    Right cfg -> acfcMode =<< scAccessControl cfg

sectionMode :: SealPaths -> IO (Maybe T.Text)
writeStore :: SealPaths -> IO ()
writeStore paths =
  saveCredentials (credentialsFilePath paths)
    (CredentialsFile credentialsVersion
       (Map.singleton "cred-1" CredentialFileConfig
          { cfcPublicKey = "cGtleQ"
          , cfcSignCount = 0
          , cfcLabel = "test key"
          , cfcCreatedAt = "2026-10-30T14:00:00Z"
          , cfcRpId = "localhost"
          , cfcAddedVia = Just "cli_token"
          }))

claimFile :: SealPaths -> FilePath
claimFile paths = spState paths </> "enrollment-grant.claimed-stale"

-- | Hold the daemon lock in a forked child for the duration of an action, so
-- the command under test sees a live daemon (record locks do not conflict
-- within one process, so the holder has to be another process).
withHeldServeLock :: SealPaths -> IO a -> IO a
withHeldServeLock paths action = do
  let dir = spState paths
      ready = dir </> "lock-ready"
      go = dir </> "lock-go"
      lockPath = serveLockPath paths
  pid <- forkProcess $ do
    acquired <- acquireServeLock lockPath
    case acquired of
      Left _   -> exitImmediately (ExitFailure 1)
      Right _  -> do
        writeFile ready "held"
        waitFor go
        exitImmediately ExitSuccess
  waitFor ready
  result <- action
  writeFile go "exit"
  status <- getProcessStatus True False pid
  status `shouldBe` Just (Exited ExitSuccess)
  pure result

waitFor :: FilePath -> IO ()
waitFor marker = go (0 :: Int)
  where
    go n = do
      exists <- doesFileExist marker
      if exists
        then pure ()
        else if n > 500
          then fail ("timed out waiting for " <> marker)
          else threadDelay 10000 >> go (n + 1)

nearSeconds :: Integer -> NominalDiffTime -> Bool
nearSeconds expected actual =
  abs (realToFrac actual - fromIntegral expected :: Double) < 5

passkeySection :: AccessControlFileConfig
passkeySection = AccessControlFileConfig
  { acfcMode = Just "passkey"
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  }
