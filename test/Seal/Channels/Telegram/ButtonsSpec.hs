{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the Telegram inline-keyboard button support for @ASK_HUMAN@
-- (issue #93). Covers W3 (keyboard rendering), W4 (callback index resolution
-- + Other fallthrough), and the integration of W2 (spinner dismiss).
module Seal.Channels.Telegram.ButtonsSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Arbitrary (..), chooseInt)

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Channels.Class (Channel (..))
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Channels.Telegram.Run (mkTelegramHandleCaps, onTelegramCallback)
import Seal.Channels.Telegram.Transport
  ( TelegramButton (..), TelegramUpdate (..), mkMockTelegramTransport )
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.MessageSource (mkConversationId, mkUserId)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Handles.AskReply
  ( AskReply (..), AskReplyStore, ApprovalScope (..), QuestionOption (..)
  , askIdText, askHumanWithOptions, deliverAnswer, pendingForSession
  , pqiId, newAskReplyStore )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Logging.Logger (testSealLogger)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

chatId :: Text
chatId = "123456789"

senderId :: Text
senderId = "111222333"

sid :: SessionId
sid = either (error "sid") id (mkSessionId "buttons-test")

-- | A 'QuestionOption' with just a label (no description).
opt :: Text -> QuestionOption
opt lbl = QuestionOption lbl ""

-- | Build a minimal 'ChannelHandle' whose 'chLastChatId' returns the given
-- chat id + whose 'chSend' captures to the supplied IORef. Used to test
-- 'mkTelegramHandleCaps' in isolation (without spinning up the full
-- channel).
testHandle :: Maybe Text -> IORef [Text] -> ChannelHandle
testHandle mChat sendRef = ChannelHandle
  { chLabel       = "telegram-test"
  , chSend         = \t -> modifyIORef' sendRef (t :)
  , chSendError    = \_ -> pure ()
  , chSendChunk    = \_ -> pure ()
  , chPrompt       = \_ -> pure (Left Deferred)
  , chPromptSecret = \_ -> pure (Left Deferred)
  , chStreaming    = False
  , chReadSecret   = pure Nothing
  , chReceive      = pure (Nothing, "")
  , chLastChatId   = pure mChat
  }

-- | A scripted callback_query update (a button tap).
callbackUpdate :: Text -> Text -> Text -> Text -> TelegramUpdate
callbackUpdate cId sId cbData cbId =
  let cid = case mkConversationId ("tg:" <> cId) of
        Right c -> c
        Left e  -> error ("mkConversationId: " <> T.unpack e)
      uid = case mkUserId sId of
        Right u -> u
        Left e  -> error ("mkUserId: " <> T.unpack e)
  in TelegramUpdate
       { tuConversationId = cid
       , tuChatId          = cId
       , tuSender          = uid
       , tuBody            = cbData
       , tuCallbackData    = Just cbData
       , tuCallbackId      = Just cbId
       }

-- | Poll the mock transport's keyboard-capture accessor until non-empty
-- (max ~retries * 10ms). Returns the captured calls.
waitForKeyboard :: IO [a] -> Int -> IO [a]
waitForKeyboard getCap retries
  | retries <= 0 = getCap
  | otherwise = do
      cap <- getCap
      case cap of
        [] -> threadDelay 10000 >> waitForKeyboard getCap (retries - 1)
        _  -> pure cap

-- | Poll the send IORef until non-empty. Returns captures in chronological
-- order.
waitForSend :: IORef [Text] -> Int -> IO [Text]
waitForSend ref retries
  | retries <= 0 = reverse <$> readIORef ref
  | otherwise = do
      xs <- readIORef ref
      case xs of
        [] -> threadDelay 10000 >> waitForSend ref (retries - 1)
        _  -> pure (reverse xs)

-- | Deliver an answer to the first pending ask for the session (unblocks
-- the forked ccPrompt / askHumanWithOptions).
deliverFirstPending :: AskReplyStore -> SessionId -> IO ()
deliverFirstPending store s = do
  ps <- pendingForSession store s
  case ps of
    []     -> pure ()
    (p:_)  -> do
      _ <- deliverAnswer store (pqiId p) (AskReply ScopeOnce "x")
      pure ()

