{-# LANGUAGE OverloadedStrings #-}
-- | Instance names and the vault-key names derived from them.
--
-- The properties here are the security-relevant part: the two derived
-- namespaces must be disjoint from each other and from the legacy keys, and the
-- name grammar must make the derivation injective.
module Seal.Providers.NameSpec (spec) where

import Data.Either (rights)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf, vectorOf, (===), (==>))

import Seal.Providers.Name
  ( ProviderName, apiKeyNameFor, apiKeyPrefix, checkNameForType, mkProviderName
  , oauthKeyNameFor, oauthKeyPrefix, providerNameText, reservedProviderNames
  , shoutySnake )

-- ── Generators (bounded: the grammar alphabet, ≤ 12 chars) ──────────────────

genName :: Gen Text
genName = do
  n <- elements [1 .. 12]
  T.pack <$> vectorOf n (elements "abz09-")

-- | A generator that only produces strings the grammar accepts.
-- | Two independent valid names.
genPair :: Gen (ProviderName, ProviderName)
genPair = (,) <$> genValidName <*> genValidName

genValidName :: Gen ProviderName
genValidName = do
  candidates <- listOf genName
  case rights (map mkProviderName candidates) of
    (n : _) -> pure n
    []      -> pure (either (error "impossible") id (mkProviderName "local-vllm"))

-- ── Spec ───────────────────────────────────────────────────────────────────

spec :: Spec
spec = describe "Seal.Providers.Name" $ do

  describe "mkProviderName" $ do
    it "accepts ordinary instance names" $
      map (fmap providerNameText . mkProviderName)
          ["groq", "work-proxy", "a1", "anthropic", "openai-compat", "openrouter"]
        `shouldBe` map Right ["groq", "work-proxy", "a1", "anthropic", "openai-compat", "openrouter"]

    it "rejects the empty string, uppercase, underscores, dots and non-ASCII" $
      map mkProviderName ["", "Work", "work_proxy", "work.proxy", T.pack "caf\233"]
        `shouldSatisfy` all isLeft'

    it "rejects leading/trailing dashes and double dashes" $
      map mkProviderName ["-x", "x-", "a--b"] `shouldSatisfy` all isLeft'

    it "rejects names longer than 32 characters" $
      mkProviderName (T.replicate 33 "a") `shouldSatisfy` isLeft'

    it "accepts a 32-character name" $
      mkProviderName (T.replicate 32 "a") `shouldSatisfy` isRight'

    it "rejects the reserved route words" $
      map mkProviderName reservedProviderNames `shouldSatisfy` all isLeft'

  describe "checkNameForType" $ do
    let known = ["anthropic", "ollama", "openai-compat"]
    it "allows a type id as its own instance name" $
      runName "anthropic" (\n -> checkNameForType known n "anthropic") `shouldBe` Right ()
    it "rejects another type's id" $
      runName "ollama" (\n -> checkNameForType known n "anthropic")
        `shouldBe` Left "is another provider's type id"
    it "allows an ordinary name" $
      runName "work" (\n -> checkNameForType known n "anthropic") `shouldBe` Right ()

  describe "derived vault-key names" $ do
    it "maps a name to SHOUTY_SNAKE" $
      runName "work-proxy" shoutySnake `shouldBe` "WORK_PROXY"

    it "keeps the legacy key for a type-named instance" $ do
      runName "anthropic" (\n -> apiKeyNameFor (Just "ANTHROPIC_API_KEY") n "anthropic")
        `shouldBe` "ANTHROPIC_API_KEY"
      runName "openai-compat" (\n -> apiKeyNameFor (Just "OPENAI_COMPAT_API_KEY") n "openai-compat")
        `shouldBe` "OPENAI_COMPAT_API_KEY"

    it "derives a prefixed key for any other name" $ do
      runName "work" (\n -> apiKeyNameFor (Just "ANTHROPIC_API_KEY") n "anthropic")
        `shouldBe` "PROVIDER_APIKEY_WORK"
      runName "anthropic-work" (\n -> oauthKeyNameFor (Just "ANTHROPIC_OAUTH_TOKENS") n "anthropic")
        `shouldBe` "PROVIDER_OAUTH_ANTHROPIC_WORK"

    it "regression: `x`'s OAuth and `x-oauth-tokens`'s API key are different keys" $ do
      let oauthOfX = runName "x" (\n -> oauthKeyNameFor Nothing n "anthropic")
          apiOfSuffix = runName "x-oauth-tokens" (\n -> apiKeyNameFor Nothing n "anthropic")
      oauthOfX `shouldBe` "PROVIDER_OAUTH_X"
      apiOfSuffix `shouldBe` "PROVIDER_APIKEY_X_OAUTH_TOKENS"
      oauthOfX `shouldNotBe` apiOfSuffix

    prop "distinct names derive distinct SHOUTY_SNAKE stems" $
      forAll genPair $ \(a, b) ->
        providerNameText a /= providerNameText b
          ==> shoutySnake a /= shoutySnake b

    prop "the api-key and oauth namespaces never alias (cross-role)" $
      forAll genPair $ \(a, b) ->
        apiKeyNameFor Nothing a "anthropic" /= oauthKeyNameFor Nothing b "anthropic"

    prop "a derived name always carries one of the two prefixes" $
      forAll genValidName $ \n ->
        let api = apiKeyNameFor Nothing n "anthropic"
            oau = oauthKeyNameFor Nothing n "anthropic"
        in (apiKeyPrefix `T.isPrefixOf` api, oauthKeyPrefix `T.isPrefixOf` oau) === (True, True)

-- ── Helpers ────────────────────────────────────────────────────────────────

runName :: Text -> (ProviderName -> a) -> a
runName t f = case mkProviderName t of
  Right n -> f n
  Left e  -> error ("mkProviderName " <> show t <> " failed: " <> T.unpack e)

isLeft' :: Either a b -> Bool
isLeft' (Left _) = True
isLeft' _        = False

isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False
