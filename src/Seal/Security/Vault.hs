{-# LANGUAGE OverloadedStrings #-}
-- | An encrypted secret vault. Values are stored as a base64-encoded JSON map,
-- encrypted as a whole by the 'VaultEncryptor'. Writes are atomic
-- (tmp → chmod 0600 → rename). Three unlock modes trade memory residency for
-- convenience. All mutations are serialised by an 'MVar'; the decrypted map is
-- cached in a 'TVar' for the startup/on-demand modes.
module Seal.Security.Vault
  ( UnlockMode (..)
  , VaultConfig (..)
  , VaultStatus (..)
  , VaultHandle (..)
  , openVault
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (IOException, try)
import Control.Monad (void, when)
import Data.Maybe (isNothing)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist, removeFile, renameFile)
import System.Posix.Files (setFileMode)

import Seal.Security.Vault.Age (VaultEncryptor (..), VaultError (..))

data UnlockMode = UnlockStartup | UnlockOnDemand | UnlockPerAccess
  deriving stock (Eq, Show)

data VaultConfig = VaultConfig
  { vcPath :: FilePath
  , vcKeyType :: Text
  , vcUnlock :: UnlockMode
  } deriving stock (Eq, Show)

data VaultStatus = VaultStatus
  { vsLocked :: Bool
  , vsSecretCount :: Int
  , vsKeyType :: Text
  } deriving stock (Eq, Show)

data VaultHandle = VaultHandle
  { vhInit :: IO (Either VaultError ())
  , vhUnlock :: IO (Either VaultError ())
  , vhLock :: IO ()
  , vhGet :: Text -> IO (Either VaultError ByteString)
  , vhPut :: Text -> ByteString -> IO (Either VaultError ())
  , vhDelete :: Text -> IO (Either VaultError ())
  , vhList :: IO (Either VaultError [Text])
  , vhStatus :: IO VaultStatus
  , vhRekey :: VaultEncryptor -> Text -> (Text -> IO Bool) -> IO (Either VaultError ())
  }

-- Internal mutable state (not exported).
data VaultState = VaultState
  { stConfig :: VaultConfig
  , stEncryptor :: IORef VaultEncryptor
  , stKeyType :: IORef Text
  , stCache :: TVar (Maybe (Map Text ByteString))
  , stWriteLock :: MVar ()
  }

openVault :: VaultConfig -> VaultEncryptor -> IO VaultHandle
openVault cfg enc = do
  st <- VaultState cfg
          <$> newIORef enc
          <*> newIORef (vcKeyType cfg)
          <*> newTVarIO Nothing
          <*> newMVar ()
  pure VaultHandle
    { vhInit   = vaultInit st
    , vhUnlock = vaultUnlock st
    , vhLock   = atomically (writeTVar (stCache st) Nothing)
    , vhGet    = withCurrentMap st . lookupKey
    , vhPut    = \k v -> mutate st (Right . Map.insert k v)
    , vhDelete = \k -> mutate st $ \m ->
        if Map.member k m then Right (Map.delete k m) else Left (VaultKeyNotFound k)
    , vhList   = withCurrentMap st (Right . Map.keys)
    , vhStatus = vaultStatus st
    , vhRekey  = vaultRekey st
    }

-- ---------------------------------------------------------------------------
-- Core operations
-- ---------------------------------------------------------------------------

vaultInit :: VaultState -> IO (Either VaultError ())
vaultInit st = withMVar (stWriteLock st) $ \_ -> do
  exists <- doesFileExist (vcPath (stConfig st))
  if exists
    then pure (Left VaultAlreadyExists)
    else persistToDisk st Map.empty

-- | Decrypt the on-disk vault into the cache (for the cached modes).
vaultUnlock :: VaultState -> IO (Either VaultError ())
vaultUnlock st = do
  res <- readMap st
  case res of
    Left e  -> pure (Left e)
    Right m -> do
      atomically (writeTVar (stCache st) (Just m))
      pure (Right ())

vaultStatus :: VaultState -> IO VaultStatus
vaultStatus st = do
  cache   <- readTVarIO (stCache st)
  keyType <- readIORef (stKeyType st)
  pure VaultStatus
    { vsLocked      = isNothing cache
    , vsSecretCount = maybe 0 Map.size cache
    , vsKeyType     = keyType
    }

-- | Obtain the current map per unlock mode, then apply a pure observation.
-- 'UnlockOnDemand' transparently unlocks first.
withCurrentMap
  :: VaultState
  -> (Map Text ByteString -> Either VaultError a)
  -> IO (Either VaultError a)
withCurrentMap st f = do
  prepareAccess st
  em <- currentMap st
  pure (em >>= f)

-- | Read-modify-write a mutation under the write lock.
mutate
  :: VaultState
  -> (Map Text ByteString -> Either VaultError (Map Text ByteString))
  -> IO (Either VaultError ())
mutate st f = do
  prepareAccess st
  withMVar (stWriteLock st) $ \_ -> do
    em <- currentMap st
    case em >>= f of
      Left e   -> pure (Left e)
      Right m' -> writeMap st m'

-- | For 'UnlockOnDemand', ensure the cache is populated before we take the
-- write lock (so we never deadlock by unlocking inside it).
prepareAccess :: VaultState -> IO ()
prepareAccess st = case vcUnlock (stConfig st) of
  UnlockOnDemand -> do
    cache <- readTVarIO (stCache st)
    case cache of
      Just _  -> pure ()
      Nothing -> void (vaultUnlock st)
  _ -> pure ()

-- | The current decrypted map according to unlock mode. Per-access always
-- reads disk; the cached modes read the 'TVar' and are 'VaultLocked' if empty.
currentMap :: VaultState -> IO (Either VaultError (Map Text ByteString))
currentMap st = case vcUnlock (stConfig st) of
  UnlockPerAccess -> readMap st
  _ -> maybe (Left VaultLocked) Right <$> readTVarIO (stCache st)

-- | Write a map to disk without updating the in-memory cache.
persistToDisk :: VaultState -> Map Text ByteString -> IO (Either VaultError ())
persistToDisk st m = do
  enc <- readIORef (stEncryptor st)
  let payload = BL.toStrict (Aeson.encode (encodeValues m))
  res <- veEncrypt enc payload
  case res of
    Left e           -> pure (Left e)
    Right ciphertext -> do
      atomicWrite (vcPath (stConfig st)) ciphertext
      pure (Right ())

-- | Persist a map to disk and, for the cached modes, refresh the cache.
writeMap :: VaultState -> Map Text ByteString -> IO (Either VaultError ())
writeMap st m = do
  res <- persistToDisk st m
  case res of
    Left e  -> pure (Left e)
    Right () -> do
      case vcUnlock (stConfig st) of
        UnlockPerAccess -> pure ()
        _ -> atomically (writeTVar (stCache st) (Just m))
      pure (Right ())

-- | Read and decrypt the on-disk vault into a map.
readMap :: VaultState -> IO (Either VaultError (Map Text ByteString))
readMap st = do
  enc        <- readIORef (stEncryptor st)
  fileResult <- try @IOException (BS.readFile (vcPath (stConfig st)))
  case fileResult of
    Left _       -> pure (Left VaultNotFound)
    Right fileBs -> do
      plain <- veDecrypt enc fileBs
      pure (plain >>= decodePayload)

-- ---------------------------------------------------------------------------
-- Rekey: write to .new, verify byte-for-byte, confirm, atomic replace
-- ---------------------------------------------------------------------------

vaultRekey
  :: VaultState -> VaultEncryptor -> Text -> (Text -> IO Bool)
  -> IO (Either VaultError ())
vaultRekey st newEnc newKeyType confirm = withMVar (stWriteLock st) $ \_ -> do
  let path    = vcPath (stConfig st)
      newPath = path <> ".new"
  cur <- readMap st
  case cur of
    Left e         -> pure (Left e)
    Right plainMap -> do
      let payload = BL.toStrict (Aeson.encode (encodeValues plainMap))
      enc <- veEncrypt newEnc payload
      case enc of
        Left e           -> pure (Left e)
        Right ciphertext -> do
          atomicWrite newPath ciphertext
          verified <- verifyRekey newEnc newPath plainMap
          if not verified
            then cleanup newPath >> pure (Left (VaultBackendError "rekey verification failed"))
            else do
              oldKeyType <- readIORef (stKeyType st)
              ok <- confirm (rekeyPrompt oldKeyType newKeyType (Map.size plainMap))
              if not ok
                then cleanup newPath >> pure (Left (VaultBackendError "rekey cancelled"))
                else do
                  renameFile newPath path
                  writeIORef (stEncryptor st) newEnc
                  writeIORef (stKeyType st) newKeyType
                  atomically (writeTVar (stCache st) (Just plainMap))
                  pure (Right ())

verifyRekey :: VaultEncryptor -> FilePath -> Map Text ByteString -> IO Bool
verifyRekey newEnc newPath expected = do
  readBack <- try @IOException (BS.readFile newPath)
  case readBack of
    Left _   -> pure False
    Right bs -> do
      plain <- veDecrypt newEnc bs
      pure $ case plain >>= decodePayload of
        Right m -> m == expected
        Left _  -> False

rekeyPrompt :: Text -> Text -> Int -> Text
rekeyPrompt oldKt newKt n =
  "Replace vault? Old: " <> oldKt <> ", New: " <> newKt
    <> ", " <> T.pack (show n) <> " secrets verified identical"

cleanup :: FilePath -> IO ()
cleanup path = do
  exists <- doesFileExist path
  when exists (removeFile path)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

lookupKey :: Text -> Map Text ByteString -> Either VaultError ByteString
lookupKey k = maybe (Left (VaultKeyNotFound k)) Right . Map.lookup k

-- | Atomic write: tmp file, chmod 0600, rename over the target.
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bs = do
  let tmp = path <> ".tmp"
  BS.writeFile tmp bs
  setFileMode tmp 0o600
  renameFile tmp path

-- Values are base64 so binary secrets survive the JSON round-trip.
encodeValues :: Map Text ByteString -> Map Text Text
encodeValues = Map.map (TE.decodeUtf8 . B64.encode)

decodePayload :: ByteString -> Either VaultError (Map Text ByteString)
decodePayload plain =
  case Aeson.decodeStrict plain of
    Nothing      -> Left (VaultBackendError "invalid JSON")
    Just encoded -> maybe (Left (VaultBackendError "invalid base64")) Right
                          (traverse decodeValue encoded)
  where
    decodeValue t = either (const Nothing) Just (B64.decode (TE.encodeUtf8 t))
