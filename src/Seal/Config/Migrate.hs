{-# LANGUAGE OverloadedStrings #-}
-- | One-time, idempotent migration of security-critical fields (vault
-- settings, @[untrusted_execution]@ and @[gateway]@) from
-- @config\/config.toml@ to @~\/.seal\/security.toml@ (design §4 Approach B).
--
-- The migration runs at boot, before 'Seal.Config.Security.loadSecurityConfig' /
-- 'Seal.Config.File.loadRuntimeConfig'. It is idempotent and fail-open (a write
-- failure logs an error and boot proceeds — the legacy values stay where they
-- are, and the next boot retries).
--
-- Two rules keep it from losing data:
--
-- * __Strip only after a successful write.__ Re-encoding @config.toml@ (which
--   'cleanConfigToml' does) drops any section the runtime codec does not know,
--   so it only happens once the new copy exists in @security.toml@.
-- * __@security.toml@ wins, except where it has no answer.__ A stale
--   @[untrusted_execution]@ / vault field in @config.toml@ is discarded, as
--   before. The @[gateway]@ table is different: on an upgraded install
--   @security.toml@ exists (seeded on first run) but has never carried a
--   @[gateway]@ table, so "security wins" would reset every operator's bind
--   address to loopback. When security has no table and config has one, the
--   table is moved across first.
--
-- A third rule covers a subtler case: a live @[gateway]@ header whose values do
-- not survive decoding (every key is 'Toml.dioptional', which demotes a type
-- mismatch to "absent"). Moving that would silently drop a value, and stripping
-- it would destroy the table, so the migration does neither and says so.
module Seal.Config.Migrate
  ( migrateSecurityConfig
  , configHasLegacySecurityFields
  ) where

import Control.Exception (try, SomeException)
import Data.Maybe (isJust, isNothing)
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
  ( SecurityConfig (..), securityConfigCodec
  , WriteMode (PreserveCredentials), loadSecurityConfig, saveSecurityConfig
  , tomlKeyPaths )
import Seal.Gateway.Config (gatewayTableCodec)

-- | One-time, idempotent migration. Examines both @config.toml@ and
-- @security.toml@ and moves any legacy security fields from @config.toml@ to
-- @security.toml@. Cases (design §4 B):
--
--   1. @security.toml@ absent, @config.toml@ has legacy fields → migrate.
--   2. @security.toml@ exists, @config.toml@ has stale legacy fields →
--      @security.toml@ wins (precedence); clean stale fields from @config.toml@.
--      The @[gateway]@ table is merged across instead when @security.toml@ has
--      none — see 'reconcileWithExisting'.
--   3. @security.toml@ exists, @config.toml@ clean → no-op (idempotent).
--   4. @config.toml@ absent → no-op (defaults apply; @security.toml@ may exist).
--   5. Write fails (permissions) → log a loud error and proceed (fail-open).
--   6. @config.toml@ carries a field but cannot be read, or carries a
--      @[gateway]@ header whose values do not decode → log a loud error and
--      change nothing (never strip what was not moved).
migrateSecurityConfig :: SealPaths -> IO ()
migrateSecurityConfig paths = do
  let cfgPath = configFilePath paths
      secPath = securityFilePath paths
  secExists <- doesFileExist secPath
  cfgExists <- doesFileExist cfgPath
  case (secExists, cfgExists) of
    -- Case 4 (and case 3 with no config.toml): nothing in config.toml to move.
    (_, False)    -> pure ()
    (False, True) -> migrateIntoNewFile cfgPath secPath
    (True, True)  -> reconcileWithExisting cfgPath secPath

-- | Do these @config.toml@ bytes still carry the pre-split security fields?
--
-- The same substring scan 'migrateSecurityConfig' uses, exported because the
-- first-run scaffolder ('Seal.Config.Templates.ensureConfigTemplates') has to
-- know: creating @security.toml@ while these fields are still in @config.toml@
-- would move the install onto the "security.toml wins" branch below.
--
-- The scan is deliberately crude: it also trips on a field name mentioned in a
-- comment, which at worst defers the template and lets the migration run. The
-- reverse mistake — missing a live field — is the one that loses data.
configHasLegacySecurityFields :: Text -> Bool
configHasLegacySecurityFields contents = any (`T.isInfixOf` contents) legacyMarkers

-- | Lines/tokens that indicate legacy security fields are present in config.toml.
legacyMarkers :: [Text]
legacyMarkers =
  [ "vault_path"
  , "vault_recipient"
  , "vault_identity"
  , "vault_unlock"
  , "vault_key_type"
  , "[untrusted_execution]"
  , "[gateway]"
  ]

-- | The keys the @[gateway]@ codec actually reads. A key outside this set was
-- never gateway configuration — TOML puts every bare key after a table header
-- inside that table, so a stray @default_provider@ under @[gateway]@ is ignored
-- by the loader and loses no setting when it is dropped.
gatewayKeys :: [Text]
gatewayKeys =
  [ "port", "ws_port", "host", "static_dir", "allowed_origins"
  , "tls_cert", "tls_key", "tls", "tls_hosts"
  ]

-- | Leaf paths of the keys the gateway codec reads, as @gateway.port@.
-- Empty for a commented-out block (it is not a table node at all).
gatewayLeafPaths :: Toml.TOML -> [Text]
gatewayLeafPaths toml =
  [ T.intercalate "." pieces
  | path <- tomlKeyPaths toml
  , let pieces = map Toml.unPiece path
  , startsWithGateway pieces
  , readsKey pieces
  ]
  where
    startsWithGateway ("gateway" : _) = True
    startsWithGateway _               = False
    readsKey pieces = case reverse pieces of
      (key : _) -> key `elem` gatewayKeys
      []        -> False

-- | Can every key of @config.toml@'s @[gateway]@ table be written back out?
--
-- Every gateway key is optional at the codec layer, and @Toml.dioptional@
-- demotes a value it cannot read to "absent": @port = "8443"@ reads as no port
-- at all. Moving such a table would silently drop the key, and stripping
-- @config.toml@ would destroy it, so the migration does neither and says why.
-- A commented-out block has no leaf paths, so it never blocks the migration.
gatewayTableSurvives :: Text -> SecurityConfig -> Bool
gatewayTableSurvives contents secCfg = case Toml.parse contents of
  Left _     -> True     -- a parse failure is reported by its own branch
  Right raw  -> all (`elem` reEncoded) (gatewayLeafPaths raw)
  where
    reEncoded = case scGateway secCfg of
      Nothing -> []
      Just gw -> case Toml.parse (Toml.encode gatewayTableCodec (Just gw)) of
        Left _     -> []
        Right toml -> gatewayLeafPaths toml

-- | Case 1: no @security.toml@. Everything the security codec understands is
-- written to a new one, then stripped from @config.toml@.
migrateIntoNewFile :: FilePath -> FilePath -> IO ()
migrateIntoNewFile cfgPath secPath = do
  contents <- TIO.readFile cfgPath
  if not (configHasLegacySecurityFields contents)
    then pure ()
    else case decodeSecurityFields contents of
      Left err -> warnUndecodable cfgPath err
      Right secCfg
        | not (gatewayTableSurvives contents secCfg) ->
            warnUndecodableGateway cfgPath
        | otherwise -> do
            written <- tryWriteSecurityConfig secPath secCfg
            case written of
              Left err -> warnWriteFailed secPath err
              Right () -> do
                cleanConfigToml cfgPath
                say ("[seal] migrated security settings from " <> T.pack cfgPath
                      <> " to " <> T.pack secPath
                      <> " (one-time). Edit " <> T.pack secPath <> " for future changes.")

-- | Case 2: @security.toml@ exists. Strip the stale fields from @config.toml@,
-- moving the @[gateway]@ table across first when security has none of its own.
reconcileWithExisting :: FilePath -> FilePath -> IO ()
reconcileWithExisting cfgPath secPath = do
  contents <- TIO.readFile cfgPath
  if not (configHasLegacySecurityFields contents)
    then pure ()
    else case decodeSecurityFields contents of
      Left err -> warnUndecodable cfgPath err
      Right fromCfg
        | not (gatewayTableSurvives contents fromCfg) ->
            warnUndecodableGateway cfgPath
        | otherwise -> do
            loaded <- loadSecurityConfig secPath
            case loaded of
              Left err ->
                -- Never rewrite a file we could not read: the merge would start
                -- from defaults and drop whatever else the operator has there.
                say ("[seal] WARNING: " <> T.pack secPath <> " could not be read ("
                      <> err <> "). Leaving " <> T.pack cfgPath <> " untouched; fix "
                      <> T.pack secPath <> " and restart.")
              Right sec
                | isJust (scGateway fromCfg) && isNothing (scGateway sec) -> do
                    written <- saveSecurityConfig secPath
                                 (sec { scGateway = scGateway fromCfg })
                                 PreserveCredentials
                    case written of
                      Left err -> warnWriteFailed secPath err
                      Right () -> do
                        cleanConfigToml cfgPath
                        say ("[seal] moved [gateway] from " <> T.pack cfgPath <> " to "
                              <> T.pack secPath <> " (one-time). Edit " <> T.pack secPath
                              <> " for future changes.")
                | otherwise -> do
                    cleanConfigToml cfgPath
                    say ("[seal] removed stale [untrusted_execution]/vault_*/[gateway] from "
                          <> T.pack cfgPath <> " (security.toml takes precedence)")

-- | Decode the security-shaped subset of a @config.toml@ document.
decodeSecurityFields :: Text -> Either Text SecurityConfig
decodeSecurityFields contents = case Toml.parse contents of
  Left err     -> Left (Toml.unTomlParseError err)
  Right toml   -> case Toml.runTomlCodec securityConfigCodec toml of
    Success cfg  -> Right cfg
    Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | A field is present but does not decode. Changing nothing is the only safe
-- outcome: stripping it would destroy the value, and the migration is a move,
-- not a validation.
warnUndecodable :: FilePath -> Text -> IO ()
warnUndecodable cfgPath err =
  say ("[seal] WARNING: " <> T.pack cfgPath <> " carries security settings that could "
        <> "not be read, so nothing was moved or removed:\n  " <> err
        <> "\n  Fix the value, or move the table to ~/.seal/security.toml by hand. "
        <> "The gateway uses its defaults until then.")

-- | A live @[gateway]@ header whose values decode to "absent".
--
-- Every gateway key is optional at the codec layer, and @Toml.dioptional@
-- demotes a type mismatch to "absent": @port = "8443"@ (quoted) reads as no
-- port at all. Moving that would drop the value silently; stripping it would
-- destroy the table. Do neither and say why.
warnUndecodableGateway :: FilePath -> IO ()
warnUndecodableGateway cfgPath =
  say ("[seal] WARNING: " <> T.pack cfgPath <> " has a [gateway] table whose values could "
        <> "not all be read (every gateway key is optional, so a quoted number or an "
        <> "unexpected spelling reads as absent). Nothing was moved or removed.\n"
        <> "  Fix the value, or move the table to ~/.seal/security.toml by hand. "
        <> "The gateway uses its defaults until then.")

-- | Clean config.toml: re-save the loaded RuntimeConfig, which drops the
-- legacy fields (the RuntimeConfig codec no longer parses them).
--
-- Only ever called after the corresponding write to @security.toml@ succeeded.
cleanConfigToml :: FilePath -> IO ()
cleanConfigToml cfgPath = do
  eCfg <- loadRuntimeConfig cfgPath
  case eCfg of
    Right cfg -> saveRuntimeConfig cfgPath cfg
    Left _    -> pure ()

-- | Try to write the security config (fail-open on error).
tryWriteSecurityConfig :: FilePath -> SecurityConfig -> IO (Either Text ())
tryWriteSecurityConfig path cfg = do
  -- Two layers now: the write can throw, and it can refuse. Both are failures
  -- the caller reports the same way, so they are flattened here rather than
  -- letting a nested Either escape.
  result <- try @SomeException (saveSecurityConfig path cfg PreserveCredentials)
  pure $ case result of
    Left err         -> Left (T.pack (show err))
    Right (Left err) -> Left err
    Right (Right ()) -> Right ()

-- | A failed write leaves @config.toml@ alone, so the settings survive to the
-- next boot. Say that, because "your settings were not moved" is very different
-- from "your settings are gone".
warnWriteFailed :: FilePath -> Text -> IO ()
warnWriteFailed secPath err =
  say ("[seal] WARNING: could not write " <> T.pack secPath <> " — " <> err
        <> "\n  Your settings are still in config.toml and nothing was removed. "
        <> "Boot continues on defaults; the next boot retries. "
        <> "Fix permissions at ~/.seal/ and restart.")

say :: Text -> IO ()
say = hPutStrLn stderr . T.unpack
