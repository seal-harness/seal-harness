{-# LANGUAGE OverloadedStrings #-}
-- | TLS material for the gateway, generated with @openssl@.
--
-- Shelling out is deliberate and matches 'Seal.Security.Vault.Age' shelling out
-- to @age@: X.509 generation is a large encoder that is easy to get subtly
-- wrong, and a fixed-argv invocation of the system @openssl@ is both smaller
-- and more likely to be correct than a hand-rolled one. The argv is never built
-- from request data — the only interpolated values are the operator's own host
-- names, passed as argv elements and, for the subject alternative names,
-- through a generated OpenSSL config file.
--
-- __Two limits drive everything here.__ A browser rejects a certificate whose
-- validity exceeds 398 days (@ERR_CERT_VALIDITY_TOO_LONG@) and rejects one
-- whose names do not match the URL (@ERR_CERT_COMMON_NAME_INVALID@); neither is
-- an interstitial the user can click through. So the generated pair is valid
-- for 'certificateLifetimeDays' and carries every name and address the gateway
-- can be reached at.
--
-- __A generated certificate does not make passkeys work by itself.__ Since
-- Chrome 110 a browser disables WebAuthn outright on a certificate it does not
-- trust, and clicking through the interstitial does not help. The certificate
-- has to be installed on the client device, and it has to name a hostname: a
-- WebAuthn RP ID can never be an IP address. This module exists so an operator
-- can stand up encrypted transport without a proxy, not so that the trust step
-- disappears.
module Seal.Security.TlsCert
  ( -- * Managing the pair on disk
    TlsCertOutcome (..)
  , ensureGeneratedCertificate
  , ensureCertificateAt
  , ensureTlsCertificateWith
  , readCertificateValidity
  , certificateDefect
  , certificateSans
  , certificateExpiryWarning
  , expiryWarning
  , certificateLifetimeDays
    -- * The names in the certificate
  , SanInputs (..)
  , SanName (..)
  , sanInputsFor
  , sanHostsFor
  , classifySanName
  , renderOpensslConfig
    -- * Local addresses
  , addressNamesFor
  , localAddressNames
  , localAddressNamesWith
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM_, void, when)
import Crypto.PubKey.RSA.Types (private_pub)
import Data.Bits (shiftL, shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Hourglass (Month (..), dateDay, dateMonth, dateYear, dtDate)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word32)
import Data.Time.Calendar (Day, diffDays, fromGregorianValid)
import Data.Time.Clock (getCurrentTime, utctDay)
import Data.X509
  ( AltName (..), Certificate (..), ExtSubjectAltName (..), PrivKey (PrivKeyRSA)
  , PubKey (PubKeyRSA), SignedCertificate, certPubKey, extensionGet, getCertificate )
import Data.X509.File (readKeyFile, readSignedObject)
import Network.Info (NetworkInterface (..), getNetworkInterfaces)
import Network.TLS (credentialLoadX509)
import Numeric (readHex, showHex)
import System.Directory
  ( copyFile, createDirectoryIfMissing, doesFileExist, removeFile, renameFile )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)

import Seal.Gateway.Config (GatewayConfig (..))
import Seal.Security.AccessControl (isIpLiteral)

-- | How long a generated certificate is valid.
--
-- 397, not 398: the 398-day browser limit is applied inclusively, and tools
-- round the boundary differently. 398 is the number in the standards and 397
-- is the number that works.
certificateLifetimeDays :: Int
certificateLifetimeDays = 397

-- | What 'ensureGeneratedCertificate' / 'ensureCertificateAt' did.
data TlsCertOutcome
  = TlsCertCreated
    -- ^ No pair existed; one was generated.
  | TlsCertReplaced Text
    -- ^ An existing pair could not serve a legal certificate; the 'Text' says
    -- why. The previous pair is kept as @*.bak@.
  | TlsCertUnchanged
    -- ^ A pair was already there and was left alone.
  deriving stock (Eq, Show)

