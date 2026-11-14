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
  , Outputs (..)
  , defaultOutputs
  , configureWith
  , ConfigureError (..)
  , PlannedConfigure (..)
  , planConfigure
  , configureExit
  ) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, finally, try)
import Control.Monad (filterM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Char (isControl, isSpace)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (diffUTCTime, getCurrentTime)
import System.Directory (doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr)
import Text.Read (readMaybe)
import Toml qualified

import Seal.Config.BootPlan
  ( BindCoordinates (..), BootInputs (..), BootPlan (..), CredentialsPresence
  , bootPlan, bootRefusalMessage, preflight )
import Seal.Config.Credentials
  ( MigrationOutcome (..), migrateLegacyCredentials )
import Seal.Config.Migrate (configHasLegacySecurityFields)
import Seal.Config.Paths
  ( SealPaths, configFilePath, credentialsFilePath, ensureSealDirs, getSealPaths
  , securityFilePath, enrollmentTokenPath, serveLockPath, tlsCertPath, tlsKeyPath )
import Seal.Config.Security
  ( AccessControlFileConfig (..), WriteMode (..), clearAccessControlSection
  , SecurityConfig (..), decodeSecurityConfig, gatewayConfigFromSecurity
  , loadSecurityConfig, securityConfigCodec, updateAccessControlSection
  , updateSecurityConfig, writeSecretFile )
import Seal.Config.Templates (ensureConfigTemplates)
import Seal.Gateway.Audit
  ( AuditEvent (..), AuditFields (..), appendAudit, emptyAuditFields )
import Seal.Gateway.Config
  ( GatewayConfig (..), PartialGatewayConfig (..), defaultGatewayConfig
  , effectiveTlsPaths, gatewayHostError, gatewayHostResolutionError, hostResolves
  , loadLegacyGatewayTable, tlsConfigError, tlsEnabled, tlsOriginError
  , withGatewayDefaults )
import Seal.Security.AccessControl
  ( CredentialAvailability (NoCredentials), canonicalOriginFor
  , credentialAvailability, isIpLiteral, isLoopbackHost, isWildcardHost )
import Seal.Security.DaemonLock
  ( acquireServeLock, daemonHoldsLock, releaseServeLock )
import Seal.Security.EnrollmentGrant
  ( Grant (..), GrantSource (..), MintedGrant (..), cancelGrant, defaultTtlFor
  , enrollGrant, grantSourceText, parseTtl )
import Seal.Security.WebAuthn (normalizeOrigin)
import Seal.Security.WebAuthn.Types (AccessMode (..), Credential (..))
import Seal.Security.TlsCert (generatedCertificateTrustHint)
import Seal.Types.Command
  ( AccessControlAction (..), ConfigureOptions (..), EnrollOptions (..) )

-- | Entry point for @seal access-control@.
runAccessControl :: AccessControlAction -> IO ExitCode
runAccessControl action = do
  paths <- getSealPaths
  -- Scaffold the two config files on first use, exactly as `serve` and `tui` do.
  -- This is not decorative here: `disable`, `reset` and `migrate-credentials`
  -- write security.toml, and 'Seal.Config.Security.saveSecurityConfig' creates it
  -- when absent — so without this a fresh install that runs one of those first
  -- would keep a comment-free file and never see the template.
  (created, warnings) <- ensureConfigTemplates paths
  forM_ created $ \fp ->
    hPutStrLn stderr ("[seal] wrote a documented config template at " <> fp)
  forM_ warnings $ \w -> hPutStrLn stderr ("[seal] " <> T.unpack w)
  runAccessControlWith paths action

-- | 'runAccessControl' against an explicit 'SealPaths'.
--
-- Split out so tests can point the command at a temporary home without
-- mutating @SEAL_HOME@ for the whole process (which every other test in the
-- suite shares).
runAccessControlWith :: SealPaths -> AccessControlAction -> IO ExitCode
runAccessControlWith paths action = case action of
  AcStatus                   -> status paths
  AcEnroll opts              -> enroll paths opts
  AcConfigure opts           -> configureWith defaultOutputs hostResolves paths opts
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
          when (any (\(_, cred) -> Just (credRpId cred) /= bpRpId plan) creds) $
            TIO.putStrLn
              "  hint: a credential is bound to another rp_id. Recover with\n\
              \  `seal access-control reset --yes` (deletes all passkeys), then\n\
              \  `seal access-control configure ...`, serve, and enroll again."
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
-- A browser-minted grant is created by the gateway, never by this command, so
-- reaching here would be a bug. Refuse rather than wave it through: the
-- window preflight is what keeps authority-without-a-secret off a reachable port.
windowAllowed _ UiToken = pure (Left "ui_token grants are minted by the gateway, not by `seal access-control enroll`.")
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
      TIO.putStrLn "  This also deleted every enrolled passkey. Enrolling again is required."
      TIO.putStrLn "  A running `seal serve` keeps its current mode until you restart it."
      TIO.putStrLn "  To target a hostname other than localhost, run"
      TIO.putStrLn "  `seal access-control configure --origin https://HOST --rp-id HOST`"
      TIO.putStrLn "  before restarting, then open the web UI to enroll a new passkey."
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
-- configure: first-run gateway coordinates
-- ---------------------------------------------------------------------------

-- | Where @configure@ writes its operator-facing output. The seam exists so
-- tests can capture stdout/stderr without redirecting the process.
data Outputs = Outputs
  { outLine :: !(Text -> IO ())
  , errLine :: !(Text -> IO ())
  }

defaultOutputs :: Outputs
defaultOutputs = Outputs TIO.putStrLn (hPutStrLn stderr . T.unpack)

-- | A configure failure. The constructor decides the exit code: malformed
-- flags are usage (2), a state/environment refusal is 1.
data ConfigureError
  = ConfigureUsage !Text
  | ConfigureRefusal !Text
  deriving stock (Eq, Show)

configureExit :: ConfigureError -> ExitCode
configureExit = \case
  ConfigureUsage _   -> ExitFailure 2
  ConfigureRefusal _ -> ExitFailure 1

configureMessage :: ConfigureError -> Text
configureMessage = \case
  ConfigureUsage m   -> m
  ConfigureRefusal m -> m

-- | The validated result: the document to write and the origin/rp_id it
-- resolves to.
data PlannedConfigure = PlannedConfigure
  { plConfig :: !SecurityConfig
  , plOrigin :: !(Maybe Text)
  , plRpId   :: !(Maybe Text)
  } deriving stock (Eq, Show)

-- | Persist the gateway coordinates. Acquires the serve lock so it cannot race
-- a running daemon; a concurrent @tui@/@vault setup@ writer can still race the
-- later write (accepted residual risk, see the plan).
configureWith
  :: Outputs
  -> (Text -> IO Bool)
  -> SealPaths
  -> ConfigureOptions
  -> IO ExitCode
configureWith out resolves paths opts = do
  ensureSealDirs paths
  acquired <- acquireServeLock (serveLockPath paths)
  case acquired of
    Left _ -> report out (ConfigureRefusal
      "`seal serve` is running for this SEAL_HOME; stop it before configuring coordinates.")
    Right lock -> configureLocked out resolves paths opts
                     `finally` releaseServeLock lock

configureLocked
  :: Outputs -> (Text -> IO Bool) -> SealPaths -> ConfigureOptions -> IO ExitCode
configureLocked out resolves paths opts = do
  legacy <- legacyConfigProblem paths
  case legacy of
    Just problem -> report out problem
    Nothing -> do
      loaded <- loadSecurityConfig (securityFilePath paths)
      case loaded of
        Left err -> report out
          (ConfigureRefusal ("security.toml could not be read: " <> err))
        Right cfg -> do
          inputs <- preflight paths
          case inputs of
            Left refusal -> report out
              (ConfigureRefusal (bootRefusalMessage refusal))
            Right bi -> case planConfigure cfg (biCredentials bi) opts of
              Left problem -> report out problem
              Right plan -> applyPlan out resolves paths opts cfg plan

applyPlan
  :: Outputs -> (Text -> IO Bool) -> SealPaths -> ConfigureOptions
  -> SecurityConfig -> PlannedConfigure -> IO ExitCode
applyPlan out resolves paths opts oldCfg plan = do
  let eff = gatewayConfigFromSecurity (plConfig plan)
  resolution <- gatewayHostResolutionError resolves (gcHost eff)
  case resolution of
    Just err -> report out (ConfigureRefusal err)
    Nothing -> do
      keys <- validateKeyFiles opts
      case keys of
        Left problem -> report out problem
        Right () -> do
          written <- updateSecurityConfig (securityFilePath paths)
                       (const (plConfig plan))
          case written of
            Left err -> report out
              (ConfigureRefusal ("could not write security.toml: " <> err))
            Right () -> do
              printConfigure out oldCfg plan
              printHints out paths plan
              pure ExitSuccess

report :: Outputs -> ConfigureError -> IO ExitCode
report out problem = errLine out (configureMessage problem)
                       >> pure (configureExit problem)

-- | Refuse when @config.toml@ still carries pre-split security fields. Running
-- @configure@ then would create a @security.toml@ that makes the next boot's
-- migration take the "security.toml wins" branch and drop the un-migrated
-- vault/execution settings, so we send the operator through one migration boot
-- first instead.
legacyConfigProblem :: SealPaths -> IO (Maybe ConfigureError)
legacyConfigProblem paths = do
  let path = configFilePath paths
  exists <- doesFileExist path
  if not exists then pure Nothing else do
    read' <- try (TIO.readFile path) :: IO (Either IOException Text)
    pure $ case read' of
      Left err -> Just (ConfigureRefusal
        ("config.toml could not be read: " <> T.pack (show err)))
      Right raw
        | configHasLegacySecurityFields raw -> Just (ConfigureRefusal
            ("config.toml still carries pre-split security fields.\n"
              <> "  Run `seal serve` once to migrate them into security.toml, "
              <> "then retry configure."))
        | otherwise -> Nothing

validateKeyFiles :: ConfigureOptions -> IO (Either ConfigureError ())
validateKeyFiles opts = do
  let named = catMaybes [coTlsCert opts, coTlsKey opts]
  bad <- filterM (fmap not . readable) named
  pure $ case bad of
    []      -> Right ()
    (p : _) -> Left (ConfigureRefusal
      ("TLS key file \"" <> T.pack p <> "\" is missing or unreadable."))
  where
    readable p = do
      exists <- doesFileExist p
      if not exists then pure False else do
        content <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
        pure (either (const False) (const True) content)

printConfigure :: Outputs -> SecurityConfig -> PlannedConfigure -> IO ()
printConfigure out oldCfg plan = do
  let oldGw = gatewayConfigFromSecurity oldCfg
      newGw = gatewayConfigFromSecurity (plConfig plan)
      oldAc = scAccessControl oldCfg
      newAc = scAccessControl (plConfig plan)
      fmtList xs = if null xs then "(none)" else T.intercalate "," xs
      fields =
        [ ("bind_host", gcHost oldGw, gcHost newGw)
        , ("bind_port", tshow (gcPort oldGw), tshow (gcPort newGw))
        , ("tls", onOff (tlsEnabled oldGw), onOff (tlsEnabled newGw))
        , ("origin", fromMaybe "(none)" (oldAc >>= acfcOrigin)
                   , fromMaybe "(none)" (newAc >>= acfcOrigin))
        , ("rp_id", fromMaybe "(none)" (oldAc >>= acfcRpId)
                  , fromMaybe "(none)" (newAc >>= acfcRpId))
        , ("allowed_origins", fmtList (gcAllowedOrigins oldGw)
                            , fmtList (gcAllowedOrigins newGw))
        , ("tls_hosts", fmtList (gcTlsHosts oldGw), fmtList (gcTlsHosts newGw))
        ]
  forM_ [ (k, o, n) | (k, o, n) <- fields, o /= n ] $ \(k, o, n) ->
    outLine out (k <> ": " <> o <> " -> " <> n)
  outLine out ("bind_host: " <> gcHost newGw)
  outLine out ("bind_port: " <> tshow (gcPort newGw))
  outLine out ("tls: " <> onOff (tlsEnabled newGw))
  outLine out ("origin: " <> fromMaybe "(none)" (plOrigin plan))
  outLine out ("rp_id: " <> fromMaybe "(none)" (plRpId plan))

printHints :: Outputs -> SealPaths -> PlannedConfigure -> IO ()
printHints out paths plan = do
  let gw = gatewayConfigFromSecurity (plConfig plan)
      mode = scAccessControl (plConfig plan) >>= acfcMode
      (certPath, _) =
        effectiveTlsPaths (tlsCertPath paths) (tlsKeyPath paths) gw
  when (tlsEnabled gw && isNothing (gcTlsCert gw)) $
    errLine out (generatedCertificateTrustHint certPath)
  when (mode == Just "none"
         && not (isLoopbackHost (gcHost gw))
         && maybe False (not . isHttps) (plOrigin plan)) $
    errLine out
      "warning: mode \"none\" on a non-loopback plain-http bind exposes the \
      \gateway without authentication."
  errLine out "next: run `seal serve`, then `seal access-control status`."
  errLine out "      Enroll through the origin clients use; changing it later orphans passkeys."

-- | Pure planning and validation. No I/O, no filesystem; the handler supplies
-- credentials and runs the resolver/certificate checks.
planConfigure
  :: SecurityConfig
  -> CredentialsPresence
  -> ConfigureOptions
  -> Either ConfigureError PlannedConfigure
planConfigure sec creds opts = do
  whenE (not (anyOption opts)) (usageE
    "configure needs at least one of --host, --port, --tls, --no-tls, \
    \--tls-cert, --tls-key, --tls-host, --origin or --rp-id.")
  mPort <- traverse parsePort (coPort opts)
  whenE (coTls opts && coNoTls opts) (usageE
    "--tls and --no-tls cannot be combined.")
  whenE (coNoTls opts && any isJust [coTlsCert opts, coTlsKey opts]
          || coNoTls opts && not (null (coTlsHosts opts))) (usageE
    "--no-tls cannot be combined with --tls-cert, --tls-key or --tls-host.")
  case (coTlsCert opts, coTlsKey opts) of
    (Just _, Nothing) -> usageE "--tls-cert requires --tls-key."
    (Nothing, Just _) -> usageE "--tls-key requires --tls-cert."
    _                 -> Right ()
  mapM_ checkCertPath (catMaybes [coTlsCert opts, coTlsKey opts])
  mapM_ checkTlsHost (coTlsHosts opts)
  requestedOrigin <- traverse parseOriginStrict (coOrigin opts)
  requestedRpId <- traverse parseRpIdText (coRpId opts)
  let oldGw = fromMaybe emptyGateway (scGateway sec)
      oldAc = fromMaybe emptyAccess (scAccessControl sec)
      oldEff = gatewayConfigFromSecurity sec
      newGw0 = applyGatewayDeltas oldGw mPort opts
      newGw1 = if coTls opts || isJust (coTlsCert opts) || isJust (coTlsKey opts)
                 then newGw0 { pgcTls = Just True }
                 else newGw0
      newGw2 = if null (coTlsHosts opts)
                 then newGw1
                 else newGw1 { pgcTlsHosts = coTlsHosts opts }
      newGw3 = if coNoTls opts
                 then newGw1 { pgcTls = Just False, pgcTlsCert = Nothing
                             , pgcTlsKey = Nothing, pgcTlsHosts = [] }
                 else newGw2
      effGw = withGatewayDefaults newGw3
      effTls = tlsEnabled effGw
  whenE (not (null (coTlsHosts opts)) && not effTls) (usageE
    "--tls-host requires TLS: pass --tls or --tls-cert/--tls-key.")
  chosenOrigin <- chooseOrigin opts oldAc effGw effTls requestedOrigin
  let derivedRpId = chosenOrigin >>= originHost
      effectiveRpId = requestedRpId <|> acfcRpId oldAc <|> derivedRpId
  validateRpId chosenOrigin effectiveRpId
  let oldDerived = derivedOriginForm (gcHost oldEff) (gcPort oldEff)
      newDerived = if effTls
                     then httpsOriginFor (gcHost effGw) (gcPort effGw)
                     else derivedOriginForm (gcHost effGw) (gcPort effGw)
      managedNew = chosenOrigin <|> newDerived
      removed = catMaybes [acfcOrigin oldAc, oldDerived]
      kept = filter (`notElem` removed)
               (map normaliseEntry (pgcAllowedOrigins oldGw))
      merged = nub (kept ++ maybeToList managedNew)
      merged' = if null merged then maybeToList managedNew else merged
      newGw = newGw3 { pgcAllowedOrigins = merged' }
      newAc = oldAc { acfcOrigin = chosenOrigin
                    , acfcRpId = requestedRpId <|> acfcRpId oldAc }
      newCfg = sec { scGateway = Just newGw, scAccessControl = Just newAc }
      raw = Toml.encode securityConfigCodec newCfg
      coords = BindCoordinates (gcHost effGw) (gcPort effGw)
      inputs = BootInputs raw (scAccessControl newCfg) creds
  plan <- case bootPlan coords inputs of
    Left refusal -> refusalE (bootRefusalMessage refusal)
    Right p      -> Right p
  maybe (Right ()) usageE (gatewayHostError (gcHost effGw))
  maybe (Right ()) refusalE (tlsConfigError effGw)
  maybe (Right ()) refusalE
    (tlsOriginError (tlsEnabled effGw) (bpOrigin plan))
  whenE (not (isLoopbackHost (gcHost effGw))
          && not (maybe False isHttps (bpOrigin plan))
          && bpMode plan /= AccessOpen) (refusalE
    "refusing to write a non-loopback plain-http gateway. Bind loopback (and \
    \use a TLS reverse proxy), enable TLS, or use mode \"none\" explicitly.")
  let enrolled = bpCreds plan
      rp = bpRpId plan
      orphans = maybe True (\r -> any ((/= r) . credRpId) (Map.elems enrolled)) rp
  whenE (not (Map.null enrolled) && orphans) (refusalE
    ("this change would orphan every enrolled passkey. Recover with:\n"
      <> "  seal access-control reset --yes   (deletes all enrolled passkeys)\n"
      <> "  seal access-control configure ... (the coordinates you want)\n"
      <> "  seal serve, then enroll a new passkey."))
  case decodeSecurityConfig raw of
    Right decoded | decoded == newCfg -> Right ()
    _ -> refusalE
      "refusing to write security.toml: the encoded document does not round-trip."
  pure PlannedConfigure
    { plConfig = newCfg
    , plOrigin = bpOrigin plan
    , plRpId = bpRpId plan
    }

anyOption :: ConfigureOptions -> Bool
anyOption opts =
  any isJust [coHost opts, coPort opts, coOrigin opts, coRpId opts]
    || any isJust [coTlsCert opts, coTlsKey opts]
    || coTls opts || coNoTls opts || not (null (coTlsHosts opts))

parsePort :: Text -> Either ConfigureError Int
parsePort raw = case readMaybe (T.unpack raw) of
  Just n | n >= 1 && n <= 65535 -> Right n
  _ -> usageE ("--port must be an integer between 1 and 65535, got \"" <> raw <> "\".")

checkCertPath :: FilePath -> Either ConfigureError ()
checkCertPath p
  | isAbsolute p = Right ()
  | otherwise = usageE ("--tls-cert/--tls-key must be absolute paths, got \""
                          <> T.pack p <> "\".")

checkTlsHost :: Text -> Either ConfigureError ()
checkTlsHost h
  | T.null (T.strip h) = usageE "--tls-host must not be empty."
  | T.any (\c -> isSpace c || isControl c) h = usageE
      "--tls-host must not contain whitespace or control characters."
  | otherwise = Right ()

parseOriginStrict :: Text -> Either ConfigureError Text
parseOriginStrict raw
  | T.any isSpace raw = usageE
      "an origin must not contain whitespace."
  | T.any (`elem` ("@?#\\" :: String)) raw = usageE
      "an origin must be scheme://host[:port] with no userinfo, query, fragment or path."
  | otherwise = case normalizeOrigin raw of
      Just o | isHttpOrigin o -> Right o
      _ -> usageE ("\"" <> raw <> "\" is not an absolute http:// or https:// origin.")

parseRpIdText :: Text -> Either ConfigureError Text
parseRpIdText raw
  | T.null rp = usageE "--rp-id must not be empty."
  | isIpLiteral rp = usageE
      ("--rp-id \"" <> rp <> "\" is an IP address; a WebAuthn rp_id must be a domain name.")
  | otherwise = Right rp
  where
    rp = T.toLower (T.strip raw)

validateRpId :: Maybe Text -> Maybe Text -> Either ConfigureError ()
validateRpId Nothing (Just _) = refusalE
  "an rp_id needs an origin; pass --origin as well."
validateRpId _ Nothing = Right ()
validateRpId (Just origin) (Just rp) =
  let host = fromMaybe "" (originHost origin)
  in if rp == host
       || (("." <> rp) `T.isSuffixOf` host && T.count "." rp >= 1)
       then Right ()
       else usageE ("--rp-id \"" <> rp <> "\" is not a parent domain of the origin host \""
                      <> host <> "\".")

chooseOrigin
  :: ConfigureOptions
  -> AccessControlFileConfig
  -> GatewayConfig
  -> Bool
  -> Maybe Text
  -> Either ConfigureError (Maybe Text)
chooseOrigin opts oldAc effGw effTls requested = case requested of
  Just o -> Right (Just o)
  Nothing
    | coNoTls opts -> Right (acfcOrigin oldAc)
    | not effTls   -> Right (acfcOrigin oldAc)
    | otherwise -> case acfcOrigin oldAc of
        Just o | isHttps o -> Right (Just o)
               | otherwise -> refusalE
                   ("TLS is enabled but [access_control] origin is \"" <> o
                     <> "\"; pass --origin https://<the host clients use>.")
        Nothing -> case httpsOriginFor (gcHost effGw) (gcPort effGw) of
          Just o  -> Right (Just o)
          Nothing -> refusalE
            ("cannot derive an https origin for bind host \"" <> gcHost effGw
              <> "\"; pass --origin.")

applyGatewayDeltas
  :: PartialGatewayConfig -> Maybe Int -> ConfigureOptions -> PartialGatewayConfig
applyGatewayDeltas oldGw mPort opts = oldGw
  { pgcHost = coHost opts <|> pgcHost oldGw
  , pgcPort = mPort <|> pgcPort oldGw
  , pgcTlsCert = fmap T.pack (coTlsCert opts) <|> pgcTlsCert oldGw
  , pgcTlsKey = fmap T.pack (coTlsKey opts) <|> pgcTlsKey oldGw
  }

derivedOriginForm :: Text -> Int -> Maybe Text
derivedOriginForm host port
  | isWildcardHost host = Nothing
  | otherwise = Just (canonicalOriginFor host port)

httpsOriginFor :: Text -> Int -> Maybe Text
httpsOriginFor host port
  | isWildcardHost host = Nothing
  | isLoopbackHost host = Just (httpsUrl "localhost" port)
  | isIpLiteral host || T.isInfixOf ":" host = Nothing
  | otherwise = Just (httpsUrl (T.toLower host) port)
  where
    httpsUrl h p
      | p == 443 = "https://" <> h
      | otherwise = "https://" <> h <> ":" <> tshow p

originHost :: Text -> Maybe Text
originHost origin =
  let (_, rest) = T.breakOn "://" origin
  in if T.null rest
       then Nothing
       else let authority = T.drop 3 rest
            in Just (T.toLower (T.takeWhile (/= ':') authority))

normaliseEntry :: Text -> Text
normaliseEntry raw = fromMaybe raw (normalizeOrigin raw)

isHttpOrigin :: Text -> Bool
isHttpOrigin o = "http://" `T.isPrefixOf` o || "https://" `T.isPrefixOf` o

isHttps :: Text -> Bool
isHttps o = "https://" `T.isPrefixOf` o

onOff :: Bool -> Text
onOff True  = "on"
onOff False = "off"

tshow :: Show a => a -> Text
tshow = T.pack . show

usageE :: Text -> Either ConfigureError a
usageE = Left . ConfigureUsage

refusalE :: Text -> Either ConfigureError a
refusalE = Left . ConfigureRefusal

whenE :: Bool -> Either ConfigureError () -> Either ConfigureError ()
whenE True  action = action
whenE False _      = Right ()

emptyGateway :: PartialGatewayConfig
emptyGateway = PartialGatewayConfig
  { pgcPort = Nothing
  , pgcHost = Nothing
  , pgcStaticDir = Nothing
  , pgcAllowedOrigins = []
  , pgcFileExplorerEnabled = Nothing
  , pgcTlsCert = Nothing
  , pgcTlsKey = Nothing
  , pgcTls = Nothing
  , pgcTlsHosts = []
  }

emptyAccess :: AccessControlFileConfig
emptyAccess = AccessControlFileConfig
  { acfcMode = Nothing
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  }

-- ---------------------------------------------------------------------------

gatewayConfig :: SealPaths -> IO GatewayConfig
gatewayConfig paths = do
  sec <- loadSecurityConfig (securityFilePath paths)
  case sec of
    Right cfg | isJust (scGateway cfg) -> pure (gatewayConfigFromSecurity cfg)
    -- Upgrade window: this SEAL_HOME has not booted serve/tui since the
    -- [gateway] section moved, so the table is still in config.toml. Read it
    -- from there — read-only. `status` and `enroll` must not rewrite
    -- security.toml: a pre-upgrade daemon may be running, and the write lock
    -- is process-local. The next serve/tui boot moves the table and this path
    -- goes quiet.
    _ -> do
      legacy <- loadLegacyGatewayTable (configFilePath paths)
      pure (maybe defaultGatewayConfig withGatewayDefaults legacy)
