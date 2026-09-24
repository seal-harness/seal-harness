{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Signal' — the Signal chat-channel adapter.
module Seal.Channels.Chat.SignalAdapterSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (newTVarIO)
import Data.Aeson qualified as A
import Data.Aeson ((.=))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Loop
  ( ChatChannelConfig (..)
  , defaultChatChannelConfig
  , handleServerEvent
  )
import Seal.Channels.Chat.RateLimit (defaultStreamProgressConfig)
import Seal.Channels.Chat.Signal
  ( withSignalChatChannel
  , mkMockSignalChatTransport
  , chunkMessage
  )
import Seal.Channels.Chat.Types
  ( defaultGatewayConfig, convKeyFromSource, newStreamingState
  , ChatMessageId (..), ReceivedMessage (..) )
import Seal.Channels.Chat.WsClient (WsClient (..))
import Seal.Gateway.Types.AllowList (AllowList (..))
import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.Core (mkSessionId, SessionId)
import Seal.Gateway.Types.MessageSource
  ( mkConversationId, mkMessageSource, MessageSource )
import Seal.Gateway.Types.Stream (ServerEvent (..))

-- | Build a MessageSource for a conversation id (test helper).
mkMessageSourceFor :: T.Text -> MessageSource
mkMessageSourceFor cid =
  case mkConversationId cid of
    Left _   -> error "bad cid"
    Right c  -> case mkMessageSource c Signal Nothing mempty of
      Right ms -> ms
      Left _   -> error "MessageSource construction failed"

-- | Test sid helper.
mkSid :: T.Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

-- | A dummy received message for seeding the last-sender in tests.
dummyMsg :: ReceivedMessage
dummyMsg = ReceivedMessage
  { rmConversationId = case mkConversationId "sig:+15551234567" of Right c -> c; Left _ -> error "bad cid"
  , rmSender = Just "+15551234567"
  , rmReplyTo = "+15551234567"
  , rmBody = "init"
  , rmCallbackData = Nothing
  , rmCallbackId = Nothing
  , rmCallbackMessageId = Nothing
  }

-- | Wait briefly for the reader thread to process the seed message.
waitForSeed :: IO ()
waitForSeed = threadDelay 50000  -- 50ms

spec :: Spec
spec = do
  describe "chunkMessage" $ do
    it "returns the message as-is when under the limit" $
      chunkMessage 100 "hello" `shouldBe` ["hello"]

    it "splits a long message at the limit" $
      chunkMessage 5 "abcdefghij" `shouldBe` ["abcde", "fghij"]

    it "handles empty string" $
      chunkMessage 5 "" `shouldBe` [""]

    it "handles exactly the limit" $
      chunkMessage 5 "abcde" `shouldBe` ["abcde"]

  describe "ChatChannel SignalChatChannel" $ do
    it "has label 'signal'" $ do
      (transport, _, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        ccLabel ch `shouldBe` "signal"

    it "sends messages via the transport" $ do
      (transport, getCaptured, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        waitForSeed
        ccSend ch "hello world"
        captured <- getCaptured
        captured `shouldBe` ["hello world"]

    it "sends with id and returns a ChatMessageId" $ do
      (transport, _, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        waitForSeed
        mId <- ccSendWithId ch "test"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected a message id"

    it "edits messages via the transport" $ do
      (transport, _, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        waitForSeed
        ok <- ccEditMessage ch (ChatMessageId "123") "new content"
        ok `shouldBe` True

    it "chunks long sends" $ do
      (transport, getCaptured, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 5 transport $ \ch -> do
        waitForSeed
        ccSend ch "abcdefghij"
        captured <- getCaptured
        captured `shouldBe` ["abcde", "fghij"]

  describe "streaming edit cadence (issue #198, part 3: total-length bug)" $ do
    it "gates edits on NEW text since the last edit, not the total length" $ do
      -- The server now rate-limits BeEntryUpdate frames (1500ms / 80 new
      -- codepoints), but the client-side gate ALSO measured the TOTAL
      -- accumulated length — so once the text passed the 80-codepoint
      -- threshold, every arriving frame forced an outbound edit (the
      -- 'lots of small updates' on the wire). The client must gate on NEW
      -- text since the last edit, matching the server's semantics.
      (transport, getCaptured, getEdits) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 4000 transport $ \ch -> do
        waitForSeed
        -- Loop plumbing: conversation key + streaming state + a stub WS
        -- client (entry-updates never touch it — it is only used by the
        -- focus paths).
        let key = convKeyFromSource (mkMessageSourceFor "sig:+15551234567")
            stubWs = WsClient
              { wcFocus = \_ -> pure ()
              , wcFocusSince = \_ _ -> pure ()
              , wcClose = pure ()
              }
        ss <- newStreamingState
        conns <- newTVarIO (Map.singleton key (stubWs, ss))
        -- Fire 40 entry-updates back-to-back. Frame 1 carries 79 chars
        -- (creates the bubble); each subsequent frame adds 5 chars, so
        -- the TOTAL crosses 80 at frame 2 — but the NEW text per frame is
        -- only 5 codepoints.
        mgr <- newManager defaultManagerSettings
        let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                      { cccStreamCfg = defaultStreamProgressConfig }
            frameLen i = 79 + 5 * (i - 1)  -- frame i (1-based) total length
            frame i = streamingJsonFor (T.replicate (frameLen i) "x")
        pendingAsks <- newTVarIO Map.empty
        tabTracker <- newTVarIO Map.empty
        _ <- handleServerEvent cfg ch key conns pendingAsks tabTracker (mkSid "stream")
                (SeEntryUpdate (mkSid "stream") (frame 1))
        mapM_ (handleServerEvent cfg ch key conns pendingAsks tabTracker (mkSid "stream")
                 . SeEntryUpdate (mkSid "stream") . frame)
              [2 .. 40]
        edits <- getEdits
        -- FIXED semantics: frame 1 creates the bubble (a send, not an
        -- edit). Then an edit fires only when 80 NEW codepoints
        -- accumulate: at frame 17 (79 + 80 new) and frame 33 (159 + 80
        -- new). 2 edits total.
        -- TOTAL-LENGTH bug: every frame from frame 2 onward (total >= 80)
        -- forces an edit — 39 edits.
        length edits `shouldBe` 2
        sends <- getCaptured
        -- The bubble-creation send carries the first frame's text.
        case sends of
          (s : _) -> s `shouldSatisfy` T.isPrefixOf (T.replicate 79 "x")
          []     -> expectationFailure "expected a bubble-creation send"
      where
        streamingJsonFor t = A.object
          [ "id" .= ("streaming" :: T.Text)
          , "direction" .= ("response" :: T.Text)
          , "payload" .= A.object
              [ "content" .= A.Array
                  (V.fromList [A.object ["text" .= t, "type" .= ("text" :: T.Text)]])
              ]
          ]
