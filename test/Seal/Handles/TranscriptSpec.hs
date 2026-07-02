{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.TranscriptSpec (spec) where

import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Transcript.Types
import Seal.Handles.Transcript

mkEntry :: IO TranscriptEntry
mkEntry = do
  now <- getCurrentTime
  pure TranscriptEntry
    { teId = "e1"
    , teTimestamp = now
    , teModel = Nothing
    , teDirection = Request
    , tePayload = object ["x" .= (1 :: Int)]
    , teDurationMs = Nothing
    , teCorrelation = Nothing
    , teMeta = Map.empty
    }

spec :: Spec
spec = describe "Seal.Handles.Transcript" $ do
  it "recordAndAck durably appends one JSONL line per entry" $
    withSystemTempDirectory "seal-tx" $ \dir -> do
      let path = dir </> "transcript.jsonl"
      e <- mkEntry
      withTranscript path $ \h -> do
        recordAndAck h e
        recordAndAck h e
      contents <- BS8.readFile path
      length (BS8.lines contents) `shouldBe` 2

  it "drains a recordAsync entry queued just before scope exit" $
    withSystemTempDirectory "seal-tx" $ \dir -> do
      let path = dir </> "transcript.jsonl"
      e <- mkEntry
      withTranscript path $ \h ->
        recordAsync h e
      contents <- BS8.readFile path
      length (BS8.lines contents) `shouldBe` 1

  it "fakeTranscript records invocation order for assertions" $ do
    (h, readLog) <- fakeTranscript
    e <- mkEntry
    recordAndAck h e
    logged <- readLog
    map teId logged `shouldBe` ["e1"]
