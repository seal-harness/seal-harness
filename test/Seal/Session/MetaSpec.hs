{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.MetaSpec (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.Either (fromRight)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
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
       , smChannel = "cli", smAgent = Nothing, smSystemOverride = Nothing, smAgentName = Nothing
       , smCreatedAt = sampleTime, smLastActive = sampleTime }

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
