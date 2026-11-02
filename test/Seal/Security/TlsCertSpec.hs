{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.TlsCertSpec (spec) where

import Data.Text (Text)
import Network.TLS (credentialLoadX509)
import System.Directory (findExecutable, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import Test.Hspec

import Seal.Security.TlsCert (ensureTlsCertificate, sanHostsFor)

-- | Run a test only when a real @openssl@ is on PATH, per the repo's rule that
-- tests needing an external binary are guarded rather than silently skipped.
withOpenSsl :: IO () -> IO ()
withOpenSsl act = findExecutable "openssl" >>= \case
  Nothing -> pendingWith "openssl is not on PATH"
  Just _  -> act

spec :: Spec
spec = describe "Seal.Security.TlsCert" $ do

  describe "sanHostsFor" $ do
    it "always covers localhost" $
      sanHostsFor "0.0.0.0" [] `shouldBe` (["localhost"] :: [Text])

    it "adds the bind host when it names a machine" $
      sanHostsFor "seal.lan" [] `shouldBe` ["seal.lan", "localhost"]

    it "prefers explicit hosts, in order, without duplicates" $
      sanHostsFor "seal.lan" ["phone.lan", "seal.lan"]
        `shouldBe` ["phone.lan", "seal.lan", "localhost"]

  describe "ensureTlsCertificate" $ do
    it "generates a pair the TLS stack loads, with a 0600 key" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "tls" </> "cert.pem"
            key  = dir </> "tls" </> "key.pem"
        first <- ensureTlsCertificate cert key ["localhost", "seal.lan"]
        first `shouldBe` Right True
        -- The point of the strongest check available: the certificate we asked
        -- openssl for is one warp-tls will actually accept.
        loaded <- credentialLoadX509 cert key
        case loaded of
          Left err -> expectationFailure ("TLS stack rejected the pair: " <> err)
          Right _  -> pure ()
        mode <- fileMode <$> getFileStatus key
        (mode `intersectFileModes` 0o777) `shouldBe` 0o600

    it "is a no-op once a pair exists, so a restart does not rotate the key" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "tls" </> "cert.pem"
            key  = dir </> "tls" </> "key.pem"
        _ <- ensureTlsCertificate cert key ["localhost"]
        certBefore <- readFile cert
        again <- ensureTlsCertificate cert key ["localhost"]
        again `shouldBe` Right False
        certAfter <- readFile cert
        certAfter `shouldBe` certBefore

    it "regenerates when only one half is present" $
      withOpenSsl $ withSystemTempDirectory "seal-tls" $ \dir -> do
        let cert = dir </> "tls" </> "cert.pem"
            key  = dir </> "tls" </> "key.pem"
        _ <- ensureTlsCertificate cert key ["localhost"]
        removeFile key
        regenerated <- ensureTlsCertificate cert key ["localhost"]
        regenerated `shouldBe` Right True
        loaded <- credentialLoadX509 cert key
        case loaded of
          Left err -> expectationFailure ("TLS stack rejected the pair: " <> err)
          Right _  -> pure ()
