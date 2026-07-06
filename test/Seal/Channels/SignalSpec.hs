{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.SignalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channels.Class (Channel (..))
import Seal.Channels.Signal (withSignalChannel)
import Seal.Channels.Signal.Transport (mkMockSignalTransport)
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( UserId, conversationIdText, mkUserId
  , msChannelKind, msConversationId )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Signal.Config (SignalAccount (..), mkSignalAccount)

-- | A scripted Signal envelope (raw shape) from a peer.
signalEnvelope :: Text -> Maybe Text -> Text -> Value
signalEnvelope source mUuid body =
  object [ "envelope" .= object (["source" .= source] <> uuidField mUuid <> ["dataMessage" .= object ["message" .= body]]) ]
  where
    uuidField (Just u) = ["sourceUuid" .= u]
    uuidField Nothing  = []

src1 :: Text
src1 = "+15551234567"
uuid1 :: Text
uuid1 = "abc-uuid"

acct :: SignalAccount
acct = case mkSignalAccount "+12025551234" of
  Right a -> a
  Left e  -> error ("mkSignalAccount: " <> T.unpack e)

spec :: Spec
spec = describe "Seal.Channels.Signal" $ do
  it "withSignalChannel + chReceive yields scripted envelopes with the right MessageSource" $ do
    let env1 = signalEnvelope src1 (Just uuid1) "hello"
        env2 = signalEnvelope src1 (Just uuid1) "/ping"
    (transport, _) <- mkMockSignalTransport [env1, env2]
    withSignalChannel (AllowAll, 1998) acct transport $ \ch -> do
      let h = toHandle ch
      (m1, t1) <- chReceive h
      (_, t2)  <- chReceive h
      t1 `shouldBe` "hello"
      t2 `shouldBe` "/ping"
      case m1 of
        Nothing -> expectationFailure "expected MessageSource for env1"
        Just ms -> do
          msChannelKind ms `shouldBe` Signal
          conversationIdText (msConversationId ms) `shouldBe` "sig:+15551234567:abc-uuid"

  it "chSend chunks a long message to the configured limit and sends to the last sender" $ do
    -- chunk limit 10: a 25-char message with no separators -> 3 chunks
    let longMsg = T.replicate 25 "a"
        env1 = signalEnvelope src1 (Just uuid1) "x"  -- primes the last-sender
    (transport, getCaptured) <- mkMockSignalTransport [env1]
    withSignalChannel (AllowAll, 10) acct transport $ \ch -> do
      let h = toHandle ch
      (_, _) <- chReceive h  -- pop env1, sets last sender to src1
      chSend h longMsg
      cap <- getCaptured
      -- 3 chunks of 10 chars each, all to src1
      map snd cap `shouldBe` [T.replicate 10 "a", T.replicate 10 "a", T.replicate 5 "a"]
      all ((== src1) . fst) cap `shouldBe` True

  it "chSend with no last sender is dropped (capture empty)" $ do
    (transport, getCaptured) <- mkMockSignalTransport []
    withSignalChannel (AllowAll, 1998) acct transport $ \ch -> do
      let h = toHandle ch
      chSend h "nobody to reply to"
      cap <- getCaptured
      cap `shouldBe` []

  it "a non-allow-listed sender is dropped (never reaches chReceive)" $ do
    let envAllowed    = signalEnvelope src1 (Just uuid1) "in"
        envDisallowed = signalEnvelope "+19999999999" Nothing "out"
    (transport, _) <- mkMockSignalTransport [envDisallowed, envAllowed]
    let allow = AllowOnly (Set.fromList [mkAllowedUserId src1])
    withSignalChannel (allow, 1998) acct transport $ \ch -> do
      let h = toHandle ch
      (m1, t1) <- chReceive h
      -- envDisallowed is dropped; envAllowed is yielded
      t1 `shouldBe` "in"
      case m1 of
        Just ms -> conversationIdText (msConversationId ms) `shouldBe` "sig:+15551234567:abc-uuid"
        Nothing -> expectationFailure "expected the allowed message"

  it "chPrompt returns Left Deferred (Signal can't answer inline)" $ do
    (transport, _) <- mkMockSignalTransport []
    withSignalChannel (AllowAll, 1998) acct transport $ \ch -> do
      r <- chPrompt (toHandle ch) "q?"
      r `shouldBe` Left Deferred

  it "chStreaming is True for Signal" $ do
    (transport, _) <- mkMockSignalTransport []
    withSignalChannel (AllowAll, 1998) acct transport $ \ch ->
      chStreaming (toHandle ch) `shouldBe` True

-- | Build the AllowList UserId for the test from a phone number.
mkAllowedUserId :: Text -> UserId
mkAllowedUserId phone = case mkUserId phone of
  Right u -> u
  Left e  -> error ("mkUserId: " <> T.unpack e)