-- | The names to put in the certificate.
--
-- Every input is explicit so the mapping from configuration to SAN list is a
-- pure function that a test can pin down, rather than six lines inside boot
-- wiring that nothing exercises.
data SanInputs = SanInputs
  { siConfigured  :: [Text]
    -- ^ @[gateway] tls_hosts@, in operator order.
  , siBindHost    :: Text
    -- ^ @[gateway] host@.
  , siMachineName :: Text
    -- ^ This machine's hostname.
  , siOriginName  :: Maybe Text
    -- ^ Host of @[access_control] origin@ — the name passkeys are bound to.
  , siAddresses   :: [Text]
    -- ^ Local interface addresses.
  }
  deriving stock (Eq, Show)

-- | A name as it has to be rendered in the SAN extension.
data SanName
  = SanDns Text
  | SanIp Text
  deriving stock (Eq, Show)

-- | Build the SAN inputs from a gateway config plus what only the caller can
-- discover (the hostname, the origin host, the interface addresses).
sanInputsFor :: GatewayConfig -> Text -> Maybe Text -> [Text] -> SanInputs
sanInputsFor cfg machineName originName addresses = SanInputs
  { siConfigured  = gcTlsHosts cfg
  , siBindHost    = gcHost cfg
  , siMachineName = machineName
  , siOriginName  = originName
  , siAddresses   = addresses
  }

-- | The SAN list, in the order it is written (the first entry becomes the CN).
--
-- Operator-configured names come first because that is the name they said they
-- use; everything else is derived, and @localhost@ plus both loopback literals
-- are always present so a pair generated on this host is usable on this host.
sanHostsFor :: SanInputs -> [Text]
sanHostsFor si = dedupe (filter (not . T.null) ordered)
  where
    ordered =
      map normaliseName (siConfigured si)
        <> foldMap (pure . normaliseName) (siOriginName si)
        <> [normaliseName (siBindHost si) | namedHost]
        <> [normaliseName (siMachineName si) | machineNamed]
        <> map normaliseName (siAddresses si)
        <> ["localhost", "127.0.0.1", "::1"]
    namedHost = normaliseName (siBindHost si) `notElem` ["0.0.0.0", "::", "*", ""]
    machineNamed = not (T.null (normaliseName (siMachineName si)))

-- | DNS names are case-insensitive, so they are lower-cased; an IPv6 zone id
-- (@%en0@) is not part of the address and is dropped. Brackets are stripped
-- because 'isIpLiteral' tolerates them but OpenSSL will not accept @[::1]@ as
-- the value of an @IP.n@ entry.
normaliseName :: Text -> Text
normaliseName raw
  | T.isInfixOf ":" debracketed = fst (T.breakOn "%" debracketed)
  | otherwise                   = T.toLower debracketed
  where
    debracketed = T.dropAround (\c -> c == '[' || c == ']') (T.strip raw)

-- | Pick the SAN key: @IP.n@ for a literal address, @DNS.n@ for a name.
classifySanName :: Text -> SanName
classifySanName raw
  | isIpLiteral normalised = SanIp normalised
  | otherwise              = SanDns normalised
  where
    normalised = normaliseName raw

tshow :: Show a => a -> Text
tshow = T.pack . show

dedupe :: [Text] -> [Text]
dedupe = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member (T.toLower x) seen = go seen xs
      | otherwise                     = x : go (Set.insert (T.toLower x) seen) xs

-- | Filter and normalise the address texts an enumeration produced.
--
-- Pure and text-based on purpose: @Network.Info@ stores addresses in
-- socket byte order, so its numeric fields are host-endianness dependent while
-- its rendered form is not. Keeping the filtering on text means the rules
-- (drop the all-zero "family not present" address, drop duplicates, agree with
-- the compressed literals 'sanHostsFor' always adds) are testable without
-- reproducing a byte order.
addressNamesFor :: [Text] -> [Text]
addressNamesFor = dedupe . filter isAssigned . map tidy
  where
    tidy = compressIpv6Text . T.toLower . T.strip
    isAssigned a = not (T.null a) && a /= "0.0.0.0" && a /= "::"