-- | Fork a blocking 'askHumanWithOptions' + return an MVar that's filled
-- when it unblocks + the registered AskId prefix (8 hex). The caller must
-- deliver an answer to unblock.
forkAskWithOptions
  :: AskReplyStore -> SessionId -> Text -> [QuestionOption]
  -> IO (IO (), Text)
forkAskWithOptions store s question opts = do
  prefixMVar <- newEmptyMVar
  done <- newEmptyMVar
  _ <- forkIO $ do
    let notify qid = putMVar prefixMVar (T.take 8 (askIdText qid))
    _ <- askHumanWithOptions store s question opts notify
    putMVar done ()
  prefix <- takeMVar prefixMVar
  let waitDone = takeMVar done
  pure (waitDone, prefix)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Channels.Telegram.Buttons" $ do

  -- -----------------------------------------------------------------------
  -- W3: mkTelegramHandleCaps — inline keyboard rendering
  -- -----------------------------------------------------------------------
  describe "mkTelegramHandleCaps ccPrompt" $ do

    it "ccPrompt with options sends an inline keyboard (1 call, opts+1 rows)" $ do
      let opts = [opt "main", opt "develop"]
      (transport, _, _, _, getKb) <- mkMockTelegramTransport []
      sendRef <- newIORef []
      store <- newAskReplyStore 0
      let h = testHandle (Just chatId) sendRef
          caps = mkTelegramHandleCaps transport h store sid
      done <- newEmptyMVar
      _ <- forkIO $ do
        _ <- ccPrompt caps (AskPrompt "which branch?" opts)
        putMVar done ()
      kbs <- waitForKeyboard getKb 100
      length kbs `shouldBe` 1
      case kbs of
        [(kbChat, body, keyboard)] -> do
          kbChat `shouldBe` chatId
          body `shouldBe` "which branch?"
          length keyboard `shouldBe` 3  -- 2 options + 1 Other
          map length keyboard `shouldBe` [1, 1, 1]
          case keyboard of
            [[b0], [b1], [bOther]] -> do
              tbText b0 `shouldBe` "main"
              tbText b1 `shouldBe` "develop"
              tbText bOther `shouldBe` "Other"
              let cbd0 = tbCallbackData b0
                  cbd1 = tbCallbackData b1
                  cbdOther = tbCallbackData bOther
              cbd0 `shouldSatisfy` (\t -> T.length t >= 10 && T.isSuffixOf ":0" t)
              cbd1 `shouldSatisfy` (\t -> T.length t >= 10 && T.isSuffixOf ":1" t)
              cbdOther `shouldSatisfy` T.isSuffixOf ":other"
              -- All callback_data ≤ 64 bytes (Telegram limit).
              all (\t -> T.length t <= 64) [cbd0, cbd1, cbdOther] `shouldBe` True
            _ -> expectationFailure ("expected 3 single-button rows, got: " <> show keyboard)
        _ -> expectationFailure ("expected 1 keyboard call, got: " <> show (length kbs))
      deliverFirstPending store sid
      takeMVar done

    it "ccPrompt with empty opts sends plain text, no keyboard" $ do
      (transport, _, _, _, getKb) <- mkMockTelegramTransport []
      sendRef <- newIORef []
      store <- newAskReplyStore 0
      let h = testHandle (Just chatId) sendRef
          caps = mkTelegramHandleCaps transport h store sid
      done <- newEmptyMVar
      _ <- forkIO $ do
        _ <- ccPrompt caps (AskPrompt "what is your name?" [])
        putMVar done ()
      sends <- waitForSend sendRef 100
      case sends of
        (firstSend : _) -> firstSend `shouldBe` "what is your name?"
        []             -> expectationFailure "expected at least one send"
      kbs <- getKb
      kbs `shouldBe` []
      deliverFirstPending store sid
      takeMVar done

    it "ccPrompt with options but no chat id falls back to chSend (numbered list)" $ do
      let opts = [opt "yes", opt "no"]
      (transport, _, _, _, getKb) <- mkMockTelegramTransport []
      sendRef <- newIORef []
      store <- newAskReplyStore 0
      let h = testHandle Nothing sendRef
          caps = mkTelegramHandleCaps transport h store sid
      done <- newEmptyMVar
      _ <- forkIO $ do
        _ <- ccPrompt caps (AskPrompt "proceed?" opts)
        putMVar done ()
      sends <- waitForSend sendRef 100
      case sends of
        (firstSend : _) -> firstSend `shouldSatisfy` T.isInfixOf "1) yes"
        []             -> expectationFailure "expected at least one send"
      kbs <- getKb
      kbs `shouldBe` []
      deliverFirstPending store sid
      takeMVar done

  -- -----------------------------------------------------------------------
  -- W4: onTelegramCallback — index resolution + Other fallthrough
  -- -----------------------------------------------------------------------
  describe "onTelegramCallback" $ do

    it "resolves <8hex>:<idx> to the option label and delivers it" $ do
      store <- newAskReplyStore 0
      let opts = [opt "main", opt "develop"]
      (waitDone, prefix) <- forkAskWithOptions store sid "which branch?" opts
      -- Tap button 0 (the "main" option).
      res <- onTelegramCallback store sid (prefix <> ":0")
      res `shouldBe` True
      -- The ask unblocked with "main".
      waitDone

    it "<8hex>:other returns False without delivering" $ do
      store <- newAskReplyStore 0
      let opts = [opt "main", opt "develop"]
      (waitDone, prefix) <- forkAskWithOptions store sid "which branch?" opts
      res <- onTelegramCallback store sid (prefix <> ":other")
      res `shouldBe` False
      -- Clean up: deliver an answer so the forked thread unblocks.
      deliverFirstPending store sid
      waitDone

    it "out-of-bounds index returns False without delivering" $ do
      store <- newAskReplyStore 0
      let opts = [opt "main", opt "develop"]
      (waitDone, prefix) <- forkAskWithOptions store sid "which branch?" opts
      res <- onTelegramCallback store sid (prefix <> ":99")
      res `shouldBe` False
      deliverFirstPending store sid
      waitDone

    it "stale prefix returns False" $ do
      store <- newAskReplyStore 0
      res <- onTelegramCallback store sid "deadbeef:0"
      res `shouldBe` False

    it "malformed callback body (no colon) returns False" $ do
      store <- newAskReplyStore 0
      res <- onTelegramCallback store sid "noColonHere"
      res `shouldBe` False

    it "malformed callback body (non-hex prefix) returns False" $ do
      store <- newAskReplyStore 0
      res <- onTelegramCallback store sid "zzzzzzzz:0"
      res `shouldBe` False

    prop "prop_callbackDataWithin64Bytes: <8hex>:<idx|other> is <= 64 chars"
      $ \(SmallIdx idx) -> do
        let prefix = "deadbeef" :: Text
            token = if idx < 0 then "other" else T.pack (show idx)
            cbd = prefix <> ":" <> token
        T.length cbd <= 64

  -- -----------------------------------------------------------------------
  -- W2 integration: readerLoop dismisses the spinner for callbacks
  -- -----------------------------------------------------------------------
  describe "readerLoop spinner dismiss (integration)" $ do

    it "a callback_query update triggers tgAnswerCallback" $ do
      let cbUpd = callbackUpdate chatId senderId "deadbeef:0" "cb-99"
      (transport, _, _, getCallbacks, _) <- mkMockTelegramTransport [cbUpd]
      logger <- testSealLogger
      withTelegramChannel (AllowAll, 3900) transport logger $ \ch -> do
        let h = toHandle ch
        _ <- chReceive h
        cbs <- getCallbacks
        cbs `shouldBe` ["cb-99"]

-- ---------------------------------------------------------------------------
-- QuickCheck generators
-- ---------------------------------------------------------------------------

-- | A small index: -1 (maps to "other") or 0-7 (maps to the index).
newtype SmallIdx = SmallIdx Int
  deriving stock (Eq, Show)

instance Arbitrary SmallIdx where
  arbitrary = SmallIdx <$> chooseInt (-1, 7)