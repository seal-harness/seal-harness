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
import System.IO (hPutStrLn, stderr)

import Seal.Config.File (RuntimeConfig (..), loadRuntimeConfig)
import Seal.Config.Credentials
  ( MigrationOutcome (..), migrateLegacyCredentials )
import Seal.Config.Paths
  ( SealPaths, configFilePath, credentialsFilePath, getSealPaths, securityFilePath )
import Seal.Config.Security (WriteMode (..), clearAccessControlSection)
import Seal.Config.BootPlan
  ( BindCoordinates (..), BootPlan (..), bootPlan, bootRefusalMessage, preflight )
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Security.WebAuthn.Types (AccessMode (..), Credential (..))
import Seal.Types.Command (AccessControlAction (..))

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
  AcReset                    -> reset paths
  AcMigrateCredentials force -> migrate paths force

-- | Say why, on stderr, and report a refusal.
--
-- stdout carries data (the status report, the enrollment token); stderr carries
-- reasons. Keeping them apart is what lets an operator do
-- @seal access-control enroll >token.txt@ and still see what happened.
refuse :: T.Text -> IO ExitCode
refuse message = hPutStrLn stderr (T.unpack message) >> pure (ExitFailure 1)

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

-- | Move credentials out of @security.toml@ and into @credentials.toml@.
migrate :: SealPaths -> Bool -> IO ExitCode
migrate paths force = do
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
  result <- clearAccessControlSection (securityFilePath paths) DropCredentials
  case result of
    Left err -> refuse ("Could not reset access control: " <> err)
    Right () -> do
      TIO.putStrLn "Removed [access_control] from ~/.seal/security.toml."
      TIO.putStrLn "  A running `seal serve` keeps its current mode until you restart it."
      TIO.putStrLn "  After restarting, open the web UI to enroll a passkey."
      pure ExitSuccess

-- ---------------------------------------------------------------------------

gatewayConfig :: SealPaths -> IO GatewayConfig
gatewayConfig paths = do
  cfg <- loadRuntimeConfig (configFilePath paths)
  pure $ case cfg of
    Right rc -> maybe defaultGatewayConfig withGatewayDefaults (rcGateway rc)
    Left _   -> defaultGatewayConfig
