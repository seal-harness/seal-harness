{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the gateway's access-control gate and its auth endpoints.
--
-- The login test is a full ceremony: it generates a P-256 key with crypton,
-- enrolls the public half, then signs a real assertion for the challenge the
-- server issued. That exercises challenge issuance and consumption, origin and
-- rpId checking, signature verification, the sign-counter bump, session
-- minting and the cookie — end to end, without a browser.
module Seal.Gateway.AccessControlSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (shiftR, (.&.))
import Data.ByteString.Builder (toLazyByteString)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64Url
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive (mk)
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (Header, Status, methodGet, methodPost)
import Network.HTTP.Types.Header (hSetCookie)
import Network.Wai
  ( Application, Request, Response, defaultRequest, pathInfo
  , requestHeaders, requestMethod, responseLBS, responseToStream
  , setRequestBodyChunks )
import Network.Wai.Internal (ResponseReceived (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Crypto.Hash (Digest, SHA256 (..), hash)
import Crypto.PubKey.ECC.ECDSA (PublicKey (..), Signature (..), sign)
import Crypto.PubKey.ECC.Generate (generate)
import Crypto.PubKey.ECC.Types (CurveName (SEC_p256r1), Point (..), getCurveByName)
import Data.ByteArray (convert)

import Seal.Config.Paths (SealPaths (..), securityFilePath)
import Seal.Config.Security
  ( AccessControlFileConfig (..), CredentialFileConfig (..), SecurityConfig (..)
  , defaultSecurityConfig, loadSecurityConfig, saveSecurityConfig )
import Seal.Gateway.AccessControl
import Seal.Gateway.Config (defaultGatewayConfig)
import Seal.Security.WebAuthn.Types (AccessMode (..))

spec :: Spec
spec = describe "Seal.Gateway.AccessControl" $ do
  describe "unconfigured" $ do
    it "closes the API" $ withHome Nothing $ \paths -> do
      na <- newAccessControlHandle paths defaultGatewayConfig Nothing
      (st, _, _) <- runApp (gated na) (getReq ["api", "sessions"])
      st `shouldBe` status403'

    it "serves the status endpoint" $ withHome Nothing $ \paths -> do
      na <- newAccessControlHandle paths defaultGatewayConfig Nothing
      (st, _, body) <- runApp (gated na) (getReq ["api", "auth", "status"])
      st `shouldBe` status200'
      jsonField body "state" `shouldBe` Just (String "unconfigured")
      jsonField body "setup_required" `shouldBe` Just (Bool True)

    it "lets the health probe and the static bundle through" $
      withHome Nothing $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig Nothing
        (st1, _, _) <- runApp (gated na) (getReq ["api", "health"])
        st1 `shouldBe` status200'
        (st2, _, _) <- runApp (gated na) (getReq ["assets", "index.js"])
        st2 `shouldBe` status200'

    it "rejects enrollment without the setup code" $ withHome Nothing $ \paths -> do
      na <- newAccessControlHandle paths defaultGatewayConfig Nothing
      (st, _, body) <- runApp (gated na)
        (postReq ["api", "auth", "register", "options"] [])
      st `shouldBe` status403'
      jsonField body "code" `shouldBe` Just (String "setup_code_required")

    it "rejects enrollment with a wrong setup code" $ withHome Nothing $ \paths -> do
      na <- newAccessControlHandle paths defaultGatewayConfig Nothing
      (st, _, body) <- runApp (gated na)
        (postReq ["api", "auth", "register", "options"] [("X-Seal-Setup-Token", "nope")])
      st `shouldBe` status403'
      jsonField body "code" `shouldBe` Just (String "setup_code_invalid")

    it "returns registration options with the right setup code" $
      withHome Nothing $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig Nothing
        code <- setupCodeOf na
        (st, _, body) <- runApp (gated na)
          (postReq ["api", "auth", "register", "options"] [("X-Seal-Setup-Token", code)])
        st `shouldBe` status200'
        jsonField body "challenge" `shouldSatisfy` isNonEmptyValue
        jsonField body "attestation" `shouldBe` Just (String "none")

  describe "status payload" $ do
    it "reports the three states with the UI's vocabulary" $ do
      -- unconfigured
      withHome Nothing $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig Nothing
        (_, _, body) <- runApp (gated na) (getReq ["api", "auth", "status"])
        jsonField body "state" `shouldBe` Just (String "unconfigured")
      -- open
      withHome Nothing $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig Nothing
        code <- setupCodeOf na
        _ <- runApp (gated na) (postReq ["api", "auth", "waive"] [("X-Seal-Setup-Token", code)])
        (_, _, body) <- runApp (gated na) (getReq ["api", "auth", "status"])
        jsonField body "state" `shouldBe` Just (String "open")
        jsonField body "authenticated" `shouldBe` Just (Bool True)
        jsonField body "setup_required" `shouldBe` Just (Bool False)
      -- passkey
      withHome (Just passkeySection) $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig (Just passkeySection)
        (_, _, body) <- runApp (gated na) (getReq ["api", "auth", "status"])
        jsonField body "state" `shouldBe` Just (String "passkey")
        jsonField body "authenticated" `shouldBe` Just (Bool False)
        jsonField body "setup_required" `shouldBe` Just (Bool False)
        jsonField body "rp_id" `shouldBe` Just (String "localhost")

  describe "waive" $ do
    it "records mode = none and opens the API" $ withHome Nothing $ \paths -> do
      na <- newAccessControlHandle paths defaultGatewayConfig Nothing
      code <- setupCodeOf na
      (st, _, _) <- runApp (gated na)
        (postReq ["api", "auth", "waive"] [("X-Seal-Setup-Token", code)])
      st `shouldBe` status200'
      accessControlMode (naHandle na) `shouldReturn` AccessOpen
      (st2, _, _) <- runApp (gated na) (getReq ["api", "sessions"])
      st2 `shouldBe` status200'
      loaded <- readSection paths
      fmap acfcMode loaded `shouldBe` Just (Just "none")

    it "is refused when a passkey is already configured" $
      withHome (Just passkeySection) $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig (Just passkeySection)
        let code = fromMaybe "" (naSetupCode na)
        (st, _, body) <- runApp (gated na)
          (postReq ["api", "auth", "waive"] [("X-Seal-Setup-Token", code)])
        st `shouldBe` status403'
        jsonField body "code" `shouldBe` Just (String "waive_forbidden")

  describe "passkey mode" $ do
    it "rejects an unauthenticated API request" $ withHome (Just passkeySection) $ \paths -> do
      na <- newAccessControlHandle paths defaultGatewayConfig (Just passkeySection)
      (st, _, body) <- runApp (gated na) (getReq ["api", "sessions"])
      st `shouldBe` status401'
      jsonField body "code" `shouldBe` Just (String "unauthenticated")

    it "accepts the in-process service token on non-auth paths" $
      withHome (Just passkeySection) $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig (Just passkeySection)
        (st, _, _) <- runApp (gated na)
          (getReqWith ["api", "sessions"]
             [("Authorization", "Bearer " <> naServiceToken na)])
        st `shouldBe` status200'

    it "refuses the service token on auth paths" $
      withHome (Just passkeySection) $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig (Just passkeySection)
        (st, _, _) <- runApp (gated na)
          (getReqWith ["api", "auth", "credentials"]
             [("Authorization", "Bearer " <> naServiceToken na)])
        st `shouldBe` status401'

    it "authenticates a full WebAuthn login ceremony" $
      withHome Nothing $ \paths -> do
        -- 1. Enroll a credential whose private key we hold.
        (pub, priv) <- generate (getCurveByName SEC_p256r1)
        let credId = BS.replicate 16 0x5a
            key64 = pointBytes (public_q pub)
            section = AccessControlFileConfig
              { acfcMode = Just "passkey"
              , acfcOrigin = Nothing
              , acfcRpId = Nothing
              , acfcCredentials = credMap credId key64
              }
        writeSection paths section
        na <- newAccessControlHandle paths defaultGatewayConfig (Just section)
        accessControlMode (naHandle na) `shouldReturn` AccessPasskey

        -- 2. Ask for login options and read the challenge we must sign.
        (stOpts, _, opts) <- runApp (gated na)
          (postReq ["api", "auth", "login", "options"] [])
        stOpts `shouldBe` status200'
        challenge <- case jsonField opts "challenge" of
          Just (String c) -> pure c
          _               -> expectationFailure "no challenge" >> pure ""

        -- 3. Build a real assertion for it.
        let clientData = clientDataJSON "webauthn.get" challenge "http://localhost:8080"
            authData = assertionAuthData 2
            message = authData <> sha256Raw clientData
        sig <- sign priv SHA256 message
        let body = object
              [ "clientDataJSON" .= b64 clientData
              , "authenticatorData" .= b64 authData
              , "signature" .= b64 (encodeDerSig sig)
              , "rawId" .= b64 credId
              ]

        -- 4. Verify: a session cookie comes back.
        verifyReq <- postJson ["api", "auth", "login", "verify"] body
        (stVerify, headers', resp) <- runApp (gated na) verifyReq
        stVerify `shouldBe` status200'
        jsonField resp "ok" `shouldBe` Just (Bool True)
        let mCookie = cookieToken <$> lookup hSetCookie headers'
        mCookie `shouldSatisfy` isNonEmptyString
        case mCookie of
          Nothing -> expectationFailure "no session cookie"
          Just c -> do
            -- 5. The cookie opens the API.
            (stAuth, _, _) <- runApp (gated na)
              (getReqWith ["api", "sessions"] [("Cookie", "seal_session=" <> c)])
            stAuth `shouldBe` status200'

        -- 6. Replaying the same assertion is refused (counter consumed).
        replayReq <- postJson ["api", "auth", "login", "verify"] body
        (stReplay, _, replayBody) <- runApp (gated na) replayReq
        stReplay `shouldBe` status400'
        jsonField replayBody "code" `shouldBe` Just (String "challenge_invalid")

  describe "rate limiting" $
    it "returns 429 once the challenge budget is spent" $
      withHome Nothing $ \paths -> do
        na <- newAccessControlHandle paths defaultGatewayConfig Nothing
        code <- setupCodeOf na
        statuses <- mapM (\_ -> do
            (st, _, _) <- runApp (gated na)
              (postReq ["api", "auth", "register", "options"]
                 [("X-Seal-Setup-Token", code)])
            pure st) ([1 .. 25] :: [Int])
        length (filter (== status200') statuses) `shouldBe` 20
        length (filter (== status429') statuses) `shouldBe` 5

-- Helpers ------------------------------------------------------------------

status200', status400', status401', status403', status429' :: Status
status200' = toEnum 200
status400' = toEnum 400
status401' = toEnum 401
status403' = toEnum 403
status429' = toEnum 429

-- | Mirror the production placement: the gate wraps only the @\/api\/*@ branch,
-- so the static bundle is always served.
gated :: NewAccess -> Application
gated na req respond =
  case pathInfo req of
    ("api" : _) -> accessControlMiddleware (naHandle na) okApp req respond
    _           -> okApp req respond

okApp :: Application
okApp _ respond = respond (responseLBS status200' [] "ok")

-- | Run a WAI app and collect status, headers and the full body.
runApp :: Application -> Request -> IO (Status, [Header], BL.ByteString)
runApp app req = do
  mv <- newEmptyMVar
  _ <- app req $ \resp -> do
    triple <- drainResponse resp
    putMVar mv triple
    pure ResponseReceived
  takeMVar mv

-- | Collect the status, headers and body of a response.
drainResponse :: Response -> IO (Status, [Header], BL.ByteString)
drainResponse resp = do
  let (st, hs, withBody) = responseToStream resp
  body <- withBody $ \streamingBody -> do
    builderRef <- newIORef mempty
    streamingBody (\builder -> modifyIORef' builderRef (<> builder)) (pure ())
    toLazyByteString <$> readIORef builderRef
  pure (st, hs, body)

jsonField :: BL.ByteString -> Text -> Maybe Value
jsonField raw k = case A.decode raw of
  Just (Object o) -> KeyMap.lookup (Key.fromText k) o
  _               -> Nothing

isNonEmptyString :: Maybe Text -> Bool
isNonEmptyString (Just t) = not (T.null t)
isNonEmptyString Nothing  = False

isNonEmptyValue :: Maybe Value -> Bool
isNonEmptyValue (Just (String t)) = not (T.null t)
isNonEmptyValue _                 = False

cookieToken :: BS.ByteString -> Text
cookieToken raw =
  let t = TE.decodeUtf8 raw
  in case T.stripPrefix "seal_session=" t of
       Just rest -> T.takeWhile (/= ';') rest
       Nothing   -> ""

setupCodeOf :: NewAccess -> IO Text
setupCodeOf na = case naSetupCode na of
  Just c  -> pure c
  Nothing -> expectationFailure "expected a setup code" >> pure ""

getReq :: [Text] -> Request
getReq segs = getReqWith segs []

getReqWith :: [Text] -> [(Text, Text)] -> Request
getReqWith segs hs = setRequestBodyChunks (pure BS.empty) defaultRequest
  { requestMethod = methodGet
  , pathInfo = segs
  , requestHeaders = [(mk (TE.encodeUtf8 k), TE.encodeUtf8 v) | (k, v) <- hs]
  }

postReq :: [Text] -> [(Text, Text)] -> Request
postReq segs hs = (getReqWith segs hs) { requestMethod = methodPost }

-- | A one-shot request body: the chunk source yields the payload, then an empty
-- chunk, exactly as a real WAI server does.
postJson :: [Text] -> Value -> IO Request
postJson segs body = do
  ref <- newIORef [BL.toStrict (A.encode body)]
  let nextChunk = atomicModifyIORef' ref $ \case
        []     -> ([], BS.empty)
        (c:cs) -> (cs, c)
  pure (setRequestBodyChunks nextChunk (postReq segs [("Content-Type", "application/json")]))

withHome :: Maybe AccessControlFileConfig -> (SealPaths -> IO a) -> IO a
withHome mSection action = withSystemTempDirectory "seal-ac-gw" $ \dir -> do
  let paths = SealPaths { spHome = dir
                        , spState = dir </> "state"
                        , spConfig = dir </> "config"
                        , spKeys = dir </> "keys"
                        , spCache = dir </> "cache"
                        }
  for_ mSection (writeSection paths)
  action paths

writeSection :: SealPaths -> AccessControlFileConfig -> IO ()
writeSection paths section = do
  createDirectoryIfMissing True (spConfig paths)
  saveSecurityConfig (securityFilePath paths)
    defaultSecurityConfig { scAccessControl = Just section }

readSection :: SealPaths -> IO (Maybe AccessControlFileConfig)
readSection paths = do
  loaded <- loadSecurityConfig (securityFilePath paths)
  pure (either (const Nothing) scAccessControl loaded)

passkeySection :: AccessControlFileConfig
passkeySection = AccessControlFileConfig
  { acfcMode = Just "passkey"
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  , acfcCredentials = credMap (BS.replicate 16 0x11) (BS.replicate 64 0x02)
  }

credMap :: ByteString -> ByteString -> Map.Map Text CredentialFileConfig
credMap credId key64 = Map.singleton (b64 credId) CredentialFileConfig
  { cfcPublicKey = b64 key64
  , cfcSignCount = 1
  , cfcLabel = "test key"
  , cfcCreatedAt = "2026-10-30T14:00:00Z"
  , cfcRpId = "localhost"
  }

pointBytes :: Point -> ByteString
pointBytes (Point x y) = be32 x <> be32 y
pointBytes PointO       = BS.replicate 64 0

-- | Big-endian, fixed width.
beN :: Int -> Integer -> ByteString
beN width n =
  BS.pack [fromIntegral ((n `shiftR` (8 * i)) .&. 0xff) | i <- [width - 1, width - 2 .. 0]]

be32 :: Integer -> ByteString
be32 = beN 32

clientDataJSON :: Text -> Text -> Text -> ByteString
clientDataJSON typ challenge origin = BL.toStrict (A.encode (object
  [ "type" .= typ
  , "challenge" .= challenge
  , "origin" .= origin
  , "crossOrigin" .= False
  ]))

assertionAuthData :: Int -> ByteString
assertionAuthData counter =
  sha256Raw "localhost" <> BS.singleton 0x05 <> beN 4 (fromIntegral counter)

sha256Raw :: ByteString -> ByteString
sha256Raw = convert . (hash :: ByteString -> Digest SHA256)

encodeDerSig :: Signature -> ByteString
encodeDerSig (Signature r s) =
  let body = encInt r <> encInt s
  in BS.singleton 0x30 <> encLen (BS.length body) <> body
  where
    encInt n =
      let raw = unsigned n
          padded = case BS.uncons raw of
            Just (b, _) | b >= 0x80 -> BS.cons 0x00 raw
            _                       -> raw
      in BS.singleton 0x02 <> encLen (BS.length padded) <> padded
    unsigned n
      | n < 256 = BS.singleton (fromIntegral n)
      | otherwise = unsigned (n `div` 256) <> BS.singleton (fromIntegral (n `mod` 256))
    encLen n
      | n < 0x80 = BS.singleton (fromIntegral n)
      | otherwise =
          let b = unsigned (toInteger n)
          in BS.singleton (0x80 + fromIntegral (BS.length b)) <> b

b64 :: ByteString -> Text
b64 = TE.decodeUtf8 . B64Url.encodeUnpadded
