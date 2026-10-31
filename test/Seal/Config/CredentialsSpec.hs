{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.CredentialsSpec (spec) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Arbitrary (..), Gen, chooseInt, elements, ioProperty, listOf, oneof, vectorOf )

import Seal.Config.Credentials
  ( CredentialsFile (..), loadCredentials, saveCredentials )
import Seal.Config.Security (CredentialFileConfig (..))

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
