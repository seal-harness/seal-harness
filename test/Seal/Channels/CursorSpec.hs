{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Cursor' — the per-conversation tab cursor
-- store. Tests the persistence serialization property: concurrent
-- 'cursorClearAll' calls must not produce stale-snapshot overwrites.
module Seal.Channels.CursorSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Cursor
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Tabs.Types (TabRef (..))

-- | Unwrap 'mkSessionId' for tests (all test ids are valid).
mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left e  -> error ("test mkSid: " <> show e)

spec :: Spec
spec = describe "Seal.Channels.Cursor" $ do

  it "persist calls are serialized — no stale-snapshot overwrite race" $ do
    -- Same race as the watch-state: without a mutation+persist lock,
    -- concurrent cursorClearAll calls can have overlapping save
    -- invocations. A stale snapshot (taken before the other thread's
    -- mutation) can overwrite the newer on-disk state. With the lock,
    -- saves are serialized and each reflects the latest in-memory state.
    activeSaves   <- newIORef (0 :: Int)
    maxConcurrent <- newIORef (0 :: Int)
    savedMaps     <- newIORef ([] :: [Map (Text, Text) TabRef])
    let saveFn m = do
          cur <- atomicModifyIORef' activeSaves (\n -> (n + 1, n + 1))
          atomicModifyIORef' maxConcurrent (\m' -> (max m' cur, ()))
          threadDelay 10000  -- 10 ms — widen the race window
          modifyIORef' savedMaps (m :)
          atomicModifyIORef' activeSaves (\n -> (n - 1, ()))
    store <- newPersistingCursorStoreWith saveFn
    let sid1 = mkSid "20260701-120000-001"
        sid2 = mkSid "20260701-120000-002"
        key1 = ("signal", "conv1") :: (Text, Text)
        key2 = ("signal", "conv2") :: (Text, Text)
        ref1 = BoundSession sid1
        ref2 = BoundSession sid2
    -- Seed with two entries pointing at different tabs
    seedCursorStore store (Map.fromList [(key1, ref1), (key2, ref2)])
    -- Concurrently clear each tab's entries
    withAsync (cursorClearAll store ref1) $ \a1 ->
      withAsync (cursorClearAll store ref2) $ \a2 -> do
        _ <- wait a1
        _ <- wait a2
        pure ()
    maxC <- readIORef maxConcurrent
    maxC `shouldBe` 1  -- saves never overlap
    -- The last save (head) must reflect both clears — empty map
    saves <- readIORef savedMaps
    case saves of
      (m:_) -> Map.null m `shouldBe` True
      []    -> pure ()  -- at least one save happened; empty is correct
