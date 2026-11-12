{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the @[access_control]@ configuration section, the narrow
-- writer, and the boot matrix.
module Seal.Config.SecurityAccessControlSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64Url
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Test.Hspec
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Toml qualified
import Validation (Validation (..))

import Seal.Config.Security
  ( AccessControlFileConfig (..)
  , CredentialFileConfig (..)
  , SecurityConfig (..)
  , defaultSecurityConfig
  , hasLegacyLayout, loadSecurityConfig
  , saveSecurityConfig
  , securityConfigCodec
  , updateAccessControlSection
  , WriteMode (PreserveCredentials)
  )
import Seal.Security.AccessControl
  ( CredentialAvailability (..), canonicalOriginFor, credentialAvailability
  , isIpLiteral, resolveCoordinates
  , credentialFromFile, credentialToFile, credentialLabelMaxLength
  , mkCredentialLabel, parseIsoTime, rpMismatch )
import Seal.Security.WebAuthn.Types
  ( AccessMode (..), CosePublicKey (..), Credential (..) )

spec :: Spec
spec = describe "Seal.Config.Security access_control" $ do
  describe "codec" $ do
    it "round-trips a full section" $ do
      let cfg = defaultSecurityConfig { scAccessControl = Just sampleSection }
      decodeSection (Toml.encode securityConfigCodec cfg)
        `shouldBe` Right (Just sampleSection)

    it "leaves the section absent when the file has none" $ do
      let cfg = defaultSecurityConfig
      decodeSection (Toml.encode securityConfigCodec cfg) `shouldBe` Right Nothing

    it "decodes the section out of a credentials-only legacy file" $
      -- The pre-split shape: no bare [access_control] header, only
      -- [access_control.credentials.<id>] tables. The section itself must still
      -- decode (mode/origin absent), and the document must be recognisable as
      -- legacy — that recognition is what stops the next write dropping it
      -- (see the hasLegacyLayout cases in Seal.Config.SecuritySpec).
      withSystemTempDirectory "seal-ac" $ \dir -> do
        let path = dir </> "security.toml"
            raw = T.unlines
              [ "[access_control.credentials." <> credIdText <> "]"
              , "public_key = \"" <> key64 <> "\""
              , "sign_count = 0"
              , "label = \"laptop\""
              , "created_at = \"2026-10-30T14:00:00Z\""
              , "rp_id = \"localhost\""
              ]
        writeFile path (T.unpack raw)
        Right cfg <- loadSecurityConfig path
        scAccessControl cfg `shouldBe` Just (AccessControlFileConfig Nothing Nothing Nothing)
        hasLegacyLayout raw `shouldBe` True

    it "round-trips the default config through the file" $
      withSystemTempDirectory "seal-ac" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig PreserveCredentials
          `shouldReturn` Right ()
        loadSecurityConfig path `shouldReturn` Right defaultSecurityConfig

  describe "updateAccessControlSection" $
    it "preserves every other section" $
      withSystemTempDirectory "seal-ac" $ \dir -> do
        let path = dir </> "security.toml"
            initial = defaultSecurityConfig
              { scVaultRecipient = Just "age1abc"
              , scVaultIdentity = Just "/keys/id.txt"
              , scVaultUnlock = Just "on_demand"
              }
        saveSecurityConfig path initial PreserveCredentials `shouldReturn` Right ()
        result <- updateAccessControlSection path (const sampleSection)
        case result of
          Left e -> expectationFailure ("write failed: " <> T.unpack e)
          Right written -> written `shouldBe` sampleSection
        reloaded <- loadSecurityConfig path
        fmap scVaultRecipient reloaded `shouldBe` Right (Just "age1abc")
        fmap scVaultIdentity reloaded `shouldBe` Right (Just "/keys/id.txt")
        fmap scVaultUnlock reloaded `shouldBe` Right (Just "on_demand")
        fmap scAccessControl reloaded `shouldBe` Right (Just sampleSection)

  describe "updateAccessControlSection error handling" $
    it "returns Left for a file that does not parse" $
      withSystemTempDirectory "seal-ac" $ \dir -> do
        let path = dir </> "security.toml"
        writeFile path "this is not toml [[["
        result <- updateAccessControlSection path (const sampleSection)
        result `shouldSatisfy` isLeft

  -- Design §7.2. The three-valued answer is what stops rp_mismatch being a
  -- boolean: "no credential enrolled" (bootstrap, mint a grant) and "every
  -- credential is orphaned" (rp_mismatch, mint a grant) must not be conflated
  -- with "some credential differs", which never clears.
  describe "credentialAvailability" $ do
    it "is NoCredentials with an empty store" $
      credentialAvailability (Just "localhost") Map.empty `shouldBe` NoCredentials

    it "is NoCredentials with an empty store and no resolved rpId" $
      credentialAvailability Nothing Map.empty `shouldBe` NoCredentials

    it "is UnusableOnly when every credential was created for another rpId" $
      credentialAvailability (Just "localhost")
        (Map.fromList [("a", mkCredential "a" "old.example.com")
                      ,("b", mkCredential "b" "old.example.com")])
        `shouldBe` UnusableOnly

    it "is Usable when one credential matches and the rest are orphaned" $
      credentialAvailability (Just "localhost")
        (Map.fromList [("a", mkCredential "a" "old.example.com")
                      ,("b", mkCredential "b" "localhost")])
        `shouldBe` Usable

    it "is Usable when every credential matches" $
      credentialAvailability (Just "localhost")
        (Map.fromList [("a", mkCredential "a" "localhost")
                      ,("b", mkCredential "b" "localhost")])
        `shouldBe` Usable

    it "is Usable when no rpId could be resolved (wildcard bind)" $
      credentialAvailability Nothing (Map.fromList [("a", mkCredential "a" "anywhere")])
        `shouldBe` Usable

  -- Design §14 / §1.6. The quantifier is the whole point: "some credential
  -- differs" is vacuously false on an empty store and permanently true once the
  -- origin changes, so the flag never cleared and every boot minted a grant.
  describe "rpMismatch" $ do
    it "is false with zero credentials" $ do
      rpMismatch (Just "localhost") Map.empty `shouldBe` False

    it "is false when any credential is usable here" $ do
      rpMismatch (Just "localhost")
        (Map.fromList [("a", mkCredential "a" "old.example.com")
                      ,("b", mkCredential "b" "localhost")])
        `shouldBe` False

    it "is true only when every credential is orphaned" $ do
      rpMismatch (Just "localhost")
        (Map.fromList [("a", mkCredential "a" "old.example.com")
                      ,("b", mkCredential "b" "older.example.com")])
        `shouldBe` True

    it "is false when no rpId could be resolved" $ do
      rpMismatch Nothing (Map.fromList [("a", mkCredential "a" "anywhere")])
        `shouldBe` False

  describe "credentialFromFile" $ do
    it "accepts a well-formed credential" $
      credentialFromFile (credIdText, sampleCredential)
        `shouldSatisfy` either (const False) (const True)

    it "rejects a public key that is not 64 bytes" $
      credentialFromFile (credIdText, sampleCredential { cfcPublicKey = "AAAA" })
        `shouldSatisfy` isLeft

    it "rejects a public key that is not base64url" $
      credentialFromFile (credIdText, sampleCredential { cfcPublicKey = "!!!!" })
        `shouldSatisfy` isLeft

    it "rejects a malformed created_at" $
      credentialFromFile (credIdText, sampleCredential { cfcCreatedAt = "yesterday" })
        `shouldSatisfy` isLeft

    it "rejects a negative sign count" $
      credentialFromFile (credIdText, sampleCredential { cfcSignCount = -1 })
        `shouldSatisfy` isLeft

    it "round-trips through credentialToFile" $
      case credentialFromFile (credIdText, sampleCredential) of
        Left e -> expectationFailure (T.unpack e)
        Right (_, cred) -> credentialToFile cred `shouldBe` sampleCredential

  -- A passkey's label is display-only, but it is stored in credentials.toml,
  -- rendered in the web UI and echoed into the audit log, so it is normalised
  -- once instead of at each reader.
  describe "mkCredentialLabel" $ do
    it "trims surrounding whitespace" $
      mkCredentialLabel "  my laptop \n" `shouldBe` Right "my laptop"

    it "rejects an empty or whitespace-only label" $ do
      mkCredentialLabel "" `shouldSatisfy` isLeft
      mkCredentialLabel "   " `shouldSatisfy` isLeft

    it "rejects control characters" $
      mkCredentialLabel "lap\ntop" `shouldSatisfy` isLeft

    it "accepts a label of exactly the maximum length and rejects one over it" $ do
      let longest = T.replicate credentialLabelMaxLength "a"
      mkCredentialLabel longest `shouldBe` Right longest
      mkCredentialLabel (longest <> "a") `shouldSatisfy` isLeft

    it "keeps non-ASCII labels as typed" $
      mkCredentialLabel "téléphone" `shouldBe` Right "téléphone"

  describe "canonicalOriginFor" $ do
    it "canonicalises a loopback bind to localhost" $ do
      canonicalOriginFor "127.0.0.1" 8080 `shouldBe` "http://localhost:8080"
      canonicalOriginFor "::1" 9000 `shouldBe` "http://localhost:9000"
    it "uses the bind host otherwise" $
      canonicalOriginFor "10.0.0.5" 8080 `shouldBe` "http://10.0.0.5:8080"

  -- A WebAuthn RP ID must be a domain string. Browsers reject an IP origin with
  -- `SecurityError` before any ceremony runs, so an IP must be caught at boot
  -- instead of surfacing as "this address does not match the relying-party id".
  describe "isIpLiteral" $ do
    it "recognises addresses that can never be a relying-party id" $
      map isIpLiteral
        ["192.168.0.107", "127.0.0.1", "10.0.0.5", "::1", "[::1]", "fe80::1"]
        `shouldBe` replicate 6 True

    it "leaves names alone, including single-label ones" $
      map isIpLiteral ["localhost", "seal.lan", "chani.tail1234.ts.net", "seal.test"]
        `shouldBe` replicate 4 False

  describe "resolveCoordinates" $ do
    it "refuses an IP origin rather than letting the browser fail the ceremony" $
      case resolveCoordinates "0.0.0.0" 8443
             (Just sampleSection { acfcOrigin = Just "https://192.168.0.107:8443" })
             AccessPasskey of
        Left err -> err `shouldSatisfy` T.isInfixOf "must be a domain name"
        Right ok -> expectationFailure ("expected a refusal, got " <> show ok)

    it "accepts a hostname origin" $
      case resolveCoordinates "0.0.0.0" 8443
             (Just sampleSection { acfcOrigin = Just "https://seal.lan:8443" })
             AccessPasskey of
        Left err -> expectationFailure ("unexpected refusal: " <> T.unpack err)
        Right (origin, rpId) -> do
          origin `shouldBe` Just "https://seal.lan:8443"
          rpId `shouldBe` Just "seal.lan"

-- Helpers ------------------------------------------------------------------

credIdText :: Text
credIdText = TE.decodeUtf8 (B64Url.encodeUnpadded (BS.replicate 16 0x03))

key64 :: Text
key64 = TE.decodeUtf8 (B64Url.encodeUnpadded (BS.replicate 64 0x02))

-- | A credential created for @rp@, for the availability cases. Only @credRpId@
-- and the id matter to 'credentialAvailability'; the rest is filler that still
-- has to be well-typed.
mkCredential :: Text -> Text -> Credential
mkCredential cid rp = Credential
  { credId        = TE.encodeUtf8 cid
  , credPublicKey = CosePublicKey (BS.replicate 64 0x01)
  , credSignCount = 0
  , credLabel     = "test"
  , credCreatedAt = fixtureTime
  , credRpId      = rp
  , credAddedVia  = Nothing
  }

fixtureTime :: UTCTime
fixtureTime = case parseIsoTime "2026-10-30T14:00:00Z" of
  Just t  -> t
  Nothing -> error "the fixture timestamp must parse"

sampleCredential :: CredentialFileConfig
sampleCredential = CredentialFileConfig
  { cfcPublicKey = key64
  , cfcSignCount = 3
  , cfcLabel = "laptop"
  , cfcCreatedAt = "2026-10-30T14:00:00Z"
  , cfcRpId = "localhost"
  , cfcAddedVia = Nothing
  }

sampleSection :: AccessControlFileConfig
sampleSection = AccessControlFileConfig
  { acfcMode = Just "passkey"
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  }

-- | Decode a whole-file encoding back to just the section.
decodeSection :: Text -> Either Text (Maybe AccessControlFileConfig)
decodeSection encoded = case Toml.parse encoded of
  Left e -> Left (Toml.unTomlParseError e)
  Right toml -> case Toml.runTomlCodec securityConfigCodec toml of
    Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)
    Success cfg  -> Right (scAccessControl cfg)

