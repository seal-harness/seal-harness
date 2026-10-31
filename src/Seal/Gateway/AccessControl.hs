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
  , newAccessControlHandle
  , accessControlAuthorize
  , accessControlMiddleware
  , accessControlStatusJson
  , accessControlMode
  , accessControlCredentialCount
  , authStatusState
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, withMVar)
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
import Control.Monad (when)
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Network.HTTP.Types
  ( Header, HeaderName, Status, hCookie, methodDelete, methodGet, methodOptions
  , methodPost, status200, status400, status401, status403, status404
  , status409, status413, status429, status500 )
import Network.Wai
  ( Application, Request, Response, getRequestBodyChunk, pathInfo
  , requestHeaders, requestMethod, responseLBS )

import Seal.Config.BootPlan (BootPlan (..))
import Seal.Config.Credentials
  ( createCredentialsFile, loadCredentials, updateCredentialsFile )
import Seal.Config.Paths (SealPaths (..), credentialsFilePath, securityFilePath)
import Seal.Config.Security
  ( AccessControlFileConfig (..), CredentialFileConfig (..)
  , updateAccessControlSection )
import Seal.Security.AccessControl (credentialToFile, rpMismatch)
import Seal.Security.Crypto (constantTimeEq, generateToken, getRandomBytes, sha256Hash)
import Seal.Security.WebAuthn
  ( AssertionInput (..), RegistrationInput (..), RegistrationResult (..)
  , WebAuthnError, verifyAssertion, verifyRegistration, webAuthnErrorCode
  , webAuthnErrorText )
import Seal.Security.WebAuthn.Types
  ( AccessMode (..), Credential (..), accessModeText )

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------

-- | A challenge issued for an in-flight ceremony. Removed on the first verify
-- attempt (consume-on-attempt), never reusable.
data Challenge = Challenge
  { chIssuedAt :: !UTCTime
  , chKind     :: !Text
    -- ^ @\"create\"@ or @\"get\"@, so a challenge cannot be redeemed by the
    -- other ceremony.
  }

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
  }

