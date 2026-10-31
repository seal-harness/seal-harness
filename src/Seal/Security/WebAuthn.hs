{-# LANGUAGE OverloadedStrings #-}
-- | WebAuthn (passkey) ceremony verification — the security core of the
-- gateway's access control. Pure: every function here takes bytes and returns
-- 'Either', so the whole surface is testable without a browser, a socket or a
-- clock.
--
-- Scope (design §9):
--
-- * registration accepts @fmt = \"none\"@ only and checks the client data,
--   the rpId hash, the presence and user-verification flags, and the attested
--   credential data (id length, @rawId@ agreement, COSE key shape);
-- * assertion checks the same client-data / rpId / flag invariants and
--   verifies the ECDSA P-256 signature over
--   @authData || SHA-256(clientDataJSON)@;
-- * the sign-counter rule lives in 'checkSignCount' so the caller can run it
--   under the same lock that persists the new value.
--
-- Attestation statements are deliberately not verified: we request
-- @attestation: \"none\"@, and the WebAuthn spec does not require an RP to
-- validate an attestation it did not ask for.
module Seal.Security.WebAuthn
  ( WebAuthnError (..)
  , webAuthnErrorText
  , webAuthnErrorCode
  , Ceremony (..)
  , ceremonyText
  , RegistrationInput (..)
  , RegistrationResult (..)
  , AssertionInput (..)
  , ClientData (..)
  , verifyRegistration
  , verifyAssertion
  , checkSignCount
  , normalizeOrigin
  , parseClientData
  , AuthenticatorData (..)
  , parseAuthenticatorData
  , adUserPresent
  , adUserVerified
  , adHasAttestedCredential
  , cosePublicKeyToPoint
  ) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (shiftL, (.&.))
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64Url
import Data.Text (Text)
import Data.Text qualified as T
import Data.Maybe (fromMaybe)
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)

import Crypto.Hash (Digest, SHA256 (..), hash)
import Crypto.PubKey.ECC.ECDSA (PublicKey (..), Signature (..), verify)
import Crypto.PubKey.ECC.Prim (isPointValid)
import Crypto.PubKey.ECC.Types
  ( CurveName (SEC_p256r1), Point (Point), getCurveByName )
import Data.ByteArray (convert)

import Seal.Security.WebAuthn.Cbor
import Seal.Security.WebAuthn.Der (decodeEcdsaSignature)
import Seal.Security.WebAuthn.Types (CosePublicKey (..))

-- | Everything that can make a ceremony fail. Callers map these to HTTP error
-- codes via 'webAuthnErrorCode'; the constructors exist so the program can
-- pattern-match on the failure class rather than parse a string.
data WebAuthnError
  = WnMalformedClientData Text
  | WnWrongCeremony Text
  | WnChallengeMismatch
  | WnOriginMismatch Text
  | WnCrossOrigin
  | WnMalformedAuthenticatorData Text
  | WnRpIdMismatch
  | WnUserPresenceMissing
  | WnUserVerificationMissing
  | WnAttestedCredentialMissing
  | WnCredentialIdMismatch
  | WnCredentialIdLength Int
  | WnUnsupportedAttestation Text
  | WnMalformedCoseKey Text
  | WnSignatureInvalid
  | WnSignCountRegression Int Int
  deriving stock (Eq, Show)

