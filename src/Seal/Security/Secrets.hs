-- | Opaque secret values. Constructors are intentionally NOT exported, there
-- are no JSON/serialization instances, and 'Show' is redacted. The only way
-- to observe the payload is the CPS accessor, which scopes the secret to a
-- single continuation so it cannot leak into a longer-lived binding.
module Seal.Security.Secrets
  ( ApiKey, BearerToken, PairingCode, RefreshToken, SecretKey
  , mkApiKey, mkBearerToken, mkPairingCode, mkRefreshToken, mkSecretKey
  , withApiKey, withBearerToken, withPairingCode, withRefreshToken, withSecretKey
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

newtype ApiKey      = ApiKey      ByteString
newtype BearerToken = BearerToken ByteString
newtype RefreshToken = RefreshToken ByteString
newtype SecretKey   = SecretKey   ByteString
newtype PairingCode = PairingCode Text

instance Show ApiKey      where show _ = "ApiKey <redacted>"
instance Show BearerToken where show _ = "BearerToken <redacted>"
instance Show RefreshToken where show _ = "RefreshToken <redacted>"
instance Show SecretKey   where show _ = "SecretKey <redacted>"
instance Show PairingCode where show _ = "PairingCode <redacted>"

mkApiKey :: ByteString -> ApiKey
mkApiKey = ApiKey

mkBearerToken :: ByteString -> BearerToken
mkBearerToken = BearerToken

mkRefreshToken :: ByteString -> RefreshToken
mkRefreshToken = RefreshToken

mkSecretKey :: ByteString -> SecretKey
mkSecretKey = SecretKey

mkPairingCode :: Text -> PairingCode
mkPairingCode = PairingCode

withApiKey :: ApiKey -> (ByteString -> r) -> r
withApiKey (ApiKey b) f = f b

withBearerToken :: BearerToken -> (ByteString -> r) -> r
withBearerToken (BearerToken b) f = f b

withRefreshToken :: RefreshToken -> (ByteString -> r) -> r
withRefreshToken (RefreshToken b) f = f b

withSecretKey :: SecretKey -> (ByteString -> r) -> r
withSecretKey (SecretKey b) f = f b

withPairingCode :: PairingCode -> (Text -> r) -> r
withPairingCode (PairingCode t) f = f t
