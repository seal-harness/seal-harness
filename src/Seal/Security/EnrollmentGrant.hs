{-# LANGUAGE OverloadedStrings #-}
-- | Enrollment grants: the authority a client presents to add a credential.
--
-- This module currently holds the shared vocabulary only. The grant record,
-- its file codec and the claim protocol land with the grant machinery; the
-- type lives here from the start because both the credential store's
-- @added_via@ and the boot plan's "should I mint a grant, and how" have to name
-- the same set of sources. Two copies of that enum would drift.
--
-- Why this is not in "Seal.Security.AccessControl": @Grant@'s phases name
-- challenge ids, which are gateway-local. Keeping the grant types out of the
-- credential-availability code is what lets the latter stay a pure function of
-- a credential map (design §7.1).
module Seal.Security.EnrollmentGrant
  ( GrantSource (..)
  , grantSourceText
  , parseGrantSource
  , GrantPhase (..)
  , GrantId (..)
  , ChallengeId (..)
  , Grant (..)
  , EnrollmentAuthority
  , GrantDenied (..)
  , GrantContext (..)
  , enrollmentAuthority
  , findAuthority
  , grantToJson
  , grantFromJson
  , grantBody
  , grantBodyText
  , MintedGrant (..)
  , enrollGrant
  , cancelGrant
  , parseTtl
  , defaultTtlFor
  , GrantClaim (..)
  , claimExclusively
  , claimLiveAt
  , effectiveDeadline
  , grantRedeems
  , loadClaimFile
  , releaseClaim
  , grantLiveAt
  , loadGrantFile
  , saveGrantFile
  , deleteGrantFile
  , tokenDigest
  ) where

import Data.Aeson (Value, eitherDecode, encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Char (isDigit)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Control.Exception (IOException, try)
import Control.Monad (forM_, when)
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory
  , removeFile, renameFile )
import System.FilePath ((</>), takeBaseName, takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (setFileMode)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive), OpenMode (WriteOnly), defaultFileFlags
  , fdToHandle, openFd )

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Base64.URL qualified as B64Url

import Seal.Security.Crypto (constantTimeEq, generateToken, sha256Hash)
import Seal.Config.Paths
  ( SealPaths (..), enrollmentGrantPath, enrollmentTokenPath )
import Seal.Security.AccessControl (CredentialAvailability (..))
import Seal.Security.WebAuthn.Types (AccessMode (..))

-- | How a grant was minted — and, for an enrolled credential, how it was added
-- (@added_via@ plus @legacy@, which no grant can produce).
--
-- The distinction is load-bearing, not descriptive: a 'CliWindow' grant is
-- authority with no secret at all, so it exists only in the bootstrap state
-- (nothing enrolled, loopback bind, loopback origin). Any other combination is
-- a refusal, which is why the type flows into both the boot plan and the
-- resolver rather than being flattened to a boolean.
data GrantSource
  = CliToken
    -- ^ Minted by @seal access-control enroll@ or by boot; presented as a
    -- request header.
  | CliWindow
    -- ^ @enroll --no-token@: loopback-confined, bootstrap-only, no secret
    -- presented.
  | Assertion
    -- ^ Minted by a successful assertion from an already-enrolled credential;
    -- the authority for adding a second passkey.
  deriving stock (Eq, Show)

-- | The wire/TOML spelling (@minted_via@, @added_via@).
grantSourceText :: GrantSource -> Text
grantSourceText source = case source of
  CliToken  -> "cli_token"
  CliWindow -> "cli_window"
  Assertion -> "assertion"

-- | Parse the stored spelling. 'Nothing' for anything unrecognised — callers
-- decide whether that is a refusal (grants) or a fallback to @legacy@
-- (credentials, where claiming nothing about the enrolling authority is safe).
parseGrantSource :: Text -> Maybe GrantSource
parseGrantSource raw = case raw of
  "cli_token"  -> Just CliToken
  "cli_window" -> Just CliWindow
  "assertion"  -> Just Assertion
  _            -> Nothing

