{-# LANGUAGE OverloadedStrings #-}
-- | A strict, bounded CBOR decoder — just enough of RFC 8949 to read a
-- WebAuthn @attestationObject@ and its COSE @EC2@ public key, and hostile to
-- everything else.
--
-- Deliberate restrictions (all fail closed with @Left@):
--
-- * definite lengths only — indefinite-length items (additional info 31) are
--   rejected, so a decoder never has to buffer an unbounded stream;
-- * no tags, no floats, no @undefined@;
-- * nesting depth ≤ 'maxDepth' and array/map arity ≤ 'maxItems';
-- * every declared length is checked against the bytes that remain, so a
--   4-gigabyte array header cannot make the decoder spin;
-- * the whole input is capped at 'maxInput' bytes, which bounds item count
--   structurally;
-- * 'decodeCbor' rejects trailing bytes.
--
-- There are no partial functions here: every length prefix is validated
-- before it is used.
module Seal.Security.WebAuthn.Cbor
  ( Cbor (..)
  , decodeCbor
  , decodeCborPrefix
  , cborLookupInt
  , maxInput
  ) where

import Data.Bits (shiftL, shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)

-- | A decoded CBOR value. Only the shapes WebAuthn actually uses are
-- representable.
data Cbor
  = CborInt !Integer
  | CborBytes !ByteString
  | CborText !Text
  | CborArray ![Cbor]
  | CborMap ![(Cbor, Cbor)]
  | CborBool !Bool
  | CborNull
  deriving stock (Eq, Show)

-- | Upper bound on an input we will parse at all (64 KiB). WebAuthn
-- attestation objects are a few hundred bytes; anything near this is an
-- attack.
maxInput :: Int
maxInput = 65536

maxDepth :: Int
maxDepth = 32

maxItems :: Int
maxItems = 1024

-- | Decode exactly one CBOR value; trailing bytes are an error.
decodeCbor :: ByteString -> Either Text Cbor
decodeCbor bs = do
  (v, rest) <- decodeCborPrefix bs
  if BS.null rest
    then Right v
    else Left "trailing bytes after CBOR value"

-- | Decode one CBOR value and return it with the unconsumed remainder. Used
-- for the COSE key that is followed by optional extension data inside
-- @attestedCredentialData@.
decodeCborPrefix :: ByteString -> Either Text (Cbor, ByteString)
decodeCborPrefix bs
  | BS.length bs > maxInput =
      Left ("CBOR input larger than " <> tshow maxInput <> " bytes")
  | otherwise = decodeItem 0 bs

decodeItem :: Int -> ByteString -> Either Text (Cbor, ByteString)
decodeItem depth bs
  | depth > maxDepth = Left "CBOR nesting too deep"
  | otherwise = do
      (h, rest) <- uncons "truncated CBOR value"
      let major = h `shiftR` 5
          ai    = h .&. 0x1f
      case major of
        0 -> do
          (n, rest') <- readLen ai rest
          Right (CborInt n, rest')
        1 -> do
          (n, rest') <- readLen ai rest
          Right (CborInt (negate n - 1), rest')
        2 -> do
          (n, rest') <- readLen ai rest
          (b, rest2) <- takeBytes n rest'
          Right (CborBytes b, rest2)
        3 -> do
          (n, rest') <- readLen ai rest
          (b, rest2) <- takeBytes n rest'
          case TE.decodeUtf8' b of
            Left _  -> Left "CBOR text string is not valid UTF-8"
            Right t -> Right (CborText t, rest2)
        4 -> do
          (n, rest') <- readLen ai rest
          checkArity n rest'
          decodeList (depth + 1) n rest'
        5 -> do
          (n, rest') <- readLen ai rest
          checkArity n rest'
          decodeMap (depth + 1) n rest'
        6 -> Left "CBOR tags are not accepted"
        7 -> case ai of
               20 -> Right (CborBool False, rest)
               21 -> Right (CborBool True, rest)
               22 -> Right (CborNull, rest)
               _  -> Left "unsupported CBOR simple/float value"
        _ -> Left "invalid CBOR major type"
  where
    uncons msg = case BS.uncons bs of
      Nothing     -> Left ("truncated CBOR: " <> msg)
      Just (x, xs) -> Right (x, xs)

-- | Read the length payload for an additional-info nibble.
readLen :: Word8 -> ByteString -> Either Text (Integer, ByteString)
readLen ai rest
  | ai <= 23 = Right (fromIntegral ai, rest)
  | ai == 24 = readN 1 rest
  | ai == 25 = readN 2 rest
  | ai == 26 = readN 4 rest
  | ai == 27 = readN 8 rest
  | otherwise = Left "CBOR indefinite or reserved length is not accepted"
  where
    readN n bs
      | BS.length bs < n = Left "truncated CBOR length"
      | otherwise = do
          let (raw, rest') = BS.splitAt n bs
          Right (foldl (\acc w -> acc `shiftL` 8 + fromIntegral w) 0 (BS.unpack raw), rest')

-- | Take @n@ bytes, refusing a length that exceeds the remaining input.
takeBytes :: Integer -> ByteString -> Either Text (ByteString, ByteString)
takeBytes n bs
  | n < 0 = Left "negative CBOR length"
  | n > fromIntegral (BS.length bs) = Left "CBOR length exceeds remaining input"
  | otherwise = Right (BS.splitAt (fromIntegral n) bs)

-- | Reject an arity that could not possibly be satisfied by the remaining
-- bytes (every element needs at least one byte; a map entry needs two).
checkArity :: Integer -> ByteString -> Either Text ()
checkArity n rest
  | n < 0 = Left "negative CBOR arity"
  | n > fromIntegral maxItems = Left ("CBOR container arity exceeds " <> tshow maxItems)
  | n > fromIntegral (BS.length rest) = Left "CBOR arity exceeds remaining input"
  | otherwise = Right ()

decodeList :: Int -> Integer -> ByteString -> Either Text (Cbor, ByteString)
decodeList depth n = go n []
  where
    go 0 acc rest = Right (CborArray (reverse acc), rest)
    go k acc rest = do
      (v, rest') <- decodeItem depth rest
      go (k - 1) (v : acc) rest'

decodeMap :: Int -> Integer -> ByteString -> Either Text (Cbor, ByteString)
decodeMap depth n = go n []
  where
    go 0 acc rest = Right (CborMap (reverse acc), rest)
    go k acc rest = do
      (key, rest1) <- decodeItem depth rest
      (val, rest2) <- decodeItem depth rest1
      go (k - 1) ((key, val) : acc) rest2

-- | Look up an integer key in a CBOR map. COSE keys are small integers, some
-- negative (@-1@..@-3@), so this is the only lookup the verifier needs.
cborLookupInt :: Integer -> Cbor -> Maybe Cbor
cborLookupInt k (CborMap pairs) = lookup (CborInt k) pairs
cborLookupInt _ _               = Nothing

tshow :: Show a => a -> Text
tshow = T.pack . show
