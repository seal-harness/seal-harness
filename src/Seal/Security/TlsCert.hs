{-# LANGUAGE OverloadedStrings #-}
-- | Self-signed TLS material for the gateway, generated with @openssl@.
--
-- Shelling out is deliberate and matches 'Seal.Security.Vault.Age' shelling out
-- to @age@: X.509 generation is a large encoder that is easy to get subtly
-- wrong, and a fixed-argv invocation of the system @openssl@ is both smaller
-- and more likely to be correct than a hand-rolled one. The argv is never built
-- from request data — the only interpolated value is the operator's own
-- hostname, passed as an argv element and, for the subject alternative names,
-- through a generated OpenSSL config file.
--
-- __A generated certificate does not make passkeys work by itself.__ Since
-- Chrome 110 a browser disables WebAuthn outright on a certificate it does not
-- trust, and clicking through the interstitial does not help. The certificate
-- has to be installed on the client device, and it has to name a hostname: a
-- WebAuthn RP ID can never be an IP address. This module exists so an operator
-- can stand up encrypted transport without a proxy, not so that the trust step
-- disappears.
module Seal.Security.TlsCert
  ( ensureTlsCertificate
  , sanHostsFor
  ) where

import Control.Exception (IOException, try)
import Data.Char (isDigit)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)

-- | The names to put in the certificate.
--
-- Every certificate is valid for @localhost@, so a pair generated on the host
-- is immediately usable there. Explicit @[gateway] tls_hosts@ wins; otherwise
-- the bind host is used when it names a machine rather than a wildcard, because
-- that is usually what the operator meant.
sanHostsFor :: Text -> [Text] -> [Text]
sanHostsFor bindHost configured =
  nub (filter (not . T.null) (configured <> derived <> ["localhost"]))
  where
    derived
      | bindHost `elem` ["0.0.0.0", "::", "*", ""] = []
      | otherwise = [bindHost]

-- | Create the certificate and key if either is missing.
--
-- Returns @Right True@ when a pair was generated and @Right False@ when both
-- files were already present, so the caller can say which happened. A failure
-- carries openssl's own stderr, because "could not generate certificate" on
-- its own tells the operator nothing.
ensureTlsCertificate
  :: FilePath   -- ^ certificate path (PEM)
  -> FilePath   -- ^ private key path (PEM, written 0600)
  -> [Text]     -- ^ host names for the subject alternative name extension
  -> IO (Either Text Bool)
ensureTlsCertificate certPath keyPath hosts = do
  certOk <- doesFileExist certPath
  keyOk  <- doesFileExist keyPath
  if certOk && keyOk
    then pure (Right False)
    else case hosts of
      [] -> pure (Left "no host names were given for the certificate")
      (primaryHost : _) -> do
        let dir = takeDirectory certPath
            confPath = certPath <> ".openssl.cnf"
        createDirectoryIfMissing True dir
        setFileMode dir 0o700
        TIO.writeFile confPath (opensslConfig primaryHost hosts)
        result <- try (readProcessWithExitCode "openssl" (reqArgs confPath) "")
        _ <- try (removeFile confPath) :: IO (Either IOException ())
        case result of
          Left (e :: IOException) ->
            pure (Left ("could not run openssl: " <> T.pack (show e)
                          <> "\n  Install openssl, or point tls_cert/tls_key at an existing pair."))
          Right (ExitFailure code, _out, err) ->
            pure (Left ("openssl exited " <> T.pack (show code) <> ": "
                          <> T.strip (T.pack err)))
          Right (ExitSuccess, _out, _err) -> do
            -- openssl honours the umask; the key must not be world-readable
            -- whatever it was.
            setFileMode keyPath 0o600
            pure (Right True)
  where
    reqArgs confPath =
      [ "req", "-x509", "-newkey", "rsa:2048", "-nodes"
      , "-days", "3650"
      , "-keyout", keyPath
      , "-out", certPath
      , "-config", confPath
      ]

-- | The OpenSSL config used for generation.
--
-- A config file rather than @-addext@ or @-pkeyopt@: both are OpenSSL 1.1.1+
-- only, and macOS still ships LibreSSL as @\/usr\/bin\/openssl@. @rsa:2048@ plus
-- a config file works on both.
--
-- @CA:TRUE@ on a self-signed leaf is what lets the operator install this one
-- file as a trusted root on a phone, which is the only way the certificate
-- becomes acceptable to WebAuthn.
opensslConfig :: Text -> [Text] -> Text
opensslConfig primaryHost hosts = T.unlines $
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
    renderAlt i host
      | isIpv4 host = "IP." <> T.pack (show i) <> " = " <> host
      | otherwise   = "DNS." <> T.pack (show i) <> " = " <> host

-- | Enough of a check to pick the right SAN key. Getting it wrong is visible
-- immediately: openssl rejects a malformed IP, and a DNS name that merely looks
-- like an address would not match the URL anyway.
isIpv4 :: Text -> Bool
isIpv4 host =
  T.count "." host == 3
    && not (T.null host)
    && T.all (\c -> isDigit c || c == '.') host
