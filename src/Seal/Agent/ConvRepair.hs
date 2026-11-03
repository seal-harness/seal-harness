{-# LANGUAGE OverloadedStrings #-}
-- | Repairs an interrupted conversation before a resumed turn.
--
-- A child turn is killed between two durable writes: the assistant message
-- carrying its @tool_use@ blocks is fsync'd before the tools run
-- ('Seal.Agent.Loop' writes the assistant message, then dispatches), so a kill
-- mid-dispatch leaves @conversation.jsonl@ ending with an assistant turn whose
-- @tool_use@ ids have no matching @tool_result@. Providers encode messages
-- verbatim, so the next request is rejected (Anthropic rejects a @tool_use@
-- without a @tool_result@).
--
-- 'repairDanglingToolUse' appends one synthetic, explicitly-unknown result per
-- unmatched id of the /final/ tool-use turn. It only ever appends, which keeps
-- the indexed-transcript writer's prefix-extension invariant intact, so the
-- repair is persisted as ordinary conversation lines.
--
-- Unmatched ids in an /earlier/ turn are reported, not repaired: appending a
-- result at the end would place it in the wrong position and the request would
-- still be invalid. Those are real corruption ('Seal.Agent.Loop' logs them).
module Seal.Agent.ConvRepair
  ( repairDanglingToolUse
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)

import Seal.Core.Types (ToolCallId (..))
import Seal.Providers.Class
  ( ContentBlock (..)
  , Message (..)
  , Role (..)
  , ToolResultPart (..)
  )

-- | The tool names that appear in @tool_use@ blocks.
toolUseIds :: Message -> [ToolCallId]
toolUseIds (Message _ blocks) = [cid | CbToolUse cid _ _ <- blocks]

-- | The tool-call ids answered anywhere in the conversation.
answeredIds :: [Message] -> Set ToolCallId
answeredIds = Set.fromList . concatMap results
  where
    results (Message _ blocks) = [cid | CbToolResult cid _ _ <- blocks]

-- | @True@ when the messages after the tool-use turn are nothing but tool
-- results. Appending a missing result is only sound in that shape: the repair
-- then lands immediately after its @tool_use@, which is where providers
-- require it. Any other trailing content means the dangling id is mid-history.
trailingOnlyResults :: [Message] -> Bool
trailingOnlyResults = all isResultsOnly
  where
    isResultsOnly (Message User blocks) =
      not (null blocks) && all isResult blocks
    isResultsOnly _ = False
    isResult CbToolResult {} = True
    isResult _               = False

-- | Index of the last assistant message that carries at least one @tool_use@.
lastToolUseIndex :: [Message] -> Maybe Int
lastToolUseIndex conv =
  case [i | (i, m) <- zip [0 ..] conv, isToolUseTurn m] of
    []    -> Nothing
    is    -> Just (last is)
  where
    isToolUseTurn m@(Message Assistant _) = not (null (toolUseIds m))
    isToolUseTurn _                       = False

-- | Append synthetic error results for the unanswered ids of the final
-- tool-use turn. See the module header.
repairDanglingToolUse :: [Message] -> ([Text], [Message])
repairDanglingToolUse conv =
  case lastToolUseIndex conv of
    Nothing -> ([], conv)
    Just i ->
      let fromIdx = drop i conv
          (toolUseTurn, after) = case fromIdx of
            (m : rest) -> (m, rest)
            []         -> (Message Assistant [], [])
          answered = answeredIds conv
          unmatched = [cid | cid <- toolUseIds toolUseTurn, Set.notMember cid answered]
      in case unmatched of
           [] -> ([], conv)
           _
             | trailingOnlyResults after ->
                 ([], conv <> [syntheticResults unmatched])
             | otherwise ->
                 (map toolCallIdText unmatched, conv)

-- | The single user message carrying one error result per unmatched id.
syntheticResults :: [ToolCallId] -> Message
syntheticResults ids =
  Message User
    [ CbToolResult cid [TrpText repairText] True
    | cid <- ids
    ]

repairText :: Text
repairText =
  "interrupted before this tool returned; it may have partially or fully \
  \completed — verify with a read or a status check before retrying."

toolCallIdText :: ToolCallId -> Text
toolCallIdText (ToolCallId t) = t
