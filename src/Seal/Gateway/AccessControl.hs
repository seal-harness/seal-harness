{-# LANGUAGE OverloadedStrings #-}
-- | Passkey access control for the HTTP gateway: the runtime handle, the
-- request gate, and the @\/api\/auth\/*@ endpoints.
--
-- The shape is deliberately narrow:
--
-- * 'newAccessControlHandle' resolves the boot configuration once
--   ('Seal.Security.AccessControl.resolveAccessControl') and mints the
--   per-boot tokens;
-- * 'accessControlAuthorize' is the single decision function, used by the HTTP
--   middleware and by the WebSocket handshake, so the two cannot disagree;
-- * 'accessControlMiddleware' is **default-deny**: only the paths named in the
--   unauthenticated allowlist are reachable without a session, so a future
--   @\/api\/*@ route is protected the moment it is added.
--
-- Nothing here can reach the vault or @untrusted_execution@ settings: the only
-- writer is 'Seal.Config.Security.updateAccessControlSection', whose callback
-- type cannot express them.
module Seal.Gateway.AccessControl
  ( AccessControlHandle
  , NewAccess (..)
  , AuthDecision (..)
  , GrantBanner (..)
  , newAccessControlHandle
  , accessControlAuthorize
  , accessControlMiddleware
  , accessControlStatusJson
  , accessControlMode
  , accessControlCredentialCount
  , authStatusState
  , printAccessControlBannerTo
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, withMVar)
import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64Url
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
  ( NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime )
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.HTTP.Types
  ( Header, HeaderName, Status, hCookie, methodDelete, methodGet, methodOptions
  , methodPost, status200, status400, status401, status403, status404
  , status409, status413, status429, status500 )
import Network.Wai
  ( Application, Request, Response, getRequestBodyChunk, pathInfo
  , requestHeaders, requestMethod, responseLBS )

import Seal.Config.BootPlan (BootPlan (..))
import Seal.Config.Credentials (enrollCredential, updateCredentialsFile)
import Seal.Config.Paths
  ( SealPaths (..), credentialsFilePath, enrollmentClaimPath, enrollmentGrantPath
  , enrollmentTokenPath, securityFilePath )
import Seal.Security.EnrollmentGrant
  ( ChallengeId (..), EnrollmentAuthority, Grant (..), GrantClaim (..)
  , GrantContext (..), GrantDenied (..), GrantId (..), GrantPhase (..)
  , GrantSource (..), MintedGrant (..), bindClaimSuperseding, cancelGrant
  , claimLiveAt, defaultTtlFor, effectiveDeadline, enrollGrant, enrollmentAuthority
  , findAuthority, grantLiveAt, grantRedeems, grantSourceText, loadClaimFile
  , loadGrantFile, saveGrantFile, tokenDigest )
import Seal.Config.Security (CredentialFileConfig (..), writeSecretFile)
import Seal.Gateway.Audit qualified as Audit
import Seal.Gateway.Audit
  ( AuditFields (..), admitRefusal, appendAudit, emptyAuditFields, newAuditGate )
import Seal.Security.AccessControl
  ( CredentialAvailability (..), credentialAvailability, credentialToFile, rpMismatch )
import Seal.Security.Crypto (constantTimeEq, generateToken, getRandomBytes, sha256Hash)
import Seal.Security.WebAuthn
  ( AssertionInput (..), RegistrationInput (..), RegistrationResult (..)
  , WebAuthnError (..), verifyAssertion, verifyRegistration, webAuthnErrorCode
  , webAuthnErrorText )
import Seal.Security.WebAuthn.Types
  ( AccessMode (..), Credential (..), accessModeText )

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------

-- | Which ceremony a challenge was issued for. A challenge cannot be redeemed
-- by a different one, which is what stops a login challenge being used to
-- register (or a step-up being used to log in).
data ChallengeKind
  = ChallengeCreate
  | ChallengeGet
  | ChallengeStepUp
    -- ^ @enroll/options@: prove an existing credential before adding another.
    -- Bound to the session that asked for it.
  deriving stock (Eq, Show)

-- | A challenge issued for an in-flight ceremony. Removed on the first verify
-- attempt (consume-on-attempt), never reusable.
data Challenge = Challenge
  { chIssuedAt :: !UTCTime
  , chKind     :: !ChallengeKind
  , chSession  :: !(Maybe Text)
    -- ^ The session key a 'ChallengeStepUp' belongs to; 'Nothing' otherwise.
  } deriving stock (Eq, Show)

-- | One authenticated browser session.
data Session = Session
  { sesIdleExpiry :: !UTCTime
    -- ^ Sliding, refreshed on every authenticated request.
  , sesCreatedAt  :: !UTCTime
    -- ^ Fixed absolute cap, so a continuously used stolen cookie still dies.
  }

data AccessControlState = AccessControlState
  { acsMode              :: !AccessMode
  , acsCredentials       :: !(Map Text Credential)
  , acsChallenges        :: !(Map Text Challenge)
  , acsSessions          :: !(Map Text Session)
  , acsSessionGrants     :: !(Map Text Grant)
    -- ^ Assertion grants, keyed by the session that earned them. Only the digest
    -- is stored, and only for the session that presented the step-up: a cookie
    -- alone can never redeem one (design §7.2, B-1).
  , acsSetupCode         :: !(Maybe Text)
  , acsSetupHash         :: !(Maybe Text)
  , acsServiceToken      :: !Text
  , acsServiceHash       :: !Text
  , acsOrigin            :: !(Maybe Text)
  , acsRpId              :: !(Maybe Text)
  , acsChallengeTokens   :: !Double
  , acsChallengeRefillAt :: !UTCTime
  , acsFailures          :: !Int
  , acsRetryAfter        :: !UTCTime
  }

-- | The handle. Opaque: mutations go through this module.
data AccessControlHandle = AccessControlHandle
  { achState :: MVar AccessControlState
  , achPaths :: SealPaths
  , achAudit :: Audit.AuditGate
    -- ^ Aggregation state for refusal events. Per-handle so a restart starts
    -- with a clean table; the log itself is path-based and shared with the CLI.
  }

-- | What a fresh handle hands back for the boot banner.
data NewAccess = NewAccess
  { naHandle       :: AccessControlHandle
  , naToken        :: Maybe Text
    -- ^ The plaintext enrollment token minted by /this/ boot, when boot minted
    -- one. Never the digest — the digest is in the grant file.
  , naServiceToken :: Text
  , naOrigin       :: Maybe Text
  , naGrant        :: Maybe GrantBanner
    -- ^ The grant outstanding after boot, whether freshly minted or preserved.
  }

-- | What the banner says about the outstanding grant, without the secret.
data GrantBanner = GrantBanner
  { gbSource    :: !GrantSource
  , gbRemaining :: !NominalDiffTime
  , gbFresh     :: !Bool
    -- ^ 'True' when this boot minted it (so the token is 'naToken').
  } deriving stock (Eq, Show)

-- | The gate's verdict.
data AuthDecision
  = AuthAllow
  | AuthUnauthorized
    -- ^ @passkey@ mode and no valid session: 401.
  | AuthSetupRequired
    -- ^ @unconfigured@: 403, only the setup screen is served.
  deriving stock (Eq, Show)

-- Constants ------------------------------------------------------------------

challengeTtlSeconds, sessionIdleSeconds, sessionAbsoluteSeconds :: Int
challengeTtlSeconds    = 120
sessionIdleSeconds     = 24 * 60 * 60
sessionAbsoluteSeconds = 7 * 24 * 60 * 60

-- | Challenge issuance: burst of 20, refilled at 5 per second. At 5\//s a
-- sustained flood can keep at most 600 alive (5 x 120 s), under the map cap, so
-- it can never evict an operator's in-flight challenge.
maxChallenges :: Int
maxChallenges = 1024

challengeBurst :: Double
challengeBurst = 20

challengeRefillPerSecond :: Double
challengeRefillPerSecond = 5

maxAuthBody :: Int
maxAuthBody = 64 * 1024

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Build the handle from an already-decided 'BootPlan'.
--
-- The plan is the whole input on purpose: the handle never reads
-- @security.toml@ or @credentials.toml@ again, so editing either file under a
-- running gateway cannot change what it trusts. Minting follows
-- 'bpMintGrant' — nothing is minted when a usable credential exists, because
-- there is already an authority the operator can present.
newAccessControlHandle :: SealPaths -> BootPlan -> IO NewAccess
newAccessControlHandle paths plan = do
  serviceToken <- generateToken 32
  now <- getCurrentTime
  let creds = bpCreds plan
      mOrigin = bpOrigin plan
      mRpId = bpRpId plan
  -- Boot never clobbers an outstanding grant (design §7.3, §16.9). The CLI
  -- mints while the daemon runs, so a restart that minted unconditionally would
  -- invalidate a token the operator is holding. Minting is also skipped
  -- entirely when a usable credential exists: an assertion is already the
  -- authority.
  (mCode, naBanner) <- case bpMintGrant plan of
    Nothing -> pure (Nothing, Nothing)
    Just source -> do
      outstanding <- loadGrantFile (enrollmentGrantPath paths)
      case outstanding of
        Just grant | grantLiveAt now grant ->
          pure (Nothing, Just (banner (grSource grant) now grant False))
        _ -> do
          minted <- enrollGrant paths source (defaultTtlFor source) True
          case minted of
            Right result -> do
              _ <- Audit.appendAudit paths now
                     (emptyAuditFields Audit.GrantMinted)
                       { afVia = Just (grSource (mgGrant result))
                       , afRemainingSeconds = Just (round (defaultTtlFor source))
                       }
              pure ()
            Left _ -> pure ()
          pure $ case minted of
            Left _ -> (Nothing, Nothing)
            Right result ->
              ( mgToken result
              , Just (banner (grSource (mgGrant result)) now (mgGrant result) True) )
  auditGate <- newAuditGate
  st <- newMVar AccessControlState
    { acsMode = bpMode plan
    , acsCredentials = creds
    , acsChallenges = Map.empty
    , acsSessions = Map.empty
    , acsSessionGrants = Map.empty
    , acsSetupCode = mCode
    , acsSetupHash = tokenKey <$> mCode
    , acsServiceToken = serviceToken
    , acsServiceHash = tokenKey serviceToken
    , acsOrigin = mOrigin
    , acsRpId = mRpId
    , acsChallengeTokens = challengeBurst
    , acsChallengeRefillAt = now
    , acsFailures = 0
    , acsRetryAfter = now
    }
  pure NewAccess
    { naHandle       = AccessControlHandle st paths auditGate
    , naToken        = mCode
    , naServiceToken = serviceToken
    , naOrigin       = mOrigin
    , naGrant        = naBanner
    }
  where
    banner source stamp grant fresh = GrantBanner
      { gbSource    = source
      , gbRemaining = diffUTCTime (grExpiresAt grant) stamp
      , gbFresh     = fresh
      }

-- | Accessors for the boot banner and for tests.
accessControlMode :: AccessControlHandle -> IO AccessMode
accessControlMode h = withMVar (achState h) (pure . acsMode)

accessControlCredentialCount :: AccessControlHandle -> IO Int
accessControlCredentialCount h =
  withMVar (achState h) (pure . Map.size . acsCredentials)

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------

-- | The single authorization decision (design §7). Used by the HTTP middleware
-- and by the WebSocket handshake.
accessControlAuthorize :: AccessControlHandle -> Request -> IO AuthDecision
accessControlAuthorize h req = do
  now <- getCurrentTime
  st <- withMVar (achState h) (pure . refillChallenges now)
  pure (decide now st)
  where
    path = pathInfo req
    decide now st
      | requestMethod req == methodOptions = AuthAllow
      | path == ["api", "health"] = AuthAllow
      | otherwise = case acsMode st of
          AccessOpen -> AuthAllow
          AccessUnconfigured
            | path `elem` unconfiguredAllow -> AuthAllow
            | hasServiceToken st req && not (isAuthPath path) -> AuthAllow
            | otherwise -> AuthSetupRequired
          AccessPasskey
            | path `elem` passkeyAllow -> AuthAllow
            | isRegisterPath path && isJustSetup st -> AuthAllow
            | hasServiceToken st req && not (isAuthPath path) -> AuthAllow
            | sessionValid now st (sessionKeyFromRequest req) -> AuthAllow
            | otherwise -> AuthUnauthorized

unconfiguredAllow :: [[Text]]
unconfiguredAllow =
  [ ["api", "auth", "status"]
  , ["api", "auth", "register", "options"]
  , ["api", "auth", "register", "verify"]
  ]

passkeyAllow :: [[Text]]
passkeyAllow =
  [ ["api", "auth", "status"]
  , ["api", "auth", "login", "options"]
  , ["api", "auth", "login", "verify"]
  ]

isJustSetup :: AccessControlState -> Bool
isJustSetup = isJust . acsSetupHash

isAuthPath :: [Text] -> Bool
isAuthPath ("api" : "auth" : _) = True
isAuthPath _                    = False

isRegisterPath :: [Text] -> Bool
isRegisterPath ["api", "auth", "register", _] = True
isRegisterPath _                              = False

-- | The WAI middleware. Auth routes are dispatched here; everything else is
-- gated and then handed to the wrapped application.
accessControlMiddleware :: AccessControlHandle -> Application -> Application
accessControlMiddleware h inner req respond
  | isAuthPath (pathInfo req) = authApp h req respond
  | otherwise = do
      decision <- accessControlAuthorize h req
      case decision of
        AuthAllow         -> inner req respond
        AuthUnauthorized  -> respond (authError status401 "unauthenticated"
                                 "a passkey session is required")
        AuthSetupRequired -> respond (authError status403 "access_control_required"
                                 "access control is not configured yet; finish setup in the browser")

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

-- | The @\/api\/auth\/status@ payload (design §11): snake case, one @state@
-- enum, and no secret in it.
accessControlStatusJson :: AccessControlHandle -> Request -> IO Value
accessControlStatusJson h req = do
  now <- getCurrentTime
  st <- withMVar (achState h) pure
  -- The file grant is read per request, never cached (design §7.3): the CLI
  -- mints while the daemon runs and the UI polls this endpoint.
  filed <- loadGrantFile (enrollmentGrantPath (achPaths h))
  let liveFile = filed >>= \grant -> if grantLiveAt now grant then Just grant else Nothing
      sessKey = sessionKeyFromRequest req
      sessGrant = sessKey >>= \key -> Map.lookup key (acsSessionGrants st)
      mismatch = rpMismatch (acsRpId st) (acsCredentials st)
      authenticated = acsMode st == AccessOpen
        || sessionValid now st sessKey
      -- A timing signal ("authority is armed"), not a boolean the UI acts on.
      enrollmentVia = case (liveFile, sessGrant) of
        (Just grant, _)   -> grantSourceText (grSource grant)
        (Nothing, Just grant) -> grantSourceText (grSource grant)
        _                 -> "none"
      usable = case acsRpId st of
        Nothing  -> Map.size (acsCredentials st)
        Just rp  -> length [ () | cred <- Map.elems (acsCredentials st)
                                , Just (credRpId cred) == Just rp ]
  pure $ object
    [ "state" .= authStatusState st
    , "authenticated" .= authenticated
    , "origin" .= acsOrigin st
    , "rp_id" .= acsRpId st
    , "rp_mismatch" .= mismatch
    , "setup_required" .= (acsMode st == AccessUnconfigured || mismatch)
    , "credentials" .= Map.size (acsCredentials st)
    -- Design §8.3: no `enrollment_available` boolean — rev 3 keyed a button on
    -- the wrong one.
    , "enrollment_via" .= enrollmentVia
    , "usable_credentials" .= usable
    , "orphaned_credentials" .= (Map.size (acsCredentials st) - usable)
    ]

authStatusState :: AccessControlState -> Text
authStatusState = accessModeText . acsMode

-- ---------------------------------------------------------------------------
-- Tokens, cookies, sessions
-- ---------------------------------------------------------------------------

tokenKey :: Text -> Text
tokenKey = TE.decodeUtf8 . sha256Hash . TE.encodeUtf8

cookieName :: Text
cookieName = "seal_session"

sessionKeyFromRequest :: Request -> Maybe Text
sessionKeyFromRequest req =
  case cookieValue cookieName req of
    Just tok -> Just (tokenKey tok)
    Nothing  -> bearerToken req >>= (Just . tokenKey)

bearerToken :: Request -> Maybe Text
bearerToken req =
  case lookup hAuthorization (requestHeaders req) of
    Nothing -> Nothing
    Just raw -> case T.stripPrefix "Bearer " (T.strip (TE.decodeUtf8Lenient raw)) of
      Just t | not (T.null t) -> Just t
      _                       -> Nothing

hAuthorization :: HeaderName
hAuthorization = "Authorization"

cookieValue :: Text -> Request -> Maybe Text
cookieValue name req = do
  raw <- lookup hCookie (requestHeaders req)
  let pieces = map T.strip (T.splitOn ";" (TE.decodeUtf8Lenient raw))
  lookup name (map splitPair pieces)
  where
    splitPair p = case T.breakOn "=" p of
      (k, v) | T.null v   -> (k, "")
             | otherwise  -> (k, T.drop 1 v)

hasServiceToken :: AccessControlState -> Request -> Bool
hasServiceToken st req = case bearerToken req of
  Nothing  -> False
  Just tok -> constantTimeEq (TE.encodeUtf8 (tokenKey tok))
                              (TE.encodeUtf8 (acsServiceHash st))

sessionValid :: UTCTime -> AccessControlState -> Maybe Text -> Bool
sessionValid now st mKey = case mKey >>= (`Map.lookup` acsSessions st) of
  Nothing  -> False
  Just ses -> now < sesIdleExpiry ses
    && now < addUTCTime (fromIntegral sessionAbsoluteSeconds) (sesCreatedAt ses)

-- | Mint a session and return the raw token (the caller sets the cookie).
mintSession :: AccessControlHandle -> IO Text
mintSession h = do
  raw <- generateToken 32
  now <- getCurrentTime
  modifyMVar_ (achState h) $ \st ->
    pure st { acsSessions = Map.insert (tokenKey raw) Session
                       { sesIdleExpiry = addUTCTime (fromIntegral sessionIdleSeconds) now
                       , sesCreatedAt = now
                       }
                       (Map.filter (stillLive now) (acsSessions st))
            }
  pure raw
  where
    stillLive now ses = now < sesIdleExpiry ses
      && now < addUTCTime (fromIntegral sessionAbsoluteSeconds) (sesCreatedAt ses)

sessionCookie :: AccessControlHandle -> Text -> IO Header
sessionCookie h token = do
  st <- withMVar (achState h) pure
  let secure = maybe False ("https://" `T.isPrefixOf`) (acsOrigin st)
  pure ("Set-Cookie", TE.encodeUtf8
    (cookieName <> "=" <> token
      <> "; Path=/; HttpOnly; SameSite=Strict; Max-Age=" <> T.pack (show sessionIdleSeconds)
      <> (if secure then "; Secure" else "")))

-- | The @Set-Cookie@ that deletes the session cookie.
clearedSessionCookie :: AccessControlHandle -> IO Header
clearedSessionCookie h = do
  st <- withMVar (achState h) pure
  let secure = maybe False ("https://" `T.isPrefixOf`) (acsOrigin st)
  pure ("Set-Cookie", TE.encodeUtf8
    (cookieName <> "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
      <> (if secure then "; Secure" else "")))

-- ---------------------------------------------------------------------------
-- Challenge lifecycle
-- ---------------------------------------------------------------------------

refillChallenges :: UTCTime -> AccessControlState -> AccessControlState
refillChallenges now st =
  let elapsed = realToFrac (diffUTCTime now (acsChallengeRefillAt st)) :: Double
      tokens = min challengeBurst (acsChallengeTokens st + elapsed * challengeRefillPerSecond)
  in st { acsChallengeTokens = tokens, acsChallengeRefillAt = now }

challengeFresh :: UTCTime -> Challenge -> Bool
challengeFresh now ch =
  realToFrac (diffUTCTime now (chIssuedAt ch)) < (fromIntegral challengeTtlSeconds :: Double)

-- | Issue a challenge, or fail when the issuance budget or the map cap is
-- exhausted (never evicting a live entry).
issueChallenge :: AccessControlHandle -> ChallengeKind -> Maybe Text -> IO (Either AuthErr Text)
issueChallenge h kind mSession = do
  now <- getCurrentTime
  modifyMVar (achState h) $ \st0 -> do
    let st = refillChallenges now st0
        live = Map.filter (challengeFresh now) (acsChallenges st)
        st' = st { acsChallenges = live }
    if acsChallengeTokens st' < 1
      then pure (st', Left (AuthErr status429 "rate_limited"
                     "too many challenge requests; try again in a moment"))
      else if Map.size live >= maxChallenges
        then pure (st', Left (AuthErr status429 "rate_limited"
                       "too many outstanding challenges; try again in a moment"))
        else do
          raw <- getRandomBytes 32
          let ch = TE.decodeUtf8 (B64Url.encodeUnpadded raw)
          pure ( st' { acsChallenges = Map.insert ch (Challenge now kind mSession) live
                     , acsChallengeTokens = acsChallengeTokens st' - 1 }
               , Right ch )

-- | Remove a challenge (consume-on-attempt) and report whether it was present,
-- fresh and of the right ceremony.
consumeChallenge :: AccessControlHandle -> Text -> ChallengeKind -> Maybe Text -> IO Bool
consumeChallenge h presented kind mSession = do
  now <- getCurrentTime
  modifyMVar (achState h) $ \st ->
    case Map.lookup presented (acsChallenges st) of
      -- A step-up challenge belongs to exactly one session: a different session
      -- presenting it consumes nothing, so a stolen challenge string is not
      -- enough to redeem it.
      Just ch | chKind ch == kind
              , chSession ch == mSession
              , challengeFresh now ch ->
        pure (st { acsChallenges = Map.delete presented (acsChallenges st) }, True)
      _ -> pure (st, False)

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

data AuthErr
  = AuthErr Status Text Text
  | AuthErrDetail Status Text Text Value
    -- ^ A refusal that also carries machine-readable fields (the @code@ is
    -- still the discriminator; the detail is what the panel renders). A
    -- separate constructor rather than a fourth field on 'AuthErr' so the
    -- ~28 positional construction sites keep working: only the two
    -- response builders below have to learn about it.
  deriving stock (Eq, Show)

-- | Auth responses carry NO @Access-Control-Allow-Origin@: the gateway's other
-- responses are @*@, and a cross-origin page must not be able to read
-- @allowCredentials@ (which enumerates credential ids) or drive setup.
authHeaders :: [Header]
authHeaders =
  [ ("Content-Type", "application/json")
  , ("Cache-Control", "no-store")
  , ("X-Content-Type-Options", "nosniff")
  ]

authJson :: Status -> [Header] -> Value -> Response
authJson st extra = responseLBS st (authHeaders <> extra) . A.encode

authError :: Status -> Text -> Text -> Response
authError st code msg = authJson st [] (object ["error" .= msg, "code" .= code])

authOk :: [Header] -> Value -> Response
authOk = authJson status200

authErrorWith :: Status -> Text -> Text -> Value -> Response
authErrorWith st code msg detail = authJson st [] $ case detail of
  Object o -> Object (KeyMap.insert (Key.fromText "error") (String msg)
           (KeyMap.insert (Key.fromText "code") (String code) o))
  other    -> object ["error" .= msg, "code" .= code, "detail" .= other]

respondResult :: [Header] -> Either AuthErr Value -> Response
respondResult extra result = case result of
  Left (AuthErr st code msg)              -> authError st code msg
  Left (AuthErrDetail st code msg detail) -> authErrorWith st code msg detail
  Right v                                 -> authOk extra v

-- | Like 'respondResult', for handlers that mint a session and therefore carry
-- a @Set-Cookie@ header back.
respondSession :: Either AuthErr (Value, [Header]) -> Response
respondSession result = case result of
  Left (AuthErr st code msg)              -> authError st code msg
  Left (AuthErrDetail st code msg detail) -> authErrorWith st code msg detail
  Right (v, extra)                        -> authOk extra v

-- ---------------------------------------------------------------------------
-- The auth API
-- ---------------------------------------------------------------------------

authApp :: AccessControlHandle -> Application
authApp h req respond =
  case (requestMethod req, pathInfo req) of
    (m, ["api", "auth", "status"]) | m == methodGet ->
      accessControlStatusJson h req >>= respond . authOk []

    (m, ["api", "auth", "register", "options"]) | m == methodPost -> do
      result <- withEnrollment h req (registerOptions h)
      respond (respondResult [] result)

    (m, ["api", "auth", "register", "verify"]) | m == methodPost -> do
      result <- withEnrollment h req (verifyRegistrationEndpoints h False)
      respond (respondSession result)

    (m, ["api", "auth", "login", "options"]) | m == methodPost -> do
      result <- loginOptions h
      respond (respondResult [] result)

    (m, ["api", "auth", "login", "verify"]) | m == methodPost -> do
      result <- loginVerify h req
      respond (respondSession result)

    (m, ["api", "auth", "logout"]) | m == methodPost -> do
      logout h req
      -- Clearing the cookie (not just forgetting the session) matters: the
      -- cookie is persistent (24 h idle), so a browser would otherwise keep
      -- presenting a token the server ignores for the rest of the day.
      cleared <- clearedSessionCookie h
      respond (authOk [cleared] (object ["ok" .= True]))

    -- The step-up endpoint pair (design §8.1): a live session confirms itself
    -- with an existing passkey and receives a short-lived assertion grant.
    (m, ["api", "auth", "enroll", "options"]) | m == methodPost -> do
      result <- enrollOptions h req
      respond (respondResult [] result)

    (m, ["api", "auth", "enroll", "verify"]) | m == methodPost -> do
      result <- enrollVerify h req
      respond (respondResult [] result)

    (m, ["api", "auth", "credentials", "options"]) | m == methodPost -> do
      result <- withEnrollment h req (registerOptions h)
      respond (respondResult [] result)

    (m, ["api", "auth", "credentials", "verify"]) | m == methodPost -> do
      result <- withEnrollment h req (verifyRegistrationEndpoints h True)
      respond (respondSession result)

    (m, ["api", "auth", "credentials"]) | m == methodGet -> do
      result <- withCredentialAdmin h req (listCredentials h)
      respond (respondResult [] result)

    (m, ["api", "auth", "credentials", cid]) | m == methodDelete -> do
      result <- withCredentialAdmin h req (const (deleteCredential h cid))
      respond (respondResult [] result)

    _ -> respond (authError status404 "not_found" "no such endpoint")

-- ---------------------------------------------------------------------------
-- Enrollment authority
-- ---------------------------------------------------------------------------

-- | The header a client presents enrollment authority in.
--
-- Replaces @X-Seal-Setup-Token@: the setup code was a boot-time bearer token
-- with no expiry, and it is now a grant like any other (design §7.2, §8.2).
enrollTokenHeader :: Request -> Maybe Text
enrollTokenHeader req =
  case lookup "X-Seal-Enroll-Token" (requestHeaders req) of
    Nothing  -> Nothing
    Just raw -> let t = T.strip (TE.decodeUtf8Lenient raw) in if T.null t then Nothing else Just t

-- | Resolve the authority this request presents, then ask whether this boot
-- state accepts it.
--
-- The file-backed grant is re-read on every call and never cached: the CLI
-- mints while the daemon runs, so a cached copy would be invisible until
-- restart (design §7.3). Only session-carried assertion grants live in memory.
--
-- A presented token that matches nothing is 'GrantInvalid' — it must not be
-- downgraded to "no authority presented", or a wrong token would be as good as
-- an absent one (gate round 4, B-1).
resolveEnrollment
  :: AccessControlHandle -> AccessControlState -> Request
  -> IO (Either GrantDenied EnrollmentAuthority)
resolveEnrollment h st req = do
  now <- getCurrentTime
  filed <- loadGrantFile (enrollmentGrantPath (achPaths h))
  let liveFile = filed >>= \grant -> if grantLiveAt now grant then Just grant else Nothing
      presented = enrollTokenHeader req
      sessKey = sessionKeyFromRequest req
      sessGrant = sessKey >>= \key -> Map.lookup key (acsSessionGrants st)
      ctx = GrantContext
        { gcMode = acsMode st
        , gcAvailability = credentialAvailability (acsRpId st) (acsCredentials st)
        , gcAuthorized = Nothing
        , gcHasSession = sessionValid now st sessKey
        }
  pure $ case findAuthority presented liveFile sessGrant (isJust sessGrant) of
    Right grant -> enrollmentAuthority ctx { gcAuthorized = Just (grSource grant) }
    Left GrantInvalid | isJust presented -> Left GrantInvalid
    Left _ -> enrollmentAuthority ctx

-- | The wire response for each refusal. The constructors exist for this.
enrollRefusal :: GrantDenied -> AuthErr
enrollRefusal denied = case denied of
  GrantRequired ->
    AuthErr status403 "grant_required"
      "enrollment needs an enrollment token; run `seal access-control enroll`"
  StepUpRequired ->
    AuthErr status403 "step_up_required"
      "confirm it's you with an existing passkey to add another"
  GrantInvalid ->
    AuthErr status403 "grant_invalid"
      "that enrollment token is not valid for this gateway; run `seal access-control enroll`"

-- | Gate an enrollment endpoint on 'resolveEnrollment', handing the accepted
-- authority to the handler.
withEnrollment
  :: AccessControlHandle -> Request
  -> (EnrollmentAuthority -> Request -> IO (Either AuthErr a))
  -> IO (Either AuthErr a)
withEnrollment h req action = do
  st <- withMVar (achState h) pure
  decision <- resolveEnrollment h st req
  case decision of
    Left denied -> do
      auditRefusal h denied
      pure (Left (enrollRefusal denied))
    Right authority -> action authority req

-- | Record a refused enrollment attempt, aggregated.
--
-- Aggregation is what keeps a pre-auth flood from rotating the state-changing
-- evidence away (design §15): the key is the refusal code, never anything the
-- client chose.
auditRefusal :: AccessControlHandle -> GrantDenied -> IO ()
auditRefusal h denied = do
  now <- getCurrentTime
  let code = case denied of
        GrantRequired   -> "grant_required"
        StepUpRequired  -> "step_up_required"
        GrantInvalid    -> "grant_invalid"
  admitted <- admitRefusal (achAudit h) now code
  when admitted $ do
    _ <- appendAudit (achPaths h) now (emptyAuditFields Audit.GrantRefused)
    pure ()

-- | Record a state-changing event. Failures are swallowed on purpose: the audit
-- log is detective, and a full disk must not fail a login.
auditEvent :: AccessControlHandle -> AuditFields -> IO ()
auditEvent h fields = do
  now <- getCurrentTime
  _ <- appendAudit (achPaths h) now fields
  pure ()

-- | Who may list and delete credentials (design §8.1).
data CredentialAdmin
  = AdminSession
  | AdminCliToken
  | AdminOpen
  | AdminDenied
  deriving stock (Eq, Show)

-- | Credential administration is session-or-CLI-token, plus unauthenticated in
-- @open@ mode (which is fully open anyway, and is what lets @\/access@ work
-- there at all). Window and assertion grants are enrollment-only.
credentialAdminFor
  :: AccessControlHandle -> AccessControlState -> Request -> IO CredentialAdmin
credentialAdminFor h st req = do
  now <- getCurrentTime
  if acsMode st == AccessOpen
    then pure AdminOpen
    else if sessionValid now st (sessionKeyFromRequest req)
      then pure AdminSession
      else do
        filed <- loadGrantFile (enrollmentGrantPath (achPaths h))
        let liveFile = filed >>= \grant -> if grantLiveAt now grant then Just grant else Nothing
            tokenOk = case (enrollTokenHeader req, liveFile) of
              (Just raw, Just grant) | grSource grant == CliToken ->
                case grTokenSha grant of
                  Just digest -> constantTimeEq digest (tokenDigest raw)
                  Nothing     -> False
              _ -> False
        pure (if tokenOk then AdminCliToken else AdminDenied)

withCredentialAdmin
  :: AccessControlHandle -> Request
  -> (Request -> IO (Either AuthErr a))
  -> IO (Either AuthErr a)
withCredentialAdmin h req action = do
  st <- withMVar (achState h) pure
  verdict <- credentialAdminFor h st req
  case verdict of
    AdminDenied -> pure (Left (enrollRefusal GrantRequired))
    _           -> action req

-- | Bind the outstanding file grant to a challenge, exclusively.
--
-- @O_CREAT|O_EXCL@ on the claim file decides which ceremony wins, and the grant
-- is written back with its bound challenge so a grant bound to A cannot redeem
-- B (design §7.3). A grant in a session ('Assertion') is not bound here: it is
-- single-use through the challenge itself.
--
-- Retries supersede an abandoned claim: see 'bindClaimSuperseding'.
bindGrant :: SealPaths -> Grant -> ChallengeId -> IO Bool
bindGrant paths grant challenge = do
  now <- getCurrentTime
  let GrantId rawId = grId grant
      claim = GrantClaim
        { clGrantId = grId grant
        , clChallengeId = challenge
        , clDeadline = effectiveDeadline grant now (fromIntegral challengeTtlSeconds)
        }
  won <- bindClaimSuperseding (enrollmentClaimPath paths rawId) claim
  if not won
    then pure False
    else do
      saved <- saveGrantFile (enrollmentGrantPath paths) grant { grPhase = GrantBound challenge }
      pure (either (const False) (const True) saved)

-- | Does the outstanding grant permit redeeming this challenge?
--
-- 'True' when there is no file grant (the authority was an assertion, carried
-- by the session), so the assertion path is unaffected by the file protocol.
grantPermits :: SealPaths -> ChallengeId -> IO Bool
grantPermits paths challenge = do
  filed <- loadGrantFile (enrollmentGrantPath paths)
  case filed of
    Nothing -> pure True
    Just grant -> do
      let GrantId rawId = grId grant
      held <- loadClaimFile (enrollmentClaimPath paths rawId)
      now <- getCurrentTime
      pure (grantRedeems challenge grant && maybe False (claimLiveAt now) held)

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

registerOptions
  :: AccessControlHandle -> EnrollmentAuthority -> Request
  -> IO (Either AuthErr Value)
registerOptions h authority _req = do
  st <- withMVar (achState h) pure
  case (acsOrigin st, acsRpId st) of
    (_, Nothing) -> pure (Left (AuthErr status400 "origin_mismatch"
                         "this gateway has no relying-party id configured"))
    (Nothing, _) -> pure (Left (AuthErr status400 "origin_mismatch"
                         "this gateway has no origin configured"))
    (Just _, Just rpId) -> do
      now <- getCurrentTime
      challenge <- issueChallenge h ChallengeCreate Nothing
      case challenge of
        Left e      -> pure (Left e)
        Right value -> do
          -- Bind the outstanding grant to this challenge before handing out
          -- the options (design §7.3): the O_EXCL claim is what makes one grant
          -- redeemable exactly once, even across processes. An assertion grant
          -- lives in the session and needs no file binding.
          bound <- case authority of
            Assertion -> pure True
            _ -> do
              filed <- loadGrantFile (enrollmentGrantPath (achPaths h))
              case filed of
                Just grant | grantLiveAt now grant ->
                  bindGrant (achPaths h) grant (ChallengeId value)
                -- The token was live when 'resolveEnrollment' looked, so this is
                -- a race with --cancel/--force: the ceremony must not proceed.
                _ -> pure False
          if not bound
            then pure (Left (enrollRefusal GrantInvalid))
            else do
              userRaw <- getRandomBytes 16
              pure (Right (object
                [ "challenge" .= value
                , "rp" .= object ["id" .= rpId, "name" .= ("Seal Harness" :: Text)]
                , "user" .= object
                    [ "id" .= TE.decodeUtf8 (B64Url.encodeUnpadded userRaw)
                    , "name" .= ("operator" :: Text)
                    , "displayName" .= ("Seal Harness operator" :: Text)
                    ]
                , "pubKeyCredParams" .=
                    [ object ["type" .= ("public-key" :: Text), "alg" .= (-7 :: Int)] ]
                , "timeout" .= (120000 :: Int)
                , "attestation" .= ("none" :: Text)
                , "authenticatorSelection" .= object
                    [ "userVerification" .= ("required" :: Text)
                    , "residentKey" .= ("preferred" :: Text)
                    ]
                , "excludeCredentials" .=
                    [ object [ "type" .= ("public-key" :: Text)
                             , "id" .= cid ] | cid <- Map.keys (acsCredentials st) ]
                ]))

loginOptions :: AccessControlHandle -> IO (Either AuthErr Value)
loginOptions h = do
  st <- withMVar (achState h) pure
  case acsRpId st of
    Nothing -> pure (Left (AuthErr status400 "origin_mismatch"
                     "this gateway has no relying-party id configured"))
    Just rpId -> do
      challenge <- issueChallenge h ChallengeGet Nothing
      case challenge of
        Left e      -> pure (Left e)
        Right value -> pure (Right (object
          [ "challenge" .= value
          , "rpId" .= rpId
          , "timeout" .= (120000 :: Int)
          , "userVerification" .= ("required" :: Text)
          , "allowCredentials" .=
              [ object [ "type" .= ("public-key" :: Text), "id" .= cid ]
              | cid <- Map.keys (acsCredentials st) ]
          ]))

-- | Verify a registration response. @isAdd@ distinguishes the
-- authenticated "add another passkey" path from first-run enrollment.
verifyRegistrationEndpoints
  :: AccessControlHandle -> Bool -> EnrollmentAuthority -> Request
  -> IO (Either AuthErr (Value, [Header]))
verifyRegistrationEndpoints h isAdd authority req = do
  body <- readJsonBody req
  case body of
    Left e -> pure (Left e)
    Right obj -> do
      st <- withMVar (achState h) pure
      case (,,) <$> b64Field obj "clientDataJSON"
                <*> b64Field obj "attestationObject"
                <*> b64Field obj "rawId" of
        Right (clientData, attestation, rawId) -> do
          now <- getCurrentTime
          let presentedChallenge = clientChallenge clientData
          -- The grant must still be bound to this challenge and its claim must
          -- still be inside the deadline; only then is the challenge consumed.
          permits <- case (authority, presentedChallenge) of
            (Assertion, Just c) -> pure (Just c)
            (_, Just c) -> do
              ok <- grantPermits (achPaths h) (ChallengeId c)
              pure (if ok then Just c else Nothing)
            (_, Nothing) -> pure Nothing
          consumed <- case permits of
            Nothing -> pure False
            Just c  -> consumeChallenge h c ChallengeCreate Nothing
          if not consumed
            then pure (Left
                   (case permits of
                      Nothing | isJust presentedChallenge -> enrollRefusal GrantInvalid
                      _ -> AuthErr status400 "challenge_invalid"
                             "the challenge is missing, expired or already used"))
            else
              case (acsOrigin st, acsRpId st) of
                (Just origin, Just rpId) ->
                  case verifyRegistration RegistrationInput
                        { riClientDataJSON = clientData
                        , riAttestationObject = attestation
                        , riRawId = rawId
                        , riExpectedChallenge = fromMaybeText presentedChallenge
                        , riExpectedOrigin = origin
                        , riExpectedRpId = rpId
                        } of
                    Left e -> pure (Left (webAuthnFailure e))
                    Right result -> persistRegistration h authority isAdd result now
                _ -> pure (Left (AuthErr status400 "origin_mismatch"
                            "this gateway has no origin configured"))
        Left e -> pure (Left e)

persistRegistration
  :: AccessControlHandle -> EnrollmentAuthority -> Bool -> RegistrationResult -> UTCTime
  -> IO (Either AuthErr (Value, [Header]))
persistRegistration h authority isAdd result now = do
  st <- withMVar (achState h) pure
  let rawId = TE.decodeUtf8 (B64Url.encodeUnpadded (rrCredentialId result))
      cred = Credential
        { credId = rrCredentialId result
        , credPublicKey = rrPublicKey result
        , credSignCount = rrSignCount result
        , credLabel = "passkey"
        , credCreatedAt = now
        , credRpId = fromMaybeText (acsRpId st)
        , credAddedVia = Just (grantSourceText authority)
        }
  -- Raise the mode and write the credential as ONE operation (design §6.1):
  -- two files, so neither is atomic alone, and two interleaved ceremonies could
  -- otherwise leave a credential on a gateway whose mode still says "none".
  -- 'enrollCredential' takes the write lock exactly once around both.
  written <- enrollCredential (securityFilePath (achPaths h))
                              (credentialsFilePath (achPaths h))
                              (Map.singleton rawId (credentialToFile cred))
  case written of
    Left err -> pure (Left (AuthErr status500 "write_failed" err))
    Right () -> do
          modifyMVar_ (achState h) $ \s ->
            let creds' = Map.insert rawId cred (acsCredentials s)
            in pure s { acsMode = AccessPasskey
                      , acsCredentials = creds'
                      , acsSetupCode = Nothing
                      , acsSetupHash = Nothing
                      }
          -- Success consumes the authority: file grant, claim marker and the
          -- plaintext token all go, and any session-carried grant with them
          -- (design §7.2). Sessions themselves are untouched.
          clearOutstandingGrants h
          auditEvent h (emptyAuditFields Audit.CredentialAdded)
            { afCredentialId = Just rawId
            , afLabel = Just (credLabel cred)
            , afRpId = Just (credRpId cred)
            , afOrigin = acsOrigin st
            , afVia = Just authority
            }
          when (acsMode st /= AccessPasskey) $
            auditEvent h (emptyAuditFields Audit.ModeEnabled) { afOrigin = acsOrigin st }
          auditEvent h (emptyAuditFields Audit.GrantConsumed) { afOrigin = acsOrigin st }
          token <- mintSession h
          cookie <- sessionCookie h token
          pure (Right ( object
            [ "ok" .= True
            , "credential" .= rawId
            , "added" .= isAdd
            ]
            , [cookie] ))


loginVerify :: AccessControlHandle -> Request -> IO (Either AuthErr (Value, [Header]))
loginVerify h req = do
  body <- readJsonBody req
  case body of
    Left e -> pure (Left e)
    Right obj -> do
      now <- getCurrentTime
      allowed <- backoffAllows h now
      if not allowed
        then pure (Left (AuthErr status429 "rate_limited" "too many failed attempts; try again shortly"))
        else do
          st <- withMVar (achState h) pure
          case (,,,) <$> b64Field obj "clientDataJSON"
                     <*> b64Field obj "authenticatorData"
                     <*> b64Field obj "signature"
                     <*> b64Field obj "rawId" of
            Right (clientData, authData, signature, rawId) -> do
              let claimedId = TE.decodeUtf8 (B64Url.encodeUnpadded rawId)
              case Map.lookup claimedId (acsCredentials st) of
                Nothing -> do
                  recordFailure h now
                  pure (Left (AuthErr status400 "unknown_credential" "no credential with that id is enrolled"))
                Just cred -> do
                  consumed <- maybe (pure False)
                                    (\c -> consumeChallenge h c ChallengeGet Nothing)
                                    (clientChallenge clientData)
                  if not consumed
                    then pure (Left (AuthErr status400 "challenge_invalid"
                               "the challenge is missing, expired or already used"))
                    else
                      case (acsOrigin st, acsRpId st) of
                        (Just origin, Just rpId) ->
                          case verifyAssertion (credPublicKey cred) AssertionInput
                                { aiClientDataJSON = clientData
                                , aiAuthenticatorData = authData
                                , aiSignature = signature
                                , aiExpectedChallenge = fromMaybeText (clientChallenge clientData)
                                , aiExpectedOrigin = origin
                                , aiExpectedRpId = rpId
                                , aiStoredSignCount = credSignCount cred
                                } of
                            Left e -> do
                              recordFailure h now
                              pure (Left (webAuthnFailure e))
                            Right newCount -> do
                              bumped <- claimSignCount h claimedId (credSignCount cred) newCount
                              if not bumped
                                then pure (Left (AuthErr status400 "sign_count_regression"
                                           "this assertion was already used"))
                                else do
                                  -- Persist, then mint. A counter that did not
                                  -- reach disk must not produce a session: the
                                  -- next boot would accept a replay of the
                                  -- assertion we just used.
                                  persisted <- persistSignCount h claimedId newCount
                                  case persisted of
                                    Left err -> pure (Left (AuthErr status500 "write_failed" err))
                                    Right () -> do
                                      resetBackoff h
                                      token <- mintSession h
                                      cookie <- sessionCookie h token
                                      pure (Right ( object
                                        ["ok" .= True, "credential" .= claimedId]
                                        , [cookie] ))
                        _ -> pure (Left (AuthErr status400 "origin_mismatch"
                                    "this gateway has no origin configured"))
            Left e -> pure (Left e)

-- ---------------------------------------------------------------------------
-- enroll/*: prove an existing passkey, then add another
-- ---------------------------------------------------------------------------

-- | @enroll/options@ (design §8.1): the assertion that authorises adding a
-- second passkey.
--
-- Unlike @login/options@ this is not a session gate but a mode+availability
-- gate: it exists only in a healthy @passkey@ boot with at least one usable
-- credential, because there is nothing to prove anywhere else. The challenge is
-- single-use and bound to the calling session, so a challenge lifted from
-- another session cannot be redeemed here.
enrollOptions :: AccessControlHandle -> Request -> IO (Either AuthErr Value)
enrollOptions h req = do
  st <- withMVar (achState h) pure
  now <- getCurrentTime
  let sessKey = sessionKeyFromRequest req
  case (acsMode st, credentialAvailability (acsRpId st) (acsCredentials st),
        sessionValid now st sessKey, sessKey) of
    (AccessPasskey, Usable, True, Just key) -> do
      challenge <- issueChallenge h ChallengeStepUp (Just key)
      case challenge of
        Left e      -> pure (Left e)
        Right value -> pure (Right (object
          [ "challenge" .= value
          , "rpId" .= fromMaybeText (acsRpId st)
          , "timeout" .= (120000 :: Int)
          , "userVerification" .= ("required" :: Text)
          -- Only usable credentials: the picker must never offer one that
          -- cannot sign in here.
          , "allowCredentials" .=
              [ object [ "type" .= ("public-key" :: Text), "id" .= cid ]
              | (cid, cred) <- Map.toList (acsCredentials st)
              , Just (credRpId cred) == acsRpId st ]
          ]))
    (AccessPasskey, _, False, _) ->
      pure (Left (enrollRefusal GrantRequired))
    _ ->
      pure (Left (AuthErr status403 "grant_required"
        "adding a passkey is available only once one is enrolled and usable here"))

-- | @enroll/verify@: check the step-up assertion and return the grant the
-- client presents to @credentials/*@.
--
-- The grant is an 'Assertion' grant: 120 s, digest stored in this session only,
-- and presented as @X-Seal-Enroll-Token@ on the retried @credentials/options@.
-- No failure body carries @grant_token@ or @grant_expires_at@.
enrollVerify :: AccessControlHandle -> Request -> IO (Either AuthErr Value)
enrollVerify h req = do
  body <- readJsonBody req
  case body of
    Left e -> pure (Left e)
    Right obj ->
      -- Order is part of the contract (design §4.1). The type checks, the
      -- mode/session gate and the outstanding-grant check all run before
      -- 'consumeChallenge', so a malformed body, an absent session or an
      -- already-armed grant costs the operator no WebAuthn prompt and burns no
      -- sign counter.
      case (parseGrantMode obj, boolField obj "force") of
        (Left e, _) -> pure (Left e)
        (_, Left e) -> pure (Left e)
        (Right portable, Right force) -> do
          now <- getCurrentTime
          st <- withMVar (achState h) pure
          let sessKey = sessionKeyFromRequest req
          if not (sessionValid now st sessKey)
               || acsMode st /= AccessPasskey
               || credentialAvailability (acsRpId st) (acsCredentials st) /= Usable
            then pure (Left (enrollRefusal GrantRequired))
            else do
              armed <- if portable && not force
                         then liveFileGrant h now
                         else pure Nothing
              case armed of
                Just grant -> pure (Left (grantOutstandingRefusal grant))
                Nothing    -> verifyStepUp h obj st sessKey portable

-- | The assertion half of @enroll/verify@: the body's base64url fields, the
-- challenge, the signature, the sign counter and the mint. Split out only so
-- the checks above read as the ordered contract they are.
verifyStepUp
  :: AccessControlHandle -> Value -> AccessControlState -> Maybe Text -> Bool
  -> IO (Either AuthErr Value)
verifyStepUp h obj st sessKey portable =
  case (,,,) <$> b64Field obj "clientDataJSON"
             <*> b64Field obj "authenticatorData"
             <*> b64Field obj "signature"
             <*> b64Field obj "rawId" of
    Left e -> pure (Left e)
    Right (clientData, authData, signature, rawId) -> do
      let claimedId = TE.decodeUtf8 (B64Url.encodeUnpadded rawId)
      case Map.lookup claimedId (acsCredentials st) of
        Nothing -> pure (Left (enrollRefusal GrantInvalid))
        Just cred
          -- The picker only offers usable credentials, so naming an orphaned
          -- one is forged or racing (design §8.1).
          | Just (credRpId cred) /= acsRpId st ->
              pure (Left (enrollRefusal GrantInvalid))
          | otherwise -> do
              consumed <- maybe (pure False)
                (\c -> consumeChallenge h c ChallengeStepUp sessKey)
                (clientChallenge clientData)
              if not consumed
                then pure (Left (AuthErr status400 "challenge_invalid"
                           "the challenge is missing, expired or already used"))
                else case (acsOrigin st, acsRpId st) of
                  (Just origin, Just rpId) ->
                    case verifyAssertion (credPublicKey cred) AssertionInput
                          { aiClientDataJSON = clientData
                          , aiAuthenticatorData = authData
                          , aiSignature = signature
                          , aiExpectedChallenge = fromMaybeText (clientChallenge clientData)
                          , aiExpectedOrigin = origin
                          , aiExpectedRpId = rpId
                          , aiStoredSignCount = credSignCount cred
                          } of
                      Left e -> pure (Left (webAuthnFailure e))
                      Right newCount -> do
                        bumped <- claimSignCount h claimedId (credSignCount cred) newCount
                        if not bumped
                          then pure (Left (AuthErr status400 "sign_count_regression"
                                    "this assertion was already used"))
                          else do
                            persisted <- persistSignCount h claimedId newCount
                            case persisted of
                              Left err -> pure (Left (AuthErr status500 "write_failed" err))
                              -- One step-up, one mint: the portable branch
                              -- deliberately does not also write a session
                              -- grant, so there is never a live same-device
                              -- token for the client to discard.
                              Right ()
                                | portable  -> mintPortableGrant h
                                | otherwise -> mintAssertionGrant h claimedId sessKey
                  _ -> pure (Left (AuthErr status400 "origin_mismatch"
                              "this gateway has no origin configured"))

-- | Which grant @enroll/verify@ should mint. Absent means the assertion grant,
-- so every pre-existing client keeps working unchanged.
parseGrantMode :: Value -> Either AuthErr Bool
parseGrantMode obj = case field obj "grant" of
  Nothing          -> Right False
  Just "assertion" -> Right False
  Just "portable"  -> Right True
  Just other       -> Left (AuthErr status400 "invalid_grant"
    ("grant must be \"assertion\" or \"portable\", not \"" <> other <> "\""))

-- | @force@ is a JSON boolean, and anything else is a refusal rather than a
-- silent 'fromMaybe False'. A typo here is the difference between "replace the
-- operator's live link" and "leave it alone", which is not a thing to guess at.
boolField :: Value -> Text -> Either AuthErr Bool
boolField (Object o) name = case KeyMap.lookup (Key.fromText name) o of
  Nothing       -> Right False
  Just (Bool b) -> Right b
  Just _        -> Left (AuthErr status400 "invalid_force"
                    ("field \"" <> name <> "\" must be a boolean"))
boolField _ _ = Right False

-- | The live file-backed grant, if any. A pure read: it never mints, reaps or
-- extends anything (design §4.1 step 3).
liveFileGrant :: AccessControlHandle -> UTCTime -> IO (Maybe Grant)
liveFileGrant h now = do
  filed <- loadGrantFile (enrollmentGrantPath (achPaths h))
  pure (filed >>= \grant -> if grantLiveAt now grant then Just grant else Nothing)

-- | 409 for "a grant is already armed". 'outstandingRefusal' is written for a
-- terminal ("re-run with --force, or run `seal access-control enroll
-- --cancel`"), so its prose is not reused here: the panel branches on @code@
-- and renders the remaining lifetime from @expires_at@.
grantOutstandingRefusal :: Grant -> AuthErr
grantOutstandingRefusal grant = AuthErrDetail status409 "grant_outstanding"
  ("an enrollment grant minted via " <> grantSourceText (grSource grant)
     <> " is already armed")
  (object
    [ "minted_via" .= grantSourceText (grSource grant)
    , "expires_at" .= isoTimeText (grExpiresAt grant)
    ])

-- | Mint the portable grant that makes the link work on another device.
--
-- A 'UiToken' file grant: the same authority a terminal-minted token carries,
-- differing only in provenance. Not an 'Assertion' grant — those are bound to
-- the session that earned them and cannot travel.
--
-- 'enrollGrant' runs with @force = True@ because the outstanding case was
-- decided above; any 'Left' here is a write failure, not a live grant.
mintPortableGrant :: AccessControlHandle -> IO (Either AuthErr Value)
mintPortableGrant h = do
  st <- withMVar (achState h) pure
  minted <- enrollGrant (achPaths h) UiToken (defaultTtlFor UiToken) True
  case minted of
    Left err -> pure (Left (AuthErr status500 "write_failed" err))
    Right mg -> case mgToken mg of
      Nothing -> pure (Left (AuthErr status500 "write_failed"
                  "the grant was written without a token"))
      Just token -> pure (Right (object
        [ "ok" .= True
        , "grant_token" .= token
        , "grant_expires_at" .= isoTimeText (grExpiresAt (mgGrant mg))
        , "enroll_url" .= enrollUrlFrom (acsOrigin st) token
        ]))

-- | Compose the handoff link. Built from the boot-resolved origin, never from
-- the request: a link composed from @Host@ would fail the origin check on the
-- other machine, and under DNS rebinding it would be the attacker's origin.
enrollUrlFrom :: Maybe Text -> Text -> Maybe Text
enrollUrlFrom origin token = fmap (<> "/#enroll=" <> token) origin

-- | Write the assertion grant into the session that earned it.
mintAssertionGrant
  :: AccessControlHandle -> Text -> Maybe Text -> IO (Either AuthErr Value)
mintAssertionGrant h _credId mSession = case mSession of
  Nothing -> pure (Left (enrollRefusal GrantRequired))
  Just key -> do
    token <- generateToken 32
    now <- getCurrentTime
    ident <- GrantId <$> generateToken 16
    let grant = Grant
          { grId        = ident
          , grExpiresAt = addUTCTime (fromIntegral assertionGrantTtlSeconds) now
          , grSource    = Assertion
          , grPhase     = GrantMinted
          , grTokenSha  = Just (tokenDigest token)
          }
    modifyMVar_ (achState h) $ \s ->
      let live = Map.filter (grantLiveAt now) (acsSessionGrants s)
      in pure s { acsSessionGrants = Map.insert key grant live }
    pure (Right (object
      [ "ok" .= True
      , "grant_token" .= token
      , "grant_expires_at" .= isoTimeText (grExpiresAt grant)
      ]))

-- | The assertion grant's lifetime (design §7.1). Short on purpose: it is the
-- window between "this is me" and "here is the credential I am adding".
assertionGrantTtlSeconds :: Int
assertionGrantTtlSeconds = 120

isoTimeText :: UTCTime -> Text
isoTimeText = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Atomically bump the stored counter only if it is still what we verified
-- against, so two concurrent replays of one assertion cannot both succeed.
claimSignCount :: AccessControlHandle -> Text -> Int -> Int -> IO Bool
claimSignCount h rawId expected newCount =
  modifyMVar (achState h) $ \st ->
    case Map.lookup rawId (acsCredentials st) of
      Just cred | credSignCount cred == expected ->
        pure (st { acsCredentials = Map.insert rawId cred { credSignCount = newCount }
                                       (acsCredentials st) }, True)
      _ -> pure (st, False)

persistSignCount :: AccessControlHandle -> Text -> Int -> IO (Either Text ())
persistSignCount h rawId newCount = do
  st <- withMVar (achState h) pure
  if Map.member rawId (acsCredentials st)
    then updateCredentialsFile (credentialsFilePath (achPaths h))
           (Right . Map.adjust (\c -> c { cfcSignCount = newCount }) rawId)
    else pure (Right ())


-- | Exponential backoff on failed verifications: 250 ms doubling to a 2 s cap,
-- reset by any success. It delays; it never denies permanently, so it cannot be
-- used to lock the operator out.
backoffAllows :: AccessControlHandle -> UTCTime -> IO Bool
backoffAllows h now = withMVar (achState h) $ \st -> pure (now >= acsRetryAfter st)

recordFailure :: AccessControlHandle -> UTCTime -> IO ()
recordFailure h now = modifyMVar_ (achState h) $ \st ->
  let failures = acsFailures st + 1
      delayMs = min 2000 (250 * (2 ^ max 0 (failures - 1)) :: Int)
  in pure st { acsFailures = failures
             , acsRetryAfter = addUTCTime (fromIntegral delayMs / 1000) now }

resetBackoff :: AccessControlHandle -> IO ()
resetBackoff h = modifyMVar_ (achState h) $ \st ->
  pure st { acsFailures = 0 }

logout :: AccessControlHandle -> Request -> IO ()
logout h req = case sessionKeyFromRequest req of
  Nothing  -> pure ()
  Just key -> modifyMVar_ (achState h) $ \st ->
    pure st { acsSessions = Map.delete key (acsSessions st) }

listCredentials :: AccessControlHandle -> Request -> IO (Either AuthErr Value)
listCredentials h _req = do
  st <- withMVar (achState h) pure
  pure (Right (A.toJSON
    [ object [ "id" .= cid
             , "label" .= credLabel cred
             , "created_at" .= credCreatedAt cred
             , "sign_count" .= credSignCount cred
             , "rp_id" .= credRpId cred
             , "added_via" .= credAddedVia cred
             , "current" .= (Just (credRpId cred) == acsRpId st)
             ]
    | (cid, cred) <- Map.toList (acsCredentials st) ]))

deleteCredential :: AccessControlHandle -> Text -> IO (Either AuthErr Value)
deleteCredential h cid = do
  st <- withMVar (achState h) pure
  let rpId = acsRpId st
      -- With a wildcard bind every credential is usable (design §9.4).
      usable cred = case rpId of
        Nothing -> True
        Just rp -> cfcRpId cred == rp
  -- The guard runs inside the writer, on the freshly loaded map, so two
  -- concurrent deletes cannot each see "one other credential remains" and both
  -- proceed. A read-then-write in the handler could.
  written <- updateCredentialsFile (credentialsFilePath (achPaths h)) $ \creds ->
    let remaining = Map.delete cid creds
        usableLeft = length (filter usable (Map.elems remaining))
    in if Map.member cid creds && usableLeft == 0
         then Left "that is the last passkey that can sign in here; add or fix another before removing it"
         else Right remaining
  case written of
    Left err -> pure (Left (AuthErr status409 "last_credential" err))
    Right () -> do
      modifyMVar_ (achState h) $ \s ->
        pure s { acsCredentials = Map.delete cid (acsCredentials s) }
      auditEvent h (emptyAuditFields Audit.CredentialRemoved)
        { afCredentialId = Just cid
        , afRpId = rpId
        , afOrigin = acsOrigin st
        }
      pure (Right (object ["ok" .= True, "removed" .= cid]))


-- | Consume every outstanding grant after a successful enrollment.
--
-- The file grant, every claim marker and the plaintext token file are removed;
-- session-carried assertion grants are dropped from memory. Sessions are never
-- touched — enrollment does not log anyone out.
clearOutstandingGrants :: AccessControlHandle -> IO ()
clearOutstandingGrants h = do
  cancelGrant (achPaths h)
  modifyMVar_ (achState h) $ \s -> pure s { acsSessionGrants = Map.empty }

-- ---------------------------------------------------------------------------
-- Body / JSON helpers
-- ---------------------------------------------------------------------------

readJsonBody :: Request -> IO (Either AuthErr Value)
readJsonBody req = do
  body <- readBoundedBody req maxAuthBody
  case body of
    Nothing -> pure (Left (AuthErr status413 "body_too_large"
                    "the request body exceeds 64 KiB"))
    Just raw -> case A.eitherDecodeStrict' raw of
      Left e -> pure (Left (AuthErr status400 "malformed_request"
                     ("could not parse the JSON body: " <> T.pack e)))
      Right v -> pure (Right v)

readBoundedBody :: Request -> Int -> IO (Maybe ByteString)
readBoundedBody req limit = go 0 []
  where
    go acc chunks = do
      chunk <- getRequestBodyChunk req
      if BS.null chunk
        then pure (Just (BS.concat (reverse chunks)))
        else
          let acc' = acc + BS.length chunk
          in if acc' > limit
               then pure Nothing
               else go acc' (chunk : chunks)

-- | Read a base64url-encoded byte field and decode it. Every WebAuthn field the
-- browser sends (clientDataJSON, attestationObject, authenticatorData,
-- signature, rawId) is base64url, and the raw bytes are what the verifier and
-- the credential lookup need.
b64Field :: Value -> Text -> Either AuthErr ByteString
b64Field obj name = case field obj name of
  Nothing  -> Left (AuthErr status400 "malformed_request"
             ("missing field \"" <> name <> "\""))
  Just raw -> case B64Url.decodeUnpadded (TE.encodeUtf8 raw) of
    Left e  -> Left (AuthErr status400 "malformed_request"
               ("field \"" <> name <> "\" is not base64url: " <> T.pack e))
    Right b -> Right b

field :: Value -> Text -> Maybe Text
field (Object o) k = case KeyMap.lookup (Key.fromText k) o of
  Just (String s) -> Just s
  _               -> Nothing
field _ _ = Nothing

-- | Read the base64url challenge out of a clientDataJSON blob. The verifier
-- re-parses it; this is only used to find which issued challenge to consume.
clientChallenge :: ByteString -> Maybe Text
clientChallenge raw =
  case A.eitherDecodeStrict' raw :: Either String Value of
    Right (Object o) -> case KeyMap.lookup (Key.fromText "challenge") o of
      Just (String s) -> Just s
      _               -> Nothing
    _ -> Nothing

fromMaybeText :: Maybe Text -> Text
fromMaybeText = fromMaybe ""

webAuthnFailure :: WebAuthnError -> AuthErr
webAuthnFailure e = AuthErr status400 (webAuthnErrorCode e) (webAuthnErrorText e)

--------------------------------------------------------------------------------
-- Boot banner
--------------------------------------------------------------------------------

-- | Tell the operator, on stderr, what access control is in and what authority
-- is armed.
--
-- Moved out of the unexported 'Seal.Command.Serve' so the behaviour is testable
-- with an injected sink (design §11). The TTY decision is an argument for the
-- same reason: the off-TTY path writes @state/enrollment-token@ and prints its
-- path, and the token itself must never reach a log.
--
-- A healthy @passkey@ boot prints neither a token nor a URL, because there is
-- nothing to set up.
printAccessControlBannerTo :: Bool -> (Text -> IO ()) -> SealPaths -> NewAccess -> IO ()
printAccessControlBannerTo stderrIsTTY emit paths access = do
  mode <- accessControlMode (naHandle access)
  count <- accessControlCredentialCount (naHandle access)
  case mode of
    AccessUnconfigured -> do
      emit "Access control is NOT configured — the API is closed until setup completes."
      enrollLines (urlFor "/#enroll=")
    AccessOpen -> do
      emit "Access control is OFF — anyone who can reach this address has full control."
      emit "  (explicitly waived by [access_control] mode = \"none\" in ~/.seal/security.toml)"
      enrollLines (urlFor "/#enroll=")
      emit "  Enrolling turns it back on: the grant below stops a network client from enrolling its own key."
    AccessPasskey -> do
      emit ("Access control: passkey (" <> T.pack (show count) <> " credential(s) enrolled)")
      case naGrant access of
        Just banner | not (gbFresh banner) -> do
          emit "  Keys registered for a different address cannot sign in here."
          grantLines banner
        Just banner -> do
          emit "  No registered key can sign in here — enroll a new one."
          grantLines banner
        Nothing -> pure ()
  where
    urlFor suffix = fmap (<> suffix) (naOrigin access)

    enrollLines mUrl = case naGrant access of
      Just banner -> grantLines banner
      Nothing -> do
        emit "  Run `seal access-control enroll` to mint an enrollment token."
        case mUrl of
          Just _ -> pure ()
          Nothing -> emit "  (no origin resolved yet — set [access_control] origin in security.toml)"

    grantLines banner
      | gbFresh banner = case naToken access of
          Just token
            | stderrIsTTY -> do
                case urlFor "/#enroll=" of
                  Just base -> emit ("  Open  " <> base <> token)
                  Nothing   -> pure ()
                emit ("  Or    paste the token " <> token <> " on the setup screen")
                emit "  It expires in a few minutes and is consumed by a successful enrollment."
            -- Off a terminal the token must never reach stderr: that stream is
            -- a log under systemd or launchd. The operator gets the path.
            | otherwise -> do
                writeSecretFile (enrollmentTokenPath paths) token
                emit ("  Token at " <> T.pack (enrollmentTokenPath paths)
                        <> " (mode 0600) — stderr is not a terminal.")
                emit "  It expires in a few minutes and is consumed by a successful enrollment."
          Nothing -> emit "  Run `seal access-control enroll` to mint an enrollment token."
      | otherwise = do
          emit ("  An enrollment grant minted via " <> grantSourceText (gbSource banner)
                  <> " is still valid for " <> tshowSeconds (gbRemaining banner) <> ".")
          emit "  Paste the token you were given, or run `seal access-control enroll --force`."

tshowSeconds :: NominalDiffTime -> Text
tshowSeconds delta =
  T.pack (show (max 0 (ceiling (realToFrac delta :: Double) :: Int))) <> "s"
