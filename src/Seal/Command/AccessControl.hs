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
import Seal.Config.Security (WriteMode (..), clearAccessControlSection)
import Seal.Config.BootPlan
  ( BindCoordinates (..), BootPlan (..), bootPlan, bootRefusalMessage, preflight )
import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig, withGatewayDefaults)
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
  gwCfg <- gatewayConfig paths
  inputs <- preflight paths
  let coords = BindCoordinates (gcHost gwCfg) (gcPort gwCfg)
      decision = inputs >>= bootPlan coords
  case decision of
    Left refusal -> do
      TIO.putStrLn ("Access control: INVALID — " <> bootRefusalMessage refusal)
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

-- | Remove the @[access_control]@ table, returning the gateway to the setup
-- screen.
--
-- 'DropCredentials' is correct here and nowhere else on this path: @reset@ is
-- CLI-only and @--yes@ is mandatory, so a human decided to destroy the
-- credential tables rather than be blocked by them. Every other writer keeps
-- 'PreserveCredentials' and is refused instead.
reset :: SealPaths -> IO ()
reset paths = do
  result <- clearAccessControlSection (securityFilePath paths) DropCredentials
  case result of
    Left err -> TIO.putStrLn ("Could not reset access control: " <> err)
    Right () -> do
      TIO.putStrLn "Removed [access_control] from ~/.seal/security.toml."
      TIO.putStrLn "  A running `seal serve` keeps its current mode until you restart it."
      TIO.putStrLn "  After restarting, open the web UI to enroll a passkey (or waive again)."

-- ---------------------------------------------------------------------------

gatewayConfig :: SealPaths -> IO GatewayConfig
gatewayConfig paths = do
  cfg <- loadRuntimeConfig (configFilePath paths)
  pure $ case cfg of
    Right rc -> maybe defaultGatewayConfig withGatewayDefaults (rcGateway rc)
    Left _   -> defaultGatewayConfig