-- | Where a grant is in its lifecycle (design §7.3).
--
-- @Minted@ may be bound to exactly one challenge; @GrantBound@ records which,
-- so a grant bound to challenge A cannot redeem B.
data GrantPhase
  = GrantMinted
  | GrantBound !ChallengeId
  deriving stock (Eq, Show)

newtype GrantId = GrantId Text
  deriving stock (Eq, Show)

-- | The challenge text (the map key the gateway issues under), so the phase
-- compares directly with what a verify request presents.
newtype ChallengeId = ChallengeId Text
  deriving stock (Eq, Show)

-- | An outstanding enrollment grant.
--
-- @grTokenSha@ is the SHA-256 of the token the client will present — never the
-- token itself, so a copy of the state directory does not hand over enrollment
-- authority. It is 'Nothing' only for 'CliWindow', which presents no secret at
-- all and is confined to a loopback-bound, credential-free bootstrap.
data Grant = Grant
  { grId        :: !GrantId
  , grExpiresAt :: !UTCTime
  , grSource    :: !GrantSource
  , grPhase     :: !GrantPhase
  , grTokenSha  :: !(Maybe ByteString)
  } deriving stock (Eq, Show)

-- | One ceremony's exclusive hold on a grant (design §7.3).
--
-- Created @O_CREAT|O_EXCL@ when @options@ binds, so the /create/ result decides
-- which of two racing verifies wins — a prior read cannot, because two readers
-- can both see "no claim" before either writes.
--
-- @clDeadline@ is 'effectiveDeadline': the claim may never outlive the grant it
-- belongs to.
data GrantClaim = GrantClaim
  { clGrantId     :: !GrantId
  , clChallengeId :: !ChallengeId
  , clDeadline    :: !UTCTime
  } deriving stock (Eq, Show)

-- | The authority a request proved it holds. Same vocabulary as
-- 'GrantSource' by design: the resolver decides /whether/ a source is
-- acceptable for this boot, not a second enum.
type EnrollmentAuthority = GrantSource

-- | Why enrollment authority was refused. The constructors select the HTTP
-- status, the wire code and the UI branch, which is why this is an ADT and not
-- @Either Text@.
data GrantDenied
  = GrantRequired
    -- ^ No authority was presented and none may be inherited.
  | StepUpRequired
    -- ^ A session exists but presented no token: prove the device, then retry.
  | GrantInvalid
    -- ^ A token was presented and does not match a live grant.
  deriving stock (Eq, Show)

-- | Resolve the authority a request holds (design §7.2).
--
-- Order: a presented token is matched against the file grant's digest, then the
-- session grant's digest — the latter only if the requesting session is the one
-- the grant was minted for.
--
-- __The load-bearing rule__ (gate round 4, B-1): /authority is presented, not
-- inherited/. An absent token is acceptable only for 'CliWindow', which by
-- construction carries no secret. Rev 4 let 'Nothing' fall through to a
-- session-held grant, so a stolen cookie could redeem the victim's live
-- assertion grant merely by omitting the header. There is now no path from a
-- cookie alone to enrollment authority.
--
-- This is a pure read: a mismatch never rebinds, consumes or extends anything,
-- so a stale token cannot shadow a live grant and cannot be used to probe the
-- grant's state.
findAuthority
  :: Maybe Text        -- ^ presented token (@X-Seal-Enroll-Token@)
  -> Maybe Grant       -- ^ the file-backed grant
  -> Maybe Grant       -- ^ the grant carried by the requesting session
  -> Bool              -- ^ does the requesting session match that session grant?
  -> Either GrantDenied Grant
