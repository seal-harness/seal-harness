{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.CredentialsSpec (spec) where

import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Arbitrary (..), Gen, chooseInt, elements, ioProperty, listOf, oneof, vectorOf )

import Seal.Config.Credentials
  ( CredentialsFile (..), MigrationOutcome (..), createCredentialsFile
  , loadCredentials, migrateLegacyCredentials, saveCredentials
  , updateCredentialsFile )
import Seal.Config.Security (CredentialFileConfig (..), hasLegacyLayout)

spec :: Spec
spec = describe "Seal.Config.Credentials" $ do

  describe "credentialsCodec" $ do
    prop "round-trips a credential map" $ \(ArbCredMap creds) -> ioProperty $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"
        saveCredentials path (CredentialsFile 1 creds)
        loaded <- loadCredentials path
        pure (loaded == Right (Just (CredentialsFile 1 creds)))

  describe "loadCredentials" $ do
    -- The bug class this pins: an operator writes the file by hand in the
    -- idiomatic TOML style — a bare `version` key plus `[credentials.<id>]`
    -- tables, no explicit `[credentials]` header. tomland leaves the
    -- `credentials` node implicit, the tableMap lookup finds nothing, and the
    -- store decodes as EMPTY. An empty store is not a parse error, so it
    -- would sail through and the operator's passkeys would vanish.
    it "decodes a hand-written [credentials.<id>]-only file" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"
        TIO.writeFile path idiomaticFixture
        loadCredentials path `shouldReturn`
          Right (Just (CredentialsFile 1 (Map.singleton idiomaticId idiomaticCredential)))

    it "decodes a file that carries an explicit [credentials] header" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"
        TIO.writeFile path explicitHeaderFixture
        loadCredentials path `shouldReturn`
          Right (Just (CredentialsFile 1 (Map.singleton idiomaticId idiomaticCredential)))

  describe "createCredentialsFile" $ do
    it "creates a store that did not exist, mode 0600" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"
        createCredentialsFile path idiomaticCreds `shouldReturn` Right ()
        loadCredentials path `shouldReturn`
          Right (Just (CredentialsFile 1 idiomaticCreds))
        stat <- getFileStatus path
        (fileMode stat .&. 0o777) `shouldBe` 0o600

  describe "createCredentialsFile / updateCredentialsFile refusals" $ do
    -- Each refusal must leave the bytes on disk exactly as they were. A guard
    -- that reports failure after writing is worse than no guard: the operator
    -- believes the store is untouched and it is not.
    it "create refuses an existing file, update refuses a missing one, both refuse an empty result" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"

        -- (1) update refuses a missing file, and must not create one.
        updateCredentialsFile path Right
          `shouldRefuseWith` "does not exist"
        doesFileExist path `shouldReturn` False

        -- (2) create refuses an existing file, byte for byte.
        createCredentialsFile path idiomaticCreds `shouldReturn` Right ()
        original <- BS.readFile path
        createCredentialsFile path otherCreds
          `shouldRefuseWith` "already exists"
        BS.readFile path `shouldReturn` original

        -- (3) an empty result is refused in both directions.
        createCredentialsFile path Map.empty
          `shouldRefuseWith` "empty"
        updateCredentialsFile path (const (Right Map.empty))
          `shouldRefuseWith` "empty"
        BS.readFile path `shouldReturn` original

    it "refuses when the callback rejects the change" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"
        createCredentialsFile path idiomaticCreds `shouldReturn` Right ()
        original <- BS.readFile path
        updateCredentialsFile path (const (Left "the last usable credential cannot be removed"))
          `shouldRefuseWith` "last usable credential"
        BS.readFile path `shouldReturn` original

    it "keeps the format version and the entries it did not touch" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let path = dir </> "credentials.toml"
            both = Map.fromList [(idiomaticId, idiomaticCredential), (otherId, otherCredential)]
        createCredentialsFile path idiomaticCreds `shouldReturn` Right ()
        updateCredentialsFile path (Right . Map.insert otherId otherCredential)
          `shouldReturn` Right ()
        loadCredentials path `shouldReturn` Right (Just (CredentialsFile 1 both))

  -- Design §16.10. The migration is the only thing standing between a
  -- pre-split install and a boot refusal, so it has to move everything and
  -- then remove the tables — or do neither.
  describe "migrateLegacyCredentials" $ do
    mapM_ migratesEveryCredential [(False, "header tables"), (True, "dotted keys")]

    it "is idempotent: a second run has nothing to do" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let securityPath = dir </> "security.toml"
            storePath    = dir </> "credentials.toml"
        TIO.writeFile securityPath (legacySecurityFixture False)
        migrateLegacyCredentials securityPath storePath False
          `shouldReturn` Right (Migrated 2)
        migrateLegacyCredentials securityPath storePath False
          `shouldReturn` Right NothingToMigrate

    it "never overwrites an existing store, even with --force" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let securityPath = dir </> "security.toml"
            storePath    = dir </> "credentials.toml"
        TIO.writeFile securityPath (legacySecurityFixture False)
        createCredentialsFile storePath otherCreds `shouldReturn` Right ()
        original <- BS.readFile storePath
        -- Without --force: refused, nothing written.
        migrateLegacyCredentials securityPath storePath False
          `shouldRefuseWith` "already exists"
        BS.readFile storePath `shouldReturn` original
        -- With --force: the tables are dropped, the store is untouched.
        migrateLegacyCredentials securityPath storePath True
          `shouldReturn` Right (Migrated 2)
        BS.readFile storePath `shouldReturn` original
        raw <- TIO.readFile securityPath
        hasLegacyLayout raw `shouldBe` False

    it "does nothing when security.toml holds no credential tables" $
      withSystemTempDirectory "seal-credentials-test" $ \dir -> do
        let securityPath = dir </> "security.toml"
            storePath    = dir </> "credentials.toml"
        TIO.writeFile securityPath "[access_control]\nmode = \"passkey\"\n"
        migrateLegacyCredentials securityPath storePath False
          `shouldReturn` Right NothingToMigrate
        doesFileExist storePath `shouldReturn` False

