{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.TlsCertSpec (spec) where

import Data.Text qualified as T
import Data.Time.Calendar (Day (..), diffDays, fromGregorian)
import Network.Info (IPv4 (..), IPv6 (..), MAC (..), NetworkInterface (..))
import Network.TLS (credentialLoadX509)
import System.Directory (doesFileExist, findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import System.Process (readProcessWithExitCode)
import Test.Hspec

import Seal.Gateway.Config (GatewayConfig (..), defaultGatewayConfig)
import Seal.Security.TlsCert

-- | Run a test only when a real @openssl@ is on PATH, per the repo's rule that
-- tests needing an external binary are guarded rather than silently skipped.
withOpenSsl :: IO () -> IO ()
withOpenSsl act = findExecutable "openssl" >>= \case
  Nothing -> pendingWith "openssl is not on PATH"
  Just _  -> act

emptyInputs :: SanInputs
emptyInputs = SanInputs
  { siConfigured  = []
  , siBindHost    = "0.0.0.0"
  , siMachineName = "arrakis.local"
  , siOriginName  = Nothing
  , siAddresses   = []
  }

-- | A loopback interface as @Network.Info@ reports it. Its numeric fields
-- carry socket byte order (on a little-endian host @127.0.0.1@ is
-- @0x0100007F@), which is why the production code renders them with 'show'
-- rather than decomposing the words itself.
loopbackInterface :: NetworkInterface
loopbackInterface =
  NetworkInterface "lo0" (IPv4 0x0100007F) (IPv6 0 0 0 0x01000000) (MAC 0 0 0 0 0 0)

-- | Generate a pair the way the old code did, so a test can prove it gets
-- replaced rather than trusted.
legacyPair :: FilePath -> FilePath -> IO ()
legacyPair cert key = do
  _ <- readProcessWithExitCode "openssl"
         [ "req", "-x509", "-newkey", "rsa:2048", "-nodes"
         , "-days", "3650", "-keyout", key, "-out", cert
         , "-subj", "/CN=legacy" ] ""
  pure ()

spec :: Spec
spec = describe "Seal.Security.TlsCert" $ do

  describe "sanHostsFor" $ do
    it "covers loopback, the machine name and every interface address" $
      sanHostsFor emptyInputs { siAddresses = ["192.168.1.42", "fd7a::5"] }
        `shouldBe` ["arrakis.local", "192.168.1.42", "fd7a::5",
                    "localhost", "127.0.0.1", "::1"]

    it "puts configured hosts first and de-duplicates case-insensitively" $
      sanHostsFor emptyInputs
        { siConfigured = ["Phone.lan", "phone.lan", "seal.test"]
        , siBindHost   = "seal.test"
        }
        `shouldBe` ["phone.lan", "seal.test", "arrakis.local",
                    "localhost", "127.0.0.1", "::1"]

    it "includes the origin host when one is configured" $
      sanHostsFor emptyInputs { siOriginName = Just "Seal.Example.com" }
        `shouldBe` ["seal.example.com", "arrakis.local",
                    "localhost", "127.0.0.1", "::1"]

    it "adds the bind host only when it names a machine" $ do
      sanHostsFor emptyInputs { siBindHost = "seal.lan" }
        `shouldBe` ["seal.lan", "arrakis.local", "localhost", "127.0.0.1", "::1"]
      sanHostsFor emptyInputs { siBindHost = "::" }
        `shouldBe` ["arrakis.local", "localhost", "127.0.0.1", "::1"]

    it "drops empty names rather than emitting a blank SAN" $
      sanHostsFor emptyInputs { siMachineName = "", siConfigured = [""] }
        `shouldBe` ["localhost", "127.0.0.1", "::1"]

  describe "classifySanName" $ do
    it "treats dotted-quad and IPv6 literals as addresses" $ do
      classifySanName "127.0.0.1" `shouldBe` SanIp "127.0.0.1"
      classifySanName "::1" `shouldBe` SanIp "::1"
      classifySanName "fd7a:115c:a1e0::5" `shouldBe` SanIp "fd7a:115c:a1e0::5"

    it "strips brackets, which OpenSSL will not accept in an IP entry" $
      classifySanName "[::1]" `shouldBe` SanIp "::1"

    it "strips an IPv6 zone id, which is not part of an address" $
      classifySanName "fe80::1%en0" `shouldBe` SanIp "fe80::1"

    it "treats everything else as a DNS name" $ do
      classifySanName "arrakis.local" `shouldBe` SanDns "arrakis.local"
      classifySanName "seal.test" `shouldBe` SanDns "seal.test"

  describe "renderOpensslConfig" $ do
    it "renders addresses under IP.n and names under DNS.n" $ do
      let conf = renderOpensslConfig "seal.test"
                   ["seal.test", "localhost", "127.0.0.1", "::1"]
          ls = T.lines conf
      ls `shouldSatisfy` elem "DNS.1 = seal.test"
      ls `shouldSatisfy` elem "DNS.2 = localhost"
      ls `shouldSatisfy` elem "IP.3 = 127.0.0.1"
      ls `shouldSatisfy` elem "IP.4 = ::1"

    it "keeps the CA:TRUE extension a phone needs to install the file as a root" $
      renderOpensslConfig "seal.test" ["seal.test"]
        `shouldSatisfy` T.isInfixOf "CA:TRUE"

  describe "addressNamesFor" $ do
    it "keeps assigned addresses and drops the all-zero 'absent' family" $
      addressNamesFor ["127.0.0.1", "0.0.0.0", "0:0:0:0:0:0:0:0", "fe80:0:0:0:0:0:0:1"]
        `shouldBe` ["127.0.0.1", "fe80::1"]

    it "compresses expanded IPv6 so it can de-duplicate against the short form" $
      addressNamesFor ["0:0:0:0:0:0:0:1", "::1", "192.168.1.42", "192.168.1.42"]
        `shouldBe` ["::1", "192.168.1.42"]

  describe "localAddressNamesWith" $ do
    it "renders a successful enumeration" $
      localAddressNamesWith (pure [loopbackInterface])
        `shouldReturn` ["127.0.0.1", "::1"]

    it "returns nothing, rather than throwing, when enumeration fails" $
      localAddressNamesWith (ioError (userError "no interfaces")) `shouldReturn` []

  describe "sanInputsFor" $ do
    it "maps every field out of the config and its arguments" $ do
      let cfg = defaultGatewayConfig
                  { gcHost = "seal.lan", gcTlsHosts = ["phone.lan"] }
          si = sanInputsFor cfg "arrakis.local" (Just "seal.example.com") ["10.0.0.7"]
      siConfigured si `shouldBe` ["phone.lan"]
      siBindHost si `shouldBe` "seal.lan"
      siMachineName si `shouldBe` "arrakis.local"
      siOriginName si `shouldBe` Just "seal.example.com"
      siAddresses si `shouldBe` ["10.0.0.7"]

  describe "certificateDefect" $ do
    let day = fromGregorian 2026 11

    it "accepts a window at the 397-day limit" $
      certificateDefect (day 1, addDays 397 (day 1)) `shouldBe` Nothing

    it "rejects a window one day over the limit" $
      certificateDefect (day 1, addDays 398 (day 1))
        `shouldSatisfy` maybe False (T.isInfixOf "397")

    it "rejects a reversed window" $
      certificateDefect (day 5, day 1) `shouldSatisfy` (/= Nothing)

  describe "ensureGeneratedCertificate" $ do
    it "generates a 397-day pair the TLS stack loads, with a 0600 key" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "tls" </> "cert.pem"
            key  = dir </> "tls" </> "key.pem"
        first <- ensureGeneratedCertificate cert key
                   ["localhost", "127.0.0.1", "::1", "seal.test"]
        first `shouldBe` Right TlsCertCreated
        -- The point of the strongest check available: the certificate we asked
        -- openssl for is one warp-tls will actually accept.
        loaded <- credentialLoadX509 cert key
        case loaded of
          Left err -> expectationFailure ("TLS stack rejected the pair: " <> err)
          Right _  -> pure ()
        Right (notBefore, notAfter) <- readCertificateValidity cert
        diffDays notAfter notBefore `shouldSatisfy` (<= fromIntegral certificateLifetimeDays)
        mode <- fileMode <$> getFileStatus key
        (mode `intersectFileModes` 0o777) `shouldBe` 0o600
        dirMode <- fileMode <$> getFileStatus (dir </> "tls")
        (dirMode `intersectFileModes` 0o777) `shouldBe` 0o700

    it "puts the whole name list in the SAN extension" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
            hosts = ["seal.test", "localhost", "127.0.0.1", "::1", "fd7a::5"]
        _ <- ensureGeneratedCertificate cert key hosts
        sans <- certificateSans cert
        sans `shouldSatisfy` elem (SanDns "localhost")
        sans `shouldSatisfy` elem (SanIp "127.0.0.1")
        sans `shouldSatisfy` elem (SanIp "::1")
        sans `shouldSatisfy` elem (SanIp "fd7a::5")
        sans `shouldSatisfy` elem (SanDns "seal.test")

    it "is a no-op once an acceptable pair exists, so a restart never re-keys" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        _ <- ensureGeneratedCertificate cert key ["localhost"]
        certBefore <- readFile cert
        again <- ensureGeneratedCertificate cert key ["localhost"]
        again `shouldBe` Right TlsCertUnchanged
        certAfter <- readFile cert
        certAfter `shouldBe` certBefore

    it "replaces a 3650-day pair and keeps the old one as a .bak" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        legacyPair cert key
        outcome <- ensureGeneratedCertificate cert key ["localhost"]
        case outcome of
          Right (TlsCertReplaced why) -> why `shouldSatisfy` T.isInfixOf "397"
          other -> expectationFailure ("expected a replacement, got " <> show other)
        Right (notBefore, notAfter) <- readCertificateValidity cert
        diffDays notAfter notBefore `shouldSatisfy` (<= fromIntegral certificateLifetimeDays)
        doesFileExist (cert <> ".bak") `shouldReturn` True
        doesFileExist (key <> ".bak") `shouldReturn` True

    it "replaces an unparseable PEM instead of aborting" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        writeFile cert "not a certificate\n"
        writeFile key "not a key\n"
        outcome <- ensureGeneratedCertificate cert key ["localhost"]
        case outcome of
          Right (TlsCertReplaced _) -> pure ()
          other -> expectationFailure ("expected a replacement, got " <> show other)
        loaded <- credentialLoadX509 cert key
        case loaded of
          Left err -> expectationFailure ("TLS stack rejected the pair: " <> err)
          Right _  -> pure ()

    it "replaces a certificate whose key does not match it" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let goodCert = dir </> "good-cert.pem"
            goodKey  = dir </> "good-key.pem"
            otherKey = dir </> "other-key.pem"
        _ <- ensureGeneratedCertificate goodCert goodKey ["localhost"]
        _ <- readProcessWithExitCode "openssl"
               [ "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "397"
               , "-keyout", otherKey, "-out", dir </> "unused.pem"
               , "-subj", "/CN=other" ] ""
        -- A cert that parses fine, next to a key that belongs to something else.
        outcome <- ensureGeneratedCertificate goodCert otherKey ["localhost"]
        case outcome of
          Right (TlsCertReplaced _) -> pure ()
          other -> expectationFailure ("expected a replacement, got " <> show other)
        loaded <- credentialLoadX509 goodCert otherKey
        case loaded of
          Left err -> expectationFailure ("TLS stack rejected the pair: " <> err)
          Right _  -> pure ()

    it "leaves no temporary files behind" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        _ <- ensureGeneratedCertificate cert key ["localhost"]
        doesFileExist (cert <> ".tmp") `shouldReturn` False
        doesFileExist (key <> ".tmp") `shouldReturn` False

    it "reports a usable error when openssl is missing" $
      withSystemTempDirectory "seal-tls" $ \dir -> do
        outcome <- ensureTlsCertificateWith (dir </> "no-such-openssl")
                     (dir </> "cert.pem") (dir </> "key.pem") ["localhost"]
        case outcome of
          Left err -> err `shouldSatisfy` T.isInfixOf "openssl"
          Right _  -> expectationFailure "expected a failure with no openssl on PATH"

  describe "an owned pair close to expiry" $ do
    it "is kept, not silently re-keyed, once it still serves a legal window" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        _ <- readProcessWithExitCode "openssl"
               [ "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "5"
               , "-keyout", key, "-out", cert, "-subj", "/CN=soon" ] ""
        outcome <- ensureGeneratedCertificate cert key ["localhost"]
        outcome `shouldBe` Right TlsCertUnchanged

  describe "ensureCertificateAt" $ do
    it "never replaces an operator-supplied pair, whatever its lifetime" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        legacyPair cert key
        certBefore <- readFile cert
        outcome <- ensureCertificateAt cert key ["localhost"]
        outcome `shouldBe` Right TlsCertUnchanged
        certAfter <- readFile cert
        certAfter `shouldBe` certBefore

    it "still creates a missing pair, which is today's behaviour" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "cert.pem"
            key  = dir </> "key.pem"
        outcome <- ensureCertificateAt cert key ["localhost"]
        outcome `shouldBe` Right TlsCertCreated
        loaded <- credentialLoadX509 cert key
        case loaded of
          Left err -> expectationFailure ("TLS stack rejected the pair: " <> err)
          Right _  -> pure ()

  describe "expiryWarning" $ do
    it "warns with the expiry date and how to regenerate" $ do
      let msg = expiryWarning (fromGregorian 2027 1 2)
      msg `shouldSatisfy` T.isInfixOf "2027"
      msg `shouldSatisfy` T.isInfixOf "cert.pem"

addDays :: Integer -> Day -> Day
addDays n (ModifiedJulianDay d) = ModifiedJulianDay (d + n)
