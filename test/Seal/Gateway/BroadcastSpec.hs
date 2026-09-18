{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Seal.Gateway.BroadcastSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar)
import Control.Exception (catch, SomeException)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Test.Hspec

import Data.Default (def)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Set qualified as Set
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Gateway.Broadcast (wrapCapsForAskStatus)
import Seal.Gateway.StreamBroker
  (BrokerEvent (..), StreamBroker, newStreamBroker, subscribe, thinkingSessions)

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

-- | Subscribe with a no-op close action and collect events into an IORef.
collectEvents :: StreamBroker -> SessionId -> IO (TVar SessionId, IORef [BrokerEvent])
collectEvents broker sid = do
  ref <- newIORef ([] :: [BrokerEvent])
  tv <- subscribe broker sid (\e -> modifyIORef' ref (e :)) (pure ())
  pure (tv, ref)

-- | Extract the status string from a BeActivity harness-status event.
harnessStatusVal :: BrokerEvent -> Maybe Text
harnessStatusVal (BeActivity _ payload) =
  case payload of
    A.Object o -> case KM.lookup "status" o of
      Just (A.String s) -> Just s
      _ -> Nothing
    _ -> Nothing
harnessStatusVal _ = Nothing

-- | Check whether any collected event carries the given harness status.
hasStatus :: Text -> [BrokerEvent] -> Bool
hasStatus expected = any (\e -> harnessStatusVal e == Just expected)

-- | Poll an IORef until the predicate holds, or timeout after the given
-- number of microseconds (retrying every 10ms). Avoids flaky timing-based
-- assertions on loaded CI runners.
waitFor :: Int -> IO a -> (a -> Bool) -> IO Bool
waitFor totalWaitUs readAction predicate = go totalWaitUs
  where
    stepUs = 10000  -- 10ms per poll
    go remaining
      | remaining <= 0 = pure False
      | otherwise = do
          val <- readAction
          if predicate val
            then pure True
            else do
              threadDelay stepUs
              go (remaining - stepUs)

spec :: Spec
spec = describe "Seal.Gateway.Broadcast" $ do

  describe "wrapCapsForAskStatus" $ do

    it "broadcasts idle before ccPrompt blocks and thinking after it returns" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "s1"
      (_, ref) <- collectEvents broker sid
      -- An MVar to control when the inner ccPrompt unblocks: the wrapped
      -- prompt calls the inner prompt, which blocks on the MVar until the
      -- test fills it. This lets us observe the idle broadcast BEFORE the
      -- answer arrives.
      unblockMVar <- newEmptyMVar
      let innerCaps = def
            { ccPrompt = \_AskPrompt -> do
                _ <- takeMVar unblockMVar
                pure "the answer"
            }
          wrapped = wrapCapsForAskStatus (Just broker) sid innerCaps
      -- Fork the wrapped ccPrompt so we can observe events before + after
      resultMVar <- newEmptyMVar
      _ <- forkIO $ do
        ans <- ccPrompt wrapped (AskPrompt "what?" [])
        putMVar resultMVar ans
      -- Wait for the idle broadcast to fire (poll up to 5 seconds to
      -- avoid flakiness on loaded CI runners).
      idleSeen <- waitFor 5000000 (readIORef ref) (hasStatus "idle")
      idleSeen `shouldBe` True
      -- The session should NOT be in the thinking set (it's idle now)
      thinkingBefore <- thinkingSessions broker
      Set.notMember sid thinkingBefore `shouldBe` True
      -- Now "the human answers" — unblock the inner prompt
      putMVar unblockMVar ()
      ans <- takeMVar resultMVar
      ans `shouldBe` "the answer"
      -- After ccPrompt returns, the thinking broadcast should have fired
      eventsAfter <- readIORef ref
      hasStatus "thinking" eventsAfter `shouldBe` True
      -- The session should be back in the thinking set
      thinkingAfter <- thinkingSessions broker
      Set.member sid thinkingAfter `shouldBe` True

    it "preserves the ccPrompt return value (passes through the answer)" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "s2"
          innerCaps = def
            { ccPrompt = \_AskPrompt -> pure "hello world"
            }
          wrapped = wrapCapsForAskStatus (Just broker) sid innerCaps
      ans <- ccPrompt wrapped (AskPrompt "q?" [])
      ans `shouldBe` "hello world"

    it "preserves other ChannelCaps fields (ccSend, ccShowHuman, ccStreaming, ccPromptSecret)" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "s3"
      sendRef <- newIORef ([] :: [Text])
      let innerCaps = def
            { ccSend = \t -> modifyIORef' sendRef (t :)
            , ccPrompt = \_ -> pure "ans"
            , ccPromptSecret = \_ -> pure "secret"
            , ccStreaming = False
            , ccShowHuman = \t -> modifyIORef' sendRef (("SHOW:" <> t) :)
            }
          wrapped = wrapCapsForAskStatus (Just broker) sid innerCaps
      -- ccSend works
      ccSend wrapped "hi"
      sends <- readIORef sendRef
      "hi" `elem` sends `shouldBe` True
      -- ccShowHuman works
      ccShowHuman wrapped "msg"
      sends2 <- readIORef sendRef
      "SHOW:msg" `elem` sends2 `shouldBe` True
      -- ccPromptSecret works
      secret <- ccPromptSecret wrapped "prompt"
      secret `shouldBe` "secret"
      -- ccStreaming preserved
      ccStreaming wrapped `shouldBe` False

    it "is a no-op when broker is Nothing (no broadcast, passthrough)" $ do
      let sid = mkSid "s4"
          innerCaps = def { ccPrompt = \_AskPrompt -> pure "passthrough" }
          wrapped = wrapCapsForAskStatus Nothing sid innerCaps
      ans <- ccPrompt wrapped (AskPrompt "q?" [])
      ans `shouldBe` "passthrough"

    it "broadcasts thinking even when the inner ccPrompt throws" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "s5"
      (_, ref) <- collectEvents broker sid
      let innerCaps = def
            { ccPrompt = \_AskPrompt -> error "boom"
            }
          wrapped = wrapCapsForAskStatus (Just broker) sid innerCaps
      -- The exception should propagate (the wrapper doesn't swallow it),
      -- but the thinking broadcast should still fire so the session is
      -- not stuck in idle after the error.
      _ <- ccPrompt wrapped (AskPrompt "q?" [])
        `catch` \(_e :: SomeException) -> pure "caught"
      events <- readIORef ref
      hasStatus "idle" events `shouldBe` True
      hasStatus "thinking" events `shouldBe` True