-- | A credential map with the key shape the real store uses: a base64url
-- credential id (a valid TOML bare key) mapped to one credential table.
newtype ArbCredMap = ArbCredMap (Map Text CredentialFileConfig)
  deriving stock Show

instance Arbitrary ArbCredMap where
  arbitrary = ArbCredMap . Map.fromList <$> listOf genEntry
  -- Shrinking a map of records whose fields feed a codec round-trip buys
  -- little: the failure is in the codec (any value reproduces it) or in one
  -- specific field (shrinking would obscure which).
  shrink _ = []

genEntry :: Gen (Text, CredentialFileConfig)
genEntry = (,) <$> genCredentialId <*> genCredential

-- | 22 base64url characters — the shape of a real credential id, and a valid
-- TOML bare key (no quoting needed, so the encoder and a hand-written file
-- agree).
genCredentialId :: Gen Text
genCredentialId = T.pack <$> vectorOf 22 (elements base64UrlChars)

base64UrlChars :: [Char]
base64UrlChars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "-_"

textChars :: [Char]
textChars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> " _-.:/+"

genCredential :: Gen CredentialFileConfig
genCredential = CredentialFileConfig
  <$> genB64 86          -- 64 bytes of x||y, base64url-unpadded
  <*> chooseInt (0, 1000000)
  <*> genText
  <*> genTimestamp
  <*> genHost
  <*> oneof [pure Nothing, Just <$> genAddedVia]

-- | A base64url string of exactly @n@ characters.
genB64 :: Int -> Gen Text
genB64 n = T.pack <$> vectorOf n (elements base64UrlChars)

-- | Bounded printable text: the shapes these fields actually hold. No
-- control characters or quotes, so a failure message stays readable.
genText :: Gen Text
genText = T.pack <$> listOf (elements textChars)

genHost :: Gen Text
genHost = T.pack <$> listOf (elements (['a' .. 'z'] <> "."))

genTimestamp :: Gen Text
genTimestamp = do
  y  <- chooseInt (1970, 2100)
  mo <- chooseInt (1, 12)
  d  <- chooseInt (1, 28)
  h  <- chooseInt (0, 23)
  mi <- chooseInt (0, 59)
  s  <- chooseInt (0, 59)
  pure (T.pack (pad 4 y <> "-" <> pad 2 mo <> "-" <> pad 2 d <> "T"
                 <> pad 2 h <> ":" <> pad 2 mi <> ":" <> pad 2 s <> "Z"))
  where
    pad w v = let s = show v in replicate (w - length s) '0' <> s

genAddedVia :: Gen Text
genAddedVia = elements ["cli_token", "cli_window", "assertion", "legacy"]

-- | A hand-written store in the idiomatic style: a bare @version@ key and one
-- @[credentials.\<id\>]@ table, with no explicit @[credentials]@ header. No
-- encoder produces this, which is exactly why it needs a test — the encoder
-- always writes the header and so hides the implicit-node bug.
idiomaticFixture :: Text
idiomaticFixture = T.unlines
  [ "version = 1"
  , ""
  , "[credentials." <> idiomaticId <> "]"
  , "public_key = \"" <> T.replicate 86 "A" <> "\""
  , "sign_count = 0"
  , "label = \"laptop\""
  , "created_at = \"2026-10-30T14:00:00Z\""
  , "rp_id = \"localhost\""
  , "added_via = \"cli_token\""
  ]

-- | The same content with the explicit @[credentials]@ header the encoder
-- emits. Both spellings must decode to the same value.
explicitHeaderFixture :: Text
explicitHeaderFixture = T.unlines
  [ "version = 1"
  , ""
  , "[credentials]"
  , ""
  , "[credentials." <> idiomaticId <> "]"
  , "public_key = \"" <> T.replicate 86 "A" <> "\""
  , "sign_count = 0"
  , "label = \"laptop\""
  , "created_at = \"2026-10-30T14:00:00Z\""
  , "rp_id = \"localhost\""
  , "added_via = \"cli_token\""
  ]

