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
import Data.Aeson (object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Set qualified as Set
import Data.Text qualified as T
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Core.Types (mkSessionId, SessionId, OpName (..))
import Seal.Gateway.Broadcast (wrapCapsForAskStatus, broadcastToolCall)
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

  describe "broadcastToolCall" $ do

    it "broadcasts a tool-call activity event with the tool name and input" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "tc1"
      (_, ref) <- collectEvents broker sid
      let input = object ["path" .= ("src/Main.hs" :: Text)]
      broadcastToolCall (Just broker) sid (OpName "FILE_READ") input
      events <- readIORef ref
      case events of
        [BeActivity _ payload] -> case payload of
          A.Object o -> do
            case KM.lookup "kind" o of
              Just (A.String "tool-call") -> pure ()
              other -> expectationFailure ("expected kind=tool-call, got " <> show other)
            case KM.lookup "tool" o of
              Just (A.String "FILE_READ") -> pure ()
              other -> expectationFailure ("expected tool=FILE_READ, got " <> show other)
            case KM.lookup "input" o of
              Just (A.String t) ->
                ("path" `T.isInfixOf` t) `shouldBe` True
              other -> expectationFailure ("expected input string, got " <> show other)
          other -> expectationFailure ("expected object payload, got " <> show other)
        other -> expectationFailure ("expected [BeActivity], got " <> show other)

    it "is a no-op when broker is Nothing" $ do
      let sid = mkSid "tc2"
      let input = object ["cmd" .= ("ls" :: Text)]
      -- Should not throw and should not block
      broadcastToolCall Nothing sid (OpName "SHELL_EXEC") input

    it "redacts input for secret opcodes (SECRET_GET)" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "tc3"
      (_, ref) <- collectEvents broker sid
      let input = object ["name" .= ("MY_API_KEY" :: Text)]
      broadcastToolCall (Just broker) sid (OpName "SECRET_GET") input
      events <- readIORef ref
      case events of
        [BeActivity _ payload] -> case payload of
          A.Object o -> do
            case KM.lookup "input" o of
              Just (A.String t) ->
                ("<redacted>" `T.isInfixOf` t) `shouldBe` True
              other -> expectationFailure ("expected input string, got " <> show other)
            -- The secret name should NOT appear in the input
            case KM.lookup "input" o of
              Just (A.String t) ->
                ("MY_API_KEY" `T.isInfixOf` t) `shouldBe` False
              _ -> pure ()
          other -> expectationFailure ("expected object payload, got " <> show other)
        other -> expectationFailure ("expected [BeActivity], got " <> show other)

    it "is delivered to ALL subscribers (not session-filtered)" $ do
      -- BeActivity is an all-subscriber event (the broker's shouldSend
      -- sends BeActivity to every subscriber, not just those focused on
      -- the session). This matches the existing harness-status behavior.
      broker <- newStreamBroker 10
      (_, refA) <- collectEvents broker (mkSid "tc4a")
      (_, refB) <- collectEvents broker (mkSid "tc4b")
      let input = object ["x" .= (1 :: Int)]
      broadcastToolCall (Just broker) (mkSid "tc4a") (OpName "BIN_EXEC") input
      a <- readIORef refA
      b <- readIORef refB
      length a `shouldBe` 1
      length b `shouldBe` 1

    it "includes the tool name even for redacted opcodes" $ do
      broker <- newStreamBroker 10
      let sid = mkSid "tc5"
      (_, ref) <- collectEvents broker sid
      let input = object ["name" .= ("TOKEN" :: Text)]
      broadcastToolCall (Just broker) sid (OpName "SECRET_GET") input
      events <- readIORef ref
      case events of
        [BeActivity _ payload] -> case payload of
          A.Object o -> case KM.lookup "tool" o of
            Just (A.String "SECRET_GET") -> pure ()
            other -> expectationFailure ("expected tool=SECRET_GET, got " <> show other)
          other -> expectationFailure ("expected object payload, got " <> show other)
        other -> expectationFailure ("expected [BeActivity], got " <> show other)
