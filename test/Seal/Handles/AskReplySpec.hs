{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.AskReplySpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (uncons)
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (mkSessionId)
import qualified Seal.Core.Types as CT (SessionId)
import Seal.Handles.AskReply
  ( ApprovalScope (..), AskOutcome (..), AskReply (..), askHuman, askIdText
  , cancelAsk, cancelSessionAsks, deliverAnswer, deliverNextAnswer, lookupAsk
  , newAskReplyStore, parseAskId, pendingForSession )

-- | A valid UUID v4 text for tests that need a pre-known id (not minted).
dummyUuidText :: Text
dummyUuidText = "12345678-1234-4234-8234-123456789012"

-- | Extract the first pending question (id, text) from a non-empty list,
-- failing the test if the list is empty.
firstPending :: [(a, Text, b, c)] -> (a, Text)
firstPending ps = case uncons ps of
  Just ((qid, q, _, _), _) -> (qid, q)
  Nothing -> error "firstPending: empty list (test invariant violation)"

-- | Safe session-id construction for tests (the literal is known-valid).
testSid :: Text -> CT.SessionId
testSid t = case mkSessionId t of
  Right s -> s
  Left _ -> error ("testSid: invalid session id " <> show t)

spec :: Spec
spec = describe "Seal.Handles.AskReply" $ do
  let sid = testSid "test-session"
      sid2 = testSid "other-session"

  describe "askHuman / deliverAnswer roundtrip" $ do
    it "blocks until the answer is delivered, then returns Right answer" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        r <- askHuman store sid "what is 2+2?" (\_qid -> pure ())
        putMVar done r
      threadDelay 10000
      ps <- pendingForSession store sid
      length ps `shouldBe` 1
      let (qid, question) = firstPending ps
      question `shouldBe` "what is 2+2?"
      accepted <- deliverAnswer store qid (AskReply ScopeOnce "4")
      accepted `shouldBe` True
      result <- takeMVar done
      result `shouldBe` Right "4"

    it "fires the notify callback with the AskId before blocking" $ do
      store <- newAskReplyStore 0
      notifiedRef <- newIORef (Nothing :: Maybe Text)
      done <- newEmptyMVar
      _ <- forkIO $ do
        _r <- askHuman store sid "notify me?" (writeIORef notifiedRef . Just . askIdText)
        putMVar done ()
      threadDelay 10000
      mNotified <- readIORef notifiedRef
      mNotified `shouldSatisfy` \case Just _ -> True; Nothing -> False
      case mNotified of
        Just qidText -> do
          Right qid <- pure (parseAskId qidText)
          _ <- deliverAnswer store qid (AskReply ScopeOnce "ok")
          takeMVar done
        Nothing -> pure ()  -- unreachable: asserted above

  describe "deliverAnswer idempotency" $ do
    it "rejects a second answer to the same question (returns False)" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        r <- askHuman store sid "once?" (\_ -> pure ())
        putMVar done r
      threadDelay 10000
      ps <- pendingForSession store sid
      let (qid, _) = firstPending ps
      first <- deliverAnswer store qid (AskReply ScopeOnce "first")
      first `shouldBe` True
      second <- deliverAnswer store qid (AskReply ScopeOnce "second")
      second `shouldBe` False
      result <- takeMVar done
      result `shouldBe` Right "first"

    it "returns False for an unknown ask id" $ do
      store <- newAskReplyStore 0
      Right qid <- pure (parseAskId dummyUuidText)
      accepted <- deliverAnswer store qid (AskReply ScopeOnce "anything")
      accepted `shouldBe` False

  describe "timeout" $ do
    it "returns Left AoTimedOut when no answer arrives within the timeout" $ do
      store <- newAskReplyStore 50000  -- 50ms
      r <- askHuman store sid "slow?" (\_ -> pure ())
      r `shouldBe` Left AoTimedOut

    it "returns Right answer when the answer arrives before the timeout" $ do
      store <- newAskReplyStore 1000000  -- 1s
      done <- newEmptyMVar
      _ <- forkIO $ do
        r <- askHuman store sid "fast?" (\_ -> pure ())
        putMVar done r
      threadDelay 10000
      ps <- pendingForSession store sid
      let (qid, _) = firstPending ps
      _ <- deliverAnswer store qid (AskReply ScopeOnce "here")
      result <- takeMVar done
      result `shouldBe` Right "here"

  describe "cancelAsk" $ do
    it "unblocks the waiting thread with Left AoCancelled" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        r <- askHuman store sid "cancel me?" (\_ -> pure ())
        putMVar done r
      threadDelay 10000
      ps <- pendingForSession store sid
      let (qid, _) = firstPending ps
      cancelled <- cancelAsk store qid
      cancelled `shouldBe` True
      result <- takeMVar done
      result `shouldBe` Left AoCancelled

    it "returns False for an unknown ask id" $ do
      store <- newAskReplyStore 0
      Right qid <- pure (parseAskId dummyUuidText)
      cancelled <- cancelAsk store qid
      cancelled `shouldBe` False

  describe "cancelSessionAsks" $ do
    it "cancels all pending questions for a session" $ do
      store <- newAskReplyStore 0
      done1 <- newEmptyMVar
      done2 <- newEmptyMVar
      _ <- forkIO $ do
        r <- askHuman store sid "q1?" (\_ -> pure ())
        putMVar done1 r
      _ <- forkIO $ do
        r <- askHuman store sid "q2?" (\_ -> pure ())
        putMVar done2 r
      threadDelay 10000
      ps <- pendingForSession store sid
      length ps `shouldBe` 2
      cancelSessionAsks store sid
      r1 <- takeMVar done1
      r2 <- takeMVar done2
      r1 `shouldBe` Left AoCancelled
      r2 `shouldBe` Left AoCancelled
      afterCancel <- pendingForSession store sid
      afterCancel `shouldBe` []

    it "does not affect other sessions" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        _r <- askHuman store sid2 "other?" (\_ -> pure ())
        putMVar done ()
      threadDelay 10000
      cancelSessionAsks store sid
      ps <- pendingForSession store sid2
      length ps `shouldBe` 1
      -- Clean up: cancel sid2's question so the forked thread unblocks.
      cancelSessionAsks store sid2
      takeMVar done

  describe "deliverNextAnswer (FIFO inbox-driven delivery)" $ do
    it "delivers to the oldest pending question first" $ do
      store <- newAskReplyStore 0
      done1 <- newEmptyMVar
      done2 <- newEmptyMVar
      _ <- forkIO $ do
        r <- askHuman store sid "first?" (\_ -> pure ())
        putMVar done1 r
      threadDelay 10000
      _ <- forkIO $ do
        r <- askHuman store sid "second?" (\_ -> pure ())
        putMVar done2 r
      threadDelay 10000
      delivered <- deliverNextAnswer store sid "answer-to-first"
      delivered `shouldBe` True
      r1 <- takeMVar done1
      r1 `shouldBe` Right "answer-to-first"
      delivered2 <- deliverNextAnswer store sid "answer-to-second"
      delivered2 `shouldBe` True
      r2 <- takeMVar done2
      r2 `shouldBe` Right "answer-to-second"

    it "returns False when no question is pending (unsolicited message)" $ do
      store <- newAskReplyStore 0
      delivered <- deliverNextAnswer store sid "unsolicited"
      delivered `shouldBe` False

    it "only delivers to the matching session" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        _r <- askHuman store sid "mine?" (\_ -> pure ())
        putMVar done ()
      threadDelay 10000
      delivered <- deliverNextAnswer store sid2 "wrong session"
      delivered `shouldBe` False
      ps <- pendingForSession store sid
      length ps `shouldBe` 1
      delivered2 <- deliverNextAnswer store sid "right session"
      delivered2 `shouldBe` True
      takeMVar done

  describe "pendingForSession" $ do
    it "lists all pending questions for the session" $ do
      store <- newAskReplyStore 0
      d1 <- newEmptyMVar
      d2 <- newEmptyMVar
      d3 <- newEmptyMVar
      -- Three concurrent asks; their createdAt ordering reflects the
      -- registration order (each thread registers before blocking). The
      -- delays (20ms each) ensure the timestamps are far enough apart that
      -- the sortByCreatedAt is deterministic.
      _ <- forkIO $ do _r <- askHuman store sid "q1?" (\_ -> pure ()); putMVar d1 ()
      threadDelay 20000
      _ <- forkIO $ do _r <- askHuman store sid "q2?" (\_ -> pure ()); putMVar d2 ()
      threadDelay 20000
      _ <- forkIO $ do _r <- askHuman store sid "q3?" (\_ -> pure ()); putMVar d3 ()
      threadDelay 20000
      ps <- pendingForSession store sid
      length ps `shouldBe` 3
      -- The questions are all present (the exact order depends on
      -- getCurrentTime resolution; the FIFO delivery test covers ordering
      -- via deliverNextAnswer which is the real consumer).
      map (\(_, q, _, _) -> q) ps `shouldMatchList` ["q1?", "q2?", "q3?"]
      cancelSessionAsks store sid
      _ <- takeMVar d1 :: IO ()
      _ <- takeMVar d2 :: IO ()
      _ <- takeMVar d3 :: IO ()
      pure ()

  describe "lookupAsk" $ do
    it "returns the session + question for a pending id" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        _r <- askHuman store sid "lookup?" (\_ -> pure ())
        putMVar done ()
      threadDelay 10000
      ps <- pendingForSession store sid
      let (qid, _) = firstPending ps
      mLookup <- lookupAsk store qid
      mLookup `shouldBe` Just (sid, "lookup?")
      _ <- cancelAsk store qid
      takeMVar done

    it "returns Nothing after the question is answered" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        _r <- askHuman store sid "answered?" (\_ -> pure ())
        putMVar done ()
      threadDelay 10000
      ps <- pendingForSession store sid
      let (qid, _) = firstPending ps
      _ <- deliverAnswer store qid (AskReply ScopeOnce "yes")
      takeMVar done
      mLookup <- lookupAsk store qid
      mLookup `shouldBe` Nothing

  describe "parseAskId / askIdText" $ do
    it "round-trips a minted AskId" $ do
      store <- newAskReplyStore 0
      done <- newEmptyMVar
      _ <- forkIO $ do
        _r <- askHuman store sid "roundtrip?" (putMVar done . askIdText)
        pure ()
      qidText <- takeMVar done
      Right qid <- pure (parseAskId qidText)
      askIdText qid `shouldBe` qidText

    it "rejects a non-UUID text" $ do
      parseAskId "not-a-uuid" `shouldBe` Left "invalid AskId: not-a-uuid"

    it "rejects an empty string" $ do
      parseAskId "" `shouldBe` Left "invalid AskId: "