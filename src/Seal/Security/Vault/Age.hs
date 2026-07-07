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
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.IO (hClose, hFlush)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess )

-- | Run a process with a strict 'ByteString' stdin, capturing stdout and
-- stderr as strict 'ByteString's. Used by the age encrypt/decrypt seam
-- where the payload is binary (ciphertext) and must not be round-tripped
-- through 'String'. Closes all handles and waits for the child before
-- returning.
readProcessBinary :: FilePath -> [String] -> ByteString
                 -> IO (ExitCode, ByteString, ByteString)
readProcessBinary cmdPath args input =
  withCreateProcess
    ( (proc cmdPath args)
        { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
    ) $ \mIn mOut mErr ph -> do
      (hIn, hOut, hErr) <- case (mIn, mOut, mErr) of
        (Just a, Just b, Just c) -> pure (a, b, c)
        _ -> error "readProcessBinary: pipe creation failed (unreachable)"
      -- Feed stdin on a child thread so we can read stdout/stderr
      -- concurrently without deadlocking on a large payload.
      BS.hPutStr hIn input
      hFlush hIn
      hClose hIn
      -- Read stdout/stderr fully after stdin is closed (age reads the
      -- whole plaintext before emitting ciphertext, so this is safe).
      out <- BS.hGetContents hOut
      err <- BS.hGetContents hErr
      ec  <- waitForProcess ph
      -- Force the lazy hGetContents results so the handles are fully read
      -- before withCreateProcess closes them.
      let !_ = BS.length out
          !_ = BS.length err
      pure (ec, out, err)

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
  versionResult <- try @IOException (callProcessNoOutput "age" ["--version"])
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
      (code, out, err) <- readProcessBinary "age" args input
      pure $ case code of
        ExitSuccess   -> Right out
        ExitFailure _ -> Left (VaultBackendError (TE.decodeUtf8Lenient err))

-- | Run a process, ignoring its stdout/stderr, returning only the exit code.
-- Used for the @age --version@ preflight. Catches a launch failure as
-- 'ExitFailure 127' (consistent with the git seam's convention).
callProcessNoOutput :: FilePath -> [String] -> IO ExitCode
callProcessNoOutput cmdPath args =
  withCreateProcess ((proc cmdPath args) { std_out = NoStream, std_err = NoStream }) $
    \_ _ _ ph -> waitForProcess ph

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