-- | Compress the zero runs of a fully expanded IPv6 literal; any other text is
-- returned unchanged. @Network.Info@ renders addresses in expanded form
-- (@0:0:0:0:0:0:0:1@), and the loopback literals 'sanHostsFor' always adds are
-- compressed (@::1@), so without this the same address would be listed twice.
compressIpv6Text :: Text -> Text
compressIpv6Text t =
  case traverse hexGroup (T.splitOn ":" t) of
    Just groups | length groups == 8 -> compressGroups groups
    _                                -> t
  where
    hexGroup g
      | T.null g  = Nothing
      | otherwise = case readHex (T.unpack g) of
          [(n, "")] -> Just n
          _         -> Nothing

-- | Enumerate this machine's interface addresses.
--
-- A failure to enumerate is not a reason to refuse to start: the certificate
-- still covers loopback, the hostname and anything in @tls_hosts@.
localAddressNames :: IO [Text]
localAddressNames = localAddressNamesWith getNetworkInterfaces

-- | 'localAddressNames' with the enumeration action supplied, so a failing
-- enumeration is a case a test can actually create.
localAddressNamesWith :: IO [NetworkInterface] -> IO [Text]
localAddressNamesWith enumerate = do
  result <- try enumerate :: IO (Either IOException [NetworkInterface])
  pure (either (const []) (addressNamesFor . concatMap rendered) result)
  where
    rendered iface = [T.pack (show (ipv4 iface)), T.pack (show (ipv6 iface))]

-- | RFC 5952 text: lower-case hex groups, with the longest run of at least two
-- zero groups compressed to @::@.
compressGroups :: [Int] -> Text
compressGroups groups =
  case longestZeroRun groups of
    Nothing -> T.intercalate ":" (map hex16 groups)
    Just (start, len) ->
      let (before, rest) = splitAt start groups
          after = drop len rest
      in T.intercalate ":" (map hex16 before) <> "::"
           <> T.intercalate ":" (map hex16 after)

-- | Render the four 32-bit groups of an IPv6 address.
renderIpv6 :: Word32 -> Word32 -> Word32 -> Word32 -> Text
renderIpv6 a b c d = compressGroups (concatMap split32 [a, b, c, d])
  where
    split32 w = [fromIntegral (w `shiftR` 16), fromIntegral (w .&. 0xffff)] :: [Int]

hex16 :: Int -> Text
hex16 n = T.pack (showHex n "")

longestZeroRun :: [Int] -> Maybe (Int, Int)
longestZeroRun = pick . runs 0
  where
    runs _ [] = []
    runs i (x : xs)
      | x == 0 =
          let (zeros, rest) = span (== 0) (x : xs)
              n = length zeros
          in [(i, n) | n >= 2] <> runs (i + n) rest
      | otherwise = runs (i + 1) xs
    pick [] = Nothing
    -- The first longest run wins, which is what RFC 5952 requires.
    pick (r : rs) = Just (foldl' (\best@(_, bestLen) cur@(_, curLen)
                                   -> if curLen > bestLen then cur else best) r rs)

