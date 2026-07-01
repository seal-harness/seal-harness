{-# LANGUAGE OverloadedStrings #-}
-- | In-memory VaultHandle for tests, backed by an IORef Map. Mirrors the real
-- handle's Either-VaultError contract without any crypto or disk.
module Seal.TestHelpers.FakeVault
  ( makeFakeVault
  , makeLockedVault
  ) where

import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Seal.Security.Vault (VaultHandle (..), VaultStatus (..))
import Seal.Security.Vault.Age (VaultError (..))

-- | An unlocked vault seeded with the given name→value pairs.
makeFakeVault :: [(Text, ByteString)] -> IO VaultHandle
makeFakeVault initial = do
  ref <- newIORef (Map.fromList initial :: Map Text ByteString)
  pure VaultHandle
    { vhInit   = pure (Right ())
    , vhUnlock = pure (Right ())
    , vhLock   = pure ()
    , vhGet    = \k -> maybe (Left (VaultKeyNotFound k)) Right . Map.lookup k <$> readIORef ref
    , vhPut    = \k v -> modifyIORef' ref (Map.insert k v) >> pure (Right ())
    , vhDelete = \k -> do
        m <- readIORef ref
        if Map.member k m
          then writeIORef ref (Map.delete k m) >> pure (Right ())
          else pure (Left (VaultKeyNotFound k))
    , vhList   = Right . Map.keys <$> readIORef ref
    , vhStatus = do
        m <- readIORef ref
        pure (VaultStatus False (Map.size m) "test")
    , vhRekey  = \_ _ _ -> pure (Right ())
    }

-- | A locked vault: every accessor returns 'VaultLocked'.
makeLockedVault :: IO VaultHandle
makeLockedVault = pure VaultHandle
  { vhInit   = pure (Right ())
  , vhUnlock = pure (Right ())
  , vhLock   = pure ()
  , vhGet    = \_   -> pure (Left VaultLocked)
  , vhPut    = \_ _ -> pure (Left VaultLocked)
  , vhDelete = \_   -> pure (Left VaultLocked)
  , vhList   = pure (Left VaultLocked)
  , vhStatus = pure (VaultStatus True 0 "test")
  , vhRekey  = \_ _ _ -> pure (Left VaultLocked)
  }
