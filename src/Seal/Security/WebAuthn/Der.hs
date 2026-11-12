{-# LANGUAGE OverloadedStrings #-}
-- | A strict, bounded DER decoder for the one structure WebAuthn needs: the
-- @Ecdsa-Sig-Value@ that an authenticator returns for an ES256 assertion,
--
-- > SEQUENCE { r INTEGER, s INTEGER }
--
-- crypton's 'Crypto.PubKey.ECC.ECDSA.verify' takes a pair of 'Integer's, and
-- nothing in the existing dependency set parses DER, so this module is the
-- third small decoder the design calls for.
--
-- Bounds: the whole input must be consumed, lengths must be definite and
-- satisfiable by the remaining bytes, and both integers must be non-empty and
-- non-negative. No partial functions.
module Seal.Security.WebAuthn.Der
  ( decodeEcdsaSignature
  , maxInput
  ) where

import Data.Bits (shiftL, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Word (Word8)

-- | Upper bound on a signature we will parse (512 bytes is generous for two
-- 256-bit integers).
maxInput :: Int
maxInput = 512

-- | Parse an ECDSA signature into @(r, s)@.
decodeEcdsaSignature :: ByteString -> Either Text (Integer, Integer)
decodeEcdsaSignature bs
  | BS.length bs > maxInput = Left "DER input too large"
  | BS.null bs              = Left "empty DER input"
  | otherwise = do
      (tag, rest0) <- take1 bs
      if tag /= 0x30
        then Left "DER: expected a SEQUENCE (0x30)"
        else do
          (len, rest1) <- takeLength rest0
          (body, rest2) <- takeExact len rest1
          if not (BS.null rest2)
            then Left "DER: trailing bytes after SEQUENCE"
            else do
              (r, rest3) <- takeInteger body
              (s, rest4) <- takeInteger rest3
              if BS.null rest4
                then Right (r, s)
                else Left "DER: trailing bytes after the integers"

take1 :: ByteString -> Either Text (Word8, ByteString)
take1 bs = case BS.uncons bs of
  Nothing      -> Left "DER: truncated input"
  Just (x, xs) -> Right (x, xs)

takeLength :: ByteString -> Either Text (Int, ByteString)
takeLength bs = do
  (b0, rest) <- take1 bs
  if b0 < 0x80
    then Right (fromIntegral b0, rest)
    else if b0 == 0x80
      then Left "DER: indefinite lengths are not accepted"
      else do
        let n = fromIntegral (b0 .&. 0x7f)
        if n == 0 || n > 3
          then Left "DER: unsupported length width"
          else do
            (raw, rest') <- takeExact n rest
            Right (foldl (\acc w -> acc `shiftL` 8 + fromIntegral w) 0 (BS.unpack raw), rest')

takeExact :: Int -> ByteString -> Either Text (ByteString, ByteString)
takeExact n bs
  | n < 0 = Left "DER: negative length"
  | n > BS.length bs = Left "DER: length exceeds remaining input"
  | otherwise = Right (BS.splitAt n bs)

takeInteger :: ByteString -> Either Text (Integer, ByteString)
takeInteger bs = do
  (tag, rest0) <- take1 bs
  if tag /= 0x02
    then Left "DER: expected an INTEGER (0x02)"
    else do
      (len, rest1) <- takeLength rest0
      if len <= 0
        then Left "DER: empty INTEGER"
        else do
          (raw, rest2) <- takeExact len rest1
          case BS.uncons raw of
            Nothing -> Left "DER: empty INTEGER"
            Just (b0, _)
              -- WebAuthn ES256 signatures are always positive; a negative r or
              -- s is a malformed signature, not a value to reinterpret.
              | b0 .&. 0x80 /= 0 -> Left "DER: negative INTEGER in an ECDSA signature"
              | otherwise ->
                  Right (foldl (\acc w -> acc `shiftL` 8 + fromIntegral w) 0 (BS.unpack raw), rest2)
