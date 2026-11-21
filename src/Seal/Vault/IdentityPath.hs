{-# LANGUAGE OverloadedStrings #-}
-- | A validated path to an age identity file.
--
-- The value travels to a subprocess argv (@age --decrypt --identity=\<path\>@)
-- and is stored in @security.toml@, so it is a smart-constructed newtype rather
-- than raw 'FilePath' (AGENTS.md invariant 2). The constructor is deliberately
-- not exported: the ONLY way to obtain a 'VaultIdentityPath' is
-- 'mkVaultIdentityPath', so no code path can hand @age@ an unvalidated path.
--
-- This module imports neither "Seal.Vault.Provision" nor "Seal.Vault.Backend"
-- nor "Seal.Config.Security", which is what lets all three depend on it without
-- an import cycle.
module Seal.Vault.IdentityPath
  ( VaultIdentityPath
  , mkVaultIdentityPath
  , vaultIdentityPathText
  , vaultIdentityPathDisplay
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath (isAbsolute, takeFileName)

-- | An absolute, existing, regular, readable file path with no control
-- characters and no leading @-@ (which a subprocess could mistake for a flag).
newtype VaultIdentityPath = VaultIdentityPath FilePath
  deriving stock (Eq, Show)

-- | Validate a user-supplied path.
--
-- Rejections, in order: empty, a control character (including newline and NUL),
-- a leading @-@ (option injection), a relative path, a path that does not
-- exist, a path that exists but is not a regular file.
--
-- The path is NOT canonicalised: the operator named it, and storing the exact
-- string they gave keeps @security.toml@ legible. Symlinks are followed only
-- for the existence/regular-file checks.
mkVaultIdentityPath :: FilePath -> IO (Either Text VaultIdentityPath)
mkVaultIdentityPath raw
  | null raw = pure (Left "identity path is empty")
  | any isControlChar raw =
      pure (Left "identity path contains a control character")
  | "-" `isPrefix` raw =
      pure (Left "identity path must not start with '-'")
  | not (isAbsolute raw) =
      pure (Left "identity path must be absolute")
  | otherwise = do
      exists <- doesFileExist raw
      if not exists
        then pure (Left ("identity file does not exist: " <> T.pack raw))
        else do
          -- doesFileExist is False for directories, so this also rejects them.
          regular <- try @IOException (doesFileExist raw)
          pure $ case regular of
            Left err  -> Left ("identity path is not readable: " <> T.pack (show err))
            Right ok
              | ok        -> Right (VaultIdentityPath raw)
              | otherwise -> Left ("identity path is not a regular file: " <> T.pack raw)
  where
    isPrefix prefix s = take (length prefix) s == prefix
    -- Anything below space, plus DEL. Tab is rejected too: it never appears in
    -- a legitimate path and hiding one in a prompt or a log is a trick.
    isControlChar c = c < ' ' || c == '\DEL'

-- | The raw path, for the one place that must hand it to @age@ or store it.
vaultIdentityPathText :: VaultIdentityPath -> FilePath
vaultIdentityPathText (VaultIdentityPath p) = p

-- | A short, log-safe rendering: the file name only, never the directory.
-- Used in user-facing messages so an error never discloses the operator's
-- home layout.
vaultIdentityPathDisplay :: VaultIdentityPath -> Text
vaultIdentityPathDisplay (VaultIdentityPath p) = T.pack (takeFileName p)
