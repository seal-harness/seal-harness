{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Memory.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Core.Types (SessionId (..))
import Seal.Memory.Types
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

-- | A known-good sample memory id, total construction via 'mkMemoryId'.
sampleMemoryId :: MemoryId
sampleMemoryId = case mkMemoryId "m1" of
  Right mid -> mid
  Left _    -> MemoryId "fallback"  -- unreachable; "m1" always validates

sampleEntry :: MemoryEntry
sampleEntry = MemoryEntry
  { meId = sampleMemoryId
  , meContent = "hello world"
  , meTags = ["greeting", "demo"]
  , meCreatedAt = sampleTime
  , meUpdatedAt = sampleTime
  , meSession = SessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Memory.Types" $ do
  describe "mkMemoryId" $ do
    it "accepts a valid id" $
      mkMemoryId "my_mem-1" `shouldBe` Right (MemoryId "my_mem-1")

    it "rejects an empty id" $
      mkMemoryId "" `shouldSatisfy` isLeft

    it "rejects a leading-dot id" $
      mkMemoryId ".hidden" `shouldSatisfy` isLeft

    it "rejects an id with disallowed chars" $
      mkMemoryId "bad/id" `shouldSatisfy` isLeft

    it "round-trips valid ids through the predicate (property)" $
      property $ \case
        MemoryId t -> mkMemoryId t === Right (MemoryId t)

  describe "MemoryEntry JSON" $ do
    it "round-trips through aeson" $
      property $ \e ->
        (decode (encode (e :: MemoryEntry)) :: Maybe MemoryEntry) === Just e

    it "the sample entry round-trips" $
      (decode (encode sampleEntry) :: Maybe MemoryEntry) `shouldBe` Just sampleEntry

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False