{-# LANGUAGE OverloadedStrings #-}
-- | In-memory VaultHandle for tests, backed by an IORef Map. Mirrors the real
-- handle's Either-VaultError contract without any crypto or disk.
module Seal.TestHelpers.FakeVault
  ( makeFakeVault
  , makeLockedVault
  , makeFakeVaultRuntime
  , makeLockedVaultRuntime
  , vaultRuntimeFromHandle
  ) where

import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Seal.Security.Vault (VaultHandle (..), VaultStatus (..))
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Vault.Commands (VaultRuntime (..))

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

-- | Build a 'VaultRuntime' wrapping a (maybe) live 'VaultHandle'. The
-- 'vrPaths'/'vrConfigPath' fields are test stubs (unused by the clone seam,
-- which only reads 'vrHandleRef'). Mirrors how 'Seal.Command.Serve' builds
-- the real 'VaultRuntime' at startup (a 'Just' handle for an unlocked
-- vault, 'Nothing' for a locked/unconfigured one).
vaultRuntimeFromHandle :: Maybe VaultHandle -> IO VaultRuntime
vaultRuntimeFromHandle mh = do
  ref <- newIORef mh
  pure VaultRuntime
    { vrPaths      = testPaths
    , vrConfigPath = "<test>"
    , vrHandleRef  = ref
    }
  where
    -- A minimal 'SealPaths' stub (the clone seam never reads it; only
    -- 'vrHandleRef' is used). The fields are set to placeholder values.
    testPaths = error "VaultRuntime.vrPaths: test stub (unused by the clone seam)"

-- | An unlocked 'VaultRuntime' seeded with the given name→value pairs.
makeFakeVaultRuntime :: [(Text, ByteString)] -> IO VaultRuntime
makeFakeVaultRuntime initial = makeFakeVault initial >>= vaultRuntimeFromHandle . Just

-- | A locked 'VaultRuntime' (the handle is 'Nothing' — the vault is
-- unconfigured, so 'resolveVaultHandle' fails closed to
-- 'CloneVaultError VaultLocked').
makeLockedVaultRuntime :: IO VaultRuntime
makeLockedVaultRuntime = vaultRuntimeFromHandle Nothing