-- | What a fresh handle hands back for the boot banner.
data NewAccess = NewAccess
  { naHandle       :: AccessControlHandle
  , naSetupCode    :: Maybe Text
  , naServiceToken :: Text
  , naOrigin       :: Maybe Text
  }

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
  mCode <- case bpMintGrant plan of
    Just _  -> Just <$> generateToken 16
    Nothing -> pure Nothing
  st <- newMVar AccessControlState
    { acsMode = bpMode plan
    , acsCredentials = creds
    , acsChallenges = Map.empty
    , acsSessions = Map.empty
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
  pure (NewAccess (AccessControlHandle st paths) mCode serviceToken mOrigin)

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
  , ["api", "auth", "waive"]
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
  let mismatch s = rpMismatch (acsRpId s) (acsCredentials s)
      authenticated = acsMode st == AccessOpen
        || sessionValid now st (sessionKeyFromRequest req)
  pure $ object
    [ "state" .= authStatusState st
    , "authenticated" .= authenticated
    , "origin" .= acsOrigin st
    , "rp_id" .= acsRpId st
    , "rp_mismatch" .= mismatch st
    , "setup_required" .= (acsMode st == AccessUnconfigured || mismatch st)
    , "credentials" .= Map.size (acsCredentials st)
    ]

authStatusState :: AccessControlState -> Text
authStatusState = accessModeText . acsMode

-- ---------------------------------------------------------------------------
-- Tokens, cookies, sessions
-- ---------------------------------------------------------------------------

tokenKey :: Text -> Text
tokenKey = TE.decodeUtf8 . sha256Hash . TE.encodeUtf8

-- | Compare a presented token with a stored hash in constant time.
tokenMatches :: Text -> Maybe Text -> Bool
tokenMatches presented mHash = case mHash of
  Nothing -> False
  Just hashed ->
    constantTimeEq (TE.encodeUtf8 (tokenKey presented)) (TE.encodeUtf8 hashed)

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
issueChallenge :: AccessControlHandle -> Text -> IO (Either AuthErr Text)
issueChallenge h kind = do
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
          pure ( st' { acsChallenges = Map.insert ch (Challenge now kind) live
                     , acsChallengeTokens = acsChallengeTokens st' - 1 }
               , Right ch )

-- | Remove a challenge (consume-on-attempt) and report whether it was present,
-- fresh and of the right ceremony.
consumeChallenge :: AccessControlHandle -> Text -> Text -> IO Bool
consumeChallenge h presented kind = do
  now <- getCurrentTime
  modifyMVar (achState h) $ \st ->
    case Map.lookup presented (acsChallenges st) of
      Just ch | chKind ch == kind && challengeFresh now ch ->
        pure (st { acsChallenges = Map.delete presented (acsChallenges st) }, True)
      _ -> pure (st, False)

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

data AuthErr = AuthErr Status Text Text
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

respondResult :: [Header] -> Either AuthErr Value -> Response
respondResult extra result = case result of
  Left (AuthErr st code msg) -> authError st code msg
  Right v                    -> authOk extra v

-- | Like 'respondResult', for handlers that mint a session and therefore carry
-- a @Set-Cookie@ header back.
respondSession :: Either AuthErr (Value, [Header]) -> Response
respondSession result = case result of
  Left (AuthErr st code msg)  -> authError st code msg
  Right (v, extra)            -> authOk extra v

-- ---------------------------------------------------------------------------
-- The auth API
-- ---------------------------------------------------------------------------

authApp :: AccessControlHandle -> Application
authApp h req respond =
  case (requestMethod req, pathInfo req) of
    (m, ["api", "auth", "status"]) | m == methodGet ->
      accessControlStatusJson h req >>= respond . authOk []

    (m, ["api", "auth", "register", "options"]) | m == methodPost -> do
      result <- withSetupAuthorization h req (registerOptions h)
      respond (respondResult [] result)

    (m, ["api", "auth", "register", "verify"]) | m == methodPost -> do
      result <- withSetupAuthorization h req (verifyRegistrationEndpoints h False)
      respond (respondSession result)

    (m, ["api", "auth", "login", "options"]) | m == methodPost -> do
      result <- loginOptions h
      respond (respondResult [] result)

    (m, ["api", "auth", "login", "verify"]) | m == methodPost -> do
      result <- loginVerify h req
      respond (respondSession result)

    (m, ["api", "auth", "waive"]) | m == methodPost -> do
      -- The mode is checked before the setup code: in passkey mode there is no
      -- setup code to present, and the honest answer is "waiving is not
      -- something a network request can do".
      result <- waive h req
      respond (respondResult [] result)

    (m, ["api", "auth", "logout"]) | m == methodPost -> do
      logout h req
      -- Clearing the cookie (not just forgetting the session) matters: the
      -- cookie is persistent (24 h idle), so a browser would otherwise keep
      -- presenting a token the server ignores for the rest of the day.
      cleared <- clearedSessionCookie h
      respond (authOk [cleared] (object ["ok" .= True]))

    (m, ["api", "auth", "credentials"]) | m == methodGet -> do
      result <- withSessionAuthorization h req (listCredentials h)
      respond (respondResult [] result)

    (m, ["api", "auth", "credentials", "options"]) | m == methodPost -> do
      result <- withSessionAuthorization h req (registerOptions h)
      respond (respondResult [] result)

    (m, ["api", "auth", "credentials", "verify"]) | m == methodPost -> do
      result <- withSessionAuthorization h req (verifyRegistrationEndpoints h True)
      respond (respondSession result)

    (m, ["api", "auth", "credentials", cid]) | m == methodDelete -> do
      result <- withSessionAuthorization h req (const (deleteCredential h cid))
      respond (respondResult [] result)

    _ -> respond (authError status404 "not_found" "no such endpoint")

-- | The setup-code gate: every enrollment path when the gateway is not yet in a
-- healthy @passkey@ state.
withSetupAuthorization
  :: AccessControlHandle -> Request -> (Request -> IO (Either AuthErr a))
  -> IO (Either AuthErr a)
withSetupAuthorization h req action = do
  allowed <- checkSetupCode h req
  case allowed of
    Left e    -> pure (Left e)
    Right ()  -> action req

-- | The session gate. In a healthy @passkey@ state the browser must hold a
-- session; otherwise (open \/ unconfigured \/ orphaned-rpId) the setup code is
-- what authorises the change, so a remote client cannot enroll a credential and
-- flip the gateway into passkey mode.
withSessionAuthorization
  :: AccessControlHandle -> Request -> (Request -> IO (Either AuthErr a))
  -> IO (Either AuthErr a)
withSessionAuthorization h req action = do
  st <- withMVar (achState h) pure
  if acsMode st == AccessPasskey && not (rpMismatch (acsRpId st) (acsCredentials st))
    then do
      now <- getCurrentTime
      if sessionValid now st (sessionKeyFromRequest req)
        then action req
        else pure (Left (AuthErr status401 "unauthenticated" "a passkey session is required"))
    else withSetupAuthorization h req action

checkSetupCode :: AccessControlHandle -> Request -> IO (Either AuthErr ())
checkSetupCode h req = do
  st <- withMVar (achState h) pure
  case acsSetupHash st of
    Nothing -> pure (Left (AuthErr status403 "setup_code_required"
                     "no setup code is active; restart `seal serve` to get one"))
    Just hashed -> case setupCodeHeader req of
      Nothing -> pure (Left (AuthErr status403 "setup_code_required"
                       "missing X-Seal-Setup-Token header"))
      Just code
        | tokenMatches code (Just hashed) -> pure (Right ())
        | otherwise -> pure (Left (AuthErr status403 "setup_code_invalid"
                             "the setup code is wrong"))

setupCodeHeader :: Request -> Maybe Text
setupCodeHeader req =
  case lookup "X-Seal-Setup-Token" (requestHeaders req) of
    Nothing  -> Nothing
    Just raw -> let t = T.strip (TE.decodeUtf8Lenient raw) in if T.null t then Nothing else Just t

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

registerOptions :: AccessControlHandle -> Request -> IO (Either AuthErr Value)
registerOptions h _req = do
  st <- withMVar (achState h) pure
  case (acsOrigin st, acsRpId st) of
    (_, Nothing) -> pure (Left (AuthErr status400 "origin_mismatch"
                         "this gateway has no relying-party id configured"))
    (Nothing, _) -> pure (Left (AuthErr status400 "origin_mismatch"
                         "this gateway has no origin configured"))
    (Just _, Just rpId) -> do
      challenge <- issueChallenge h "create"
      case challenge of
        Left e      -> pure (Left e)
        Right value -> do
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
      challenge <- issueChallenge h "get"
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
  :: AccessControlHandle -> Bool -> Request -> IO (Either AuthErr (Value, [Header]))
verifyRegistrationEndpoints h isAdd req = do
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
          consumed <- maybe (pure False) (\c -> consumeChallenge h c "create")
                                           presentedChallenge
          if not consumed
            then pure (Left (AuthErr status400 "challenge_invalid"
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
                    Right result -> persistRegistration h isAdd result now
                _ -> pure (Left (AuthErr status400 "origin_mismatch"
                            "this gateway has no origin configured"))
        Left e -> pure (Left e)

persistRegistration
  :: AccessControlHandle -> Bool -> RegistrationResult -> UTCTime
  -> IO (Either AuthErr (Value, [Header]))
persistRegistration h isAdd result now = do
  st <- withMVar (achState h) pure
  let rawId = TE.decodeUtf8 (B64Url.encodeUnpadded (rrCredentialId result))
      cred = Credential
        { credId = rrCredentialId result
        , credPublicKey = rrPublicKey result
        , credSignCount = rrSignCount result
        , credLabel = "passkey"
        , credCreatedAt = now
        , credRpId = fromMaybeText (acsRpId st)
        }
  -- Mode first, credential second (design §6.1). A crash between the two leaves
  -- passkey mode with no credentials, which resolves to the loud, grant-gated
  -- bootstrap. The other order would leave a credential on a still-open
  -- gateway: silent non-enforcement.
  raised <- updateAccessControlSection (securityFilePath (achPaths h))
              (\cfg -> cfg { acfcMode = Just "passkey" })
  case raised of
    Left err -> pure (Left (AuthErr status500 "write_failed" err))
    Right _ -> do
      written <- upsertCredential (achPaths h) rawId (credentialToFile cred)
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
          clearSetupCodeFile h
          token <- mintSession h
          cookie <- sessionCookie h token
          pure (Right ( object
            [ "ok" .= True
            , "credential" .= rawId
            , "added" .= isAdd
            ]
            , [cookie] ))

-- | Add or replace one credential in @credentials.toml@.
--
-- Creates the store when it does not exist (the first enrollment) and updates
-- it otherwise. 'updateCredentialsFile' refuses a missing file on purpose, so
-- the absent case is its own branch rather than a read-then-write that could
-- race another process creating the file in between.
upsertCredential :: SealPaths -> Text -> CredentialFileConfig -> IO (Either Text ())
upsertCredential paths rawId cfg = do
  let path = credentialsFilePath paths
  existing <- loadCredentials path
  case existing of
    Right Nothing -> createCredentialsFile path (Map.singleton rawId cfg)
    _             -> updateCredentialsFile path (Right . Map.insert rawId cfg)


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
                                    (\c -> consumeChallenge h c "get")
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

waive :: AccessControlHandle -> Request -> IO (Either AuthErr Value)
waive h req = do
  st <- withMVar (achState h) pure
  if acsMode st == AccessPasskey
    then pure (Left (AuthErr status403 "waive_forbidden"
               "access control is already configured; edit ~/.seal/security.toml or run `seal access-control reset --yes`"))
    else do
      allowed <- checkSetupCode h req
      case allowed of
        Left e -> pure (Left e)
        Right () -> do
          written <- updateAccessControlSection (securityFilePath (achPaths h)) $ \cfg ->
            cfg { acfcMode = Just "none" }
          case written of
            Left err -> pure (Left (AuthErr status500 "write_failed" err))
            Right _ -> do
              modifyMVar_ (achState h) $ \s -> pure s
                { acsMode = AccessOpen, acsSetupCode = Nothing, acsSetupHash = Nothing }
              clearSetupCodeFile h
              pure (Right (object ["ok" .= True, "mode" .= ("none" :: Text)]))

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
             , "current" .= (Just (credRpId cred) == acsRpId st)
             ]
    | (cid, cred) <- Map.toList (acsCredentials st) ]))

deleteCredential :: AccessControlHandle -> Text -> IO (Either AuthErr Value)
deleteCredential h cid = do
  -- The guard runs inside the writer, on the freshly loaded map, so two
  -- concurrent deletes cannot each see "one other credential remains" and both
  -- proceed. A read-then-write in the handler could.
  written <- updateCredentialsFile (credentialsFilePath (achPaths h)) $ \creds ->
    if Map.size creds <= 1 && Map.member cid creds
      then Left "that is the only passkey; add another before removing it"
      else Right (Map.delete cid creds)
  case written of
    Left err -> pure (Left (AuthErr status409 "last_credential" err))
    Right () -> do
      modifyMVar_ (achState h) $ \s ->
        pure s { acsCredentials = Map.delete cid (acsCredentials s) }
      pure (Right (object ["ok" .= True, "removed" .= cid]))


-- | The setup code has been spent, so the non-interactive copy on disk (written
-- by `seal serve` when stderr is not a TTY) must go too.
clearSetupCodeFile :: AccessControlHandle -> IO ()
clearSetupCodeFile h = do
  let path = spState (achPaths h) </> "setup-code"
  exists <- doesFileExist path
  when exists (removeFile path)

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
