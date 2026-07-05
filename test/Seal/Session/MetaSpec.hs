{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.MetaSpec (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.Either (fromRight)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

sampleMeta :: SessionMeta
sampleMeta =
  let sid = fromRight (error "bad id") (mkSessionId "20260701-120000-042")
  in SessionMeta
       { smId = sid, smProvider = "anthropic", smModel = "claude-opus-4-8"
       , smChannel = "cli", smCreatedAt = sampleTime, smLastActive = sampleTime }

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