-- | The OpenSSL config used for generation.
--
-- A config file rather than @-addext@: that option is OpenSSL 1.1.1+ only, and
-- macOS still ships LibreSSL as @\/usr\/bin\/openssl@. @rsa:2048@ plus a config
-- file works on both.
--
-- @CA:TRUE@ on a self-signed leaf is what lets the operator install this one
-- file as a trusted root on a phone, which is the only way the certificate
-- becomes acceptable to WebAuthn.
renderOpensslConfig :: Text -> [Text] -> Text
renderOpensslConfig primaryHost hosts = T.unlines $
  [ "[req]"
  , "prompt = no"
  , "distinguished_name = dn"
  , "x509_extensions = v3"
  , ""
  , "[dn]"
  , "CN = " <> primaryHost
  , ""
  , "[v3]"
  , "basicConstraints = critical, CA:TRUE"
  , "keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign"
  , "extendedKeyUsage = serverAuth"
  , "subjectAltName = @alt"
  , ""
  , "[alt]"
  ] <> zipWith renderAlt [1 :: Int ..] hosts
  where
    renderAlt i host = case classifySanName host of
      SanIp ip  -> "IP." <> tshow i <> " = " <> ip
      SanDns nm -> "DNS." <> tshow i <> " = " <> nm

-- | The reason an existing pair cannot serve a legal certificate, if it cannot.
--
-- Pure, and deliberately narrow: it answers "would a browser reject this file
-- outright", not "would a new one be better". Refreshing a merely stale name
-- set is an operator action (delete the pair), not a silent re-key.
certificateDefect :: (Day, Day) -> Maybe Text
certificateDefect (notBefore, notAfter)
  | notAfter <= notBefore =
      Just "its expiry date is not after its start date"
  | window > toInteger certificateLifetimeDays =
      Just (tshow window <> " days of validity: browsers refuse more than "
              <> tshow certificateLifetimeDays <> " days")
  | otherwise = Nothing
  where
    window = diffDays notAfter notBefore

-- | The validity window of the certificate in a PEM file, in whole days.
readCertificateValidity :: FilePath -> IO (Either Text (Day, Day))
readCertificateValidity path = do
  parsed <- try (readSignedObject path) :: IO (Either IOException [SignedCertificate])
  pure $ case parsed of
    Left e -> Left ("could not read " <> T.pack path <> ": " <> T.pack (show e))
    Right [] -> Left (T.pack path <> " holds no certificate")
    Right (c : _) ->
      case certValidity (getCertificate c) of
        (start, end) -> case (asDay start, asDay end) of
          (Just s, Just e) -> Right (s, e)
          _ -> Left ("the certificate in " <> T.pack path <> " has an unreadable validity window")
  where
    asDay dt =
      let date = dtDate dt
      in fromGregorianValid (toInteger (dateYear date))
                            (monthNumber (dateMonth date))
                            (dateDay date)

-- | 1-based month number, spelled out rather than taken from 'Enum':
-- @Data.Hourglass.Month@'s 'Enum' instance is zero-based, which silently
-- shifts every parsed date by one month.
monthNumber :: Month -> Int
monthNumber = \case
  January   -> 1
  February  -> 2
  March     -> 3
  April     -> 4
  May       -> 5
  June      -> 6
  July      -> 7
  August    -> 8
  September -> 9
  October   -> 10
  November  -> 11
  December  -> 12

-- | The SAN entries of the certificate in a PEM file.
certificateSans :: FilePath -> IO [SanName]
certificateSans path = do
  parsed <- try (readSignedObject path) :: IO (Either IOException [SignedCertificate])
  pure $ case parsed of
    Right (c : _) ->
      case extensionGet (certExtensions (getCertificate c)) of
        Just (ExtSubjectAltName alts) -> mapMaybe altName alts
        Nothing                       -> []
    _ -> []
  where
    altName (AltNameDNS d)  = Just (SanDns (T.pack d))
    altName (AltNameIP raw) = SanIp <$> renderAddressBytes raw
    altName _               = Nothing

-- | Render the raw SAN address bytes the way 'renderIpv6' renders ours, so the
-- two can be compared directly.
renderAddressBytes :: ByteString -> Maybe Text
renderAddressBytes raw
  | BS.length raw == 4 =
      Just (T.intercalate "." (map (tshow . toInteger) (BS.unpack raw)))
  | BS.length raw == 16 =
      Just (renderIpv6 (word32 0) (word32 1) (word32 2) (word32 3))
  | otherwise = Nothing
  where
    word32 i =
      foldl' (\acc k -> acc + (fromIntegral (BS.index raw (i * 4 + k)) `shiftL` (8 * (3 - k))))
             0 [0 .. 3 :: Int]

