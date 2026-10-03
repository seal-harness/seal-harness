{-# LANGUAGE OverloadedStrings #-}
-- | Pure context window management: token estimation and message truncation.
--
-- The agent loop ('Seal.Agent.Loop') calls these functions before building a
-- 'CompletionRequest' to ensure the conversation fits within the model's
-- context window. All functions are pure — no IO, no 'AgentEnv' dependency —
-- so they can be tested independently.
module Seal.Agent.ContextTruncation
  ( estimateTokenCount
  , truncateMessages
  , aggressiveTruncate
  , TruncationConfig (..)
  , defaultTruncationConfig
  , aggressiveKeepCount
  , truncationNotice
  ) where

import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Providers.Class

-- | Configuration for the truncation strategy.
data TruncationConfig = TruncationConfig
  { tcKeepRecent :: Int
    -- ^ The number of most-recent messages to always preserve (the "active
    -- context window"). Default: 20.
  , tcMinKeep :: Int
    -- ^ The minimum number of messages to keep, even if they exceed the
    -- budget. Prevents pathological cases where even the last few messages
    -- are too large. Default: 2.
  }

-- | Default truncation config: keep 20 recent messages, minimum 2.
defaultTruncationConfig :: TruncationConfig
defaultTruncationConfig = TruncationConfig
  { tcKeepRecent = 20
  , tcMinKeep = 2
  }

-- | The number of messages to keep in aggressive truncation mode (used
-- for prompt-too-long error recovery).
aggressiveKeepCount :: Int
aggressiveKeepCount = 5

-- | The synthetic message inserted when older context is truncated, so the
-- model knows history is missing. Uses 'User' role because the provider-
-- agnostic 'Message' type has no @System@ role (system prompt is a separate
-- 'crSystem' field).
truncationNotice :: Text
truncationNotice =
  "[System: Older conversation context was truncated to fit the model's \
  \context window. Some earlier messages are no longer available.]"

-- | Estimate the token count for a completion request's components: system
-- prompt + tool definitions + messages. Uses the chars/4 approximation
-- (the standard rough estimate; a proper tokenizer is out of scope for MVP).
estimateTokenCount :: Maybe Text -> [Message] -> [ToolDefinition] -> Int
estimateTokenCount mSystem msgs tools =
  systemTokens + toolTokens + messageTokens
  where
    systemTokens = maybe 0 textTokens mSystem
    toolTokens = sum (map toolTokens' tools)
    messageTokens = sum (map messageTokens' msgs)
    -- chars / 4, minimum 1 for non-empty text
    textTokens t = if T.null t then 0 else max 1 (T.length t `div` 4)
    -- Estimate tool tokens from JSON encoding (tool definitions are already
    -- ToJSON; their wire size is what the provider sees).
    toolTokens' td =
      let bs = A.encode td
          charLen = BL.length bs
      in if charLen == 0 then 0 else max 1 (fromIntegral charLen `div` 4)
    -- Sum the text/thinking/tool content of a message.
    messageTokens' (Message _ blocks) =
      sum (map blockTokens' blocks)
    blockTokens' (CbText t) = textTokens t
    blockTokens' (CbThinking t) = textTokens t
    blockTokens' (CbToolUse _ _ v) =
      let bs = A.encode v
          charLen = BL.length bs
      in if charLen == 0 then 0 else max 1 (fromIntegral charLen `div` 4)
    blockTokens' (CbToolResult _ parts _) =
      sum (map partTokens' parts)
    partTokens' (TrpText t) = textTokens t

-- | Truncate the message list to fit within the given token budget (for
-- the message portion only — system and tools are accounted for separately
-- by the caller). When messages fit, they are returned unchanged. When they
-- don't, the oldest messages are dropped from the middle, a synthetic
-- truncation notice is inserted, and the most recent messages are preserved.
-- The last tool-use + tool-result pair is never split (if the tool-result
-- is kept, the preceding tool-use is also kept).
truncateMessages :: TruncationConfig -> Int -> [Message] -> [Message]
truncateMessages cfg budget msgs
  | currentTokens <= budget = msgs
  | otherwise = truncated
  where
    currentTokens = estimateTokenCount Nothing msgs []
    -- Take the last tcKeepRecent messages, but ensure we don't split a
    -- tool-use/tool-result pair. If the first kept message is a tool-result
    -- (User with CbToolResult), include the preceding message too.
    keepN = tcKeepRecent cfg
    rawKept = takeEnd keepN msgs
    kept = alignToolPair (dropEnd keepN msgs) rawKept
    -- Check if the kept messages fit; if not, progressively drop from front
    keptTokens = estimateTokenCount Nothing kept []
    finalKept = if keptTokens <= budget
                  then kept
                  else shrinkToFit budget (tcMinKeep cfg) kept
    -- Insert the truncation notice before the kept messages
    truncated = truncationNoticeMsg : finalKept

-- | Aggressively truncate: keep only the last 'aggressiveKeepCount' messages.
-- Used for prompt-too-long error recovery, where we need to shrink the
-- context as much as possible in one shot. No truncation notice is inserted
-- (the caller handles messaging).
aggressiveTruncate :: [Message] -> [Message]
aggressiveTruncate msgs
  | length msgs <= aggressiveKeepCount = msgs
  | otherwise = alignToolPair dropped (takeEnd aggressiveKeepCount msgs)
  where
    dropped = dropEnd aggressiveKeepCount msgs

-- | If the first message in @kept@ is a tool-result (User role with
-- CbToolResult blocks), include the preceding message from @dropped@ (the
-- Assistant message with the matching tool-use). This prevents splitting a
-- tool-use/tool-result pair across the truncation boundary.
alignToolPair :: [Message] -> [Message] -> [Message]
alignToolPair dropped kept =
  case kept of
    (m : _) | isToolResult m ->
      case takeEnd 1 dropped of
        (prev : _) | isToolUse prev -> prev : kept
        _ -> kept
    _ -> kept

-- | Shrink the message list from the front until it fits within the budget,
-- but never below minKeep messages.
shrinkToFit :: Int -> Int -> [Message] -> [Message]
shrinkToFit budget minKeep = go
  where
    go ms
      | length ms <= minKeep = ms
      | estimateTokenCount Nothing ms [] <= budget = ms
      | otherwise = go (dropOne ms)

-- | Drop one message from the front. If the dropped message was a tool-use
-- whose matching tool-result is the next message, drop both to avoid
-- leaving an orphaned tool-result.
dropOne :: [Message] -> [Message]
dropOne [] = []
dropOne (m : rest)
  | isToolUse m = case rest of
      (m2 : _) | isToolResult m2 -> drop 1 rest
      _ -> rest
  | otherwise = rest

-- | The truncation notice as a 'Message' (User role).
truncationNoticeMsg :: Message
truncationNoticeMsg = textMsg User truncationNotice

-- | Check if a message is a tool-result (User role with CbToolResult blocks).
isToolResult :: Message -> Bool
isToolResult (Message User blocks) = any isResultBlock blocks
  where isResultBlock CbToolResult{} = True
        isResultBlock _ = False
isToolResult _ = False

-- | Check if a message is a tool-use (Assistant role with CbToolUse blocks).
isToolUse :: Message -> Bool
isToolUse (Message Assistant blocks) = any isUseBlock blocks
  where isUseBlock CbToolUse{} = True
        isUseBlock _ = False
isToolUse _ = False

-- | Take the last @n@ elements of a list.
takeEnd :: Int -> [a] -> [a]
takeEnd n xs = drop (max 0 (length xs - n)) xs

-- | Drop the last @n@ elements of a list.
dropEnd :: Int -> [a] -> [a]
dropEnd n xs = take (max 0 (length xs - n)) xs
