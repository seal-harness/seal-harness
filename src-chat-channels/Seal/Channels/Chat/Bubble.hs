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
  , chunkMessage
  ) where

import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Channels.Chat.Class (QuestionOption (..))

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
formatAsk question [] = question <> "\n\nReply with your answer."
formatAsk question opts =
  question
  <> "\n\n"
  <> T.intercalate "\n" (zipWith formatOption [1 :: Int ..] opts)
  <> "\n\nReply with a number or type your own answer."
  where
    formatOption n (QuestionOption lbl desc)
      | T.null desc = T.pack (show n) <> ") " <> lbl
      | otherwise   = T.pack (show n) <> ") " <> lbl <> " \8212 " <> desc

-- | Split a message into chunks of at most @limit@ characters on word
-- boundaries where possible. Splits at the last newline inside the limit, then
-- the last space; only a single token longer than the limit is hard-split. A
-- line that fits on its own is never broken, which matters for the numbered
-- option lists this module renders. Pure.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit msg
  | limit <= 0 = [msg]
  | T.length msg <= limit = [msg]
  | otherwise = go msg
  where
    go t
      | T.length t <= limit = [t]
      | otherwise = T.take n t : go (T.drop n t)
      where n = splitPoint t

    -- How many characters the first chunk takes: break AFTER the last newline
    -- inside the limit, else after the last space, else hard-split at the
    -- limit. The break separator stays with the chunk, so concatenating the
    -- chunks reproduces the input exactly.
    splitPoint t = fromMaybe (fromMaybe limit (lastBreak ' ' t)) (lastBreak '\n' t)

    -- 1-based length of the prefix ending at the last @ch@ inside the limit.
    -- 'Nothing' when @ch@ does not occur in the first @limit@ characters.
    lastBreak ch t =
      let headPart = T.take limit t
      in case T.findIndex (== ch) (T.reverse headPart) of
           Just fromEnd -> Just (T.length headPart - fromEnd)
           Nothing      -> Nothing
