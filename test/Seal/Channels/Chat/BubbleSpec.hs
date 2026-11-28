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

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf1)

import Seal.Channels.Chat.Bubble
  ( bubbleText
  , formatAsk
  , formatQuestionBody
  , chunkLen
  , chunkMessage
  , liveAskHint
  )
import Seal.Channels.Chat.Class (ChunkUnit (..), QuestionOption (..))

-- | UTF-8 encoded length, the unit Signal's limit is actually expressed in.
utf8Len :: Text -> Int
utf8Len = BS.length . TE.encodeUtf8

-- | Arbitrary text with no newlines, so splice offsets stay meaningful.
genLine :: Gen Text
genLine = T.pack <$> listOf1 (elements (['a' .. 'z'] <> ['A' .. 'Z'] <> " "))

-- | Text mixing ASCII, multi-byte BMP characters, astral (emoji) characters
-- and the separators the chunker keys on. The mixing is what exercises the
-- unit arithmetic: a code-point count agrees with neither a byte budget nor a
-- UTF-16 one.
genMixed :: Gen Text
genMixed = T.pack <$> listOf1 (elements pieces)
  where
    pieces = ['a' .. 'z']
          <> ['A' .. 'Z']
          <> "    \n\n.;:,.?!"
          <> ['\x4E16', '\x1F600', '\x00E9']   -- CJK, emoji, e-acute

