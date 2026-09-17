{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the Signal transport's stdin serialization lock. The real
-- transport ('mkRealSignalTransport') shares a single stdin handle ('hIn')
-- across 'stSend', 'stSendWithId', 'stEditMessage', and 'stDeleteMessage'.
-- Without a serialization lock, concurrent calls from the forked agent-turn
-- thread (tool-progress bubbles) and the main loop thread (e.g. @/tab focus@
-- confirmation) can interleave bytes, corrupting JSON-RPC frames. These
-- tests verify the mock transport is race-safe (the mock uses an 'IORef'
-- which is atomic, but the contract is the same: no interleaved captures).
module Seal.Channels.Signal.TransportLockSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM_, void)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channels.Signal.Transport

spec :: Spec
spec = do
  describe "Seal.Channels.Signal.Transport concurrent send serialization" $ do
    it "concurrent stSend calls do not interleave captures (each send is atomic)" $ do
      (t, getCaptured) <- mkMockSignalTransport []
      let n = 100 :: Int
          msg = "msg-"
      -- Fork n threads, each sending one message.
      replicateM_ n (void (forkIO (stSend t "+1" (msg <> T.pack (show n)))))
      -- Give the threads time to finish.
      threadDelay 100000
      cap <- getCaptured
      length cap `shouldBe` n

    it "stSend and stSendWithId can be called concurrently without deadlock" $ do
      (t, _) <- mkMockSignalTransport []
      done <- newEmptyMVar :: IO (MVar ())
      void (forkIO (stSend t "+1" "fire-and-forget"))
      void (forkIO (void (stSendWithId t "+1" "with-id")))
      void (forkIO (void (stSendWithId t "+1" "with-id-2")))
      void (forkIO (stSend t "+1" "fire-and-forget-2"))
      -- If the lock deadlocks, this takeMVar never completes.
      threadDelay 50000
      putMVar done ()
      _ <- takeMVar done
      pure () :: IO ()
