{-# LANGUAGE OverloadedStrings #-}
-- | The pure pieces of access-control configuration: coordinates, credential
-- (de)serialisation, and how many credentials can actually authenticate here.
--
-- The origin and rpId are resolved **once, at boot**, never from a request
-- header: a request-derived origin would make the WebAuthn origin check
-- vacuous, because whoever can rebind a hostname to the port controls both
-- sides of the comparison (design §3).
--
-- Deciding whether the gateway may start, and in which mode, lives in
-- "Seal.Config.BootPlan" — one function for the whole §10 table, so there is no
-- second copy of "what does an absent mode mean" to drift from it.
module Seal.Security.AccessControl
  ( resolveCoordinates
  , canonicalOriginFor
  , isLoopbackHost
  , isWildcardHost
  , credentialFromFile
  , credentialToFile
  , parseIsoTime
  , formatIsoTime
  , CredentialAvailability (..)
  , credentialAvailability
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64Url
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Char (isDigit)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)

import Seal.Config.Security
  ( AccessControlFileConfig (..), CredentialFileConfig (..) )
import Seal.Security.WebAuthn (normalizeOrigin)
import Seal.Security.WebAuthn.Types
  ( AccessMode (..), CosePublicKey (..), Credential (..) )

-- | Resolve @origin@ and @rp_id@ for an already-decided mode.
--
-- Split out of 'resolveAccessControl' so the boot plan can resolve the pair
-- without also deciding the mode and decoding credentials: those two now live
-- in 'Seal.Config.BootPlan.bootPlan', and having a second copy here is how the
-- two would drift apart.
resolveCoordinates
  :: Text                       -- ^ bind host
  -> Int                        -- ^ bind port
  -> Maybe AccessControlFileConfig
  -> AccessMode
  -> Either Text (Maybe Text, Maybe Text)
resolveCoordinates bindHost bindPort mSection mode = do
  origin <- resolveOrigin bindHost bindPort (isWildcardHost bindHost)
                          (mSection >>= acfcOrigin) mode
  rpId <- resolveRpId origin (mSection >>= acfcRpId)
  pure (origin, rpId)

resolveOrigin
  :: Text -> Int -> Bool -> Maybe Text -> AccessMode -> Either Text (Maybe Text)
resolveOrigin bindHost bindPort wildcard mOrigin mode = case mOrigin of
  Just raw -> case normalizeOrigin raw of
    Just o  -> Right (Just o)
    Nothing -> Left ("[access_control] origin \"" <> raw
                      <> "\" is not an absolute URL of the form scheme://host[:port]")
  Nothing
    | wildcard && mode == AccessOpen -> Right Nothing
    | wildcard ->
        Left "[access_control] origin must be set when the gateway binds a wildcard \
             \address and access control is not \"none\""
    | otherwise -> Right (Just (canonicalOriginFor bindHost bindPort))

-- | @http:\/\/localhost:\<port\>@ for a loopback bind, @http:\/\/\<host\>:\<port\>@
-- otherwise.
--
-- Loopback canonicalises to the literal @localhost@ because that is the name
-- every browser treats as a secure context, it is the value the gateway's
-- default origin already uses, and it makes the banner URL and the verified
-- origin the same string. @127.0.0.1@ is deliberately not used: rpIds match by
-- domain suffix, so mixing the two spellings yields credentials that silently
-- fail depending on which URL the operator typed.
canonicalOriginFor :: Text -> Int -> Text
canonicalOriginFor bindHost bindPort
  | isLoopbackHost bindHost = "http://localhost:" <> tshow bindPort
  | otherwise               = "http://" <> T.toLower bindHost <> ":" <> tshow bindPort

resolveRpId :: Maybe Text -> Maybe Text -> Either Text (Maybe Text)
resolveRpId mOrigin mRpId = case (mOrigin, mRpId) of
  (Nothing, Nothing) -> Right Nothing
  (Just o, Nothing)  -> Right (hostOf o)
  (Nothing, Just _)  ->
    Left "[access_control] rp_id is set but no origin could be resolved"
  (Just o, Just raw) ->
    case hostOf o of
      Nothing -> Left "[access_control] origin has no host"
      Just host
        | raw == host
            || ("." <> host) `T.isSuffixOf` raw
            || ("." <> raw) `T.isSuffixOf` host
          -> Right (Just raw)
        | otherwise ->
            Left ("[access_control] rp_id \"" <> raw <> "\" is not a suffix of the "
                  <> "origin host \"" <> host <> "\"")
  where
    -- 'o' is already normalised to scheme://host[:port]
    hostOf o = case T.breakOn "://" o of
      (_, rest) | T.null rest -> Nothing
      (_, rest) ->
        let authority = T.takeWhile (/= '/') (T.drop 3 rest)
        in Just (T.toLower (fst (splitHostPort' authority)))

splitHostPort' :: Text -> (Text, Maybe Text)
splitHostPort' authority =
  case T.breakOnEnd ":" authority of
    (withColon, port)
      | T.null withColon -> (authority, Nothing)
      | T.any (== ':') (T.dropEnd 1 withColon) -> (authority, Nothing)
      | T.null port -> (authority, Nothing)
      | T.all isDigit port -> (T.dropEnd 1 withColon, Just port)
      | otherwise -> (authority, Nothing)

-- ---------------------------------------------------------------------------
-- Credential availability
-- ---------------------------------------------------------------------------

-- | What the enrolled credentials can actually do on /this/ boot.
--
-- Three values, not a boolean, because the three states call for three
-- different responses and conflating them is the bug this type removes:
-- "some credential differs" never clears, so it mints a grant on every boot
-- and never stops.
data CredentialAvailability
  = NoCredentials
    -- ^ Nothing enrolled: the bootstrap state. A CLI-minted grant is the only
    -- authority (design §5 invariant 3).
  | UnusableOnly
    -- ^ Credentials exist, but none was created for this rpId — the operator
    -- changed @origin@/@rp_id@, or the gateway is reached under a different
    -- name. This is @rp_mismatch@. A CLI-minted grant is the only authority:
    -- deliberately not the loopback window, since this is the state an
    -- attacker who can change @origin@/@rp_id@ would aim to create (§7.2).
  | Usable
    -- ^ At least one credential can authenticate here.
  deriving stock (Eq, Show)

-- | Classify a credential map against the boot-resolved rpId.
--
-- A 'Nothing' rpId means no origin could be resolved (a wildcard bind with no
-- explicit @origin@), so there is no name to call a credential unusable — every
-- credential counts as usable, which is also what the last-usable-credential
-- deletion guard relies on (design §9.4).
credentialAvailability :: Maybe Text -> Map Text Credential -> CredentialAvailability
credentialAvailability _        creds | Map.null creds = NoCredentials
credentialAvailability Nothing  _                      = Usable
credentialAvailability (Just rp) creds
  | any ((== rp) . credRpId) (Map.elems creds) = Usable
  | otherwise                                  = UnusableOnly

-- ---------------------------------------------------------------------------
-- Credential (de)serialisation
-- ---------------------------------------------------------------------------

-- | Decode one @[access_control.credentials.\<id\>]@ table. The map key is the
-- base64url credential id.
credentialFromFile :: (Text, CredentialFileConfig) -> Either Text (Text, Credential)
credentialFromFile (rawId, cfc) = do
  rawIdBytes <- case B64Url.decodeUnpadded (TE.encodeUtf8 rawId) of
    Left e  -> Left (bad <> "the credential id is not base64url (" <> T.pack e <> ")")
    Right b
      | BS.null b || BS.length b > 1023 -> Left (bad <> "the credential id length is out of range")
      | otherwise -> Right b
  key <- case B64Url.decodeUnpadded (TE.encodeUtf8 (cfcPublicKey cfc)) of
    Left e -> Left (bad <> "public_key is not base64url (" <> T.pack e <> ")")
    Right b
      | BS.length b == 64 -> Right (CosePublicKey b)
      | otherwise -> Left (bad <> "public_key must be 64 bytes (x || y)")
  createdAt <- case parseIsoTime (cfcCreatedAt cfc) of
    Nothing -> Left (bad <> "created_at is not an ISO-8601 timestamp")
    Just t  -> Right t
  signCount <- if cfcSignCount cfc < 0
                 then Left (bad <> "sign_count is negative")
                 else Right (cfcSignCount cfc)
  pure (rawId, Credential
    { credId = rawIdBytes
    , credPublicKey = key
    , credSignCount = signCount
    , credLabel = cfcLabel cfc
    , credCreatedAt = createdAt
    , credRpId = cfcRpId cfc
    })
  where
    bad = "credential \"" <> rawId <> "\": "

-- | The inverse, for the writer.
credentialToFile :: Credential -> CredentialFileConfig
credentialToFile cred = CredentialFileConfig
  { cfcPublicKey = TE.decodeUtf8 (B64Url.encodeUnpadded (unCose (credPublicKey cred)))
  , cfcSignCount = credSignCount cred
  , cfcLabel     = credLabel cred
  , cfcCreatedAt = formatIsoTime (credCreatedAt cred)
  , cfcRpId      = credRpId cred
  , cfcAddedVia  = Nothing
  }
  where
    unCose (CosePublicKey b) = b

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

isLoopbackHost :: Text -> Bool
isLoopbackHost h = T.toLower h `elem` ["127.0.0.1", "::1", "localhost"]

isWildcardHost :: Text -> Bool
isWildcardHost h = h `elem` ["0.0.0.0", "::", "*"]

parseIsoTime :: Text -> Maybe UTCTime
parseIsoTime t =
  parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t)
    `orElse` parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack t)

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just a) _ = Just a
orElse Nothing  b = b

formatIsoTime :: UTCTime -> Text
formatIsoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

tshow :: Show a => a -> Text
tshow = T.pack . show
