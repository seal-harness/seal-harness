-- | A gated view of the vault. The allow-list is baked into the type —
-- session-level code receives a 'VaultAccess' and cannot access the raw
-- 'VaultRuntime' or 'VaultHandle' through this module. The constructor
-- and the 'vaVault' field are NOT exported.
--
-- All vault operations ('vaGet', 'vaPut', 'vaDelete', 'vaList') check the
-- allow-list ('vaAllowed') before touching the underlying 'VaultHandle'.
-- An empty allow-list means no access (fail-closed default).
module Seal.Vault.Access
  ( VaultAccess
  , noVaultAccess
  , vaultAccess
  , unrestrictedVaultAccess
  , vaGet
  , vaPut
  , vaDelete
  , vaList
  , vaAllowedSet
  ) where

import Data.IORef (readIORef)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.ByteString (ByteString)

import Seal.Security.Vault (VaultHandle (..))
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Vault.Commands (VaultRuntime (..))

-- | A gated view of the vault. The allow-list is baked into the type.
-- All session-level vault access goes through this type. The underlying
-- 'VaultRuntime' and 'VaultHandle' are NOT accessible through this
-- module — the constructor and 'vaVault' field are not exported.
data VaultAccess = VaultAccess VaultRuntime (Set Text)

-- | Fail-closed default: no secrets accessible.
noVaultAccess :: VaultRuntime -> VaultAccess
noVaultAccess rt = VaultAccess rt Set.empty

-- | Construct a 'VaultAccess' with the given allow-list.
-- Empty set = no access (fail-closed default).
vaultAccess :: VaultRuntime -> Set Text -> VaultAccess
vaultAccess = VaultAccess

-- | Admin-only: construct a 'VaultAccess' with ALL current vault keys.
-- Reads the vault key list via 'vhList' and creates a 'VaultAccess' with
-- the full set. Used by admin 'CloneDeps' construction sites
-- ('mkRepoTestSeam', 'cloneDepsForApiDeps') that legitimately need
-- unrestricted vault access.
unrestrictedVaultAccess :: VaultRuntime -> IO VaultAccess
unrestrictedVaultAccess rt = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> pure (noVaultAccess rt)
    Just h  -> do
      eKeys <- vhList h
      case eKeys of
        Left _     -> pure (noVaultAccess rt)
        Right keys -> pure (VaultAccess rt (Set.fromList keys))

-- | Extract the allow-list (for the 'toAuthorize' gate in 'secretManageOp').
vaAllowedSet :: VaultAccess -> Set Text
vaAllowedSet (VaultAccess _ allowed) = allowed

-- | Gated get: checks the allow-list before touching the vault.
-- Returns 'Left VaultAccessDenied' if the key is not in the allow-list.
-- Returns 'Left VaultLocked' if the vault is unconfigured/locked.
vaGet :: VaultAccess -> Text -> IO (Either VaultError ByteString)
vaGet (VaultAccess rt allowed) key
  | not (key `Set.member` allowed) = pure (Left (VaultAccessDenied key))
  | otherwise = do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just h  -> vhGet h key

-- | Gated put: checks the allow-list before touching the vault.
vaPut :: VaultAccess -> Text -> ByteString -> IO (Either VaultError ())
vaPut (VaultAccess rt allowed) key val
  | not (key `Set.member` allowed) = pure (Left (VaultAccessDenied key))
  | otherwise = do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just h  -> vhPut h key val

-- | Gated delete: checks the allow-list before touching the vault.
vaDelete :: VaultAccess -> Text -> IO (Either VaultError ())
vaDelete (VaultAccess rt allowed) key
  | not (key `Set.member` allowed) = pure (Left (VaultAccessDenied key))
  | otherwise = do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just h  -> vhDelete h key

-- | Gated list: returns only keys in the allow-list.
-- Short-circuits to @Right []@ when the allow-list is empty (does NOT
-- touch the vault — avoids leaking vault-locked state).
vaList :: VaultAccess -> IO (Either VaultError [Text])
vaList (VaultAccess rt allowed)
  | Set.null allowed = pure (Right [])
  | otherwise = do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just h  -> do
          eKeys <- vhList h
          pure $ case eKeys of
            Left e   -> Left e
            Right ks -> Right (filter (`Set.member` allowed) ks)
