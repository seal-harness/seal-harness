{-# LANGUAGE OverloadedStrings #-}
-- | One-time, idempotent migration of security-critical fields (vault
-- settings + @[untrusted_execution]@) from @config\/config.toml@ to
-- @~\/.seal\/security.toml@ (design §4 Approach B).
--
-- The migration runs at boot, before 'loadSecurityConfig' / 'loadRuntimeConfig'.
-- It is idempotent and fail-open (a write failure logs an error and boot
-- proceeds — the legacy values are read directly for that session, re-tried
-- next boot).
module Seal.Config.Migrate
  ( migrateSecurityConfig
  ) where

import Control.Exception (try, SomeException)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.IO (hPutStrLn, stderr)

import Toml qualified

import Validation (Validation (..))

import Seal.Config.File
  ( loadRuntimeConfig, saveRuntimeConfig )
import Seal.Config.Paths (SealPaths, configFilePath, securityFilePath)
import Seal.Config.Security
  ( SecurityConfig, securityConfigCodec
  , saveSecurityConfig )

-- | One-time, idempotent migration. Examines both @config.toml@ and
-- @security.toml@ and moves any legacy security fields from @config.toml@ to
-- @security.toml@. Cases (design §4 B):
--
--   1. @security.toml@ absent, @config.toml@ has legacy fields → migrate.
--   2. @security.toml@ exists, @config.toml@ has stale legacy fields →
--      @security.toml@ wins (precedence); clean stale fields from @config.toml@.
--   3. @security.toml@ exists, @config.toml@ clean → no-op (idempotent).
--   4. Neither exists → no-op (defaults apply).
--   5. Write fails (permissions) → log a loud error and proceed (fail-open).
migrateSecurityConfig :: SealPaths -> IO ()
migrateSecurityConfig paths = do
  let cfgPath = configFilePath paths
      secPath = securityFilePath paths
  secExists <- doesFileExist secPath
  cfgExists <- doesFileExist cfgPath
  case (secExists, cfgExists) of
    -- Case 4: neither exists → no-op.
    (False, False) -> pure ()
    -- Case 3: security.toml exists, config.toml absent → no-op.
    (True, False)  -> pure ()
    -- Case 1 & 2: config.toml exists — check for legacy fields.
    (secExists', True) -> do
      contents <- TIO.readFile cfgPath
      let hasLegacy = any (`T.isInfixOf` contents) legacyMarkers
      if not hasLegacy
        then pure ()  -- Case 3 (clean): no-op.
        else do
          if secExists'
            then do
              -- Case 2: security.toml exists → clean stale fields from
              -- config.toml (security.toml wins).
              cleanConfigToml cfgPath
              hPutStrLn stderr $ "[seal] removed stale [untrusted_execution]/vault_* from "
                                 <> cfgPath
                                 <> " (security.toml takes precedence)"
            else do
              -- Case 1: security.toml absent → migrate.
              migrateFields cfgPath secPath contents

-- | Lines/tokens that indicate legacy security fields are present in config.toml.
legacyMarkers :: [Text]
legacyMarkers =
  [ "vault_path"
  , "vault_recipient"
  , "vault_identity"
  , "vault_unlock"
  , "vault_key_type"
  , "[untrusted_execution]"
  ]

-- | Migrate legacy fields from config.toml to security.toml (Case 1).
migrateFields :: FilePath -> FilePath -> Text -> IO ()
migrateFields cfgPath secPath contents = do
  -- Parse the legacy fields from config.toml using the security codec.
  case Toml.parse contents of
    Left _ -> pure ()  -- malformed; skip migration.
    Right toml ->
      case Toml.runTomlCodec securityConfigCodec toml of
        Success secCfg -> do
          writeResult <- tryWriteSecurityConfig secPath secCfg
          case writeResult of
            Right () -> do
              -- Clean config.toml (re-save RuntimeConfig, which drops legacy fields).
              cleanConfigToml cfgPath
              hPutStrLn stderr $ "[seal] migrated [untrusted_execution]/vault_* from "
                                 <> cfgPath <> " to " <> secPath
                                 <> " (one-time). Edit " <> secPath
                                 <> " for future changes."
            Left err ->
              -- Case 5: write failed → fail-open.
              hPutStrLn stderr $ "[seal] WARNING: could not write " <> secPath
                                 <> " — " <> T.unpack err
                                 <> ". Reading legacy fields from config.toml for this session."
                                 <> " Fix permissions and restart."
        Failure _ ->
          -- Could not parse legacy fields; skip migration.
          pure ()

-- | Clean config.toml: re-save the loaded RuntimeConfig, which drops the
-- legacy fields (the RuntimeConfig codec no longer parses them).
cleanConfigToml :: FilePath -> IO ()
cleanConfigToml cfgPath = do
  eCfg <- loadRuntimeConfig cfgPath
  case eCfg of
    Right cfg -> saveRuntimeConfig cfgPath cfg
    Left _    -> pure ()

-- | Try to write the security config (fail-open on error).
tryWriteSecurityConfig :: FilePath -> SecurityConfig -> IO (Either Text ())
tryWriteSecurityConfig path cfg = do
  result <- try @SomeException (saveSecurityConfig path cfg)
  pure $ case result of
    Left err  -> Left (T.pack (show err))
    Right ()  -> Right ()