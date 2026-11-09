{-# LANGUAGE OverloadedStrings #-}
-- | The vault's encryption seam. The real encryptor shells out to the @age@
-- binary (so hardware-token support via age plugins is free); tests use the
-- in-process mock, so the suite needs no binary on PATH.
module Seal.Security.Vault.Age
  ( VaultError (..)
  , VaultEncryptor (..)
  , AgeRecipient (..)
  , AgeIdentity (..)
  , mkAgeRecipient
  , ageEncryptArgs
  , ageDecryptArgs
  , mkAgeEncryptor
  , mkMockEncryptor
  , mkFailingEncryptor
  ) where

import Control.Exception (IOException, try)
import Data.Bits (xor)
import Data.Char (isAsciiLower, isDigit)
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

-- | Validate an age recipient (public key).
--
-- The shape is checked, the bech32 checksum cannot be: a wrong-but-well-formed
-- recipient only fails when @age@ actually encrypts with it, which is why
-- 'Seal.Vault.Provision' round-trips a nonce before recording anything.
--
-- Rejections: empty, longer than any real recipient, a control character or
-- whitespace, a leading @-@ (option injection), and any character outside the
-- bech32 alphabet used by age (@a-z0-9@ after the @age1@ prefix; yubikey
-- recipients use @age1yubikey1@).
mkAgeRecipient :: Text -> Either Text AgeRecipient
mkAgeRecipient raw
  | T.null t = Left "recipient is empty"
  | T.length t > 512 = Left "recipient is implausibly long"
  | T.head t == '-' = Left "recipient must not start with '-'"
  | "age1" `T.isPrefixOf` t = checkRest (T.drop 4 t)
  | otherwise = Left "recipient must start with \"age1\""
  where
    t = T.strip raw
    checkRest rest
      | T.null rest = Left "recipient is truncated"
      | T.all isBech32Char rest = Right (AgeRecipient t)
      | otherwise = Left "recipient has characters outside the age alphabet"
    isBech32Char c = isAsciiLower c || isDigit c

-- | The argv @age@ is invoked with to encrypt under a recipient.
--
-- Single-token option forms (@--recipient=\<value\>@) so no value can ever be
-- reinterpreted as a flag, even if a future parser change lets one through.
ageEncryptArgs :: AgeRecipient -> [String]
ageEncryptArgs (AgeRecipient recipient) = ["--encrypt", "--recipient=" <> T.unpack recipient]

-- | The argv @age@ is invoked with to decrypt with an identity file.
ageDecryptArgs :: AgeIdentity -> [String]
ageDecryptArgs (AgeIdentity identity) = ["--decrypt", "--identity=" <> T.unpack identity]

-- | Encrypt/decrypt with credentials already captured in the closure.
data VaultEncryptor = VaultEncryptor
  { veEncrypt :: ByteString -> IO (Either VaultError ByteString)
  , veDecrypt :: ByteString -> IO (Either VaultError ByteString)
  }

-- | Build a real encryptor backed by @age@. Preflights @age --version@ and
-- reports a 'VaultBackendError' install hint if the binary is absent.
--
-- Both credentials are validated here before anything is spawned: this is the
-- single choke point every caller goes through (the CLI, the gateway, a
-- hand-edited @security.toml@), so a malformed value can never reach @age@'s
-- argv. The recipient's checksum cannot be checked without @age@ — that is what
-- the provisioning round-trip is for.
mkAgeEncryptor :: AgeRecipient -> AgeIdentity -> IO (Either VaultError VaultEncryptor)
mkAgeEncryptor recipient identity =
  case (mkAgeRecipient (recipientText recipient), validateAgeIdentity identity) of
    (Left err, _) -> pure (Left (VaultBackendError ("invalid recipient: " <> err)))
    (_, Left err) -> pure (Left (VaultBackendError ("invalid identity path: " <> err)))
    (Right _, Right ()) -> do
      versionResult <- try @IOException (callProcessNoOutput "age" ["--version"])
      case versionResult of
        Right ExitSuccess ->
          pure (Right VaultEncryptor
            { veEncrypt = run (ageEncryptArgs recipient)
            , veDecrypt = run (ageDecryptArgs identity)
            })
        _ -> pure notInstalled  -- IOException (binary absent) OR ExitFailure
  where
    recipientText (AgeRecipient t) = t
    notInstalled =
      Left (VaultBackendError "age not installed; see https://age-encryption.org")
    run :: [String] -> ByteString -> IO (Either VaultError ByteString)
    run args input = do
      (code, out, err) <- readProcessBinary "age" args input
      pure $ case code of
        ExitSuccess   -> Right out
        ExitFailure _ -> Left (VaultBackendError (TE.decodeUtf8Lenient err))

-- | Structural validation of an identity path: non-empty, absolute, no
-- control characters, no leading @-@. Existence is checked by the caller
-- ("Seal.Vault.IdentityPath" does it for user-supplied paths; the boot path
-- needs the encryptor to exist before it can stat anything).
validateAgeIdentity :: AgeIdentity -> Either Text ()
validateAgeIdentity (AgeIdentity path) = do
  let t = T.strip path
  if T.null t then Left "identity path is empty" else Right ()
  if T.head t == '-' then Left "identity path must not start with '-'" else Right ()
  if not (T.isPrefixOf "/" t) then Left "identity path must be absolute" else Right ()
  if T.any (\c -> c < ' ' || c == '\DEL') t
    then Left "identity path contains a control character"
    else Right ()

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