idiomaticId :: Text
idiomaticId = T.replicate 22 "A"

idiomaticCredential :: CredentialFileConfig
idiomaticCredential = CredentialFileConfig
  { cfcPublicKey = T.replicate 86 "A"
  , cfcSignCount = 0
  , cfcLabel     = "laptop"
  , cfcCreatedAt = "2026-10-30T14:00:00Z"
  , cfcRpId      = "localhost"
  , cfcAddedVia  = Just "cli_token"
  }

idiomaticCreds :: Map Text CredentialFileConfig
idiomaticCreds = Map.singleton idiomaticId idiomaticCredential

otherId :: Text
otherId = T.replicate 22 "B"

otherCredential :: CredentialFileConfig
otherCredential = idiomaticCredential { cfcLabel = "desktop" }

otherCreds :: Map Text CredentialFileConfig
otherCreds = Map.singleton otherId otherCredential


legacyIdA, legacyIdB :: T.Text
legacyIdA = T.replicate 22 "A"
legacyIdB = T.replicate 22 "B"

-- | A pre-split security.toml holding two credentials, written in one of the
-- two spellings a hand-written file uses. Both spellings have to migrate: the
-- dotted one is what a header-scanning migration would silently drop.
legacySecurityFixture :: Bool -> T.Text
legacySecurityFixture dotted = T.unlines $
  [ "[access_control]"
  , "mode = \"passkey\""
  ] <> credentialLines legacyIdA "laptop" 3 <> credentialLines legacyIdB "desktop" 0
  where
    credentialLines :: T.Text -> T.Text -> Int -> [T.Text]
    credentialLines ident label signCount
      | dotted =
          [ "credentials." <> ident <> ".public_key = \"" <> T.replicate 86 "A" <> "\""
          , "credentials." <> ident <> ".sign_count = " <> T.pack (show signCount)
          , "credentials." <> ident <> ".label = \"" <> label <> "\""
          , "credentials." <> ident <> ".created_at = \"2026-10-30T14:00:00Z\""
          , "credentials." <> ident <> ".rp_id = \"localhost\""
          ]
      | otherwise =
          [ ""
          , "[access_control.credentials." <> ident <> "]"
          , "public_key = \"" <> T.replicate 86 "A" <> "\""
          , "sign_count = " <> T.pack (show signCount)
          , "label = \"" <> label <> "\""
          , "created_at = \"2026-10-30T14:00:00Z\""
          , "rp_id = \"localhost\""
          ]

-- | The named 1.10 behaviour, once per spelling: everything moves, the
-- credentials are marked @legacy@, and the tables are gone afterwards so the
-- next boot does not refuse with BrLegacyLayout.
migratesEveryCredential :: (Bool, String) -> Spec
migratesEveryCredential (dotted, spelling) =
  it ("moves every credential, marks it legacy, and removes the table (" <> spelling <> ")") $
    withSystemTempDirectory "seal-credentials-test" $ \dir -> do
      let securityPath = dir </> "security.toml"
          storePath    = dir </> "credentials.toml"
      TIO.writeFile securityPath (legacySecurityFixture dotted)
      migrateLegacyCredentials securityPath storePath False
        `shouldReturn` Right (Migrated 2)
      loaded <- loadCredentials storePath
      case loaded of
        Left err -> expectationFailure ("store: " <> T.unpack err)
        Right Nothing -> expectationFailure "store was not created"
        Right (Just file) -> do
          crdVersion file `shouldBe` 1
          Map.keys (crdCredentials file) `shouldBe` [legacyIdA, legacyIdB]
          fmap cfcLabel (Map.lookup legacyIdA (crdCredentials file)) `shouldBe` Just "laptop"
          fmap cfcSignCount (Map.lookup legacyIdA (crdCredentials file)) `shouldBe` Just 3
          fmap cfcCreatedAt (Map.lookup legacyIdB (crdCredentials file))
            `shouldBe` Just "2026-10-30T14:00:00Z"
          fmap cfcRpId (Map.lookup legacyIdB (crdCredentials file))
            `shouldBe` Just "localhost"
          fmap cfcAddedVia (Map.lookup legacyIdA (crdCredentials file))
            `shouldBe` Just (Just "legacy")
      raw <- TIO.readFile securityPath
      hasLegacyLayout raw `shouldBe` False

-- | Assert the action refuses, with a message mentioning @needle@.
shouldRefuseWith :: Show a => IO (Either Text a) -> Text -> Expectation
shouldRefuseWith action needle = action >>= \case
  Left msg -> msg `shouldSatisfy` T.isInfixOf needle
  Right ok -> expectationFailure
    ("expected a refusal mentioning " <> show needle <> ", got Right " <> show ok)