findAuthority presented fileGrant sessionGrant sessionMatches =
  case presented of
    -- A token was presented, so it must resolve. Nothing is inherited.
    Just raw ->
      case matchesToken raw fileGrant of
        Just grant -> Right grant
        -- The same token is tried against the session grant, and only when the
        -- requesting session is the one it was minted for. A token that matches
        -- neither is GrantInvalid: it must not inherit the session grant, which
        -- would make a wrong token as good as an absent one.
        Nothing -> case matchesToken raw (if sessionMatches then sessionGrant else Nothing) of
          Just grant -> Right grant
          Nothing    -> Left GrantInvalid
    Nothing -> case fileGrant of
      Just grant@Grant { grSource = CliWindow } -> Right grant
      _ -> Left (if sessionMatches && isJust sessionGrant
                   then StepUpRequired
                   else GrantRequired)
  where
    matchesToken raw mGrant = mGrant >>= \grant ->
      case grTokenSha grant of
        Just digest | not (BS.null digest)
                    , constantTimeEq digest (tokenDigest raw) -> Just grant
        _ -> Nothing

-- | SHA-256 of a token, as stored. The token itself is never persisted.
tokenDigest :: Text -> ByteString
tokenDigest = sha256Hash . TE.encodeUtf8

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------

grantToJson :: Grant -> Value
grantToJson grant = object
  [ "grant_id" .= grantIdText (grId grant)
  , "minted_via" .= grantSourceText (grSource grant)
  , "expires_at" .= isoTime (grExpiresAt grant)
  , "bound_challenge" .= boundChallenge
  , "token_sha256" .= fmap base64Text (grTokenSha grant)
  ]
  where
    boundChallenge = case grPhase grant of
      GrantBound cid -> Just (challengeIdText cid)
      GrantMinted    -> Nothing

-- | Decode a stored grant.
--
-- Deliberately total in the permissive direction: an unreadable field is
-- treated as /absent/, never as a boot refusal. Absent is never more
-- permissive than present (design §7.3) — the caller deletes a grant it cannot
-- read, and a missing grant is just "no authority".
grantFromJson :: Value -> Maybe Grant
grantFromJson = parseMaybe parseGrant

parseGrant :: Value -> Parser Grant
parseGrant = withObject "Grant" $ \o -> do
  ident@(GrantId rawId) <- GrantId <$> o .: "grant_id"
  -- The id names the claim file, so a separator in it would move the file.
  -- Grant ids are minted as hex, so this only rejects a hand-edited or
  -- corrupted document.
  when (any (`elem` ("/\\" :: String)) (T.unpack rawId)
          || ".." `T.isInfixOf` rawId)
    (fail "grant_id must not contain a path separator")
  source <- o .: "minted_via" >>= requireSource
  expires <- o .: "expires_at" >>= requireTime
  phase <- maybe GrantMinted (GrantBound . ChallengeId) <$> o .:? "bound_challenge"
  digest <- (o .:? "token_sha256") >>= traverse requireDigest
  -- CliWindow carries no secret; every other source must.
  case (source, digest) of
    (CliWindow, _)     -> pure (Grant ident expires source phase Nothing)
    (_, Just d)        -> pure (Grant ident expires source phase (Just d))
    (_, Nothing)       -> fail "a token-backed grant must carry token_sha256"
  where
    requireSource raw = case parseGrantSource raw of
      Just source -> pure source
      Nothing     -> fail ("unknown minted_via: " <> T.unpack raw)
    requireTime raw = case parseIsoTimeMaybe raw of
      Just t  -> pure t
      Nothing -> fail ("unparseable expires_at: " <> T.unpack raw)
    -- The digest is stored base64url, because JSON has no byte string.
    requireDigest raw = case B64Url.decodeUnpadded (TE.encodeUtf8 raw) of
      Left e   -> fail ("token_sha256 is not base64url: " <> e)
      Right bs -> pure bs

-- | The grant as one line of JSON, for the state file.
grantBody :: Grant -> LBS.ByteString
grantBody = encode . grantToJson

grantBodyText :: Grant -> Text
grantBodyText = TE.decodeUtf8 . LBS.toStrict . grantBody

