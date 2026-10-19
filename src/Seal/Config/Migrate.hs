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
  , providerRenameMigration
  , migratedMsg
  , couldNotUpdateMsg
  ) where

import Control.Exception (try, SomeException)
import Data.Text (Text)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (hPutStrLn, stderr)
import System.Directory (doesFileExist)


import Toml qualified

import Validation (Validation (..))

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), loadRuntimeConfig, saveRuntimeConfig
  , updateRuntimeConfig )
import Seal.Config.Paths (SealPaths, configFilePath, securityFilePath)
import Seal.Config.Security
  ( SecurityConfig, securityConfigCodec
  , saveSecurityConfig )
import Seal.Providers.Registry
  ( legacyOpenRouterBaseUrl, legacyOpenRouterModel )

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
-- ---------------------------------------------------------------------------
-- Provider rename: openrouter -> openai-compat (issue #271)
-- ---------------------------------------------------------------------------

-- | One-time, idempotent migration of the provider id Seal used to ship as
-- @openrouter@. Must run **after** 'migrateSecurityConfig': this function
-- rewrites @config.toml@ through the 'RuntimeConfig' codec, which does not
-- model the legacy security fields — running it first would make
-- 'migrateSecurityConfig'\'s text scan find nothing and silently drop
-- @vault_*@ / @[untrusted_execution]@ (downgrading @mode = remote@ to local).
--
-- Migrates:
--
--   * @default_provider = "openrouter"@ → @openai-compat@;
--   * @[providers.openrouter]@ → @[providers.openai-compat]@, keeping
--     @default_model@ and @base_url@; the OpenRouter endpoint and the old
--     implicit model are filled in when absent; an existing
--     @[providers.openai-compat]@ wins; the old section is removed.
--
-- The vault entry cannot be copied here (the migration runs before the vault is
-- unlocked), so the stderr line names the one manual step.
-- Returns the one-line message for the caller to log (never throws).
providerRenameMigration :: SealPaths -> IO (Maybe Text)
providerRenameMigration paths = do
  let cfgPath = configFilePath paths
  eCfg <- loadRuntimeConfig cfgPath
  case eCfg of
    Left _ -> pure Nothing               -- malformed config: leave it alone
    Right cfg -> case renamePlan cfg of
      Nothing -> pure Nothing            -- never had openrouter / already done
      Just (url, model) -> do
        r <- try @SomeException (updateRuntimeConfig cfgPath applyRename)
        pure $ Just $ case r of
          Left e          -> couldNotUpdateMsg url model (T.pack (show e))
          Right (Left e)  -> couldNotUpdateMsg url model e
          Right (Right ()) -> migratedMsg url model

-- | What the migration would produce, or 'Nothing' when there is nothing to do.
-- Returns the effective (URL, model) for the operator-facing message.
renamePlan :: RuntimeConfig -> Maybe (Text, Text)
renamePlan cfg
  | not (legacyDefault || legacySection) = Nothing
  | otherwise = Just (url, model)
  where
    provs = rcProviders cfg
    legacySection = Map.member "openrouter" provs
    legacyDefault = rcDefaultProvider cfg == Just "openrouter"
    newSec = Map.lookup "openai-compat" provs
    oldSec = Map.lookup "openrouter" provs
    pick newF oldF fallback =
      fromMaybe (fromMaybe fallback (oldSec >>= oldF)) (newSec >>= newF)
    url = pick pcBaseUrl pcBaseUrl legacyOpenRouterBaseUrl
    model = pick pcDefaultModel pcDefaultModel legacyOpenRouterModel

-- | Apply the rename to a 'RuntimeConfig'.
applyRename :: RuntimeConfig -> RuntimeConfig
applyRename cfg = case renamePlan cfg of
  Nothing -> cfg
  Just (url, model) -> cfg
    { rcProviders = Map.insert "openai-compat"
                      (ProviderConfig { pcBaseUrl = Just url
                                      , pcDefaultModel = Just model })
                      (Map.delete "openrouter" (rcProviders cfg))
    , rcDefaultProvider = if rcDefaultProvider cfg == Just "openrouter"
                            then Just "openai-compat"
                            else rcDefaultProvider cfg
    }

migratedMsg :: Text -> Text -> Text
migratedMsg url model =
  "openrouter was renamed to openai-compat; your config was updated (base URL "
    <> url <> ", model " <> model
    <> "). Run /provider add openai-compat to store the API key."

couldNotUpdateMsg :: Text -> Text -> Text -> Text
couldNotUpdateMsg url model err =
  "openrouter was renamed to openai-compat, but Seal could not update your"
    <> " config (" <> err <> "). Run /provider add openai-compat (base URL "
    <> url <> ", model " <> model <> ")."
