{-# LANGUAGE OverloadedStrings #-}
-- | The vault's encryption seam. The real encryptor shells out to the @age@
-- binary (so hardware-token support via age plugins is free); tests use the
-- in-process mock, so the suite needs no binary on PATH.
module Seal.Security.Vault.Age
  ( VaultError (..)
  , VaultEncryptor (..)
  , AgeRecipient (..)
  , AgeIdentity (..)
  , mkAgeEncryptor
  , mkMockEncryptor
  , mkFailingEncryptor
  ) where

import Control.Exception (IOException, try)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Process.Typed
  ( ExitCode (..), byteStringInput, proc, readProcess, runProcess, setStdin )

-- | The vault's error type. The first four constructors are matched on to
-- drive control flow (so they earn being a sum type per the haskell-coder
-- skill); 'VaultBackendError' is the single catch-all for failures that are
-- only reported — @age@ stderr, "age not installed", corrupt vault data.
data VaultError
  = VaultLocked
  | VaultNotFound
  | VaultAlreadyExists
  | VaultKeyNotFound Text
  | VaultBackendError Text
  deriving stock (Eq, Show)

newtype AgeRecipient = AgeRecipient Text deriving stock (Eq, Show)
newtype AgeIdentity  = AgeIdentity  Text deriving stock (Eq, Show)

-- | Encrypt/decrypt with credentials already captured in the closure.
data VaultEncryptor = VaultEncryptor
  { veEncrypt :: ByteString -> IO (Either VaultError ByteString)
  , veDecrypt :: ByteString -> IO (Either VaultError ByteString)
  }

-- | Build a real encryptor backed by @age@. Preflights @age --version@ and
-- reports a 'VaultBackendError' install hint if the binary is absent.
mkAgeEncryptor :: AgeRecipient -> AgeIdentity -> IO (Either VaultError VaultEncryptor)
mkAgeEncryptor (AgeRecipient recipient) (AgeIdentity identity) = do
  versionResult <- try @IOException (runProcess (proc "age" ["--version"]))
  case versionResult of
    Right ExitSuccess ->
      pure (Right VaultEncryptor
        { veEncrypt = run ["--encrypt", "--recipient", T.unpack recipient]
        , veDecrypt = run ["--decrypt", "--identity", T.unpack identity]
        })
    _ -> pure notInstalled  -- IOException (binary absent) OR ExitFailure
  where
    notInstalled =
      Left (VaultBackendError "age not installed; see https://age-encryption.org")
    run :: [String] -> ByteString -> IO (Either VaultError ByteString)
    run args input = do
      let cfg = setStdin (byteStringInput (BL.fromStrict input)) (proc "age" args)
      (code, out, err) <- readProcess cfg
      pure $ case code of
        ExitSuccess   -> Right (BL.toStrict out)
        ExitFailure _ -> Left (VaultBackendError (TE.decodeUtf8Lenient (BL.toStrict err)))

-- | XOR-with-0xAB mock; reversible, no binary required.
mkMockEncryptor :: VaultEncryptor
mkMockEncryptor = VaultEncryptor
  { veEncrypt = pure . Right . BS.map (`xor` 0xAB)
  , veDecrypt = pure . Right . BS.map (`xor` 0xAB)
  }

-- | An encryptor that always fails; for exercising vault error paths.
mkFailingEncryptor :: VaultError -> VaultEncryptor
mkFailingEncryptor e = VaultEncryptor
  { veEncrypt = const (pure (Left e))
  , veDecrypt = const (pure (Left e))
  }
