{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.WatchPersist' — the watch-state map
-- persistence module (save/load round-trip, missing file, corrupt file).
module Seal.Channels.Chat.WatchPersistSpec (spec) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import System.Directory (doesFileExist)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Types (ConversationKey (..))
import Seal.Channels.Chat.WatchPersist

-- | Run an action with a temp file path, cleaning up afterward.
withTempFile :: (FilePath -> IO a) -> IO a
withTempFile action =
  withSystemTempDirectory "watch-persist-test" $ \dir ->
    action (dir <> "/watch_state.json")

spec :: Spec
spec = describe "Seal.Channels.Chat.WatchPersist" $ do

  it "saveWatchMap then loadWatchMap round-trips a non-empty map" $
    withTempFile $ \path -> do
      let m :: Map ConversationKey Bool
          m = Map.fromList
                [ (ConversationKey "telegram" "12345", True)
                , (ConversationKey "signal" "conv1", False)
                , (ConversationKey "telegram" "67890", True)
                ]
      saveWatchMap path m
      loaded <- loadWatchMap path
      loaded `shouldBe` Just m

  it "saveWatchMap writes a file" $
    withTempFile $ \path -> do
      let m = Map.singleton (ConversationKey "signal" "conv1") True
      saveWatchMap path m
      exists <- doesFileExist path
      exists `shouldBe` True

  it "loadWatchMap returns Nothing for a missing file" $
    withTempFile $ \path -> do
      loaded <- loadWatchMap path
      loaded `shouldBe` Nothing

  it "loadWatchMap returns Nothing for a corrupt file" $
    withTempFile $ \path -> do
      writeFile path "{not valid json"
      loaded <- loadWatchMap path
      loaded `shouldBe` Nothing

  it "saveWatchMap with empty map round-trips" $
    withTempFile $ \path -> do
      let m = Map.empty :: Map ConversationKey Bool
      saveWatchMap path m
      loaded <- loadWatchMap path
      loaded `shouldBe` Just Map.empty

  it "saveWatchMap overwrites previous content" $
    withTempFile $ \path -> do
      let m1 = Map.singleton (ConversationKey "signal" "conv1") True
          m2 = Map.singleton (ConversationKey "telegram" "12345") False
      saveWatchMap path m1
      saveWatchMap path m2
      loaded <- loadWatchMap path
      loaded `shouldBe` Just m2
