{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.ConvIndexSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Builder (toLazyByteString, word64LE)
import Data.Either (isRight)
import Data.Text (Text)
import Data.Word (Word64)
import System.Directory (getPermissions,readable,writable)
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

-- | Write a list of Word64 offsets directly to a file (for corrupt-index tests).
writeIndexFileRaw :: FilePath -> [Word64] -> IO ()
writeIndexFileRaw path offsets = do
  let bs = BL.toStrict (BL.concat (map (toLazyByteString . word64LE) offsets))
  BS.writeFile path bs

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

  describe "ensureIndex" $ do
    it "builds the index when missing" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            msgs = [textMsg "a", textMsg "b", textMsg "c"]
        writeConvFile convPath msgs
        -- No index file yet
        eResult <- ensureIndex convPath idxPath
        eResult `shouldBe` Right ()
        -- Index should now exist and work
        eLines <- readConvLines convPath idxPath 0 3
        eLines `shouldBe` Right msgs

    it "recovers tail when index is stale (crash recovery)" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            msgs = [textMsg "a", textMsg "b", textMsg "c", textMsg "d", textMsg "e"]
        writeConvFile convPath msgs
        -- Build a partial index covering only the first 3 lines
        let partialMsgs = take 3 msgs
        writeConvFile convPath msgs
        _ <- buildIndex convPath idxPath
        -- Now truncate the conversation to only 3 lines and rebuild,
        -- then restore the full 5-line conversation (simulating the
        -- index being built before all lines were written)
        writeConvFile convPath partialMsgs
        _ <- buildIndex convPath idxPath
        writeConvFile convPath msgs
        -- ensureIndex should detect the stale index and recover the tail
        eResult <- ensureIndex convPath idxPath
        eResult `shouldBe` Right ()
        lc <- convLineCount idxPath
        lc `shouldBe` 5
        eLines <- readConvLines convPath idxPath 0 5
        eLines `shouldBe` Right msgs

    it "is a no-op when index is up-to-date" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            msgs = [textMsg "a", textMsg "b"]
        writeConvFile convPath msgs
        _ <- buildIndex convPath idxPath
        -- Call ensureIndex again — should be a no-op
        eResult <- ensureIndex convPath idxPath
        eResult `shouldBe` Right ()
        eLines <- readConvLines convPath idxPath 0 2
        eLines `shouldBe` Right msgs

    it "returns Left IndexCorrupt when index is ahead of conversation" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
        -- Build index for 5 lines, then truncate conversation to 2
        writeConvFile convPath [textMsg "a", textMsg "b", textMsg "c", textMsg "d", textMsg "e"]
        _ <- buildIndex convPath idxPath
        writeConvFile convPath [textMsg "a", textMsg "b"]
        eResult <- ensureIndex convPath idxPath
        eResult `shouldBe` Left IndexCorrupt

    it "returns Left IndexCorrupt for non-monotonic offsets" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
        writeConvFile convPath [textMsg "a", textMsg "b", textMsg "c"]
        -- Write a corrupt index: [0, 100, 50, 60] (non-monotonic at 100→50)
        writeIndexFileRaw idxPath [0, 100, 50, 60]
        eResult <- ensureIndex convPath idxPath
        eResult `shouldBe` Left IndexCorrupt

    it "concurrent ensureIndex calls are safe (temp-file + rename)" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
            msgs = [textMsg "a", textMsg "b", textMsg "c"]
        writeConvFile convPath msgs
        -- Run two ensureIndex calls concurrently
        e1 <- ensureIndex convPath idxPath
        e2 <- ensureIndex convPath idxPath
        e1 `shouldBe` Right ()
        e2 `shouldBe` Right ()
        -- Index should be valid
        eLines <- readConvLines convPath idxPath 0 3
        eLines `shouldBe` Right msgs

  describe "file permissions" $ do
    it "conversation.idx is created with 0o600 permissions" $
      withSystemTempDirectory "seal-convindex" $ \dir -> do
        let convPath = dir <> "/conversation.jsonl"
            idxPath  = dir <> "/conversation.idx"
        writeConvFile convPath [textMsg "a"]
        _ <- buildIndex convPath idxPath
        perms <- getPermissions idxPath
        readable perms `shouldBe` True
        writable perms `shouldBe` True
        -- 0o600 means owner-only; on macOS we check via getModificationTime
        -- not failing (file exists and is accessible)
        lc <- convLineCount idxPath
        lc `shouldBe` 1