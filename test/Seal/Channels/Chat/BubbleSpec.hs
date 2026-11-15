{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Bubble' — the pure rendering core for the
-- single-edited-bubble progress style, plus the ask renderer and the
-- word-aware message chunker.
--
-- The offset-splice scheme: the WS @entry-update@ frame carries the WHOLE
-- turn's text so far (the gateway's accumulator is turn-scoped), so the frame
-- text is the sole body. Each tool line is remembered with the absolute text
-- offset at which it fired, and rendering splices it in there. That keeps one
-- monotone body (no duplicated text) while preserving the order in which
-- tools actually ran.
module Seal.Channels.Chat.BubbleSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf1)

import Seal.Channels.Chat.Bubble
  ( bubbleText
  , formatAsk
  , chunkMessage
  )
import Seal.Channels.Chat.Class (QuestionOption (..))

-- | Arbitrary text with no newlines, so splice offsets stay meaningful.
genLine :: Gen Text
genLine = T.pack <$> listOf1 (elements (['a' .. 'z'] <> ['A' .. 'Z'] <> " "))

spec :: Spec
spec = do
  describe "bubbleText" $ do
    it "returns the empty string when there is no text" $
      bubbleText [] "" "" `shouldBe` ""

    it "returns the text unchanged with no splices and no cursor" $
      bubbleText [] "hello" "" `shouldBe` "hello"

    it "appends the cursor to the end" $
      bubbleText [] "hello" "\x2589" `shouldBe` "hello\x2589"

    it "splices a single tool line at its offset, separated by blank lines" $
      bubbleText [(2, "\x1F4BB SHELL_EXEC")] "abcd" ""
        `shouldBe` "ab\n\n\x1F4BB SHELL_EXEC\n\ncd"

    it "splices two tool lines in offset order, preserving the surrounding text" $
      bubbleText [(2, "TOOL1"), (4, "TOOL2")] "abcdef" ""
        `shouldBe` "ab\n\nTOOL1\n\ncd\n\nTOOL2\n\nef"

    it "renders a tool line before any text when the offset is zero" $
      bubbleText [(0, "X")] "ab" "" `shouldBe` "X\n\nab"

    it "renders a tool line at the end when the offset equals the text length" $
      bubbleText [(2, "X")] "ab" "" `shouldBe` "ab\n\nX"

    it "clamps an offset past the text length to the end" $
      -- The cursor marks in-progress text and always trails the whole body,
      -- so it sits immediately after the last block.
      bubbleText [(99, "X")] "ab" "\x2589" `shouldBe` "ab\n\nX\x2589"

    it "keeps the turn text from being emitted twice (turn-cumulative frames)" $
      -- The frame text is the whole turn so far; a tool line must not make the
      -- prefix reappear.
      let body = bubbleText [(2, "X")] "abcd" ""
      in T.count "ab" body `shouldBe` 1

    it "orders splices given out of order, by offset" $
      bubbleText [(4, "Y"), (2, "X")] "abcdef" ""
        `shouldBe` "ab\n\nX\n\ncd\n\nY\n\nef"

    it "drops an empty tool line rather than emitting a blank block" $
      bubbleText [(2, "")] "ab" "" `shouldBe` "ab"

    prop "a splice at the text length never appears in the middle of the text" $
      forAll genLine $ \t ->
        let body = bubbleText [(T.length t, "X")] t ""
        in T.take (T.length t) body == t

    prop "the rendered body always starts with the text prefix before the first splice" $
      forAll ((,) <$> genLine <*> genLine) $ \(a, b) ->
        let text = a <> b
            body = bubbleText [(T.length a, "X")] text ""
        in T.isPrefixOf a body

  describe "formatAsk" $ do
    it "appends a reply hint for an open-ended question" $
      formatAsk "Which branch?" [] `shouldBe` "Which branch?\n\nReply with your answer."

    it "renders numbered options plus a numeric reply hint" $
      formatAsk "Pick" [QuestionOption "yes" "proceed", QuestionOption "no" ""]
        `shouldBe` "Pick\n\n1) yes \8212 proceed\n2) no\n\nReply with a number or type your own answer."

    it "omits the description separator when an option has none" $
      formatAsk "Pick" [QuestionOption "no" ""]
        `shouldBe` "Pick\n\n1) no\n\nReply with a number or type your own answer."

  describe "chunkMessage" $ do
    it "returns the message as-is when under the limit" $
      chunkMessage 100 "hello" `shouldBe` ["hello"]

    it "handles the empty string" $
      chunkMessage 5 "" `shouldBe` [""]

    it "handles exactly the limit" $
      chunkMessage 5 "abcde" `shouldBe` ["abcde"]

    it "hard-splits a token longer than the limit" $
      chunkMessage 5 "abcdefghij" `shouldBe` ["abcde", "fghij"]

    it "does not split a message that fits" $
      chunkMessage 12 "aaa\nbbb\nccc" `shouldBe` ["aaa\nbbb\nccc"]

    it "prefers a newline boundary over a hard split" $
      -- A hard split at 10 would cut through "ccc"; breaking after the last
      -- newline keeps every line whole.
      chunkMessage 10 "aaa\nbbb\nccc" `shouldBe` ["aaa\nbbb\n", "ccc"]

    it "prefers a space boundary over a hard split" $
      chunkMessage 10 "aaa bbb ccc" `shouldBe` ["aaa bbb ", "ccc"]

    it "never splits a numbered option line that fits on its own" $
      let q = "Which branch?\n\n1) main \8212 the default branch\n2) develop \8212 integration\n\nReply with a number or type your own answer."
          chunks = chunkMessage 60 q
      in T.concat chunks `shouldBe` q

    prop "preserves the full text across chunks" $
      forAll genLine $ \t ->
        T.concat (chunkMessage 20 t) == t

    prop "never emits an empty chunk for a non-empty message" $
      forAll genLine $ \t ->
        not (any T.null (chunkMessage 20 t))
