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