-- | A human-readable sentence (goes in the API's @error@ field).
webAuthnErrorText :: WebAuthnError -> Text
webAuthnErrorText err = case err of
  WnMalformedClientData d        -> "malformed clientDataJSON: " <> d
  WnWrongCeremony t              -> "unexpected ceremony type \"" <> t <> "\""
  WnChallengeMismatch            -> "the challenge does not match the one this server issued"
  WnOriginMismatch o             -> "the request origin (" <> o <> ") does not match this gateway's configured origin"
  WnCrossOrigin                  -> "cross-origin ceremonies are not accepted"
  WnMalformedAuthenticatorData d -> "malformed authenticator data: " <> d
  WnRpIdMismatch                 -> "the credential was registered for a different relying-party id"
  WnUserPresenceMissing          -> "the authenticator did not assert user presence"
  WnUserVerificationMissing      -> "the authenticator did not verify the user (PIN or biometric required)"
  WnAttestedCredentialMissing    -> "the registration response carried no credential"
  WnCredentialIdMismatch         -> "the credential id does not match the attested credential"
  WnCredentialIdLength n         -> "the credential id length (" <> tshow n <> ") is out of range"
  WnUnsupportedAttestation f     -> "unsupported attestation format \"" <> f <> "\""
  WnMalformedCoseKey d           -> "malformed public key: " <> d
  WnSignatureInvalid             -> "the signature does not verify"
  WnSignCountRegression old new  ->
    "the signature counter went backwards (" <> tshow new <> " after "
      <> tshow old <> "), which indicates a replayed assertion"

-- | A stable machine token for the API's @code@ field (design §8). The UI
-- switches on this, never on the sentence.
webAuthnErrorCode :: WebAuthnError -> Text
webAuthnErrorCode err = case err of
  WnMalformedClientData _        -> "malformed_client_data"
  WnWrongCeremony _              -> "wrong_ceremony"
  WnChallengeMismatch            -> "challenge_invalid"
  WnOriginMismatch _             -> "origin_mismatch"
  WnCrossOrigin                  -> "origin_mismatch"
  WnMalformedAuthenticatorData _ -> "malformed_authenticator_data"
  WnRpIdMismatch                 -> "rp_mismatch"
  WnUserPresenceMissing          -> "user_presence_required"
  WnUserVerificationMissing      -> "user_verification_required"
  WnAttestedCredentialMissing    -> "attested_credential_missing"
  WnCredentialIdMismatch         -> "credential_id_mismatch"
  WnCredentialIdLength _         -> "credential_id_invalid"
  WnUnsupportedAttestation _     -> "unsupported_attestation"
  WnMalformedCoseKey _           -> "malformed_key"
  WnSignatureInvalid             -> "signature_invalid"
  WnSignCountRegression _ _      -> "sign_count_regression"

-- | Which ceremony a challenge was issued for. A challenge is bound to its
-- ceremony so a @create@ challenge cannot be redeemed at the @get@ endpoint.
data Ceremony = CerCreate | CerGet | CerAdd
  deriving stock (Eq, Show)

ceremonyText :: Ceremony -> Text
ceremonyText c = case c of
  CerCreate -> "webauthn.create"
  CerGet    -> "webauthn.get"
  CerAdd    -> "webauthn.create"

-- ---------------------------------------------------------------------------
-- clientDataJSON
-- ---------------------------------------------------------------------------

-- | The fields of @clientDataJSON@ we act on.
data ClientData = ClientData
  { cdType        :: Text
  , cdChallenge   :: Text
  , cdOrigin      :: Text
  , cdCrossOrigin :: Bool
  } deriving stock (Eq, Show)

-- | Parse @clientDataJSON@ with aeson (never by string matching).
parseClientData :: ByteString -> Either WebAuthnError ClientData
parseClientData raw =
  case A.eitherDecodeStrict' raw :: Either String Value of
    Left e -> Left (WnMalformedClientData (T.pack e))
    Right (Object o) -> ClientData
      <$> field o "type"
      <*> field o "challenge"
      <*> field o "origin"
      <*> pure (case KeyMap.lookup (Key.fromText "crossOrigin") o of
                  Just (Bool b) -> b
                  _             -> False)
    Right _ -> Left (WnMalformedClientData "not a JSON object")
  where
    field o k = case KeyMap.lookup (Key.fromText k) o of
      Just (String s) -> Right s
      Just _          -> Left (WnMalformedClientData ("field \"" <> k <> "\" is not a string"))
      Nothing         -> Left (WnMalformedClientData ("missing field \"" <> k <> "\""))

-- | Check the ceremony type, the challenge and the origin.
--
-- Both sides of the challenge comparison are base64url-decoded, so a
-- re-encoded (but equivalent) challenge cannot be used to smuggle a mismatch
-- past an exact text comparison — and a different challenge never compares
-- equal by accident.
checkClientData :: Ceremony -> Text -> Text -> ClientData -> Either WebAuthnError ()
checkClientData ceremony expectedChallenge expectedOrigin cd = do
  if cdType cd /= ceremonyText ceremony
    then Left (WnWrongCeremony (cdType cd))
    else Right ()
  if cdCrossOrigin cd
    then Left WnCrossOrigin
    else Right ()
  case (decodeB64Url (cdChallenge cd), decodeB64Url expectedChallenge) of
    (Right a, Right b) | a == b -> Right ()
    (Right _, Right _)          -> Left WnChallengeMismatch
    -- One side is not valid base64url: fall back to a padding-insensitive
    -- text comparison so a browser that only re-pads still verifies.
    _ | stripPadding (cdChallenge cd) == stripPadding expectedChallenge -> Right ()
      | otherwise -> Left WnChallengeMismatch
  case normalizeOrigin (cdOrigin cd) of
    Just o | o == normalizeOrigin' expectedOrigin -> Right ()
    _ -> Left (WnOriginMismatch (cdOrigin cd))
  where
    normalizeOrigin' = fromMaybe expectedOrigin . normalizeOrigin

-- | Normalise an origin to @scheme://host[:port]@ with scheme and host
-- lower-cased, a trailing slash removed, and the scheme's default port
-- elided. Returns 'Nothing' for anything that is not an absolute
-- @scheme://host@ URL.
normalizeOrigin :: Text -> Maybe Text
normalizeOrigin t0 =
  case T.breakOn "://" (T.dropWhileEnd (== '/') (T.strip t0)) of
    (scheme, rest)
      | T.null rest || T.null scheme -> Nothing
      | not (T.all validSchemeChar scheme) -> Nothing
      | otherwise ->
          let (authority, path) = T.break (== '/') (T.drop 3 rest)
          in if not (T.null path) || T.null authority
               then Nothing
               else
                 let schemeL = T.toLower scheme
                     (host, port) = splitHostPort authority
                     hostL = T.toLower host
                     defaultPort = case schemeL of
                       "https" -> Just "443"
                       "http"  -> Just "80"
                       _       -> Nothing
                 in if T.null hostL
                      then Nothing
                      else Just $ case port of
                        Just p | Just p /= defaultPort -> schemeL <> "://" <> hostL <> ":" <> p
                        _                              -> schemeL <> "://" <> hostL
  where
    validSchemeChar c =
      isAsciiLower c || isAsciiUpper c || isDigit c || c == '+' || c == '-' || c == '.'

-- | Split @host[:port]@. A bare IPv6 literal is returned unchanged with no
-- port (the gateway never derives an IPv6 origin; a wildcard bind has no
-- derivable origin at all).
splitHostPort :: Text -> (Text, Maybe Text)
splitHostPort authority =
  case T.breakOnEnd ":" authority of
    (withColon, port)
      | T.null withColon -> (authority, Nothing)
      | T.any (== ':') (T.dropEnd 1 withColon) -> (authority, Nothing)
      | T.null port -> (authority, Nothing)
      | T.all isDigit port -> (T.dropEnd 1 withColon, Just port)
      | otherwise -> (authority, Nothing)

-- ---------------------------------------------------------------------------
-- authenticatorData
-- ---------------------------------------------------------------------------

-- | The parsed fixed header of @authenticatorData@ plus the attested
-- credential data when the @AT@ flag is set.
data AuthenticatorData = AuthenticatorData
  { adRpIdHash   :: ByteString
  , adFlags      :: Word8
  , adSignCount  :: Int
  , adCredential :: Maybe (ByteString, CosePublicKey)
  , adRaw        :: ByteString
    -- ^ The exact bytes, needed verbatim for signature verification.
  } deriving stock (Eq, Show)

flagUserPresent, flagUserVerified, flagAttested :: Word8
flagUserPresent  = 0x01
flagUserVerified = 0x04
flagAttested     = 0x40

adUserPresent :: AuthenticatorData -> Bool
adUserPresent ad = adFlags ad .&. flagUserPresent /= 0

adUserVerified :: AuthenticatorData -> Bool
adUserVerified ad = adFlags ad .&. flagUserVerified /= 0

adHasAttestedCredential :: AuthenticatorData -> Bool
adHasAttestedCredential ad = adFlags ad .&. flagAttested /= 0

-- | Parse @authenticatorData@. Requires at least the 37-byte fixed header;
-- when @AT@ is set, parses @aaguid(16) || credIdLen(2) || credId || COSE key@.
parseAuthenticatorData :: ByteString -> Either WebAuthnError AuthenticatorData
parseAuthenticatorData raw
  | BS.length raw < 37 =
      Left (WnMalformedAuthenticatorData "shorter than the 37-byte header")
  | flags .&. flagAttested == 0 =
      Right AuthenticatorData
        { adRpIdHash = rpIdHash, adFlags = flags, adSignCount = signCount
        , adCredential = Nothing, adRaw = raw }
  | otherwise = do
      (credId, credIdLen, keyBytes) <- parseAttested rest
      if credIdLen < 1 || credIdLen > 1023
        then Left (WnCredentialIdLength credIdLen)
        else do
          cose <- case decodeCborPrefix keyBytes of
            Left e           -> Left (WnMalformedCoseKey e)
            Right (value, _) -> Right value
          key <- parseCoseKey cose
          Right AuthenticatorData
            { adRpIdHash = rpIdHash, adFlags = flags, adSignCount = signCount
            , adCredential = Just (credId, key), adRaw = raw }
  where
    rpIdHash  = BS.take 32 raw
    flags     = BS.index raw 32
    signCount = be32 (BS.take 4 (BS.drop 33 raw))
    rest      = BS.drop 37 raw

-- | Split @aaguid(16) || credIdLen(2) || credId@ off the front, returning the
-- id, its declared length and the remaining (COSE key + optional extensions)
-- bytes.
parseAttested :: ByteString -> Either WebAuthnError (ByteString, Int, ByteString)
parseAttested r
  | BS.length r < 18 =
      Left (WnMalformedAuthenticatorData "truncated attested credential data")
  | otherwise =
      let afterAaguid = BS.drop 16 r
          len = be16 (BS.take 2 afterAaguid)
          credId = BS.take len (BS.drop 2 afterAaguid)
      in if BS.length credId /= len
           then Left (WnMalformedAuthenticatorData "truncated credential id")
           else Right (credId, len, BS.drop (2 + len) afterAaguid)

-- | Parse a COSE @EC2@ public key: @{1: 2, 3: -7, -1: 1, -2: x, -3: y}@.
parseCoseKey :: Cbor -> Either WebAuthnError CosePublicKey
parseCoseKey cose = do
  kty <- intField 1
  alg <- intField 3
  crv <- intField (-1)
  x   <- bytesField (-2)
  y   <- bytesField (-3)
  if kty /= 2
    then Left (WnMalformedCoseKey "kty is not EC2 (2)")
    else if alg /= -7
      then Left (WnMalformedCoseKey "alg is not ES256 (-7)")
      else if crv /= 1
        then Left (WnMalformedCoseKey "crv is not P-256 (1)")
        else if BS.length x /= 32 || BS.length y /= 32
          then Left (WnMalformedCoseKey "x/y are not 32 bytes each")
          else do
            let key = CosePublicKey (x <> y)
            _ <- cosePublicKeyToPoint key
            Right key
  where
    intField k = case cborLookupInt k cose of
      Just (CborInt n) -> Right n
      Just _           -> Left (WnMalformedCoseKey ("field " <> tshow k <> " is not an integer"))
      Nothing          -> Left (WnMalformedCoseKey ("missing field " <> tshow k))
    bytesField k = case cborLookupInt k cose of
      Just (CborBytes b) -> Right b
      Just _             -> Left (WnMalformedCoseKey ("field " <> tshow k <> " is not a byte string"))
      Nothing            -> Left (WnMalformedCoseKey ("missing field " <> tshow k))

-- | Convert a 64-byte @x || y@ key into a crypton 'PublicKey', rejecting a
-- point that is not on the curve.
cosePublicKeyToPoint :: CosePublicKey -> Either WebAuthnError PublicKey
cosePublicKeyToPoint (CosePublicKey bytes)
  | BS.length bytes /= 64 = Left (WnMalformedCoseKey "key is not 64 bytes")
  | not (isPointValid curve point) = Left (WnMalformedCoseKey "point is not on P-256")
  | otherwise = Right (PublicKey curve point)
  where
    (xb, yb) = BS.splitAt 32 bytes
    point = Point (beInteger xb) (beInteger yb)
    curve = getCurveByName SEC_p256r1

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

data RegistrationInput = RegistrationInput
  { riClientDataJSON    :: ByteString
  , riAttestationObject :: ByteString
  , riRawId             :: ByteString
  , riExpectedChallenge :: Text
  , riExpectedOrigin    :: Text
  , riExpectedRpId      :: Text
  } deriving stock (Eq, Show)

data RegistrationResult = RegistrationResult
  { rrCredentialId :: ByteString
  , rrPublicKey    :: CosePublicKey
  , rrSignCount    :: Int
  } deriving stock (Eq, Show)

-- | Verify a @navigator.credentials.create()@ response.
verifyRegistration :: RegistrationInput -> Either WebAuthnError RegistrationResult
verifyRegistration ri = do
  cd <- parseClientData (riClientDataJSON ri)
  checkClientData CerCreate (riExpectedChallenge ri) (riExpectedOrigin ri) cd
  authData <- attestationAuthData (riAttestationObject ri)
  ad <- parseAuthenticatorData authData
  checkHeader (riExpectedRpId ri) ad
  (credId, key) <- case adCredential ad of
    Just pair -> Right pair
    Nothing   -> Left WnAttestedCredentialMissing
  if credId /= riRawId ri
    then Left WnCredentialIdMismatch
    else if BS.length credId < 1 || BS.length credId > 1023
      then Left (WnCredentialIdLength (BS.length credId))
      else Right RegistrationResult
             { rrCredentialId = credId
             , rrPublicKey = key
             , rrSignCount = adSignCount ad
             }

-- | Pull @authData@ out of the attestation object, requiring
-- @fmt = \"none\"@.
attestationAuthData :: ByteString -> Either WebAuthnError ByteString
attestationAuthData raw = do
  cose <- either (Left . WnUnsupportedAttestation) Right (decodeCbor raw)
  pairs <- case cose of
    CborMap ps -> Right ps
    _          -> Left (WnUnsupportedAttestation "attestation object is not a map")
  fmt <- case lookup (CborText "fmt") pairs of
    Just (CborText f) -> Right f
    _                 -> Left (WnUnsupportedAttestation "missing fmt")
  if fmt /= "none"
    then Left (WnUnsupportedAttestation fmt)
    else case lookup (CborText "authData") pairs of
      Just (CborBytes b) -> Right b
      _                  -> Left (WnUnsupportedAttestation "missing authData")

-- | The invariants shared by both ceremonies.
checkHeader :: Text -> AuthenticatorData -> Either WebAuthnError ()
checkHeader expectedRpId ad = do
  if adRpIdHash ad /= sha256 (TE.encodeUtf8 expectedRpId)
    then Left WnRpIdMismatch
    else Right ()
  if not (adUserPresent ad)
    then Left WnUserPresenceMissing
    else Right ()
  if not (adUserVerified ad)
    then Left WnUserVerificationMissing
    else Right ()

-- ---------------------------------------------------------------------------
-- Assertion
-- ---------------------------------------------------------------------------

data AssertionInput = AssertionInput
  { aiClientDataJSON    :: ByteString
  , aiAuthenticatorData :: ByteString
  , aiSignature         :: ByteString
  , aiExpectedChallenge :: Text
  , aiExpectedOrigin    :: Text
  , aiExpectedRpId      :: Text
  , aiStoredSignCount   :: Int
  } deriving stock (Eq, Show)

-- | Verify a @navigator.credentials.get()@ response. Returns the new sign
-- counter; the caller persists it under the same lock, so the
-- read-check-write cannot interleave with a replayed assertion.
verifyAssertion :: CosePublicKey -> AssertionInput -> Either WebAuthnError Int
verifyAssertion key ai = do
  cd <- parseClientData (aiClientDataJSON ai)
  checkClientData CerGet (aiExpectedChallenge ai) (aiExpectedOrigin ai) cd
  ad <- parseAuthenticatorData (aiAuthenticatorData ai)
  checkHeader (aiExpectedRpId ai) ad
  newCount <- checkSignCount (aiStoredSignCount ai) (adSignCount ad)
  (r, s) <- either
    (Left . WnMalformedAuthenticatorData . ("signature: " <>))
    Right
    (decodeEcdsaSignature (aiSignature ai))
  pub <- cosePublicKeyToPoint key
  let message = aiAuthenticatorData ai <> sha256 (aiClientDataJSON ai)
  if verify SHA256 pub (Signature r s) message
    then Right newCount
    else Left WnSignatureInvalid

-- | The WebAuthn sign-counter rule, stated exactly:
--
-- * a stored counter of 0 and a reported counter of 0 means the authenticator
--   does not implement one — accept (the spec allows this for platform
--   authenticators);
-- * a reported counter of 0 when we stored a non-zero one is a regression;
-- * otherwise the reported counter must be strictly greater.
checkSignCount :: Int -> Int -> Either WebAuthnError Int
checkSignCount stored new
  | stored == 0 && new == 0 = Right 0
  | new <= stored           = Left (WnSignCountRegression stored new)
  | otherwise               = Right new

-- ---------------------------------------------------------------------------
-- Byte helpers
-- ---------------------------------------------------------------------------

sha256 :: ByteString -> ByteString
sha256 bs = convert (hash bs :: Digest SHA256)

be16 :: ByteString -> Int
be16 = fromIntegral . beInteger

be32 :: ByteString -> Int
be32 = fromIntegral . beInteger

beInteger :: ByteString -> Integer
beInteger = BS.foldl' (\acc w -> acc `shiftL` 8 + fromIntegral w) 0

decodeB64Url :: Text -> Either Text ByteString
decodeB64Url = either (Left . T.pack) Right . B64Url.decodeUnpadded . TE.encodeUtf8

stripPadding :: Text -> Text
stripPadding = T.dropWhileEnd (== '=')

tshow :: Show a => a -> Text
tshow = T.pack . show