-- | Does the pair load the way warp-tls will load it?
--
-- 'credentialLoadX509' is the same loader the TLS stack uses, so a truncated
-- write or a certificate next to somebody else's key is caught at boot instead
-- of on the first handshake.
pairLoads :: FilePath -> FilePath -> IO (Either Text ())
pairLoads certPath keyPath = do
  loaded <- try (credentialLoadX509 certPath keyPath)
  case loaded of
    Left (e :: IOException) -> pure (Left (T.pack (show e)))
    Right (Left err)        -> pure (Left (T.pack err))
    Right (Right _) -> do
      matches <- keyBelongsToCertificate certPath keyPath
      pure (if matches
              then Right ()
              else Left "the private key does not belong to the certificate")

-- | Does the key in @keyPath@ pair with the certificate in @certPath@?
--
-- 'credentialLoadX509' parses both files but does not check that they belong
-- together, so a cert next to somebody else's key loads happily and then fails
-- every handshake. Comparing public keys closes that.
--
-- A key type with no comparable public half (anything but RSA, which is all
-- this module generates) is reported as belonging: refusing to start over a key
-- shape we do not model would be worse than the handshake error it prevents.
keyBelongsToCertificate :: FilePath -> FilePath -> IO Bool
keyBelongsToCertificate certPath keyPath = do
  certs <- try (readSignedObject certPath) :: IO (Either IOException [SignedCertificate])
  keys <- try (readKeyFile keyPath) :: IO (Either IOException [PrivKey])
  pure $ case (certs, keys) of
    (Right (c : _), Right (k : _)) ->
      samePublic (publicHalf k) (certPubKey (getCertificate c))
    _ -> True
  where
    samePublic (Just (PubKeyRSA a)) (PubKeyRSA b) = a == b
    samePublic _ _ = True

publicHalf :: PrivKey -> Maybe PubKey
publicHalf (PrivKeyRSA k) = Just (PubKeyRSA (private_pub k))
publicHalf _              = Nothing

-- | The warning to log when a generated pair is close to expiry.
expiryWarning :: Day -> Text
expiryWarning expiresOn = T.intercalate "\n"
  [ "the generated TLS certificate expires on " <> T.pack (show expiresOn) <> "."
  , "  Delete keys/tls/cert.pem and keys/tls/key.pem and restart to generate a"
  , "  new one, then trust it on the devices that use this gateway."
  ]

-- | 'expiryWarning' when the certificate is within a month of expiry.
certificateExpiryWarning :: FilePath -> IO (Maybe Text)
certificateExpiryWarning certPath = do
  validity <- readCertificateValidity certPath
  today <- utctDay <$> getCurrentTime
  pure $ case validity of
    Right (_, notAfter)
      | diffDays notAfter today <= certificateExpiryWarningDays ->
          Just (expiryWarning notAfter)
    _ -> Nothing

-- | How close to expiry is close enough to warn about. Part 1 has no rotation
-- (that is the CA/leaf split), so this warning is the only thing standing
-- between an operator and a listener that one day stops being accepted.
certificateExpiryWarningDays :: Integer
certificateExpiryWarningDays = 30

-- | Manage the pair at the default paths: create it when missing, replace it
-- when it cannot serve a legal certificate.
ensureGeneratedCertificate
  :: FilePath -> FilePath -> [Text] -> IO (Either Text TlsCertOutcome)
ensureGeneratedCertificate = ensurePair True "openssl"

