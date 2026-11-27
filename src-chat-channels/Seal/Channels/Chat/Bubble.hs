{-# LANGUAGE OverloadedStrings #-}
-- | The pure rendering core for the single-edited-bubble progress style
-- (@PsSingleBubble@), plus the ask renderer and the word-aware message
-- chunker. No IO: everything here is directly testable.
--
-- == Why offset-splice
--
-- The gateway's streaming accumulator is /turn-scoped/: 'webAskCaps' creates
-- its accumulator once per turn and appends every delta
-- ("Seal.Gateway.Send"), so each @entry-update@ frame carries the WHOLE turn's
-- text so far — not just the current response segment. That makes the frame
-- text monotone within a turn, and it means any design that both commits
-- per-response text into blocks and renders frames will emit text twice.
--
-- 'bubbleText' therefore treats the frame text as the sole body and remembers
-- each tool line with the absolute text offset at which it fired. Rendering
-- splices tool lines into that body at their offsets, which keeps the body
-- monotone (no duplication) while preserving the order in which tools actually
-- ran — rather than dumping every tool line below all of the text.
module Seal.Channels.Chat.Bubble
  ( Splice
  , bubbleText
  , formatAsk
  , formatQuestionBody
  , liveAskHint
  , chunkMessage
  , chunkLen
  ) where

import Data.ByteString qualified as BS
import Data.Char (isAsciiUpper)
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Seal.Channels.Chat.Class (ChunkUnit (..), QuestionOption (..))

-- | A tool-progress line together with the length of the streamed text at the
-- moment it fired. The offset is absolute within the turn's cumulative text,
-- so it stays valid as later frames extend that text.
type Splice = (Int, Text)

-- | Render the bubble body from the turn's cumulative text, the tool lines
-- spliced into it, and the trailing cursor (empty for a final edit).
--
-- Offsets are clamped to the text length: a tool-call activity can arrive
-- before the frame that grew the text past it. The body always begins with the
-- text received before the first tool line, so no part of the turn's text is
-- reordered or repeated. Empty tool lines are dropped rather than rendered as a
-- blank block. Pure.
bubbleText :: [Splice] -> Text -> Text -> Text
bubbleText splices text cursor =
  T.intercalate "\n\n" (filter (not . T.null) blocks) <> cursor
  where
    blocks = go 0 (sortOn fst [ s | s@(_, line) <- splices, not (T.null line) ])

    -- Walk the splices in offset order. @consumed@ is how much of @text@ has
    -- already been emitted, so offsets stay absolute as the walk advances.
    go consumed [] = [T.drop consumed text]
    go consumed ((rawOffset, line) : more) =
      let offset = max consumed (min rawOffset (T.length text))
          before = T.take (offset - consumed) (T.drop consumed text)
      in before : line : go offset more

-- | Render an @ASK_HUMAN@ question with a hint telling the human how to reply.
-- An open-ended question gets a bare reply hint; one with options gets a
-- numbered list plus the numeric hint (the form a chat channel without inline
-- keyboards can answer). Pure.
formatAsk :: Text -> [QuestionOption] -> Text
formatAsk question opts = formatQuestionBody question opts <> liveAskHint opts

-- | The question and its numbered options, with **no** reply hint.
--
-- Split out from 'formatAsk' because the hint is only correct when a plain
-- reply actually reaches the question. On the @\\/last@ path it does not (a
-- plain reply goes to the focused tab, not the tab being viewed), so @\\/last@
-- supplies its own answer hint. Emitting "Reply with a number" there would
-- tell the user to do the one thing that misroutes their answer.
--
-- Joining 'formatQuestionBody' with 'liveAskHint' reproduces 'formatAsk'
-- exactly, for both the open-ended and the optioned shape. Pure.
formatQuestionBody :: Text -> [QuestionOption] -> Text
formatQuestionBody question [] = question
formatQuestionBody question opts =
  question
  <> "\n\n"
  <> T.intercalate "\n" (zipWith formatOption [1 :: Int ..] opts)
  where
    formatOption n (QuestionOption lbl desc)
      | T.null desc = T.pack (show n) <> ") " <> lbl
      | otherwise   = T.pack (show n) <> ") " <> lbl <> " \8212 " <> desc

-- | The trailing hint 'formatAsk' appends. Carries its own leading blank line,
-- so @'formatQuestionBody' q os <> 'liveAskHint' os@ is byte-identical to
-- 'formatAsk' @q os@. Pure.
liveAskHint :: [QuestionOption] -> Text
liveAskHint []   = "\n\nReply with your answer."
liveAskHint _    = "\n\nReply with a number or type your own answer."

-- ---------------------------------------------------------------------------
-- Chunking
-- ---------------------------------------------------------------------------

-- | How many @unit@s @t@ occupies.
chunkLen :: ChunkUnit -> Text -> Int
chunkLen ChunkUtf8Bytes  = BS.length . TE.encodeUtf8
chunkLen ChunkUtf16Units = T.foldl' (\n c -> n + codeUnits c) 0
  where
    -- A code point above the BMP (an emoji, many CJK extensions) needs a
    -- surrogate pair, i.e. two UTF-16 code units.
    codeUnits c = if fromEnum c > 0xFFFF then 2 else 1

-- | Split a message into chunks of at most @limit@ @unit@s, breaking at the
-- most natural boundary that fits.
--
-- Platforms inline only the first message and demote the rest to an
-- attachment (or split it themselves at an arbitrary point), so where the
-- split falls is user-visible. Breaking mid-sentence reads as a glitch;
-- breaking at a paragraph break reads as two messages that were always meant
-- to be two. Candidate boundaries, best first:
--
-- 1. paragraph break (@\n\n@)
-- 2. line break (@\n@)
-- 3. sentence end (@.@ @?@ @!@ followed by whitespace, not an abbreviation)
-- 4. clause break (@;@ @:@ @,@ followed by a space)
-- 5. word break (a space)
-- 6. hard split — only when a single token is longer than the whole budget
--
-- Within a class the LATEST boundary that fits wins, so chunks are as full as
-- the class allows rather than as short as possible.
--
-- The separator stays at the END of the chunk it precedes — it is neither
-- dropped nor moved to the front of the next chunk. Keeping it there is what
-- stops a blank line from becoming its own message: the "\n\n" between two
-- paragraphs is consumed by the chunk before it, so the next chunk begins with
-- the following paragraph's text.
--
-- Invariant: @T.concat (chunkMessage u l t)@ equals @t@ modulo TRAILING
-- whitespace. Every non-space character survives, in order, with no separator
-- lost from the middle; only a final all-whitespace remainder is discarded
-- (see 'go').
--
-- Pure. A non-positive @limit@ is treated as "cannot chunk" and returns the
-- text unchanged rather than looping.
chunkMessage :: ChunkUnit -> Int -> Text -> [Text]
chunkMessage unit limit msg
  | limit <= 0 = [msg]
  | chunkLen unit msg <= limit = [msg]
  | otherwise = go msg
  where
    go t
      | T.null t = []
      -- A remainder holding only separators is dropped rather than sent as a
      -- message of its own: a reply ending in a newline would otherwise
      -- deliver a final blank message, which reads as a glitch. Nothing is
      -- lost -- it holds no content, since every non-space character has
      -- already been emitted. The invariant preserved is "no content lost",
      -- not "every byte preserved".
      --
      -- Folding it into the previous chunk instead is not an option: the
      -- remainder is whatever did not fit, so appending it can push that chunk
      -- past the platform limit -- exactly what chunking exists to prevent.
      -- Only a TRAILING all-space remainder is dropped; the
      -- separator-before-content rule in 'naturalCut' already prevents an
      -- INTERIOR blank chunk.
      | T.null (T.strip t) = []
      | chunkLen unit t <= limit = [t]
      | otherwise =
          let (chunk, rest) = splitOne t
          in chunk : go rest

    -- Cut @t@ into (chunk, remainder). The chunk is never empty, so 'go'
    -- always makes progress.
    splitOne t =
      let fitting = takeFitting unit limit t
          cut
            | T.null fitting = 1   -- one character exceeds the whole budget
            | otherwise      = naturalCut fitting
      in (T.take cut t, T.drop cut t)

-- | The longest prefix of @t@ whose unit count fits @limit@, counting whole
-- characters only. A byte-level cut could split a codepoint and produce
-- invalid UTF-8, which the platform would reject or mangle.
takeFitting :: ChunkUnit -> Int -> Text -> Text
takeFitting unit limit t = T.take (fittingChars 0 0) t
  where
    fittingChars n used =
      case T.uncons (T.drop n t) of
        Nothing -> n
        Just (c, _) ->
          let w = chunkLen unit (T.singleton c)
          in if used + w <= limit then fittingChars (n + 1) (used + w) else n

-- | Choose how many characters of @fitting@ to keep, preferring the most
-- natural boundary. The latest boundary in the highest-priority class that
-- has one wins; with no separator at all, the whole fitted prefix is used.
naturalCut :: Text -> Int
naturalCut fitting =
  case catMaybes [paragraphCut, lineCut, sentenceCut, clauseCut, wordCut] of
    (n : _) -> n
    []      -> T.length fitting
  where
    -- A candidate cut is usable only if the chunk it produces holds some
    -- actual content. Without this, a separator at the very start of the
    -- remaining text (the "\n\n" between two paragraphs, which is where the
    -- previous chunk's trim left off) becomes the only candidate and we emit a
    -- message consisting of nothing but a blank line.
    usable n = T.any (not . isSpaceChar) (T.take n fitting)

    -- The latest position just past a run of separators, if any is > 0.
    latestAfter pat = case [ i + T.length pat
                           | i <- [0 .. T.length fitting - T.length pat]
                           , pat `T.isPrefixOf` T.drop i fitting
                           , i + T.length pat > 0
                           , usable (i + T.length pat) ] of
                        [] -> Nothing
                        ns -> Just (maximum ns)
    paragraphCut = latestAfter "\n\n"
    lineCut      = latestAfter "\n"
    wordCut      = latestAfter " "
    clauseCut    = latestBefore ' '
    sentenceCut  = latestSentence

    -- Break after a clause separator that is followed by a space.
    latestBefore ch = case [ i + 1
                           | i <- [1 .. T.length fitting - 1]
                           , T.index fitting i == ch
                           , T.index fitting (i - 1) `elem` (";:," :: String)
                           , usable (i + 1) ] of
                        [] -> Nothing
                        ns -> Just (maximum ns)

    -- Break after sentence-ending punctuation followed by whitespace.
    latestSentence = case [ i + 1
                          | i <- [0 .. T.length fitting - 1]
                          , T.index fitting i `elem` (".?!" :: String)
                          , endsSentence fitting i
                          , usable (i + 1) ] of
                       [] -> Nothing
                       ns -> Just (maximum ns)

-- | Does the terminator at offset @i@ plausibly end a sentence? Requires the
-- next character to be whitespace or absent, and rejects abbreviations and
-- single-letter initials.
--
-- Deliberately conservative: a MISSED sentence break falls through to a
-- clause or word break (a cosmetic loss), whereas a WRONG one — splitting
-- "Dr. Smith" after "Dr." — is visible. Note "e.g." is caught by the
-- single-letter-initial rule only if the lookbehind is applied per token, so
-- the abbreviation list carries the common dotted forms explicitly.
endsSentence :: Text -> Int -> Bool
endsSentence fitting i =
  let after = T.drop (i + 1) fitting
      nextOk = case T.uncons after of
        Nothing     -> True
        Just (c, _) -> c == ' ' || c == '\n' || c == '\t'
      -- The word the terminator is attached to. Taken back to the previous
      -- whitespace, so "e.g." yields "e.g" here and the abbreviation list
      -- matches on the token WITHOUT its final period.
      prevToken = T.dropWhileEnd (== '.') (T.takeWhileEnd (/= ' ') (T.take i fitting))
      lowerTok  = T.toLower prevToken
      isAbbrev  = lowerTok `elem`
        [ "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs", "etc"
        , "e.g", "i.e", "fig", "no", "vol", "al", "cf", "approx", "inc", "ltd" ]
      isInitial = T.length prevToken == 1 && T.all isAsciiUpper prevToken
  in nextOk && not isAbbrev && not isInitial


-- | Whitespace, spelled locally so this module needs no @Data.Char@ import for
-- one predicate.
isSpaceChar :: Char -> Bool
isSpaceChar c = c == ' ' || c == '\n' || c == '\t' || c == '\r'