-- | Local whitespace predicate, matching the chunker's own.
isSpaceChar :: Char -> Bool
isSpaceChar c = c == ' ' || c == '\n' || c == '\t' || c == '\r'

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

  describe "formatQuestionBody" $ do
    it "omits the reply hint entirely for an open-ended question" $
      formatQuestionBody "Which branch?" [] `shouldBe` "Which branch?"

    it "renders numbered options with no reply hint" $
      formatQuestionBody "Pick" [QuestionOption "yes" "proceed", QuestionOption "no" ""]
        `shouldBe` "Pick\n\n1) yes \8212 proceed\n2) no"

    it "never emits a reply hint (the /last path supplies its own)" $
      formatQuestionBody "Pick" [QuestionOption "yes" ""]
        `shouldSatisfy` (not . T.isInfixOf "Reply with")

  describe "liveAskHint" $ do
    it "is the open-ended hint" $
      liveAskHint [] `shouldBe` "\n\nReply with your answer."

    it "is the numbered hint" $
      liveAskHint [QuestionOption "yes" ""]
        `shouldBe` "\n\nReply with a number or type your own answer."

    it "recomposes formatAsk exactly, for both shapes" $ do
      formatQuestionBody "Q" [] <> liveAskHint []
        `shouldBe` formatAsk "Q" []
      let os = [QuestionOption "yes" "proceed", QuestionOption "no" ""]
      formatQuestionBody "Q" os <> liveAskHint os `shouldBe` formatAsk "Q" os

  describe "chunkMessage" $ do
    it "returns the message as-is when under the limit" $
      chunkMessage ChunkUtf8Bytes 100 "hello" `shouldBe` ["hello"]

    it "handles the empty string" $
      chunkMessage ChunkUtf8Bytes 5 "" `shouldBe` [""]

    it "handles exactly the limit" $
      chunkMessage ChunkUtf8Bytes 5 "abcde" `shouldBe` ["abcde"]

    it "hard-splits a token longer than the limit" $
      chunkMessage ChunkUtf8Bytes 5 "abcdefghij" `shouldBe` ["abcde", "fghij"]

    -- Signal's limit is BYTES, not characters: text over ~2048 bytes is moved
    -- to an attachment and only the first part is inlined. Splitting on
    -- character count therefore overruns the real limit for any non-ASCII
    -- text (an emoji is 4 UTF-8 bytes), causing silent truncation on the
    -- recipient's device.
    it "measures the limit in UTF-8 bytes, not characters" $ do
      -- 4 ASCII chars = 4 bytes, so three fit in 12.
      chunkMessage ChunkUtf8Bytes 12 "abcdefghijkl" `shouldBe` ["abcdefghijkl"]
      -- 3 emoji = 12 bytes; a 12-byte budget allows all three in one chunk.
      let three = T.replicate 3 "\x1F600"
      T.concat (chunkMessage ChunkUtf8Bytes 12 three) `shouldBe` three

    it "splits multi-byte text by byte size even when the char count fits" $ do
      -- 4 emoji are only 4 codepoints but 16 UTF-8 bytes.
      let four = T.replicate 4 "\x1F600"
          chunks = chunkMessage ChunkUtf8Bytes 8 four
      chunks `shouldSatisfy` ((> 1) . length)
      chunks `shouldSatisfy` all (\c -> T.length c <= 2)

    prop "never exceeds the byte limit" $
      forAll genLine $ \t ->
        all (\c -> utf8Len c <= 20) (chunkMessage ChunkUtf8Bytes 20 t)

    it "does not split a message that fits" $
      chunkMessage ChunkUtf8Bytes 12 "aaa\nbbb\nccc" `shouldBe` ["aaa\nbbb\nccc"]

    it "prefers a newline boundary over a hard split" $
      -- A hard split at 10 would cut through "ccc"; breaking after the last
      -- newline keeps every line whole.
      chunkMessage ChunkUtf8Bytes 10 "aaa\nbbb\nccc" `shouldBe` ["aaa\nbbb\n", "ccc"]

    it "prefers a space boundary over a hard split" $
      chunkMessage ChunkUtf8Bytes 10 "aaa bbb ccc" `shouldBe` ["aaa bbb ", "ccc"]

    it "never splits a numbered option line that fits on its own" $
      let q = "Which branch?\n\n1) main \8212 the default branch\n2) develop \8212 integration\n\nReply with a number or type your own answer."
          chunks = chunkMessage ChunkUtf8Bytes 60 q
      in T.concat chunks `shouldBe` q

    prop "preserves all content across chunks (trailing whitespace aside)" $
      forAll genLine $ \t ->
        T.stripEnd (T.concat (chunkMessage ChunkUtf8Bytes 20 t)) == T.stripEnd t

    prop "never emits an empty chunk for a non-empty message" $
      forAll genLine $ \t ->
        not (any T.null (chunkMessage ChunkUtf8Bytes 20 t))

  describe "chunkMessage boundary awareness" $ do
    -- Where a split falls is user-visible: the platform inlines the first
    -- message and demotes the rest to an attachment, so breaking mid-sentence
    -- reads as a glitch. These pin the preference order.

    it "breaks at a paragraph boundary rather than mid-sentence" $
      let doc = "First para.\n\nSecond para is longer than the budget here."
      in chunkMessage ChunkUtf8Bytes 20 doc
           `shouldBe` ["First para.\n\n", "Second para is ", "longer than the ", "budget here."]

    it "keeps a whole paragraph together when it fits" $
      let doc = "aaa bbb ccc.\n\nddd eee fff."
      in chunkMessage ChunkUtf8Bytes 14 doc
           `shouldBe` ["aaa bbb ccc.\n\n", "ddd eee fff."]

    it "breaks at a sentence end rather than mid-sentence" $
      let s = "The first sentence is short. The second one is longer than the limit."
      in chunkMessage ChunkUtf8Bytes 32 s
           `shouldBe` ["The first sentence is short.", " The second one is longer than ", "the limit."]

    it "does not break after an abbreviation" $
      -- The period in "Dr." is followed by a space, but splitting there is
      -- visibly wrong, so the abbreviation must fall through to a word break.
      chunkMessage ChunkUtf8Bytes 20 "Dr. Smith went to Washington today."
        `shouldBe` ["Dr. Smith went to ", "Washington today."]

    it "does not break after a single-letter initial" $
      chunkMessage ChunkUtf8Bytes 12 "J. Smith wrote this."
        `shouldBe` ["J. Smith ", "wrote this."]

    it "prefers a sentence boundary over a word boundary at the same length" $
      let s = "Done. More words follow right after this point."
      in chunkMessage ChunkUtf8Bytes 7 s
           `shouldBe` ["Done.", " More ", "words ", "follow ", "right ", "after ", "this ", "point."]

    it "never emits a chunk that is only whitespace" $
      -- The "\\n\\n" between paragraphs sits at the start of the remainder
      -- once the previous chunk ends a paragraph. It must not become its own
      -- message.
      let doc = "First paragraph here.\n\nSecond paragraph that is a bit longer than sixty bytes total.\n\nThird."
          chunks = chunkMessage ChunkUtf8Bytes 60 doc
      in chunks `shouldSatisfy` all (T.any (not . isSpaceChar))

    it "round-trips text that is mostly paragraph breaks" $
      let doc = "A.\n\nB.\n\nC.\n\nD."
      in T.concat (chunkMessage ChunkUtf8Bytes 4 doc) `shouldBe` doc

  describe "chunkMessage units" $ do
    -- Signal's budget is UTF-8 bytes; Telegram's is UTF-16 code units.
    -- Counting code points is correct for neither, and overruns both.

    it "measures UTF-8 bytes so an emoji costs four" $
      chunkMessage ChunkUtf8Bytes 8 (T.replicate 3 "\x1F600")
        `shouldBe` [T.replicate 2 "\x1F600", "\x1F600"]

    it "measures UTF-16 code units so an emoji costs two" $
      chunkMessage ChunkUtf16Units 4 (T.replicate 3 "\x1F600")
        `shouldBe` [T.replicate 2 "\x1F600", "\x1F600"]

    it "counts a BMP character as one UTF-16 unit" $ do
      chunkLen ChunkUtf16Units "abc" `shouldBe` 3
      chunkLen ChunkUtf8Bytes "abc" `shouldBe` 3

    it "counts an astral character as two UTF-16 units but four bytes" $ do
      chunkLen ChunkUtf16Units "\x1F600" `shouldBe` 2
      chunkLen ChunkUtf8Bytes "\x1F600" `shouldBe` 4

    it "counts a CJK character as one UTF-16 unit but three bytes" $ do
      chunkLen ChunkUtf16Units "\x4E16" `shouldBe` 1
      chunkLen ChunkUtf8Bytes "\x4E16" `shouldBe` 3

    prop "a byte budget is never exceeded, whatever the character mix" $
      forAll genMixed $ \t ->
        all (\c -> chunkLen ChunkUtf8Bytes c <= 24)
            (chunkMessage ChunkUtf8Bytes 24 t)

    prop "a UTF-16 unit budget is never exceeded, whatever the character mix" $
      forAll genMixed $ \t ->
        all (\c -> chunkLen ChunkUtf16Units c <= 12)
            (chunkMessage ChunkUtf16Units 12 t)

    prop "loses no content under a byte budget (trailing space aside)" $
      forAll genMixed $ \t ->
        T.stripEnd (T.concat (chunkMessage ChunkUtf8Bytes 24 t)) == T.stripEnd t

    prop "loses no content under a UTF-16 budget (trailing space aside)" $
      forAll genMixed $ \t ->
        T.stripEnd (T.concat (chunkMessage ChunkUtf16Units 12 t)) == T.stripEnd t

    prop "never emits an empty chunk" $
      forAll genMixed $ \t ->
        not (any T.null (chunkMessage ChunkUtf8Bytes 24 t))

    prop "never emits a whitespace-only chunk for text with any non-space" $
      forAll genMixed $ \t ->
        T.null (T.strip t) || all (T.any (not . isSpaceChar))
                                  (chunkMessage ChunkUtf8Bytes 24 t)

    it "does not send a trailing space as its own message" $ do
      -- Regression: a reply ending in whitespace produced a final message
      -- containing just that whitespace. A chunk holding only separators is
      -- dropped, since it carries no content.
      let t = "DBLuX:GExbW\19990l!lUN\x1F600y "
      chunkMessage ChunkUtf8Bytes 24 t
        `shouldBe` ["DBLuX:GExbW\19990l!lUN\x1F600y"]
      -- Every non-space character survives.
      T.stripEnd (T.concat (chunkMessage ChunkUtf8Bytes 24 t)) `shouldBe` T.stripEnd t

    it "keeps a trailing newline with the content it follows" $
      -- The newline belongs to the "cc\n" chunk rather than becoming a
      -- message of its own.
      chunkMessage ChunkUtf8Bytes 10 "aaa bbb cc\n"
        `shouldBe` ["aaa bbb ", "cc\n"]

    it "drops a whitespace-only message rather than sending a blank one" $
      chunkMessage ChunkUtf8Bytes 3 "abc  "
        `shouldBe` ["abc"]

    it "passes the text through when the budget is non-positive" $
      chunkMessage ChunkUtf8Bytes 0 "hello" `shouldBe` ["hello"]

    it "always makes progress on a single character wider than the budget" $
      chunkMessage ChunkUtf8Bytes 2 (T.replicate 3 "\x1F600")
        `shouldBe` ["\x1F600", "\x1F600", "\x1F600"]
