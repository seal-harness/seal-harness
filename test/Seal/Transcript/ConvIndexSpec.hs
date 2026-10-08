{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.ConvIndexSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Either (isRight)
import Data.Text (Text)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck

import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.TestHelpers.Arbitrary ()
import Seal.Transcript.Conv (ConvLine (..), encodeConvLine)
import Seal.Transcript.ConvIndex

-- | Encode a message as a conversation line (with trailing newline).
encodeLine :: Message -> BS.ByteString
encodeLine m = encodeConvLine (ConvLine m) <> "\n"

-- | Write messages as a conversation.jsonl file (one JSON line per message).
writeConvFile :: FilePath -> [Message] -> IO ()
writeConvFile path msgs = BS.writeFile path (BS8.concat (map encodeLine msgs))

-- | A simple user text message.
textMsg :: Text -> Message
textMsg t = Message User [CbText t]

spec :: Spec
spec = describe "Seal.Transcript.ConvIndex" $ do

  describe "buildIndex + readConvLines round-trip" $ do
    it "reads back the correct messages for a subset range [2,5)" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            msgs = [textMsg "msg0", textMsg "msg1", textMsg "msg2"
                   ,textMsg "msg3", textMsg "msg4", textMsg "msg5"
                   ,textMsg "msg6", textMsg "msg7"]
        writeConvFile convPath msgs
        eResult <- buildIndex convPath idxPath
        eResult `shouldSatisfy` isRight
        eLines <- readConvLines convPath idxPath 2 5
        eLines `shouldBe` Right [textMsg "msg2", textMsg "msg3", textMsg "msg4"]

    it "reads back all messages with range [0,N)" $
      property $ \msgs ->
        not (null msgs) ==>
          ioProperty $ do
            withSystemTempDirectory "seal-convindex" $ \dir -> do
              let convPath = dir <> "/conversation.jsonl"
                  idxPath  = dir <> "/conversation.idx"
              writeConvFile convPath msgs
              eResult <- buildIndex convPath idxPath
              eResult `shouldSatisfy` isRight
              eLines <- readConvLines convPath idxPath 0 (length msgs)
              pure (eLines `shouldBe` Right msgs)

  describe "edge cases" $ do
    it "empty conversation file: convLineCount=0, readConvLines=[]" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
        BS.writeFile convPath ""
        eResult <- buildIndex convPath idxPath
        eResult `shouldSatisfy` isRight
        lc <- convLineCount idxPath
        lc `shouldBe` 0
        eLines <- readConvLines convPath idxPath 0 0
        eLines `shouldBe` Right []

    it "single line: readConvLines 0 1 returns the one message" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
        writeConvFile convPath [textMsg "hello"]
        _ <- buildIndex convPath idxPath
        eLines <- readConvLines convPath idxPath 0 1
        eLines `shouldBe` Right [textMsg "hello"]

    it "lines with embedded \\n in JSON strings (escaped, not real newlines)" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            -- The text "line1\nline2" is JSON-encoded as "line1\\nline2"
            -- (no actual 0x0a byte in the file)
            msgs = [textMsg "line1\nline2", textMsg "ok"]
        writeConvFile convPath msgs
        _ <- buildIndex convPath idxPath
        lc <- convLineCount idxPath
        lc `shouldBe` 2
        eLines <- readConvLines convPath idxPath 0 2
        eLines `shouldBe` Right msgs

    it "readConvLines with start == end returns []" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
        writeConvFile convPath [textMsg "a", textMsg "b", textMsg "c"]
        _ <- buildIndex convPath idxPath
        eLines <- readConvLines convPath idxPath 1 1
        eLines `shouldBe` Right []

    it "readConvLines with end > lineCount clamps to available lines" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            msgs = [textMsg "a", textMsg "b", textMsg "c"]
        writeConvFile convPath msgs
        _ <- buildIndex convPath idxPath
        eLines <- readConvLines convPath idxPath 0 999999
        eLines `shouldBe` Right msgs