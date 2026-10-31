{-# LANGUAGE OverloadedStrings #-}
-- | @seal access-control@ — the human-driven admin path for the passkey
-- settings in @~\/.seal\/security.toml@.
--
-- This is the terminal escape hatch: 'AcReset' removes the
-- @[access_control]@ table so an operator who lost their only passkey can get
-- back to the setup screen. It is a CLI command, never an opcode — nothing an
-- agent can invoke reaches @~\/.seal@.
module Seal.Command.AccessControl
  ( runAccessControl
  ) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO

import Seal.Config.File (RuntimeConfig (..), loadRuntimeConfig)
import Seal.Config.Paths (SealPaths, configFilePath, getSealPaths, securityFilePath)
import Seal.Config.Security
  ( AccessControlFileConfig (..), SecurityConfig (..), clearAccessControlSection
  , loadSecurityConfig )
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
import Seal.Security.AccessControl
  ( ResolvedAccessControl (..), resolveAccessControl )
import Seal.Security.WebAuthn.Types (AccessMode (..), Credential (..))
import Seal.Types.Command (AccessControlAction (..))

-- | Entry point for @seal access-control status@ and
-- @seal access-control reset --yes@.
runAccessControl :: AccessControlAction -> IO ()
runAccessControl action = do
  paths <- getSealPaths
  case action of
    AcStatus   -> status paths
    AcReset    -> reset paths

-- | Print the current mode, the resolved origin/rpId and the enrolled
-- credentials (labels and counters — never key material).
status :: SealPaths -> IO ()
status paths = do
  section <- loadSection paths
  gwCfg <- gatewayConfig paths
  case resolveAccessControl (gcHost gwCfg) (gcPort gwCfg) section of
    Left err -> do
      TIO.putStrLn ("Access control: INVALID — " <> err)
      TIO.putStrLn "  Fix [access_control] in ~/.seal/security.toml, or run `seal access-control reset --yes`."
    Right resolved -> do
      TIO.putStrLn ("Access control: " <> describe (racMode resolved))
      case (racOrigin resolved, racRpId resolved) of
        (Just origin, Just rpId) -> do
          TIO.putStrLn ("  origin: " <> origin)
          TIO.putStrLn ("  rp id:  " <> rpId)
        _ -> TIO.putStrLn "  (no origin resolved — set [access_control] origin for a wildcard bind)"
      let creds = Map.toList (racCredentials resolved)
      if null creds
        then TIO.putStrLn "  credentials: none enrolled"
        else do
          TIO.putStrLn ("  credentials: " <> T.pack (show (length creds)))
          mapM_ printCred creds
  where
    describe mode = case mode of
      AccessPasskey      -> "passkey"
      AccessOpen         -> "none (explicitly waived — anyone who can reach the gateway has full control)"
      AccessUnconfigured -> "not configured (the gateway serves only the setup screen)"

    printCred (credIdText, cred) = TIO.putStrLn
      ("    - " <> credIdText <> "  " <> credLabel cred
        <> "  rp_id=" <> credRpId cred
        <> "  sign_count=" <> T.pack (show (credSignCount cred)))

-- | Remove the @[access_control]@ table, returning the gateway to the setup
-- screen.
reset :: SealPaths -> IO ()
reset paths = do
  result <- clearAccessControlSection (securityFilePath paths)
  case result of
    Left err -> TIO.putStrLn ("Could not reset access control: " <> err)
    Right () -> do
      TIO.putStrLn "Removed [access_control] from ~/.seal/security.toml."
      TIO.putStrLn "  A running `seal serve` keeps its current mode until you restart it."
      TIO.putStrLn "  After restarting, open the web UI to enroll a passkey (or waive again)."

-- ---------------------------------------------------------------------------

loadSection :: SealPaths -> IO (Maybe AccessControlFileConfig)
loadSection paths = do
  loaded <- loadSecurityConfig (securityFilePath paths)
  pure $ case loaded of
    Left _    -> Nothing
    Right cfg -> scAccessControl cfg

gatewayConfig :: SealPaths -> IO GatewayConfig
gatewayConfig paths = do
  cfg <- loadRuntimeConfig (configFilePath paths)
  pure $ case cfg of
    Right rc -> maybe defaultGatewayConfig withGatewayDefaults (rcGateway rc)
    Left _   -> defaultGatewayConfig
