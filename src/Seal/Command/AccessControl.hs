{-# LANGUAGE OverloadedStrings #-}
-- | @seal access-control@ — the human-driven admin path for the passkey
-- settings in @~\/.seal\/security.toml@.
--
-- This is the terminal escape hatch: @reset@ removes the @[access_control]@
-- table so an operator who lost their only passkey can get back to the setup
-- screen, and @enroll@ mints the one-time authority that adds a new one. It is
-- a CLI command, never an opcode — nothing an agent can invoke reaches
-- @~\/.seal@.
--
-- Every action returns an 'ExitCode' instead of exiting: @exitWith@ stays at
-- the @AppMain.hs@ call site, so @0@ (ok) / @1@ (refusal) / @2@ (usage) are
-- assertable in-process.
module Seal.Command.AccessControl
  ( runAccessControl
  , runAccessControlWith
  ) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (ExitCode (..))
import System.IO (hIsTerminalDevice, hPutStrLn, stderr)
import Data.Maybe (fromMaybe, isJust)
import Control.Monad (unless, when)
import Data.Time (diffUTCTime, getCurrentTime)
import System.Directory (doesFileExist, removeFile)

import Seal.Config.File (RuntimeConfig (..), loadRuntimeConfig)
import Seal.Config.Credentials
  ( MigrationOutcome (..), migrateLegacyCredentials )
import Seal.Config.Paths
  ( SealPaths, configFilePath, credentialsFilePath, getSealPaths, securityFilePath
  , enrollmentTokenPath, serveLockPath )
import Seal.Security.DaemonLock (daemonHoldsLock)
import Seal.Gateway.Audit
  ( AuditEvent (..), AuditFields (..), appendAudit, emptyAuditFields )
import Seal.Config.Security
  ( AccessControlFileConfig (..), WriteMode (..), clearAccessControlSection
  , updateAccessControlSection, writeSecretFile )
import Seal.Security.AccessControl
  ( CredentialAvailability (NoCredentials), credentialAvailability, isLoopbackHost )
import Seal.Security.EnrollmentGrant
  ( Grant (..), GrantSource (..), MintedGrant (..), cancelGrant, defaultTtlFor
  , enrollGrant, grantSourceText, parseTtl )
import Seal.Config.BootPlan
  ( BindCoordinates (..), BootPlan (..), bootPlan, bootRefusalMessage, preflight )
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Security.WebAuthn.Types (AccessMode (..), Credential (..))
import Seal.Types.Command (AccessControlAction (..), EnrollOptions (..))

-- | Entry point for @seal access-control@.
runAccessControl :: AccessControlAction -> IO ExitCode
runAccessControl action = getSealPaths >>= \paths -> runAccessControlWith paths action

-- | 'runAccessControl' against an explicit 'SealPaths'.
--
-- Split out so tests can point the command at a temporary home without
-- mutating @SEAL_HOME@ for the whole process (which every other test in the
-- suite shares).
runAccessControlWith :: SealPaths -> AccessControlAction -> IO ExitCode
runAccessControlWith paths action = case action of
  AcStatus                   -> status paths
  AcEnroll opts              -> enroll paths opts
  AcDisable yes              -> disable paths yes
  AcReset                    -> reset paths
  AcMigrateCredentials force -> migrate paths force

-- | Say why, on stderr, and report a refusal.
--
-- stdout carries data (the status report, the enrollment token); stderr carries
-- reasons. Keeping them apart is what lets an operator do
-- @seal access-control enroll >token.txt@ and still see what happened.
refuse :: T.Text -> IO ExitCode
refuse message = hPutStrLn stderr (T.unpack message) >> pure (ExitFailure 1)

-- | A usage error: the flags do not make sense together, or a value is
-- malformed. Exit code 2, distinguishing "you typed it wrong" from "the state
-- refused you" (design §12).
usage :: T.Text -> IO ExitCode
usage message = hPutStrLn stderr (T.unpack message) >> pure (ExitFailure 2)

-- | Refuse to touch the store while a daemon owns this @SEAL_HOME@.
--
-- The probe is the kernel lock, not a pid file: a daemon that crashed leaves no
-- false refusal behind (design §12).
requireDaemonStopped :: SealPaths -> T.Text -> IO (Either T.Text ())
requireDaemonStopped paths action = do
  running <- daemonHoldsLock (serveLockPath paths)
  pure $ if running
    then Left ("refusing to " <> action <> ": `seal serve` is running for this SEAL_HOME.\n"
                <> "  Stop it first — it has the credential store and state files open.")
    else Right ()

-- | Print the current mode, the resolved origin/rpId and the enrolled
-- credentials (labels and counters — never key material).
status :: SealPaths -> IO ExitCode
status paths = do
  gwCfg <- gatewayConfig paths
  inputs <- preflight paths
  let coords = BindCoordinates (gcHost gwCfg) (gcPort gwCfg)
      decision = inputs >>= bootPlan coords
  case decision of
    Left refusal ->
      refuse ("Access control: INVALID — " <> bootRefusalMessage refusal)
    Right plan -> do
      TIO.putStrLn ("Access control: " <> describe (bpMode plan))
      case (bpOrigin plan, bpRpId plan) of
        (Just origin, Just rpId) -> do
          TIO.putStrLn ("  origin: " <> origin)
          TIO.putStrLn ("  rp id:  " <> rpId)
        _ -> TIO.putStrLn "  (no origin resolved — set [access_control] origin for a wildcard bind)"
      let creds = Map.toList (bpCreds plan)
      if null creds
        then TIO.putStrLn "  credentials: none enrolled"
        else do
          TIO.putStrLn ("  credentials: " <> T.pack (show (length creds)))
          mapM_ (printCred (bpRpId plan)) creds
      TIO.putStrLn (case bpMintGrant plan of
        Just _  -> "  enrollment: boot mints a token (run `seal access-control enroll`)"
        Nothing -> "  enrollment: a usable passkey authorizes a new one")
      pure ExitSuccess
  where
    describe mode = case mode of
      AccessPasskey      -> "passkey"
      AccessOpen         -> "none (explicitly waived — anyone who can reach the gateway has full control)"
      AccessUnconfigured -> "not configured (the gateway serves only the setup screen)"

    printCred rpId (credIdText, cred) = TIO.putStrLn
      ("    - " <> credIdText <> "  " <> credLabel cred
        <> "  rp_id=" <> credRpId cred
        <> "  " <> (if Just (credRpId cred) == rpId then "usable" else "not usable here")
        <> "  sign_count=" <> T.pack (show (credSignCount cred)))

-- | @enroll@: mint the one-time authority that adds a credential.
--
-- stdout carries the token (and nothing else), stderr carries the hints, so
-- @seal access-control enroll > token.txt@ works and still tells the operator
-- what to do with it.
enroll :: SealPaths -> EnrollOptions -> IO ExitCode
enroll paths opts
  | eoCancel opts, eoNoToken opts || eoForce opts || isJust (eoTtl opts) =
      usage "--cancel cannot be combined with --no-token, --ttl or --force."
  | otherwise = case traverse (parseTtl . T.pack) (eoTtl opts) of
      Left err -> usage err
      Right mTtl
        | eoCancel opts -> do
            cancelGrant paths
            TIO.putStrLn "Cancelled any outstanding enrollment grant."
            pure ExitSuccess
        | otherwise -> do
            let source = if eoNoToken opts then CliWindow else CliToken
                ttl = fromMaybe (defaultTtlFor source) mTtl
            allowed <- windowAllowed paths source
            case allowed of
              Left err -> refuse err
              Right () -> do
                minted <- enrollGrant paths source ttl (eoForce opts)
                case minted of
                  Left err     -> refuse err
                  Right result -> announce paths result

-- | @--no-token@ is authority with no secret, so it is confined to the
-- bootstrap state (design §7.1, §12): a loopback bind, a loopback resolved
-- origin, and nothing enrolled. There is no override — a window on a reachable
-- gateway is anyone's enrollment.
windowAllowed :: SealPaths -> GrantSource -> IO (Either T.Text ())
windowAllowed _ CliToken = pure (Right ())
windowAllowed _ Assertion = pure (Right ())
windowAllowed paths CliWindow = do
  gwCfg <- gatewayConfig paths
  inputs <- preflight paths
  let coords = BindCoordinates (gcHost gwCfg) (gcPort gwCfg)
  pure $ case inputs >>= bootPlan coords of
    Left refusal -> Left (windowRefusal
      ("this SEAL_HOME cannot serve as configured: " <> bootRefusalMessage refusal))
    Right plan
      | not (isLoopbackHost (bcHost coords)) ->
          Left (windowRefusal "the gateway binds a non-loopback address")
      | not (maybe False isLoopbackHost (bpRpId plan)) ->
          Left (windowRefusal "the resolved origin is not loopback")
      | credentialAvailability (bpRpId plan) (bpCreds plan) /= NoCredentials ->
          Left (windowRefusal "credentials are already enrolled; use a token or an assertion")
      | otherwise -> Right ()
  where
    windowRefusal reason =
      "--no-token is not available here: " <> reason <> ".\n"
        <> "  An enrollment window presents no secret, so it exists only while\n"
        <> "  nothing is enrolled and the gateway is reachable from this machine\n"
        <> "  alone. Mint a token instead: `seal access-control enroll`."

-- | Print the minted grant: token on stdout, everything else on stderr.
announce :: SealPaths -> MintedGrant -> IO ExitCode
announce paths minted = do
  now <- getCurrentTime
  _ <- appendAudit paths now (emptyAuditFields GrantMinted)
         { afVia = Just (grSource (mgGrant minted))
         , afRemainingSeconds = Just (secondsLeft now (mgGrant minted))
         }
  interactive <- hIsTerminalDevice stderr
  case mgToken minted of
    Just token -> do
      TIO.putStrLn token
      unless interactive $ do
        writeSecretFile (enrollmentTokenPath paths) token
        hPutStrLn stderr ("The token is also stored at "
                            <> enrollmentTokenPath paths <> " (mode 0600), because "
                            <> "stderr is not a terminal.")
    Nothing ->
      TIO.putStrLn "No token: this is a loopback enrollment window (5 minutes)."
  hPutStrLn stderr (T.unpack (summary now (mgGrant minted)))
  pure ExitSuccess
  where
    secondsLeft now grant =
      max 0 (ceiling (realToFrac (diffUTCTime (grExpiresAt grant) now) :: Double) :: Int)

    summary now grant =
      "Grant minted via " <> grantSourceText (grSource grant) <> ", expiring in "
        <> T.pack (show (max 0 (ceiling
             (realToFrac (diffUTCTime (grExpiresAt grant) now) :: Double) :: Int)))
        <> "s. Open the web UI and enroll a passkey; the grant is consumed on success."

-- | @disable@: the only way to turn access control off.
--
-- No HTTP request can do this (design §5 invariant 7), which is what removes
-- the "one token enrolls and disables" blast radius. Credentials are kept: the
-- operator who wants them gone runs @reset --yes@.
disable :: SealPaths -> Bool -> IO ExitCode
disable _ False =
  usage "disable requires --yes: it turns access control off, and anyone who can reach the gateway gets full control."
disable paths True = do
  stopped <- requireDaemonStopped paths "disable access control"
  case stopped of
    Left err -> refuse err
    Right () -> do
      written <- updateAccessControlSection (securityFilePath paths) $ \cfg ->
        cfg { acfcMode = Just "none" }
      case written of
        Left err -> refuse ("could not disable access control: " <> err)
        Right _ -> do
          now <- getCurrentTime
          _ <- appendAudit paths now (emptyAuditFields ModeDisabled)
          TIO.putStrLn "Access control is off ([access_control] mode = \"none\")."
          TIO.putStrLn "  Credentials are kept. `seal access-control enroll` turns it back on."
          pure ExitSuccess

-- | Move credentials out of @security.toml@ and into @credentials.toml@.
migrate :: SealPaths -> Bool -> IO ExitCode
migrate paths force = do
  stopped <- requireDaemonStopped paths "migrate credentials"
  case stopped of
    Left err -> refuse err
    Right () -> migrateWith paths force

migrateWith :: SealPaths -> Bool -> IO ExitCode
migrateWith paths force = do
  result <- migrateLegacyCredentials (securityFilePath paths)
                                     (credentialsFilePath paths) force
  case result of
    Left err -> refuse ("Could not migrate credentials: " <> err)
    Right NothingToMigrate -> do
      TIO.putStrLn "Nothing to migrate: security.toml holds no credential tables."
      pure ExitSuccess
    Right (Migrated count) -> do
      TIO.putStrLn ("Moved " <> T.pack (show count) <> " credential(s) to "
                     <> T.pack (credentialsFilePath paths) <> ".")
      TIO.putStrLn "  Removed the [access_control.credentials] tables from security.toml."
      TIO.putStrLn "  Restart `seal serve` to pick up the new store."
      pure ExitSuccess

-- | Remove the @[access_control]@ table, returning the gateway to the setup
-- screen.
--
-- 'DropCredentials' is correct here and nowhere else on this path: @reset@ is
-- CLI-only and @--yes@ is mandatory, so a human decided to destroy the
-- credential tables rather than be blocked by them. Every other writer keeps
-- 'PreserveCredentials' and is refused instead.
reset :: SealPaths -> IO ExitCode
reset paths = do
  stopped <- requireDaemonStopped paths "reset access control"
  case stopped of
    Left err -> refuse err
    Right () -> resetWith paths

resetWith :: SealPaths -> IO ExitCode
resetWith paths = do
  result <- clearAccessControlSection (securityFilePath paths) DropCredentials
  case result of
    Left err -> refuse ("Could not reset access control: " <> err)
    Right () -> do
      TIO.putStrLn "Removed [access_control] from ~/.seal/security.toml."
      TIO.putStrLn "  A running `seal serve` keeps its current mode until you restart it."
      TIO.putStrLn "  After restarting, open the web UI to enroll a passkey."
      -- `reset` is the lost-every-device escape hatch, so it also destroys what
      -- would otherwise be left half-configured: the store, the outstanding
      -- grant and its token. The [access_control] section is already gone, so a
      -- crash from here leaves the loud `unconfigured` state, not a locked-out
      -- one.
      cancelGrant paths
      removeStoreFile paths
      pure ExitSuccess

-- | Delete @credentials.toml@ if it exists. Only @reset --yes@ may do this.
removeStoreFile :: SealPaths -> IO ()
removeStoreFile paths = do
  let path = credentialsFilePath paths
  exists <- doesFileExist path
  when exists (removeFile path)

-- ---------------------------------------------------------------------------

gatewayConfig :: SealPaths -> IO GatewayConfig
gatewayConfig paths = do
  cfg <- loadRuntimeConfig (configFilePath paths)
  pure $ case cfg of
    Right rc -> maybe defaultGatewayConfig withGatewayDefaults (rcGateway rc)
    Left _   -> defaultGatewayConfig
