{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the streaming file-reading helpers in 'Seal.Util.StrictIO'.
-- These verify that 'streamDecodeLines' and 'streamDecodeAfter' correctly
-- decode JSONL files line-by-line without materializing the entire file,
-- and that 'streamDecodeAfter' correctly skips the first N non-empty lines.
module Seal.Util.StrictIOSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (mapMaybe)
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Test.Hspec

import Seal.Util.StrictIO (streamDecodeLines, streamDecodeAfter)

-- | Encode a 'Value' as a strict 'ByteString' (one JSONL line, no newline).
encVal :: Value -> ByteString
encVal = BL.toStrict . A.encode

-- | Write JSONL lines to a file. Each 'Value' is encoded on its own line.
writeJsonl :: FilePath -> [Value] -> IO ()
writeJsonl path vals =
  BS.writeFile path (BS.concat (map (\v -> encVal v <> "\n") vals))

-- | Write raw lines (each followed by a newline) to a file.
writeRawLines :: FilePath -> [ByteString] -> IO ()
writeRawLines path lines' =
  BS.writeFile path (BS.concat (map (<> "\n") lines'))

-- | Extract the integer value of the "i" field from a JSON object.
getInt :: Value -> Maybe Int
getInt (Object o) = case KeyMap.lookup (Key.fromString "i") o of
  Just (Number n) -> Just (round n)
  _ -> Nothing
getInt _ = Nothing

spec :: Spec
spec = describe "Seal.Util.StrictIO streaming" $ do

  describe "streamDecodeLines" $ do
    it "decodes all JSON lines from a file" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
            vals = [ object ["i" .= (1 :: Int)]
                   , object ["i" .= (2 :: Int)]
                   , object ["i" .= (3 :: Int)]
                   ]
        writeJsonl path vals
        result <- streamDecodeLines path :: IO [Value]
        length result `shouldBe` 3
        result `shouldBe` vals

    it "skips empty lines" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
        writeRawLines path
          [ encVal (object ["i" .= (1 :: Int)])
          , ""  -- empty line
          , encVal (object ["i" .= (2 :: Int)])
          , ""  -- empty line
          ]
        result <- streamDecodeLines path :: IO [Value]
        length result `shouldBe` 2

    it "handles file with no trailing newline" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
            v1 = object ["i" .= (1 :: Int)]
            v2 = object ["i" .= (2 :: Int)]
        -- Write without trailing newline
        BS.writeFile path (encVal v1 <> "\n" <> encVal v2)
        result <- streamDecodeLines path :: IO [Value]
        length result `shouldBe` 2
        result `shouldBe` [v1, v2]

    it "returns empty list for empty file" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "empty.jsonl"
        BS.writeFile path ""
        result <- streamDecodeLines path :: IO [Value]
        result `shouldBe` []

    it "drops unparseable lines silently" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
        writeRawLines path
          [ encVal (object ["i" .= (1 :: Int)])
          , "not valid json{{"
          , encVal (object ["i" .= (2 :: Int)])
          ]
        result <- streamDecodeLines path :: IO [Value]
        length result `shouldBe` 2

  describe "streamDecodeAfter" $ do
    it "skips first K lines and decodes the rest" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
            vals = [ object ["i" .= (1 :: Int)]
                   , object ["i" .= (2 :: Int)]
                   , object ["i" .= (3 :: Int)]
                   , object ["i" .= (4 :: Int)]
                   , object ["i" .= (5 :: Int)]
                   ]
        writeJsonl path vals
        result <- streamDecodeAfter 2 path :: IO [Value]
        length result `shouldBe` 3
        mapMaybe getInt result `shouldBe` [3, 4, 5]

    it "returns all lines when skip=0" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
            vals = [ object ["i" .= (1 :: Int)]
                   , object ["i" .= (2 :: Int)]
                   ]
        writeJsonl path vals
        result <- streamDecodeAfter 0 path :: IO [Value]
        length result `shouldBe` 2

    it "returns empty when skip >= total lines" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
            vals = [ object ["i" .= (1 :: Int)]
                   , object ["i" .= (2 :: Int)]
                   ]
        writeJsonl path vals
        result <- streamDecodeAfter 5 path :: IO [Value]
        result `shouldBe` []

    it "does not count empty lines toward skip count" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
        writeRawLines path
          [ encVal (object ["i" .= (1 :: Int)])
          , ""  -- empty line (not counted)
          , encVal (object ["i" .= (2 :: Int)])
          , ""  -- empty line (not counted)
          , encVal (object ["i" .= (3 :: Int)])
          ]
        -- Skip 1 non-empty line -> should return items 2 and 3
        result <- streamDecodeAfter 1 path :: IO [Value]
        length result `shouldBe` 2

    it "handles skip=1 with no trailing newline on last line" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
            v1 = object ["i" .= (1 :: Int)]
            v2 = object ["i" .= (2 :: Int)]
        BS.writeFile path (encVal v1 <> "\n" <> encVal v2)
        result <- streamDecodeAfter 1 path :: IO [Value]
        length result `shouldBe` 1
        result `shouldBe` [v2]

    it "handles empty file with skip > 0" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "empty.jsonl"
        BS.writeFile path ""
        result <- streamDecodeAfter 3 path :: IO [Value]
        result `shouldBe` []

    it "drops unparseable lines in the decode phase" $
      withSystemTempDirectory "seal-strictio" $ \dir -> do
        let path = dir </> "test.jsonl"
        writeRawLines path
          [ encVal (object ["i" .= (1 :: Int)])
          , encVal (object ["i" .= (2 :: Int)])
          , "not valid json{{"
          , encVal (object ["i" .= (3 :: Int)])
          ]
        -- Skip 1 -> starts at line 2. Line 2 is valid, line 3 is junk
        -- (dropped), line 4 is valid.
        result <- streamDecodeAfter 1 path :: IO [Value]
        length result `shouldBe` 2