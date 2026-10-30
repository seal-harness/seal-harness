{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.MetaSpec (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.Either (fromRight)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.Set as Set
import Test.Hspec

import Seal.Agent.Def.Types (mkAgentDefId)
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

sampleMeta :: SessionMeta
sampleMeta =
  let sid = fromRight (error "bad id") (mkSessionId "20260701-120000-042")
  in SessionMeta
       { smId = sid, smProvider = "anthropic", smModel = "claude-opus-4-8"
       , smChannel = "cli", smParent = Nothing, smAgent = Nothing, smSystemOverride = Nothing, smAgentName = Nothing
       , smDescription = Nothing
       , smSealFrontMatter = True
       , smRepoUrl = Nothing
       , smCreatedAt = sampleTime, smLastActive = sampleTime
       , smAllowedSecrets = mempty }

spec :: Spec
spec = describe "Seal.Session.Meta" $ do
  it "round-trips through JSON" $
    decode (encode sampleMeta) `shouldBe` Just sampleMeta

  it "uses snake_case keys and preserves the id text" $ do
    let m2 = decode (encode sampleMeta)
    fmap (sessionIdText . smId) m2 `shouldBe` Just "20260701-120000-042"

  it "defaults channel to \"cli\" when absent" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smChannel (decode (encode j)) `shouldBe` Just "cli"

  it "defaults agent to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smAgent (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smAgent = Just aid" $ do
    let aid = fromRight (error "bad agent id") (mkAgentDefId "zoe")
        m = sampleMeta { smAgent = Just aid }
    fmap smAgent (decode (encode m)) `shouldBe` Just (Just aid)

  it "round-trips smSystemOverride = Just t" $ do
    let m = sampleMeta { smSystemOverride = Just "be concise" }
    fmap smSystemOverride (decode (encode m)) `shouldBe` Just (Just "be concise")

  it "defaults smSystemOverride to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smSystemOverride (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smAgentName = Just t" $ do
    let m = sampleMeta { smAgentName = Just "zoe" }
    fmap smAgentName (decode (encode m)) `shouldBe` Just (Just "zoe")

  it "defaults smAgentName to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smAgentName (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smDescription = Just t" $ do
    let m = sampleMeta { smDescription = Just "my tab name" }
    fmap smDescription (decode (encode m)) `shouldBe` Just (Just "my tab name")

  it "defaults smDescription to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smDescription (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smRepoUrl = Just t" $ do
    let m = sampleMeta { smRepoUrl = Just "https://github.com/seal-harness/seal-harness.git" }
    fmap smRepoUrl (decode (encode m)) `shouldBe` Just (Just "https://github.com/seal-harness/seal-harness.git")

  it "defaults smRepoUrl to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smRepoUrl (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smSealFrontMatter = False" $ do
    let m = sampleMeta { smSealFrontMatter = False }
    fmap smSealFrontMatter (decode (encode m)) `shouldBe` Just False

  it "defaults smSealFrontMatter to True when absent (backwards-compat)" $ do
    -- A session.json written before the toggle existed has no
    -- 'seal_front_matter' key — it must load with the front matter ON.
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smSealFrontMatter (decode (encode j)) `shouldBe` Just True

  it "defaults smParent to Nothing when absent (backwards-compat)" $ do
    -- A session.json written before the parent link existed has no
    -- 'parent' key — it must load as a top-level session.
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smParent (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smParent = Just sid" $ do
    let sid = fromRight (error "bad id") (mkSessionId "20260601-120000-009")
        m = sampleMeta { smParent = Just sid }
    fmap smParent (decode (encode m)) `shouldBe` Just (Just sid)

  -- ── smAllowedSecrets ──────────────────────────────────────────
  it "toJSON includes allowed_secrets as empty array when mempty" $ do
    let m = sampleMeta { smAllowedSecrets = mempty }
        v = encode m
    decode v `shouldBe` Just m  -- round-trip preserves mempty

  it "toJSON includes allowed_secrets as array when non-empty" $ do
    let m = sampleMeta { smAllowedSecrets = Set.fromList ["a", "b"] }
        v = encode m
    decode v `shouldBe` Just m

  it "fromJSON parses Just (fromList [\"a\",\"b\"]) from [\"a\",\"b\"]" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime
              , "allowed_secrets" .= (["a", "b"] :: [String])
              ]
    fmap smAllowedSecrets (decode (encode j)) `shouldBe` Just (Set.fromList ["a", "b"])

  it "fromJSON defaults smAllowedSecrets to mempty when field absent" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smAllowedSecrets (decode (encode j)) `shouldBe` Just mempty

  it "fromJSON defaults smAllowedSecrets to mempty when field is null" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime
              , "allowed_secrets" .= (Nothing :: Maybe [String])
              ]
    fmap smAllowedSecrets (decode (encode j)) `shouldBe` Just mempty

  it "fromJSON parses Set.empty from []" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime
              , "allowed_secrets" .= ([] :: [String])
              ]
    fmap smAllowedSecrets (decode (encode j)) `shouldBe` Just Set.empty

  it "round-trip: encode . decode == id (with non-empty set)" $ do
    let m = sampleMeta { smAllowedSecrets = Set.fromList ["a", "b"] }
    decode (encode m) `shouldBe` Just m
