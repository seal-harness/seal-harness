{-# LANGUAGE OverloadedStrings #-}
-- | Standalone symmetric-crypto primitives: AES-256-CTR encryption, SHA-256
-- hashing, constant-time comparison, and random-byte / token generation.
--
-- __Important — confidentiality only, no authentication.__
-- The 'encrypt' and 'decrypt' functions use AES-256 in CTR mode, which
-- provides /confidentiality/ but /not/ integrity or authentication.  The
-- ciphertext is unauthenticated and malleable: bit-flips to the ciphertext
-- produce bit-flips in the decrypted output with no error raised.  Callers
-- that need tamper-detection must pair this with a MAC, switch to an AEAD
-- construction, or — for at-rest secrets — use the vault API, which is backed
-- by @age@ (an authenticated encryption scheme).
module Seal.Security.Crypto
  ( getRandomBytes
  , sha256Hash
  , constantTimeEq
  , generateToken
  , encrypt
  , decrypt
  ) where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (ctrCombine, cipherInit, makeIV)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256, hash, Digest)
import Crypto.Random qualified as R
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Seal.Security.Secrets (SecretKey, withSecretKey)

ivLength :: Int
ivLength = 16

-- | Cryptographically secure random bytes from system entropy.
getRandomBytes :: Int -> IO ByteString
getRandomBytes = R.getRandomBytes

-- | Lowercase-hex SHA-256 of the input (64 ASCII bytes).
-- crypton-1.x wraps GHC's native ByteArray, which is not an instance of
-- memory's ByteArrayAccess, so we go through the Show instance (which renders
-- lowercase hex) rather than convertToBase.
sha256Hash :: ByteString -> ByteString
sha256Hash bs = BC.pack $ show (hash bs :: Digest SHA256)

-- | Constant-time equality, for comparing secrets/tokens/hashes.
constantTimeEq :: ByteString -> ByteString -> Bool
constantTimeEq = constEq

-- | A hex token of @n@ random bytes (so 2n hex chars).
generateToken :: Int -> IO Text
generateToken n = do
  raw <- getRandomBytes n
  pure (TE.decodeUtf8 (convertToBase Base16 raw))

-- | AES-256-CTR encrypt. A fresh random 16-byte IV is generated and prepended
-- to the ciphertext. The key must be exactly 32 bytes.
--
-- __Warning — confidentiality only, NOT integrity\/authentication.__
-- The ciphertext is unauthenticated and malleable: bit-flips in transit go
-- undetected.  Callers needing tamper-detection must add a MAC or use an AEAD
-- construction; for at-rest secrets prefer the vault API, which uses an
-- authenticated scheme end-to-end.
encrypt :: SecretKey -> ByteString -> IO (Either Text ByteString)
encrypt sk plaintext = withSecretKey sk $ \keyBytes ->
  case cipherInit keyBytes :: CryptoFailable AES256 of
    CryptoFailed _      -> pure (Left "key must be 32 bytes for AES-256")
    CryptoPassed cipher -> do
      ivBytes <- getRandomBytes ivLength
      case makeIV ivBytes of
        Nothing -> pure (Left "could not construct a 16-byte IV")
        Just iv -> pure (Right (ivBytes <> ctrCombine cipher iv plaintext))

-- | Inverse of 'encrypt'. Pure: CTR needs no entropy to decrypt.
--
-- __Warning — confidentiality only, NOT integrity\/authentication.__
-- No MAC is checked; a tampered ciphertext decrypts silently to corrupted
-- plaintext.  See 'encrypt' for guidance on when to use a MAC or AEAD instead.
decrypt :: SecretKey -> ByteString -> Either Text ByteString
decrypt sk blob = withSecretKey sk $ \keyBytes ->
  if BS.length blob < ivLength
    then Left "ciphertext shorter than the IV it must carry"
    else
      let (ivBytes, ciphertext) = BS.splitAt ivLength blob
      in case cipherInit keyBytes :: CryptoFailable AES256 of
           CryptoFailed _      -> Left "key must be 32 bytes for AES-256"
           CryptoPassed cipher ->
             case makeIV ivBytes of
               Nothing -> Left "could not construct a 16-byte IV"
               Just iv -> Right (ctrCombine cipher iv ciphertext)
