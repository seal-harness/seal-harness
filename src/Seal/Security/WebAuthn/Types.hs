{-# LANGUAGE OverloadedStrings #-}
-- | Leaf types shared by the access-control config, the WebAuthn verifier and
-- the gateway. This module deliberately depends on neither
-- 'Seal.Config.Security' nor 'Seal.Gateway.*', so it can sit at the bottom of
-- the import graph (design §5: no cycle).
module Seal.Security.WebAuthn.Types
  ( AccessMode (..)
  , accessModeText
  , parseAccessMode
  , CosePublicKey (..)
  , Credential (..)
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)

-- | The operator's access-control decision, as recorded in
-- @~\/.seal\/security.toml@.
--
-- 'AccessUnconfigured' is also the state of a @mode = \"passkey\"@ file whose
-- credential list is empty — nobody could authenticate, so the gateway must be
-- treatable as still awaiting setup. 'Seal.Config.Security' normalises that
-- case.
data AccessMode
  = AccessUnconfigured
  | AccessOpen
  | AccessPasskey
  deriving stock (Eq, Show)

-- | The wire spelling of an 'AccessMode', as reported by
-- @\/api\/auth\/status@ and consumed by the SPA.
--
-- This is deliberately NOT the config spelling: the config says @none@ (the
-- operator's waiver), while the reported state says @open@ (what the gateway is
-- actually doing). Keeping them distinct means "access control is off" can be
-- stated in the API without the UI having to know that @none@ means open.
accessModeText :: AccessMode -> Text
accessModeText mode = case mode of
  AccessUnconfigured -> "unconfigured"
  AccessOpen         -> "open"
  AccessPasskey      -> "passkey"

-- | Parse the config spelling. Anything other than @\"none\"@ or
-- @\"passkey\"@ is rejected — fail-closed, so a typo can never silently mean
-- "open".
parseAccessMode :: Text -> Either Text AccessMode
parseAccessMode t = case T.strip (T.toLower t) of
  "none"    -> Right AccessOpen
  "passkey" -> Right AccessPasskey
  other     -> Left ("invalid access_control.mode \"" <> other
                      <> "\" (expected \"passkey\" or \"none\")")

-- | A P-256 public key as the 64-byte uncompressed @x || y@ pair taken from a
-- COSE EC2 key. A newtype so callers cannot mistake it for the SEC1
-- @0x04@-prefixed or DER forms.
newtype CosePublicKey = CosePublicKey ByteString
  deriving stock (Eq, Show)

-- | One enrolled passkey.
data Credential = Credential
  { credId        :: ByteString
    -- ^ The raw WebAuthn credential id.
  , credPublicKey :: CosePublicKey
  , credSignCount :: Int
    -- ^ The last sign counter accepted. 0 means the authenticator does not
    -- implement one.
  , credLabel     :: Text
  , credCreatedAt :: UTCTime
  , credRpId      :: Text
    -- ^ The rpId this credential was created for. A credential only validates
    -- against its own rpId, so this is compared with the boot-resolved rpId to
    -- detect an orphaned credential.
  } deriving stock (Eq, Show)
