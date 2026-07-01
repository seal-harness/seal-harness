{-# LANGUAGE OverloadedStrings #-}
-- | Anthropic OAuth (PKCE, S256) for the Claude subscription flow. Pure PKCE
-- math + authorize-URL construction + pasted-code parsing here; the HTTP code
-- exchange, refresh, and the vault-blob codec are added alongside. This module
-- is imported by 'Seal.Providers.Anthropic'; it must not depend on it.
module Seal.Providers.Anthropic.OAuth
  ( Pkce (..)
  , OAuthTokens (..)
    -- * Endpoint constants
  , oauthClientId
  , oauthAuthorizeUrl
  , oauthTokenUrl
  , oauthRedirectUri
  , oauthScope
  , anthropicVersion
  , anthropicBeta
    -- * PKCE + authorize URL
  , codeChallenge
  , buildAuthorizeUrl
  , parsePastedCode
  , newPkce
    -- * Token-response parser + vault-blob codec
  , parseTokenResponse
  , serializeTokens
  , deserializeTokens
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, eitherDecodeStrict', object, withObject, (.:), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Types (parseEither)
import Data.ByteArray.Encoding (Base (Base16, Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Network.HTTP.Types.URI (renderSimpleQuery)

import Seal.Security.Crypto (getRandomBytes)
import Seal.Security.Secrets
  (BearerToken, RefreshToken, mkBearerToken, mkRefreshToken, withBearerToken, withRefreshToken)

-- | A PKCE verifier/challenge pair. In this flow @state@ == the verifier.
data Pkce = Pkce
  { pkceVerifier :: Text
  , pkceChallenge :: Text
  } deriving stock (Eq, Show)

-- | OAuth credentials. Secrets stay opaque; there is deliberately NO 'Show' or
-- 'ToJSON' instance. The only serialization path is 'serializeTokens' (added
-- with the codec), which writes into the encrypted vault.
data OAuthTokens = OAuthTokens
  { otAccess :: BearerToken
  , otRefresh :: RefreshToken
  , otExpiresAt :: UTCTime
  }

-- Endpoint constants -------------------------------------------------------

oauthClientId :: Text
oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

oauthAuthorizeUrl :: Text
oauthAuthorizeUrl = "https://claude.ai/oauth/authorize"

oauthTokenUrl :: Text
oauthTokenUrl = "https://console.anthropic.com/v1/oauth/token"

oauthRedirectUri :: Text
oauthRedirectUri = "https://console.anthropic.com/oauth/code/callback"

oauthScope :: Text
oauthScope = "org:create_api_key user:profile user:inference"

anthropicVersion :: Text
anthropicVersion = "2023-06-01"

anthropicBeta :: Text
anthropicBeta = "oauth-2025-04-20"

-- PKCE ---------------------------------------------------------------------

-- | @base64url-nopad(SHA-256(bytes))@. The argument is the ASCII bytes of the
-- verifier string.
--
-- Note: crypton 1.x stores 'Digest' in GHC's native @ByteArray#@, which is
-- not an instance of @memory@'s 'ByteArrayAccess'. We extract the raw digest
-- bytes by decoding the lowercase-hex 'Show' instance, mirroring the approach
-- used in "Seal.Security.Crypto".
codeChallenge :: ByteString -> Text
codeChallenge bs =
  TE.decodeUtf8 (convertToBase Base64URLUnpadded (sha256Raw bs))
  where
    sha256Raw :: ByteString -> ByteString
    sha256Raw b =
      let hexBs = TE.encodeUtf8 $ T.pack $ show (hash b :: Digest SHA256)
      in case convertFromBase Base16 hexBs :: Either String ByteString of
           Right raw -> raw
           Left e -> error ("sha256Raw: impossible hex decode: " <> e)

-- | Build the authorize URL. Query params are emitted in the required order and
-- percent-encoded by 'renderSimpleQuery' (space -> %20, ':' -> %3A, etc.).
buildAuthorizeUrl :: Pkce -> Text
buildAuthorizeUrl pkce =
  oauthAuthorizeUrl <> TE.decodeUtf8 (renderSimpleQuery True params)
  where
    params =
      [ ("response_type",        "code")
      , ("client_id",            TE.encodeUtf8 oauthClientId)
      , ("redirect_uri",         TE.encodeUtf8 oauthRedirectUri)
      , ("scope",                TE.encodeUtf8 oauthScope)
      , ("state",                TE.encodeUtf8 (pkceVerifier pkce))
      , ("code_challenge",       TE.encodeUtf8 (pkceChallenge pkce))
      , ("code_challenge_method","S256")
      ]

-- | Split the pasted @CODE#STATE@ on the FIRST '#'. With no '#', the whole
-- string is the code and the state is empty.
parsePastedCode :: Text -> (Text, Text)
parsePastedCode t =
  let (code, rest) = T.breakOn "#" t
  in (code, T.drop 1 rest)

-- | Fresh PKCE pair: 32 random bytes -> base64url-nopad verifier (43 chars);
-- challenge = 'codeChallenge' of the verifier's ASCII bytes.
newPkce :: IO Pkce
newPkce = do
  raw <- getRandomBytes 32
  let verifier = TE.decodeUtf8 (convertToBase Base64URLUnpadded raw)
  pure (Pkce verifier (codeChallenge (TE.encodeUtf8 verifier)))

-- Token-response parser + vault-blob codec ------------------------------------

-- | Parse the token endpoint's JSON response. @now@ is the reference time used
-- to turn the relative @expires_in@ (seconds) into an absolute expiry.
-- @token_type@ and @scope@ are ignored.
parseTokenResponse :: UTCTime -> Value -> Either Text OAuthTokens
parseTokenResponse now = mapLeft T.pack . parseEither parse
  where
    mapLeft f = either (Left . f) Right
    parse = withObject "token response" $ \o -> do
      acc     <- o .: "access_token"
      ref     <- o .: "refresh_token"
      expires <- o .: "expires_in"
      pure OAuthTokens
        { otAccess    = mkBearerToken (TE.encodeUtf8 acc)
        , otRefresh   = mkRefreshToken (TE.encodeUtf8 ref)
        , otExpiresAt = addUTCTime (fromIntegral (expires :: Int)) now
        }

-- | Encode tokens as the vault blob. This is the ONLY place token bytes are
-- serialized; the target is the encrypted vault.
serializeTokens :: OAuthTokens -> ByteString
serializeTokens ts =
  withBearerToken (otAccess ts) $ \acc ->
    withRefreshToken (otRefresh ts) $ \ref ->
      BL.toStrict $ A.encode $ object
        [ "access_token"  .= TE.decodeUtf8 acc
        , "refresh_token" .= TE.decodeUtf8 ref
        , "expires_at"    .= (round (utcTimeToPOSIXSeconds (otExpiresAt ts)) :: Int)
        ]

-- | Decode the vault blob back into tokens.
deserializeTokens :: ByteString -> Either Text OAuthTokens
deserializeTokens bs =
  case eitherDecodeStrict' bs of
    Left e  -> Left (T.pack e)
    Right v -> mapLeft T.pack (parseEither parse v)
  where
    mapLeft f = either (Left . f) Right
    parse = withObject "oauth tokens blob" $ \o -> do
      acc  <- o .: "access_token"
      ref  <- o .: "refresh_token"
      exp' <- o .: "expires_at"
      pure OAuthTokens
        { otAccess    = mkBearerToken (TE.encodeUtf8 acc)
        , otRefresh   = mkRefreshToken (TE.encodeUtf8 ref)
        , otExpiresAt = posixSecondsToUTCTime (fromIntegral (exp' :: Int))
        }
