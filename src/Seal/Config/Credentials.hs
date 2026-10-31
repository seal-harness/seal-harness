{-# LANGUAGE OverloadedStrings #-}
-- | The gateway-owned credential store: @~\/.seal\/credentials.toml@.
--
-- Credentials live here rather than in @security.toml@ because the two have
-- opposite write patterns. @security.toml@ is the boot-critical document —
-- unparseable means the gateway does not start — and it is rewritten only by
-- human-driven admin commands. Credentials change on a successful login (the
-- signature counter) and on every enrollment or deletion, so keeping them in
-- the boot-critical file means a login rewrites the document the next boot
-- depends on.
--
-- Format (design §6.2):
--
-- > version = 1
-- >
-- > [credentials.<credential-id-base64url>]
-- > public_key = "<base64url, 64-byte x||y>"
-- > sign_count = 0
-- > label      = "passkey"
-- > created_at = "2026-10-30T14:00:00Z"
-- > rp_id      = "localhost"
-- > added_via  = "cli_token"
--
-- The file is a sibling of @security.toml@ (not under @config\/@), written
-- atomically with mode @0600@. The temp name is unique per call so two
-- processes cannot collide on it before the rename.
module Seal.Config.Credentials
  ( CredentialsFile (..)
  , credentialsCodec
  , normalizeCredentialsTable
  , decodeCredentials
  , encodeCredentials
  , loadCredentials
  , saveCredentials
  , createCredentialsFile
  , updateCredentialsFile
  ) where

import Control.Concurrent.MVar (withMVar)
import Control.Exception (IOException, displayException, try)
import Data.ByteString qualified as BS
import Data.HashMap.Strict qualified as HashMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import System.FilePath (takeBaseName, takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (setFileMode)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive), OpenMode (WriteOnly), defaultFileFlags
  , fdToHandle, openFd )
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified

import Seal.Config.Security
  ( CredentialFileConfig, credentialCodec, fixNode, securityWriteLock )

-- | The decoded @credentials.toml@: a format version plus the credential map
-- keyed by base64url credential id.
--
-- @version@ is explicit so a future format change is a boot refusal
-- ('BrCredentialsVersion') rather than a silent misread.
data CredentialsFile = CredentialsFile
  { crdVersion     :: !Int
  , crdCredentials :: !(Map Text CredentialFileConfig)
  } deriving stock (Eq, Show)

-- | Bidirectional codec for the whole file.
--
-- 'Seal.Config.Security.credentialCodec' is reused rather than duplicated: the
-- same @[..credentials.\<id\>]@ table shape is still decoded out of
-- @security.toml@ by the legacy-layout check until the migration lands.
credentialsCodec :: Toml.TomlCodec CredentialsFile
credentialsCodec = CredentialsFile
  <$> Toml.int "version" .= crdVersion
  <*> Toml.tableMap Toml._KeyText (Toml.table credentialCodec) "credentials"
        .= crdCredentials

-- | Make the implicit @credentials@ node explicit before decoding.
--
-- tomland's 'Toml.tableMap' looks the table up under its @[credentials]@
-- header, so an operator-written file that carries only @[credentials.\<id\>]@
-- sub-tables leaves that node implicit in the prefix tree and the lookup
-- yields an EMPTY map (learnings 2026-10-30 §4). An empty store is not a parse
-- error, so without this the operator's passkeys disappear silently — the
-- worst failure mode available here, because the file still "loads".
--
-- A file written by 'saveCredentials' already has the explicit header and
-- passes through unchanged.
normalizeCredentialsTable :: Toml.TOML -> Toml.TOML
normalizeCredentialsTable toml =
  toml { Toml.tomlTables =
           HashMap.adjust (fixNode "credentials") "credentials" (Toml.tomlTables toml) }

-- | Render a 'CredentialsFile' as TOML.
encodeCredentials :: CredentialsFile -> Text
encodeCredentials = Toml.encode credentialsCodec

-- | Parse and decode a 'CredentialsFile' from raw TOML text.
decodeCredentials :: Text -> Either Text CredentialsFile
decodeCredentials raw = case Toml.parse raw of
  Left err -> Left (Toml.unTomlParseError err)
  Right toml -> case Toml.runTomlCodec credentialsCodec
                       (normalizeCredentialsTable toml) of
    Success file -> Right file
    Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | Load @credentials.toml@.
--
-- Three outcomes, distinguished because boot treats them differently
-- (design §10): @Right Nothing@ — the file is absent (a normal state: the
-- operator has not enrolled anything yet); @Right (Just file)@ — decoded;
-- @Left@ — present but unparseable or semantically invalid.
loadCredentials :: FilePath -> IO (Either Text (Maybe CredentialsFile))
loadCredentials path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right Nothing)
    else do
      raw <- TIO.readFile path
      pure (Just <$> decodeCredentials raw)

