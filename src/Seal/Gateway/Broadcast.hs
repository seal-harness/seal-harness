{-# LANGUAGE OverloadedStrings #-}
-- | The broadcast helper for the WS @lists@ frame. Builds the partitioned
-- snapshot, wraps it with the WS @{"type": "lists", ...}@ envelope, and
-- pushes it to every WS subscriber via 'broadcastLists'. Called after
-- every state change that affects the sidebar partition (tab
-- insert/remove/rebind/rename/acknowledge/release, archive/unarchive,
-- session create, auto-tab insert).
--
-- The REST @GET /api/lists@ returns the bare 'ListsSnapshotWire' (no
-- @type@ field); this wrapper adds the WS envelope for the broadcast path
-- (the frontend's @useListsStream@ discriminates on @type: "lists"@).
--
-- NOTE: the design's 50ms debounce/coalesce is deferred to a follow-up —
-- at the expected single-user scale, bursts are rare and the direct
-- broadcast is correct (if occasionally redundant). A debounce helper
-- can be layered in here without changing the call sites.
module Seal.Gateway.Broadcast
  ( broadcastListsSnapshot
  , broadcastHarnessStatus
  , broadcastReplyDelivered
  , broadcastToolCall
  , broadcastAgentDefsChanged
  , broadcastSkillsChanged
  , broadcastReposChanged
  , wrapCapsForAskStatus
  ) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (getCurrentTime)
import Data.ByteString.Lazy qualified as BL

import Control.Exception (onException)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (SessionId, OpName (..))
import Seal.Gateway.ListsSnapshot (buildListsSnapshot)
import Seal.ISA.Registry (secretOpcodes)
import Seal.Gateway.StreamBroker qualified as SB (broadcastAgentDefsChanged, broadcastSkillsChanged, broadcastReposChanged)
import Seal.Gateway.StreamBroker (StreamBroker, BrokerEvent (..), broadcast, broadcastLists, setThinking, thinkingSessions)
import Seal.Gateway.Transcript (showIso)
import Seal.Tabs (TabsHandle)

-- | Build the WS @lists@ envelope (@{"type": "lists", ...}@) from the
-- current state and push it to every WS subscriber via 'broadcastLists'.
-- Includes the broker's current thinking-session set so a freshly-connected
-- web client hydrates its sidebar (mid-turn tabs show Thinking immediately).
broadcastListsSnapshot :: StreamBroker -> TabsHandle -> SealPaths -> IO ()
broadcastListsSnapshot broker tabsH paths = do
  thinkingSids <- thinkingSessions broker
  snap <- buildListsSnapshot tabsH paths thinkingSids
  -- Merge the "type": "lists" tag into the snapshot object so the WS frame
  -- carries the discriminator the frontend's useListsStream dispatches on.
  let snapObj = case A.toJSON snap of
        A.Object o -> o
        other      -> KeyMap.singleton (Key.fromText "snapshot") other
      envelope = A.Object (KeyMap.insert (Key.fromText "type") (A.String "lists") snapObj)
  broadcastLists broker envelope

-- | Push a per-session @harness-status@ activity signal to every WS
-- subscriber focused on the session. The frontend's
-- @useSessionActivityStream@ consumes the @activity@ envelope to drive the
-- tab status indicator (Thinking while the LLM is actively processing,
-- Idle otherwise). 'Nothing' broker (tests) is a no-op. @status@ is
-- @"thinking"@ at turn start and @"idle"@ at turn end (including failures).
-- Also updates the broker's in-memory thinking set so a freshly-connected
-- web client can hydrate its sidebar from the lists snapshot without
-- waiting for the next harness-status event.
broadcastHarnessStatus :: Maybe StreamBroker -> SessionId -> Text -> IO ()
broadcastHarnessStatus mBroker sid status =
  case mBroker of
    Nothing -> pure ()
    Just broker -> do
      setThinking broker sid (status == "thinking")
      broadcast broker (BeActivity sid (object
        [ "kind" .= ("harness-status" :: Text)
        , "status" .= status
        ]))

-- | Push a per-session @reply-delivered@ activity signal to every WS
-- subscriber focused on the session. Marks the last assistant reply as
-- "seen" because it was delivered to ≥1 subscribed chat channel
-- (Signal/Telegram/CLI), so the frontend transitions the tab to Idle Read.
-- 'Nothing' broker (tests) is a no-op. The timestamp defaults to now.
broadcastReplyDelivered :: Maybe StreamBroker -> SessionId -> IO ()
broadcastReplyDelivered mBroker sid =
  case mBroker of
    Nothing -> pure ()
    Just broker -> do
      now <- getCurrentTime
      broadcast broker (BeActivity sid (object
        [ "kind" .= ("reply-delivered" :: Text)
        , "timestamp" .= T.pack (showIso now)
        ]))

-- | Push a per-session @tool-call@ activity signal to every WS subscriber.
-- The WS client receives this as an @activity@ envelope with
-- @kind: "tool-call"@, the tool (opcode) name, and a redacted+truncated
-- rendering of the tool input. Secret opcodes (those in
-- 'Seal.ISA.Registry.secretOpcodes') have their input replaced with
-- @"\<redacted\>"@ so secret values never reach the WS stream. Non-secret
-- inputs are JSON-encoded and truncated to 120 codepoints (matching
-- 'Seal.Channels.StreamProgress.formatToolLine'). 'Nothing' broker (tests)
-- is a no-op.
broadcastToolCall :: Maybe StreamBroker -> SessionId -> OpName -> A.Value -> IO ()
broadcastToolCall mBroker sid opName input =
  case mBroker of
    Nothing -> pure ()
    Just broker ->
      broadcast broker (BeActivity sid (object
        [ "kind" .= ("tool-call" :: Text)
        , "tool" .= opName
        , "input" .= displayInput
        ]))
  where
    displayInput
      | opName `Set.member` secretOpcodes = "<redacted>" :: Text
      | otherwise =
          let encoded = decodeUtf8 (BL.toStrict (A.encode input))
          in if T.length encoded > 120 then T.take 120 encoded <> "..." else encoded

-- | Push an @agent-defs-changed@ signal to every WS subscriber. The
-- frontend re-fetches GET /api/agents on receipt (invalidation, not
-- payload — the full list is too large to inline). 'Nothing' broker
-- (tests) is a no-op.
broadcastAgentDefsChanged :: Maybe StreamBroker -> IO ()
broadcastAgentDefsChanged mBroker =
  for_ mBroker SB.broadcastAgentDefsChanged

-- | Push a @skills-changed@ signal to every WS subscriber. The frontend
-- re-fetches GET /api/skills on receipt. 'Nothing' broker (tests) is a
-- no-op.
broadcastSkillsChanged :: Maybe StreamBroker -> IO ()
broadcastSkillsChanged mBroker =
  for_ mBroker SB.broadcastSkillsChanged

-- | Push a @repos-changed@ signal to every WS subscriber. The frontend
-- re-fetches GET /api/repos on receipt. 'Nothing' broker (tests) is a
-- no-op.
broadcastReposChanged :: Maybe StreamBroker -> IO ()
broadcastReposChanged mBroker =
  for_ mBroker SB.broadcastReposChanged

-- | Wrap a 'ChannelCaps' so that 'ccPrompt' (the blocking ask primitive
-- used by @ASK_HUMAN@ and the Untrusted confirmation gate) broadcasts a
-- harness-status transition: @idle@ /before/ blocking on the human's
-- reply, and @thinking@ /after/ the reply arrives (the turn is resuming).
-- This ensures the web frontend shows the session as idle (not thinking)
-- while it is waiting for human input — the core fix for the recurring
-- \"stuck on thinking during ASK_HUMAN\" bug.
--
-- The wrapper uses 'onException' so the @thinking@ broadcast fires even
-- if the inner 'ccPrompt' throws (e.g. a timeout/cancel from the
-- AskReplyStore). Without this, an exception in the inner prompt would
-- leave the session permanently idle in the broker's in-memory state
-- (the turn's bracket cleanup would still broadcast idle at turn end,
-- but the broker's thinking set would be inconsistent until then).
--
-- 'Nothing' broker (tests, standalone CLI) is a passthrough: the caps
-- are returned unchanged except for the 'ccPrompt' wrapper which is a
-- direct delegate (no broadcast, no overhead).
--
-- All other 'ChannelCaps' fields ('ccSend', 'ccShowHuman',
-- 'ccPromptSecret', 'ccStreaming') are passed through unchanged.
wrapCapsForAskStatus :: Maybe StreamBroker -> SessionId -> ChannelCaps -> ChannelCaps
wrapCapsForAskStatus mBroker sid caps =
  caps { ccPrompt = \prompt -> do
           broadcastHarnessStatus mBroker sid "idle"
           ans <- ccPrompt caps prompt `onException` broadcastHarnessStatus mBroker sid "thinking"
           broadcastHarnessStatus mBroker sid "thinking"
           pure ans
       }