--------------------------------------------------------------------------------
-- Rendering helpers
--------------------------------------------------------------------------------

grantIdText :: GrantId -> Text
grantIdText (GrantId raw) = raw

challengeIdText :: ChallengeId -> Text
challengeIdText (ChallengeId raw) = raw

base64Text :: ByteString -> Text
base64Text = TE.decodeUtf8 . B64Url.encodeUnpadded

isoTime :: UTCTime -> Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

parseIsoTimeMaybe :: Text -> Maybe UTCTime
parseIsoTimeMaybe raw =
  parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack raw)

--------------------------------------------------------------------------------
-- Which authorities this boot accepts
--------------------------------------------------------------------------------

-- | Everything the enrollment decision depends on.
--
-- There is no clock here on purpose. A grant's expiry is decided when it is
-- read ('findAuthority' returns a grant that is already known live, and the
-- claim protocol re-checks the deadline), so this function cannot decide it and
-- a @gcNow@ field would suggest otherwise. Design §7.2 lists one; it is
-- deliberately omitted rather than carried unused.
data GrantContext = GrantContext
  { gcMode         :: !AccessMode
  , gcAvailability :: !CredentialAvailability
  , gcAuthorized   :: !(Maybe EnrollmentAuthority)
    -- ^ What 'findAuthority' resolved. 'Nothing' means no authority was
    -- presented, which is a state this function must still answer for: the
    -- status endpoint asks it without a request.
  , gcHasSession   :: !Bool
  } deriving stock (Eq, Show)

-- | Which authorities are acceptable in this boot state.
--
-- Total over 3 modes x 3 availabilities x 4 authorities. Two rules do most of
-- the work:
--
-- * __The loopback window exists only with nothing enrolled.__ It is authority
--   that presents no secret, so allowing it once a credential exists — or in
--   @UnusableOnly@, which is the state an attacker who can change
--   @origin@\\/@rp_id@ aims to create — would hand enrollment to anyone who
--   can reach the port. That is gate round 4's B-2, and the reason
--   @cli_window@ outside @NoCredentials@ is @GrantRequired@ rather than
--   @GrantInvalid@: the token is well-formed, the state no longer permits it.
-- * __Enrolling always needs authority, even in @open@ mode.__ A public gateway
--   that let a network client enroll would be flipped from open to locked with
--   a key the operator does not hold.
enrollmentAuthority :: GrantContext -> Either GrantDenied EnrollmentAuthority
enrollmentAuthority ctx
  -- Bootstrap. Nothing is enrolled, so a token (or the confined window) is the
  -- only thing that can authorize; an assertion cannot exist yet.
  | gcAvailability ctx == NoCredentials = case gcAuthorized ctx of
      Just CliToken  -> Right CliToken
      Just CliWindow -> Right CliWindow
      _              -> Left GrantRequired
  | otherwise = case (gcMode ctx, gcAuthorized ctx) of
      -- Open mode is fully open to *use*, not to enroll.
      (AccessOpen, Just CliToken) -> Right CliToken
      (AccessOpen, _)             -> Left GrantRequired
      -- passkey + UnusableOnly is rp_mismatch: token only, never the window.
      (AccessPasskey, Just CliToken) -> Right CliToken
      (AccessPasskey, _) | gcAvailability ctx == UnusableOnly -> Left GrantRequired
      -- passkey + Usable: an existing credential's assertion can add another,
      -- and a token still works.
      (AccessPasskey, Just Assertion) -> Right Assertion
      -- Only "no authority presented at all" can ask for a step-up. A window
      -- that arrives in the wrong state is well-formed but not permitted, so it
      -- is GrantRequired: telling that client to prove its device would be a
      -- dead end.
      (AccessPasskey, Nothing)
        | gcHasSession ctx -> Left StepUpRequired
        | otherwise        -> Left GrantRequired
      (AccessPasskey, Just _) -> Left GrantRequired
      -- Unconfigured with credentials present is not a state boot produces
      -- (it resolves to passkey or open); answering it keeps the function total
      -- without granting anything.
      (AccessUnconfigured, Just CliToken) -> Right CliToken
      (AccessUnconfigured, _)             -> Left GrantRequired

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