-- | Write @file@ to @path@ atomically, mode @0600@.
--
-- The temp file gets a unique name from 'openBinaryTempFile' (not a fixed
-- @.tmp@ suffix) so two processes writing concurrently cannot collide on the
-- temp path and produce a truncated document; the rename is atomic, and
-- @0600@ is applied at creation and again explicitly to defeat a permissive
-- umask. The security write lock is process-local, so the unique temp name
-- plus the atomic rename are the only cross-process guarantees.
saveCredentials :: FilePath -> CredentialsFile -> IO ()
saveCredentials path file = do
  let dir = takeDirectory path
  (tmp, h) <- openBinaryTempFile dir (takeBaseName path <> ".tmp")
  BS.hPut h (TE.encodeUtf8 (encodeCredentials file))
  hClose h
  setFileMode tmp 0o600
  renameFile tmp path

-- | The format version this build writes.
credentialsVersion :: Int
credentialsVersion = 1

-- | Create a store that does not exist yet.
--
-- Refuses when the file is already there, and refuses an empty credential map.
-- The two refusals are the store's integrity rules (design §9.2): the store is
-- never empty, and an existing store is never silently replaced — re-creating
-- it would discard credentials the operator cannot get back.
--
-- The destination is opened with @O_CREAT|O_EXCL@ rather than written through a
-- temp file: @rename@ would happily replace an existing store, whereas
-- @O_EXCL@ is the only way to make "does not already exist" atomic across
-- processes. @0600@ is applied at creation, so credential public keys are
-- never world-readable.
createCredentialsFile :: FilePath -> Map Text CredentialFileConfig -> IO (Either Text ())
createCredentialsFile path creds
  | Map.null creds = pure (Left emptyStoreRefusal)
  | otherwise = withMVar securityWriteLock $ \_ -> do
      exists <- doesFileExist path
      if exists
        then pure (Left (existsRefusal path))
        else do
          opened <- try (openFd path WriteOnly defaultFileFlags
                           { creat = Just 0o600, exclusive = True })
          case opened of
            Left (err :: IOException) -> pure (Left (T.pack path
              <> ": could not create the credential store: "
              <> T.pack (displayException err)))
            Right fd -> do
              h <- fdToHandle fd
              BS.hPut h (TE.encodeUtf8
                           (encodeCredentials (CredentialsFile credentialsVersion creds)))
              hClose h
              setFileMode path 0o600
              pure (Right ())

-- | Replace the credential map of an existing store.
--
-- The callback returns 'Either' so a rule that depends on the /current/
-- contents — the last-usable-credential guard — is evaluated inside the write,
-- not by a read-then-write in the caller that another request can invalidate in
-- between. A @Left@ from the callback writes nothing.
--
-- Refuses a missing file: enrollment creates the store, every later mutation
-- requires it. Without that rule, a store deleted underneath a running gateway
-- would read as empty and the next write would report success.
updateCredentialsFile
  :: FilePath
  -> (Map Text CredentialFileConfig -> Either Text (Map Text CredentialFileConfig))
  -> IO (Either Text ())
updateCredentialsFile path f = withMVar securityWriteLock $ \_ -> do
  loaded <- loadCredentials path
  case loaded of
    Left err          -> pure (Left err)
    Right Nothing     -> pure (Left (missingRefusal path))
    Right (Just file) -> case f (crdCredentials file) of
      Left err -> pure (Left err)
      Right creds
        | Map.null creds -> pure (Left emptyStoreRefusal)
        | otherwise -> do
            let updated = file { crdCredentials = creds }
            -- Verify the encoded document decodes back to what we intend
            -- before it replaces the store, so a codec change that drops a
            -- field is a refusal rather than silent data loss.
            case decodeCredentials (encodeCredentials updated) of
              Right back | back == updated ->
                saveCredentials path updated >> pure (Right ())
              _ -> pure (Left roundTripRefusal)

emptyStoreRefusal :: Text
emptyStoreRefusal =
  "refusing to write an empty credential store: removing the last credential \
  \would lock the gateway out with no way back in"

existsRefusal :: FilePath -> Text
existsRefusal path =
  "refusing to create the credential store: " <> T.pack path <> " already exists"

missingRefusal :: FilePath -> Text
missingRefusal path =
  "refusing to update the credential store: " <> T.pack path <> " does not exist"

roundTripRefusal :: Text
roundTripRefusal =
  "refusing to write credentials.toml: the encoded document does not round-trip \
  \the new credential map"
