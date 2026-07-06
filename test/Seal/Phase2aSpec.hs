{-# LANGUAGE OverloadedStrings #-}
-- | Phase 2a capstone: prove the cross-channel types + the widened handle +
-- the Channel class wire together end-to-end through 'Seal.Ingest'. A
-- 'FakeChannel' (Signal-flavoured) is driven through 'ingest': a slash
-- command dispatches via a 'ChannelCaps' adapter, a plain message routes as
-- 'PlainMessage', and the 'MessageSource' carries the right 'ChannelKind'/
-- 'ConversationId' through 'chReceive'.
module Seal.Phase2aSpec (spec) where

import Data.Either (fromRight)
import Options.Applicative (info, progDesc)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channels.Class (Channel (..))
import Seal.Command.Spec
  ( Availability (..)
  , CommandAction (..)
  , CommandGroup (..)
  , CommandName (..)
  , CommandSpec (..)
  , Registry
  , mkRegistry
  )
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( ConversationId, MessageSource, conversationIdText, mkConversationId
  , mkMessageSource, mkUserId, msChannelKind, msConversationId )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Ingest (Disposition (..), RawInbound (..), ingest, emptyChain)
import Seal.TestHelpers.FakeChannel

-- ---------------------------------------------------------------------------
-- A trivial /ping registry (mirrors Seal.IngestSpec's pattern)
-- ---------------------------------------------------------------------------

pingAction :: CommandAction
pingAction = CommandAction $ \caps -> ccSend caps "pong"

pingSpec :: CommandSpec
pingSpec = CommandSpec
  { csName         = CommandName "ping"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Echo pong"
  , csParserInfo   = info (pure pingAction) (progDesc "Echo pong")
  , csAvailability = AlwaysAvailable
  }

testRegistry :: Registry
testRegistry = mkRegistry [pingSpec]

-- ---------------------------------------------------------------------------
-- Adapter: ChannelHandle -> ChannelCaps (for slash-command dispatch only)
-- ---------------------------------------------------------------------------

-- | A throwaway 'ChannelCaps' that forwards to the widened 'ChannelHandle'.
-- The command registry still speaks 'ChannelCaps' today; 2a does not change
-- that. A later phase widens 'CommandAction' to take 'ChannelHandle'.
handleCaps :: ChannelHandle -> ChannelCaps
handleCaps h = ChannelCaps
  { ccSend         = chSend h
  , ccPrompt       = fmap (fromRight "") . chPrompt h
  , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
  }

-- ---------------------------------------------------------------------------
-- A scripted Signal-flavoured MessageSource
-- ---------------------------------------------------------------------------

src :: MessageSource
src = case mkConversationId "sig:+15551234567" of
  Right convId -> case mkUserId "+15551234567" of
    Right uid -> case mkMessageSource convId Signal (Just uid) mempty of
      Right ms -> ms
      Left e   -> error ("mkMessageSource: " <> show e)
    Left e   -> error ("mkUserId: " <> show e)
  Left e   -> error ("mkConversationId: " <> show e)

cid :: ConversationId
cid = msConversationId src

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

showShape :: Disposition -> String
showShape (DispatchAction _) = "DispatchAction"
showShape (ShowText t)       = "ShowText " <> show t
showShape (PlainMessage t)   = "PlainMessage " <> show t
showShape (Rejected t)       = "Rejected " <> show t

spec :: Spec
spec = describe "Seal.Phase2aSpec" $ do
  it "MessageSource carries ChannelKind=Signal + the server-derived ConversationId" $ do
    msChannelKind src `shouldBe` Signal
    conversationIdText cid `shouldBe` "sig:+15551234567"

  it "a FakeChannel's chReceive yields the scripted (MessageSource, Text)" $ do
    fc <- newFakeChannelWith True [(src, "/ping"), (src, "hello")] []
    let h = toHandle fc
    (m1, t1) <- chReceive h
    (m2, t2) <- chReceive h
    t1 `shouldBe` "/ping"
    m1 `shouldBe` Just src
    t2 `shouldBe` "hello"
    m2 `shouldBe` Just src

  it "drives /ping and hello through ingest — slash dispatches, plain routes" $ do
    fc <- newFakeChannelWith True [(src, "/ping"), (src, "hello")] []
    let h    = toHandle fc
        caps = handleCaps h
    -- Pull /ping
    (_, t1) <- chReceive h
    d1      <- ingest testRegistry emptyChain (RawInbound t1)
    case d1 of
      DispatchAction a -> runCommandAction a caps
      other            -> expectationFailure
                            ("expected DispatchAction, got: " <> showShape other)
    -- Pull hello
    (_, t2) <- chReceive h
    d2      <- ingest testRegistry emptyChain (RawInbound t2)
    case d2 of
      PlainMessage t -> t `shouldBe` "hello"
      other          -> expectationFailure
                          ("expected PlainMessage, got: " <> showShape other)
    -- The /ping reply was sent via the handle (forwarded by the adapter)
    sent <- getSent fc
    sent `shouldBe` ["pong"]