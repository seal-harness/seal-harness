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
  , loadSecurityConfig
  , saveSecurityConfig
  , securityConfigCodec
  , updateAccessControlSection
  , WriteMode (PreserveCredentials)
  )
import Seal.Security.AccessControl
  ( BootDecision (..), CredentialAvailability (..), ResolvedAccessControl (..)
  , bootDecision, canonicalOriginFor, credentialAvailability, credentialFromFile
  , credentialToFile, parseIsoTime, resolveAccessControl )
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

    it "decodes an idiomatic credentials-only file (the tableMap gotcha)" $
      -- No bare [access_control] header: exactly the shape a hand-written file
      -- takes, and the shape tomland silently mis-decodes without
      -- normalizeAccessControlTable.
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
        loaded <- loadSecurityConfig path
        case loaded of
          Left e -> expectationFailure ("load: " <> T.unpack e)
          Right cfg -> do
            let creds = maybe Map.empty acfcCredentials (scAccessControl cfg)
            Map.keys creds `shouldBe` [credIdText]
            fmap cfcLabel (Map.lookup credIdText creds) `shouldBe` Just "laptop"

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

  describe "resolveAccessControl" $ do
    it "is unconfigured when the section is absent, but still resolves an origin" $
      resolveAccessControl "127.0.0.1" 8080 Nothing
        `shouldBe` Right (ResolvedAccessControl AccessUnconfigured
                            (Just "http://localhost:8080") (Just "localhost") Map.empty)

    it "derives a localhost origin for a loopback bind" $
      fmap racOrigin (resolveAccessControl "127.0.0.1" 8080 (Just openSection))
        `shouldBe` Right (Just "http://localhost:8080")

    it "derives the origin from the bind host when not loopback" $
      fmap racOrigin (resolveAccessControl "10.1.2.3" 9000 (Just openSection))
        `shouldBe` Right (Just "http://10.1.2.3:9000")

    it "has no origin for an open gateway on a wildcard bind" $
      resolveAccessControl "0.0.0.0" 8080 (Just openSection)
        `shouldBe` Right (ResolvedAccessControl AccessOpen Nothing Nothing Map.empty)

    it "refuses a wildcard bind with access control configured" $
      resolveAccessControl "0.0.0.0" 8080 (Just passkeySection) `shouldSatisfy` isLeft

    it "honours an explicit origin and derives the rpId from it" $
      let section = openSection
            { acfcOrigin = Just "https://seal.example.com"
            , acfcRpId = Nothing
            }
      in do
        fmap racOrigin (resolveAccessControl "127.0.0.1" 8080 (Just section))
          `shouldBe` Right (Just "https://seal.example.com")
        fmap racRpId (resolveAccessControl "127.0.0.1" 8080 (Just section))
          `shouldBe` Right (Just "seal.example.com")

    it "accepts an rp_id that is a suffix of the origin host" $
      fmap racRpId
        (resolveAccessControl "127.0.0.1" 8080
          (Just openSection { acfcOrigin = Just "https://a.seal.example.com"
                            , acfcRpId = Just "seal.example.com" }))
        `shouldBe` Right (Just "seal.example.com")

    it "rejects an rp_id that is unrelated to the origin host" $
      resolveAccessControl "127.0.0.1" 8080
        (Just openSection { acfcOrigin = Just "https://seal.example.com"
                          , acfcRpId = Just "evil.example" })
        `shouldSatisfy` isLeft

    it "rejects an invalid mode rather than treating it as open" $
      resolveAccessControl "127.0.0.1" 8080
        (Just openSection { acfcMode = Just "off" })
        `shouldSatisfy` isLeft

    it "treats passkey-with-no-credentials as unconfigured" $
      fmap racMode
        (resolveAccessControl "127.0.0.1" 8080
          (Just passkeySection { acfcCredentials = Map.empty }))
        `shouldBe` Right AccessUnconfigured

    it "resolves a passkey section with one credential" $ do
      let cfg = resolveAccessControl "127.0.0.1" 8080 (Just passkeySection)
      fmap racMode cfg `shouldBe` Right AccessPasskey
      fmap (Map.size . racCredentials) cfg `shouldBe` Right 1
      fmap racOrigin cfg `shouldBe` Right (Just "http://localhost:8080")

  describe "canonicalOriginFor" $ do
    it "canonicalises a loopback bind to localhost" $ do
      canonicalOriginFor "127.0.0.1" 8080 `shouldBe` "http://localhost:8080"
      canonicalOriginFor "::1" 9000 `shouldBe` "http://localhost:9000"
    it "uses the bind host otherwise" $
      canonicalOriginFor "10.0.0.5" 8080 `shouldBe` "http://10.0.0.5:8080"

  describe "bootDecision" $ do
    it "always starts unconfigured and open" $ do
      bootDecision AccessUnconfigured True True 0 `shouldBe` BdStart
      bootDecision AccessUnconfigured False False 0 `shouldBe` BdStart
      bootDecision AccessOpen False False 0 `shouldBe` BdStart

    it "refuses passkey with no credentials" $
      bootDecision AccessPasskey True True 0 `shouldSatisfy` isRefusal

    it "refuses passkey on a non-loopback plain-http bind" $
      bootDecision AccessPasskey False False 1 `shouldSatisfy` isRefusal

    it "starts passkey on loopback" $
      bootDecision AccessPasskey True False 1 `shouldBe` BdStart

    it "starts passkey on a non-loopback bind behind https" $
      bootDecision AccessPasskey False True 1 `shouldBe` BdStart

-- Helpers ------------------------------------------------------------------

isRefusal :: BootDecision -> Bool
isRefusal (BdRefuse _) = True
isRefusal BdStart      = False

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
  , acfcCredentials = Map.fromList [(credIdText, sampleCredential)]
  }

openSection :: AccessControlFileConfig
openSection = AccessControlFileConfig
  { acfcMode = Just "none"
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  , acfcCredentials = Map.empty
  }

passkeySection :: AccessControlFileConfig
passkeySection = sampleSection

-- | Decode a whole-file encoding back to just the section.
decodeSection :: Text -> Either Text (Maybe AccessControlFileConfig)
decodeSection encoded = case Toml.parse encoded of
  Left e -> Left (Toml.unTomlParseError e)
  Right toml -> case Toml.runTomlCodec securityConfigCodec toml of
    Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)
    Success cfg  -> Right (scAccessControl cfg)

