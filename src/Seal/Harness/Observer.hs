{-# LANGUAGE OverloadedStrings #-}
-- | The per-flavour harness observer: classify a captured screen + the
-- tmux marker map into a 'Liveness'. Pure (the capture is IO, the
-- classification is pure). Only the Claude Code screen-capture heuristic
-- lands in 6a; a codex/generic observer is a follow-up.
module Seal.Harness.Observer
  ( observeClaudeCode
  , livenessToActivity
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Harness.Registry (Liveness (..))

-- | Classify a captured Claude Code screen + the marker map into a
-- 'Liveness'. Heuristic:
--
-- * 'LvExited' when the @seal_id marker is gone AND the pane is dead
--   (the @pane_dead@ marker is present).
-- * 'LvOrphaned' when the pane exists but the @seal_id marker is gone
--   (someone renamed the window out from under us, or the harness crashed
--   and the pane is in a stale state).
-- * 'LvThinking' when the screen shows a spinner / "Thinking…" / "Working…".
-- * 'LvAwaitingInput' when the screen shows the Claude Code prompt (@> @
--   at the bottom + no spinner) or a yes/no confirmation.
-- * 'LvIdle' otherwise (at the main prompt but not awaiting input).
observeClaudeCode :: Text -> Map Text Text -> Liveness
observeClaudeCode screen markers
  | not hasSealId && paneDead        = LvExited
  | not hasSealId                    = LvOrphaned
  | T.isInfixOf "Thinking" stripped  = LvThinking
  | T.isInfixOf "Working" stripped   = LvThinking
  | isAwaiting screen                 = LvAwaitingInput
  | otherwise                        = LvIdle
  where
    hasSealId = Map.member "seal_id" markers
    paneDead  = Map.lookup "pane_dead" markers == Just "1"
    stripped  = T.strip screen
    isAwaiting s =
      let ll = T.strip (lastLine s)
      in ll == ">" || ll == ">"
         || T.isInfixOf "? (y/n)" s
         || T.isInfixOf "? Yes/No" s
         || T.isInfixOf "Press Enter" s

-- | The last non-empty line of a captured screen.
lastLine :: Text -> Text
lastLine s = case filter (not . T.null) (T.lines s) of
  []  -> ""
  xs  -> last xs

-- | Map a 'Liveness' to the activity-stream tag the frontend (Phase 7)
-- consumes.
livenessToActivity :: Liveness -> Text
livenessToActivity = \case
  LvIdle          -> "idle"
  LvThinking      -> "thinking"
  LvAwaitingInput -> "awaiting_input"
  LvExited        -> "exited"
  LvOrphaned      -> "orphaned"