-- | Is the grant still within its lifetime?
--
-- Expiry is an upper bound, never a quota: a grant that has expired is
-- indistinguishable from no grant at all, which is why every reader treats it
-- that way instead of refusing.
grantLiveAt :: UTCTime -> Grant -> Bool
grantLiveAt now grant = now < grExpiresAt grant

-- | Read the outstanding grant.
--
-- Three states collapse to @Nothing@, deliberately:
--
-- * absent — the normal state;
-- * unparseable — treated as absent /and deleted/, because a file the gateway
--   cannot read must never be more permissive than no file (design §7.3);
-- * expired — treated as absent, but left on disk for the reaper. Reaping on a
--   polled read would turn @GET \/status@ into a writer.
--
-- Never cached: the CLI mints grants while the daemon runs, so a cached copy
-- would be invisible until restart.
loadGrantFile :: FilePath -> IO (Maybe Grant)
loadGrantFile path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      raw <- LBS.readFile path
      case eitherDecode raw of
        Right value -> case grantFromJson value of
          Just grant -> pure (Just grant)
          Nothing    -> reap path
        Left _ -> reap path
  where
    reap p = removeFile p >> pure Nothing

-- | Write the grant atomically, mode @0600@.
--
-- A unique temp name and an atomic rename are the only cross-process
-- guarantees available here: the write lock is process-local, and the CLI writes
-- this file while the daemon reads it.
saveGrantFile :: FilePath -> Grant -> IO (Either Text ())
saveGrantFile path grant = do
  let dir = takeDirectory path
  (tmp, h) <- openBinaryTempFile dir (takeBaseName path <> ".tmp")
  LBS.hPut h (grantBody grant)
  hClose h
  setFileMode tmp 0o600
  renameFile tmp path
  pure (Right ())

deleteGrantFile :: FilePath -> IO ()
deleteGrantFile path = do
  exists <- doesFileExist path
  when exists (removeFile path)

--------------------------------------------------------------------------------
-- Claims
--------------------------------------------------------------------------------

-- | The one deadline rule: a claim expires at whichever comes first, the
-- grant's own expiry or the challenge's TTL from now.
--
-- Both bounds are needed. Only the challenge TTL would let a claim outlive a
-- grant with a shorter TTL; only the grant expiry would let a ceremony keep a
-- bound claim alive for the grant's whole lifetime after its prompt was
-- abandoned.
effectiveDeadline :: Grant -> UTCTime -> NominalDiffTime -> UTCTime
effectiveDeadline grant now challengeTtl =
  min (grExpiresAt grant) (addUTCTime challengeTtl now)

-- | Is the claim still within its deadline?
--
-- @now == deadline@ is expired: the deadline is the first instant at which the
-- claim may no longer be used.
claimLiveAt :: UTCTime -> GrantClaim -> Bool
claimLiveAt now claim = now < clDeadline claim

-- | May this grant redeem @challenge@?
--
-- Only a grant that @options@ bound to this exact challenge can. A grant still
-- in 'GrantMinted' means the client skipped @options@, and a grant bound
-- elsewhere is a race or a forgery — both refuse, and neither silently rebinds.
grantRedeems :: ChallengeId -> Grant -> Bool
grantRedeems challenge grant = grPhase grant == GrantBound challenge

-- | Take the exclusive claim for a grant, or lose the race.
--
-- @True@ means this caller holds it. The file is created @O_CREAT|O_EXCL@ and
-- written directly: there is no temp-and-rename here, because the atomicity
-- this needs is over /existence/, not over content. A crash mid-write leaves a
-- claim the reader cannot parse, which is treated as no claim — the next
-- @options@ rebinds.
claimExclusively :: FilePath -> GrantClaim -> IO Bool
claimExclusively path claim = do
  opened <- try (openFd path WriteOnly defaultFileFlags
                   { creat = Just 0o600, exclusive = True })
  case opened of
    Left (_ :: IOException) -> pure False
    Right fd -> do
      h <- fdToHandle fd
      LBS.hPut h (claimBody claim)
      hClose h
      setFileMode path 0o600
      pure True

