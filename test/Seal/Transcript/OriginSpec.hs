{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Rendering per-message origin into the text the model reads. The stored
-- transcript keeps the clean text plus the structured origin; only the
-- provider request carries the rendered tag.
module Seal.Transcript.OriginSpec (spec) where

import Data.Text (Text)
import Test.Hspec
import Test.QuickCheck

import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, mkConversationId, mkMessageSource, mkUserId )
import Seal.Core.Types (ToolCallId (..))
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), MessageOrigin (..), Role (..), pattern Message
  , ToolResultPart (..), textMsg )
import Seal.TestHelpers.Arbitrary ()
import Seal.Transcript.Origin

-- | A Telegram 'MessageSource', as the gateway mints one from transport
-- metadata (server-derived conversation id + optional authenticated sender).
telegramSource :: Maybe Text -> MessageSource
telegramSource mUid =
  case mkConversationId "tg:12345" of
    Left e -> error ("test: bad conversation id: " <> show e)
    Right cid -> case traverse mkUserId mUid of
      Left e -> error ("test: bad user id: " <> show e)
      Right uid -> case mkMessageSource cid Telegram uid mempty of
        Left e   -> error ("test: bad message source: " <> show e)
        Right ms -> ms

-- | The text blocks of a message, in order.
texts :: Message -> [Text]
texts m = [t | CbText t <- msgContent m]

-- | Drop every origin, for the "unchanged when there is nothing to render"
-- property.
stripOrigins :: [Message] -> [Message]
stripOrigins = map (\m -> m { msgOrigin = Nothing })

originOf :: Text -> Message -> Message
originOf ch m = m { msgOrigin = Just (MessageOrigin ch Nothing Nothing) }

toolResultOnly :: Message
toolResultOnly = Message User [CbToolResult (ToolCallId "t1") [TrpText "r"] False]

spec :: Spec
spec = describe "Seal.Transcript.Origin" $ do
  describe "originFromSource" $ do
    it "carries the channel tag, the sender id, and the conversation id" $
      originFromSource (telegramSource (Just "12345"))
        `shouldBe` MessageOrigin "telegram" (Just "12345") (Just "tg:12345")

    it "carries no sender when the channel authenticated none" $
      originFromSource (telegramSource Nothing)
        `shouldBe` MessageOrigin "telegram" Nothing (Just "tg:12345")

  describe "renderOriginTag" $ do
    it "renders channel and sender as [channel:userId]" $
      renderOriginTag (MessageOrigin "signal" (Just "+15551234567") Nothing)
        `shouldBe` "[signal:+15551234567]"

    it "renders just the channel when there is no sender" $
      renderOriginTag (MessageOrigin "signal" Nothing Nothing)
        `shouldBe` "[signal]"

  describe "annotateOrigins" $ do
    it "prefixes a user message with its origin tag" $
      annotateOrigins [originOf "telegram" (textMsg User "hello")]
        `shouldBe` [originOf "telegram" (textMsg User "[telegram] hello")]

    it "gives each message in a group chat its own sender tag" $ do
      let firstSender  = (textMsg User "from one") { msgOrigin = Just (MessageOrigin "signal" (Just "+1") Nothing) }
          secondSender = (textMsg User "from two") { msgOrigin = Just (MessageOrigin "signal" (Just "+2") Nothing) }
      map texts (annotateOrigins [firstSender, secondSender])
        `shouldBe` [["[signal:+1] from one"], ["[signal:+2] from two"]]

    it "leaves a message with no origin unchanged" $
      property $ \msgs ->
        annotateOrigins (stripOrigins msgs) === stripOrigins msgs

    it "leaves assistant messages unchanged" $
      annotateOrigins [originOf "telegram" (textMsg Assistant "hi")]
        `shouldBe` [originOf "telegram" (textMsg Assistant "hi")]

    it "tags only the first text block" $
      annotateOrigins [originOf "web" (Message User [CbText "one", CbText "two"])]
        `shouldBe` [originOf "web" (Message User [CbText "[web] one", CbText "two"])]

    it "prefixes the first text block when a message leads with another block" $
      annotateOrigins [originOf "web" (Message User [CbToolResult (ToolCallId "t1") [TrpText "r"] False, CbText "words"])]
        `shouldBe`
          [ originOf "web"
              (Message User [CbToolResult (ToolCallId "t1") [TrpText "r"] False, CbText "[web] words"]) ]

    it "leaves a user message with no text block unchanged" $
      annotateOrigins [originOf "web" toolResultOnly] `shouldBe` [originOf "web" toolResultOnly]

    it "is idempotent" $
      property $ \m ->
        let annotated = annotateOrigins [originOf "web" m]
        in annotateOrigins annotated === annotated
