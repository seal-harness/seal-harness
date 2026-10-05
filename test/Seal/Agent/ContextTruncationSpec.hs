{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.ContextTruncationSpec (spec) where

import Data.Aeson (object)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Agent.ContextTruncation
import Seal.Core.Types (OpName (..), ToolCallId (..))
import Seal.Providers.Class

-- | Generate a message with a text content block of the given size.
mkTextMsg :: Role -> Text -> Message
mkTextMsg role text = Message role [CbText text]

-- | Arbitrary non-empty text for QuickCheck.
newtype NonEmptyText = NonEmptyText Text deriving stock (Eq, Show)

instance Arbitrary NonEmptyText where
  arbitrary = NonEmptyText . T.pack <$> listOf1 (elements "abcdefghij ")

spec :: Spec
spec = do
  describe "Seal.Agent.ContextTruncation" $ do

    describe "estimateTokenCount" $ do
      it "returns >= 0 for empty messages and no system prompt" $
        estimateTokenCount Nothing [] [] `shouldSatisfy` (>= 0)

      it "returns >= 0 for empty messages with empty system" $
        estimateTokenCount (Just "") [] [] `shouldSatisfy` (>= 0)

      it "estimates tokens for system prompt only (chars/4)" $ do
        let sys = T.replicate 400 "x"  -- 400 chars → ~100 tokens
        estimateTokenCount (Just sys) [] [] `shouldSatisfy` (> 80)

      it "estimates tokens for messages" $ do
        let msgs = [mkTextMsg User (T.replicate 400 "a")]  -- 400 chars → ~100 tokens
        estimateTokenCount Nothing msgs [] `shouldSatisfy` (> 80)

      it "estimates tokens for tool definitions" $ do
        let tools = [ToolDefinition (OpName "SOME_OP") (T.replicate 400 "d") (object [])]
        estimateTokenCount Nothing [] tools `shouldSatisfy` (> 80)

      it "scales with message count" $ do
        let small = [mkTextMsg User "hello"]
            large = replicate 100 (mkTextMsg User "hello")
            s = estimateTokenCount Nothing small []
            l = estimateTokenCount Nothing large []
        l `shouldSatisfy` (> s)

      prop "always returns non-negative" $ \(NonEmptyText t) ->
        estimateTokenCount (Just t) [mkTextMsg User t] [] >= 0

    describe "truncateMessages" $ do
      it "returns messages unchanged when under budget" $ do
        let msgs = [mkTextMsg User "hello", mkTextMsg Assistant "hi"]
        truncateMessages defaultTruncationConfig 10000 msgs
          `shouldBe` msgs

      it "drops oldest messages when over budget" $ do
        let msgs = [ mkTextMsg User "old message that is quite long indeed"
                   , mkTextMsg User "new message"
                   ]
            budget = estimateTokenCount Nothing [mkTextMsg User "new message"] []
            result = truncateMessages defaultTruncationConfig budget msgs
        -- The newest message should be preserved
        result `shouldSatisfy` any (\m -> "new message" `T.isInfixOf` msgContentText m)

      it "inserts a truncation notice when truncation occurs" $ do
        let msgs = replicate 50 (mkTextMsg User (T.replicate 100 "x"))
            budget = 50  -- very small, forces truncation
            result = truncateMessages defaultTruncationConfig budget msgs
            noticeTexts = [t | Message _ blocks <- result, CbText t <- blocks
                             , truncationNotice `T.isInfixOf` t]
        noticeTexts `shouldNotSatisfy` null

      it "does not insert a truncation notice when messages fit" $ do
        let msgs = [mkTextMsg User "hello", mkTextMsg Assistant "hi"]
            budget = 10000
            result = truncateMessages defaultTruncationConfig budget msgs
            noticeTexts = [t | Message _ blocks <- result, CbText t <- blocks
                             , truncationNotice `T.isInfixOf` t]
        noticeTexts `shouldBe` []

      it "preserves the most recent messages" $ do
        let msgs = map (\i -> mkTextMsg User ("msg-" <> T.pack (show i)))
                        [1 .. 30 :: Int]
                    <> [mkTextMsg User "final"]
            budget = 50  -- very small, forces truncation
            result = truncateMessages defaultTruncationConfig budget msgs
        -- "final" should always be in the result
        result `shouldSatisfy` any (\m -> "final" `T.isInfixOf` msgContentText m)

      it "produces fewer messages than input when truncation occurs" $ do
        let msgs = replicate 50 (mkTextMsg User (T.replicate 100 "x"))
            budget = 50  -- very small, forces truncation
            result = truncateMessages defaultTruncationConfig budget msgs
        length result `shouldSatisfy` (< length msgs)

      it "preserves the last tool-use + tool-result pair (not split)" $ do
        -- Construct a list where the truncation boundary falls between
        -- a tool-use and tool-result. With keepRecent=20 and 25 messages,
        -- the first 5 are dropped. Place tool-use at position 5 (last
        -- dropped) and tool-result at position 6 (first kept). The
        -- alignToolPair function should pull back the tool-use.
        let big = mkTextMsg User (T.replicate 200 "x")  -- ~50 tokens each
            toolUse = Message Assistant
              [CbToolUse (ToolCallId "tc1") (OpName "SOME_OP") (object [])]
            toolResult = Message User
              [CbToolResult (ToolCallId "tc1") [TrpText "result"] False]
            -- 4 big (dropped) + toolUse (pos 5, last dropped) + toolResult
            -- (pos 6, first kept) + 19 big (kept) = 25 total
            msgs = replicate 4 big <> [toolUse, toolResult] <> replicate 19 big
            budget = 100  -- forces truncation (25 messages × ~50 tokens = ~1250)
            result = truncateMessages defaultTruncationConfig budget msgs
            hasUse = any hasToolUseBlock result
            hasResult = any hasToolResultBlock result
        -- If the tool-use is present, the tool-result must also be present
        -- (and vice versa) — never split a tool-use/tool-result pair.
        (hasUse && hasResult) || (not hasUse && not hasResult)
          `shouldBe` True
        -- When the budget is very small, both may be dropped together
        -- (by shrinkToFit's dropOne) — the invariant is "not split", not
        -- "always preserved".

      it "alignToolPair positively pulls back tool-use at boundary" $ do
        -- Use a budget large enough to keep the tool pair after alignToolPair
        -- pulls it back, but small enough to trigger truncation of the
        -- oldest messages. With 25 messages and keepRecent=20, the first 5
        -- are dropped. Place tool-use at position 5 (last dropped) and
        -- tool-result at position 6 (first kept). With a generous budget,
        -- shrinkToFit won't drop the tool pair.
        let small = mkTextMsg User "short"  -- ~1 token each
            toolUse = Message Assistant
              [CbToolUse (ToolCallId "tc1") (OpName "SOME_OP") (object [])]
            toolResult = Message User
              [CbToolResult (ToolCallId "tc1") [TrpText "result"] False]
            -- 5 small (dropped) + toolUse (pos 6, last dropped) + toolResult
            -- (pos 7, first kept) + 19 small (kept) = 26 total
            -- Wait: keepRecent=20, so last 20 kept = [toolResult, small×19]
            -- dropped = first 6 = [small×5, toolUse]
            -- alignToolPair sees toolResult at front of kept, pulls back toolUse
            msgs = replicate 5 small <> [toolUse, toolResult] <> replicate 19 small
            -- Budget: enough for ~22 messages of ~1 token each + notice (~42 tokens)
            budget = 100
            result = truncateMessages defaultTruncationConfig budget msgs
        -- The tool-use should be present (pulled back by alignToolPair)
        any hasToolUseBlock result `shouldBe` True
        -- The tool-result should be present
        any hasToolResultBlock result `shouldBe` True

      it "aggressive mode keeps only the last aggressiveKeepCount messages" $ do
        let msgs = map (\i -> mkTextMsg User ("msg-" <> T.pack (show i)))
                        [1 .. 20 :: Int]
            result = aggressiveTruncate msgs
        length result `shouldBe` aggressiveKeepCount
        -- The last message should be preserved
        result `shouldSatisfy` any (\m -> "msg-20" `T.isInfixOf` msgContentText m)

      it "aggressive mode returns all messages if fewer than aggressiveKeepCount" $ do
        let msgs = [mkTextMsg User "a", mkTextMsg User "b"]
        aggressiveTruncate msgs `shouldBe` msgs

      prop "never returns more messages than input" $ \(NonEmptyText t) ->
        let msgs = replicate 10 (mkTextMsg User t)
            budget = 1  -- very small budget
            result = truncateMessages defaultTruncationConfig budget msgs
        in length result <= length msgs

      prop "result fits within budget or is minimum viable" $ \(NonEmptyText t) ->
        let msgs = replicate 5 (mkTextMsg User t)
            budget = max 1 (estimateTokenCount Nothing [mkTextMsg User t] [])
            result = truncateMessages defaultTruncationConfig budget msgs
            resultTokens = estimateTokenCount Nothing result []
            -- The truncation notice is a constant overhead (always 1 extra
            -- message when truncation occurs). The minimum result is
            -- notice + minKeep content messages.
            minResultLen = tcMinKeep defaultTruncationConfig + 1
        in resultTokens <= budget || length result <= minResultLen

  where
    -- Helpers
    msgContentText :: Message -> Text
    msgContentText (Message _ blocks) =
      T.intercalate "\n" [t | CbText t <- blocks]

    hasToolUseBlock :: Message -> Bool
    hasToolUseBlock (Message _ blocks) = any isUse blocks
      where isUse CbToolUse{} = True
            isUse _ = False

    hasToolResultBlock :: Message -> Bool
    hasToolResultBlock (Message _ blocks) = any isResult blocks
      where isResult CbToolResult{} = True
            isResult _ = False