-- | Give the claim back, but only if it is still /this/ ceremony's claim.
--
-- Compare-and-delete: a failed verify must not delete a claim that a newer
-- @options@ has already replaced, or the retry would find the grant claimed by
-- nobody and the loser of that race would win the next one.
releaseClaim :: FilePath -> ChallengeId -> IO ()
releaseClaim path challenge = do
  held <- loadClaimFile path
  case held of
    Just claim | clChallengeId claim == challenge -> deleteGrantFile path
    _ -> pure ()

-- | Read a claim. Unparseable or absent both mean "nobody holds it".
loadClaimFile :: FilePath -> IO (Maybe GrantClaim)
loadClaimFile path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      raw <- LBS.readFile path
      pure (either (const Nothing) claimFromJson (eitherDecode raw))

claimBody :: GrantClaim -> LBS.ByteString
claimBody claim = encode (object
  [ "grant_id" .= grantIdText (clGrantId claim)
  , "challenge_id" .= challengeIdText (clChallengeId claim)
  , "deadline" .= isoTime (clDeadline claim)
  ])

claimFromJson :: Value -> Maybe GrantClaim
claimFromJson = parseMaybe $ withObject "GrantClaim" $ \o -> do
  ident     <- GrantId <$> o .: "grant_id"
  challenge <- ChallengeId <$> o .: "challenge_id"
  deadline  <- o .: "deadline" >>= requireTime
  pure (GrantClaim ident challenge deadline)
  where
    requireTime raw = case parseIsoTimeMaybe raw of
      Just t  -> pure t
      Nothing -> fail ("unparseable deadline: " <> T.unpack raw)

--------------------------------------------------------------------------------
-- Minting
--------------------------------------------------------------------------------

-- | A grant that was just written to @state/@, plus the plaintext token the
-- client must present.
--
-- The token is the only copy: the file stores its digest. Losing it means
-- @--force@ (or @--cancel@), which is why the command prints it to stdout.
-- 'Nothing' for a 'CliWindow' grant, which presents no secret at all.
data MintedGrant = MintedGrant
  { mgGrant :: !Grant
  , mgToken :: !(Maybe Text)
  } deriving stock (Eq, Show)

-- | The default lifetime of a grant minted from the terminal (design §7.1).
defaultGrantTtl :: GrantSource -> NominalDiffTime
defaultGrantTtl CliWindow = 5 * 60
defaultGrantTtl _         = 10 * 60

-- | Mint a grant, unless one is already outstanding.
--
-- Refusing rather than overwriting is what makes a lost token recoverable: the
-- refusal names the outstanding grant's source and remaining lifetime, and
-- @--force@ is the deliberate way to replace it. Minting also reaps every stale
-- claim marker and the previous token file, because a new grant invalidates all
-- of them.
enrollGrant
  :: SealPaths
  -> GrantSource
  -> NominalDiffTime
  -> Bool              -- ^ force: replace an outstanding grant
  -> IO (Either Text MintedGrant)
enrollGrant paths source ttl force = do
  now <- getCurrentTime
  -- The grant lives in state/, which boot creates; a CLI invocation may be the
  -- first thing to touch it (a fresh SEAL_HOME, or state/ removed by hand).
  createDirectoryIfMissing True (spState paths)
  existing <- loadGrantFile (enrollmentGrantPath paths)
  case existing of
    Just grant | grantLiveAt now grant, not force ->
      pure (Left (outstandingRefusal now grant))
    _ -> do
      token <- case source of
        CliWindow -> pure Nothing
        _         -> Just <$> generateToken 32
      ident <- GrantId <$> generateToken 16
      let grant = Grant
            { grId        = ident
            , grExpiresAt = addUTCTime ttl now
            , grSource    = source
            , grPhase     = GrantMinted
            , grTokenSha  = tokenDigest <$> token
            }
      reapClaims paths
      reapTokenFile paths
      saved <- saveGrantFile (enrollmentGrantPath paths) grant
      pure $ case saved of
        Left err  -> Left err
        Right ()  -> Right (MintedGrant grant token)