-- | Manage a pair the operator pointed at explicitly: create it when missing,
-- and never touch an existing one. Their certificate may legitimately outlive
-- 'certificateLifetimeDays' (a real CA, a private PKI), so validating or
-- replacing it would be destructive.
ensureCertificateAt
  :: FilePath -> FilePath -> [Text] -> IO (Either Text TlsCertOutcome)
ensureCertificateAt = ensurePair False "openssl"

-- | 'ensureGeneratedCertificate' with the @openssl@ binary supplied, so the
-- missing-openssl path is a test case rather than an untested branch.
ensureTlsCertificateWith
  :: FilePath -> FilePath -> FilePath -> [Text] -> IO (Either Text TlsCertOutcome)
ensureTlsCertificateWith = ensurePair True

ensurePair
  :: Bool -> FilePath -> FilePath -> FilePath -> [Text] -> IO (Either Text TlsCertOutcome)
ensurePair manage binary certPath keyPath hosts = do
  certOk <- doesFileExist certPath
  keyOk  <- doesFileExist keyPath
  if not (certOk && keyOk)
    then generate False Nothing
    else if not manage
      then pure (Right TlsCertUnchanged)
      else do
        defect <- existingDefect
        case defect of
          Nothing   -> pure (Right TlsCertUnchanged)
          Just why  -> generate True (Just why)
  where
    existingDefect = do
      loaded <- pairLoads certPath keyPath
      case loaded of
        Left err -> pure (Just ("it does not load: " <> err))
        Right () -> do
          validity <- readCertificateValidity certPath
          pure (either Just certificateDefect validity)

    generate isReplace why = case hosts of
      [] -> pure (Left "no host names were given for the certificate")
      (primaryHost : _) -> do
          let dir = takeDirectory certPath
              confPath = certPath <> ".openssl.cnf"
              tmpCert = certPath <> ".tmp"
              tmpKey = keyPath <> ".tmp"
          createDirectoryIfMissing True dir
          setFileMode dir 0o700
          TIO.writeFile confPath (renderOpensslConfig primaryHost hosts)
          result <- try (readProcessWithExitCode binary (reqArgs confPath tmpCert tmpKey) "")
          _ <- try (removeFile confPath) :: IO (Either IOException ())
          case result of
            Left (e :: IOException) -> do
              discardTemps
              pure (Left ("could not run openssl: " <> T.pack (show e)
                            <> "\n  Install openssl, or point tls_cert/tls_key at an existing pair."))
            Right (ExitFailure code, _out, err) -> do
              discardTemps
              pure (Left ("openssl exited " <> tshow code <> ": " <> T.strip (T.pack err)))
            Right (ExitSuccess, _out, _err) -> do
              checked <- pairLoads tmpCert tmpKey
              case checked of
                Left err -> do
                  discardTemps
                  pure (Left ("the generated pair did not load: " <> err))
                Right () -> do
                  when isReplace keepPreviousPair
                  renameFile tmpCert certPath
                  renameFile tmpKey keyPath
                  -- openssl honours the umask; the key must not be world-readable
                  -- whatever it was.
                  setFileMode keyPath 0o600
                  pure (Right (if isReplace
                                 then TlsCertReplaced (fromMaybe "it could not serve a legal certificate" why)
                                 else TlsCertCreated))
      where
        reqArgs confPath tmpCert tmpKey =
          [ "req", "-x509", "-newkey", "rsa:2048", "-nodes"
          , "-days", show certificateLifetimeDays
          , "-keyout", tmpKey
          , "-out", tmpCert
          , "-config", confPath
          ]
        discardTemps =
          forM_ [certPath <> ".tmp", keyPath <> ".tmp"] $ \p ->
            void (try (removeFile p) :: IO (Either IOException ()))
        keepPreviousPair = do
          exists <- doesFileExist certPath
          when exists $ do
            copyFile certPath (certPath <> ".bak")
            keyExists <- doesFileExist keyPath
            when keyExists $ do
              copyFile keyPath (keyPath <> ".bak")
              setFileMode (keyPath <> ".bak") 0o600
