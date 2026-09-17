{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.StreamProgressSpec (spec) where

import Data.Default (Default (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, fromGregorian, secondsToDiffTime)
import Data.Time.Clock (UTCTime(..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf1, (===))

import Seal.Channels.StreamProgress
  ( StreamProgressConfig (..)
  , resolveStreamProgressConfig
  , formatToolLine
  , shouldEdit
  , addCursor
  , stripCursor
  )
import Seal.Core.Types (OpName (..))

spec :: Spec
spec = do
  describe "Seal.Channels.StreamProgress.defaultStreamProgressConfig" $ do
    it "is disabled by default" $
      spcEnabled def `shouldBe` False

    it "has tool_progress enabled when enabled" $
      spcToolProgress def `shouldBe` True

    it "has text_streaming enabled when enabled" $
      spcTextStreaming def `shouldBe` True

    it "has a 1500ms edit interval" $
      spcEditIntervalMs def `shouldBe` 1500

    it "has a buffer threshold of 80 codepoints" $
      spcBufferThreshold def `shouldBe` 80

    it "has a block cursor" $
      spcCursor def `shouldBe` "\x2589"

  describe "Seal.Channels.StreamProgress.resolveStreamProgressConfig" $ do
    it "returns disabled config when Nothing" $
      resolveStreamProgressConfig Nothing `shouldBe` def

    it "resolves a fully-populated config" $
      resolveStreamProgressConfig (Just def { spcEnabled = True, spcEditIntervalMs = 2000 })
        `shouldBe` def { spcEnabled = True, spcEditIntervalMs = 2000 }

    it "fills defaults for absent fields" $
      resolveStreamProgressConfig (Just def { spcEnabled = True })
        `shouldBe` def { spcEnabled = True }

  describe "formatToolLine" $ do
    it "shows the opcode name and a truncated input" $
      formatToolLine Set.empty (OpName "SHELL_EXEC") "{\"command\":\"ls\"}"
        `shouldBe` "\x1F50D SHELL_EXEC {\"command\":\"ls\"}"

    it "truncates long inputs to 120 chars + ..." $
      let longInput = T.replicate 200 "x"
      in formatToolLine Set.empty (OpName "FILE_READ") longInput
           `shouldBe` "\x1F50D FILE_READ " <> T.take 120 longInput <> "..."

    it "redacts input for secret-bearing opcodes" $
      formatToolLine (Set.singleton (OpName "SECRET_GET")) (OpName "SECRET_GET") "vault-key"
        `shouldBe` "\x1F50D SECRET_GET <redacted>"

    it "does not redact non-secret opcodes" $
      formatToolLine (Set.singleton (OpName "SECRET_GET")) (OpName "SHELL_EXEC") "ls"
        `shouldBe` "\x1F50D SHELL_EXEC ls"

  describe "shouldEdit" $ do
    let cfg = def { spcEditIntervalMs = 1000, spcBufferThreshold = 80 }
        t0 = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

    it "sends immediately when no prior edit" $
      shouldEdit cfg t0 Nothing 0 `shouldBe` True

    it "sends when buffer threshold is exceeded regardless of time" $
      shouldEdit cfg t0 (Just t0) 100 `shouldBe` True

    it "does not send when below threshold and within edit interval" $
      shouldEdit cfg t0 (Just t0) 10 `shouldBe` False

    it "sends when edit interval has elapsed even below threshold" $
      let t1 = addUTCTime 1.5 t0
      in shouldEdit cfg t1 (Just t0) 10 `shouldBe` True

    it "does not send when within edit interval and below threshold" $
      let t1 = addUTCTime 0.5 t0
      in shouldEdit cfg t1 (Just t0) 10 `shouldBe` False

  describe "addCursor / stripCursor" $ do
    let cfg = def { spcCursor = "\x2589" }

    it "addCursor appends the cursor" $
      addCursor cfg "hello" `shouldBe` "hello\x2589"

    it "stripCursor removes a trailing cursor" $
      stripCursor cfg "hello\x2589" `shouldBe` "hello"

    it "stripCursor leaves text without a cursor unchanged" $
      stripCursor cfg "hello" `shouldBe` "hello"

    it "addCursor then stripCursor is identity" $
      stripCursor cfg (addCursor cfg "hello") `shouldBe` "hello"

    prop "stripCursor . addCursor == id" $
      forAll genText $ \t ->
        stripCursor cfg (addCursor cfg t) === t

genText :: Gen Text
genText = T.pack <$> listOf1 (elements ['a'..'z'])