-- | Drop every trace of the outstanding grant: the grant file, every claim
-- marker and the plaintext token.
--
-- Idempotent and silent when nothing is outstanding — @--cancel@ with nothing
-- to cancel is a success, not an error.
cancelGrant :: SealPaths -> IO ()
cancelGrant paths = do
  deleteGrantFile (enrollmentGrantPath paths)
  reapClaims paths
  reapTokenFile paths

-- | Delete every claim marker. A new grant (or a cancel) invalidates all of
-- them: they name grants that no longer exist.
reapClaims :: SealPaths -> IO ()
reapClaims paths = do
  -- A fresh SEAL_HOME has no state/ yet; nothing to reap is not an error.
  present <- doesDirectoryExist (spState paths)
  when present $ do
    entries <- listDirectory (spState paths)
    forM_ entries $ \entry -> when (claimPrefix `T.isPrefixOf` T.pack entry) $
      removeFile (spState paths </> entry)
  where
    claimPrefix = "enrollment-grant.claimed-"

reapTokenFile :: SealPaths -> IO ()
reapTokenFile paths = do
  let path = enrollmentTokenPath paths
  exists <- doesFileExist path
  when exists (removeFile path)

-- | How long the grant has left. Negative once expired.
grantRemaining :: UTCTime -> Grant -> NominalDiffTime
grantRemaining now grant = diffUTCTime (grExpiresAt grant) now

outstandingRefusal :: UTCTime -> Grant -> Text
outstandingRefusal now grant =
  "an enrollment grant is already outstanding (minted via "
    <> grantSourceText (grSource grant) <> ", "
    <> tshowSeconds (grantRemaining now grant) <> " left).\n"
    <> "  Use the token you were given, or re-run with --force to replace it,\n"
    <> "  or run `seal access-control enroll --cancel` to drop it."

tshowSeconds :: NominalDiffTime -> Text
tshowSeconds delta =
  T.pack (show (max 0 (ceiling (realToFrac delta :: Double) :: Int))) <> "s"

-- | Parse a @--ttl@ value: @\<N\>\<s|m|h\>@.
--
-- A bare number is a usage error, not a default unit: "10" meaning ten minutes
-- and "10" meaning ten seconds are both plausible, so guessing is how an
-- operator ends up with a window that closed before they used it. The result is
-- clamped to 30 s – 24 h, the range the design allows.
parseTtl :: Text -> Either Text NominalDiffTime
parseTtl raw =
  case T.unsnoc (T.strip raw) of
    Just (digits, unit) | not (T.null digits), T.all isAsciiDigit digits ->
      let multiplier = case unit of
            's' -> 1
            'm' -> 60
            'h' -> 3600
            _   -> 0
      in if multiplier == 0
           then Left (badTtl raw)
           else Right (fromIntegral (max 30 (min 86400 (digitsToSeconds digits * multiplier))))
    _ -> Left (badTtl raw)
  where
    badTtl value =
      "--ttl \"" <> value <> "\" is not a duration.\n"
        <> "  Use a number followed by s, m or h — for example 90s, 10m or 1h."

isAsciiDigit :: Char -> Bool
isAsciiDigit = isDigit

digitsToSeconds :: Text -> Integer
digitsToSeconds = T.foldl' (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0')) 0

-- | The lifetime the command should use when @--ttl@ is absent.
defaultTtlFor :: GrantSource -> NominalDiffTime
defaultTtlFor = defaultGrantTtl
