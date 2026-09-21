{-# LANGUAGE OverloadedStrings #-}
-- | The WebSocket stream protocol types — the wire shapes for the WS event
-- union and the client-to-server focus op. These are the types both the
-- server (WS server in 'Seal.Gateway.Stream') and channel clients (WS
-- client in 'Seal.Channels.WsClient') import.
--
-- 'BrokerEvent' is the in-process event the broker fans out. The WS server
-- encodes it to wire JSON; the WS client decodes from wire JSON. Only the
-- 'BrokerEvent' data type and 'FocusOp' live here — the 'Subscriber' and
-- 'StreamBroker' runtime types stay in the server (they carry STM state).
--
-- Canonical home; 'Seal.Gateway.Stream' and 'Seal.Gateway.StreamBroker' in
-- the server re-export 'FocusOp' and 'BrokerEvent' from here.
module Seal.Gateway.Types.Stream
  ( BrokerEvent (..)
  , FocusOp (..)
  , ServerEvent (..)
  , StreamErrorCode (..)
  ) where

import Data.Aeson (Value, (.:), (.:?))
import Data.Aeson qualified as A
import Data.Text (Text)
import Control.Applicative ((<|>))

import Seal.Gateway.Types.Core (SessionId)

-- | One event the broker fans out to subscribers. The 'Value' payloads are
-- the pre-encoded JSON the WS peer receives — the server's 'sendEvent'
-- wraps them in the wire envelope.
data BrokerEvent
  = BeEntryRecorded SessionId Value   -- ^ a transcript entry (the JSON the WS peer receives)
  | BeEntryUpdate SessionId Value      -- ^ a streaming entry whose text is still growing (the WS peer renders as an @entry-update@ event, replacing the in-place entry by id)
  | BeHarnessStatus Value             -- ^ a harness liveness change
  | BeListsSnapshot Value             -- ^ a refreshed tab/session snapshot
  | BeAsk SessionId Value             -- ^ a pending human-question from ASK_HUMAN (the JSON the WS peer renders)
  | BeAskResolved SessionId Value      -- ^ a pending question was answered/cancelled (the JSON carries the ask id)
  | BeActivity SessionId Value          -- ^ a per-session activity signal (harness-status / reply-delivered) the WS peer renders as an @activity@ envelope
  | BeAgentDefsChanged                 -- ^ agent defs were created/updated/deleted; clients should re-fetch
  | BeSkillsChanged                    -- ^ skills were created/updated/deleted; clients should re-fetch
  | BeReposChanged                     -- ^ the source-control repo registry was mutated; clients should re-fetch /api/repos
  deriving stock (Eq, Show)

-- | The focus op the client sends to change its focused session. Accepts
-- both the frontend's shape (@{"op":"focus","sessionId":"..."}@) and the
-- legacy shape (@{"session":"..."}@) for robustness. The optional @since@
-- field requests replay of entries after the given entry id.
data FocusOp = FocusOp
  { foSession :: Text
  , foSince   :: Maybe Text
  }
  deriving stock (Eq, Show)

instance A.FromJSON FocusOp where
  parseJSON = A.withObject "focus" $ \o ->
    FocusOp
      <$> (o .: "sessionId" <|> o .: "session")
      <*> (o .:? "since")

-- | The WS wire event union — the discriminated union the WS peer
-- receives. Tagged by the @type@ field. This is the Haskell mirror of the
-- frontend's @ServerEvent@ TypeScript type
-- (@frontend/src/types/stream.ts@). The server encodes 'BrokerEvent's into
-- these wire shapes; the channel WS client decodes them.
--
-- Currently only the 'FocusOp' and 'BrokerEvent' types are wired. The full
-- 'ServerEvent' union will be fleshed out as the chat-channel WS client
-- is implemented (Step 2). For now, this is the type declaration that
-- establishes the contract.
data ServerEvent
  = SeHello Text Text          -- ^ @hello@: protocolVersion + serverStartedAt
  | SeEntry SessionId Value    -- ^ @entry@: a complete transcript entry
  | SeEntryUpdate SessionId Value  -- ^ @entry-update@: a streaming entry update
  | SeActivity SessionId Value     -- ^ @activity@: a per-session activity signal
  | SeReplayEnd SessionId (Maybe Text)  -- ^ @replay-end@: replay finished, last replayed entry id
  | SeLists Value              -- ^ @lists@: a tab/session snapshot
  | SeAsk SessionId Value      -- ^ @ask@: a pending human question
  | SeAskResolved SessionId Value  -- ^ @ask_resolved@: a question was answered/cancelled
  | SeAgentDefsChanged         -- ^ @agent-defs-changed@
  | SeSkillsChanged            -- ^ @skills-changed@
  | SeReposChanged             -- ^ @repos-changed@
  | SeError StreamErrorCode Text  -- ^ @error@: an error code + message
  deriving stock (Eq, Show)

-- | The error codes the WS server can send in an @error@ event. Mirrors
-- the frontend's @StreamErrorCode@ type.
data StreamErrorCode
  = SecInvalidOp
  | SecInvalidFrame
  | SecSessionNotFound
  | SecFrameTooLarge
  | SecReplayFailed
  | SecReplayAborted
  | SecInternal
  deriving stock (Eq, Show)

instance A.ToJSON StreamErrorCode where
  toJSON = \case
    SecInvalidOp      -> A.String "invalid-op"
    SecInvalidFrame   -> A.String "invalid-frame"
    SecSessionNotFound -> A.String "session-not-found"
    SecFrameTooLarge  -> A.String "frame-too-large"
    SecReplayFailed   -> A.String "replay-failed"
    SecReplayAborted  -> A.String "replay-aborted"
    SecInternal       -> A.String "internal"

instance A.FromJSON StreamErrorCode where
  parseJSON = A.withText "StreamErrorCode" $ \case
    "invalid-op"        -> pure SecInvalidOp
    "invalid-frame"     -> pure SecInvalidFrame
    "session-not-found" -> pure SecSessionNotFound
    "frame-too-large"   -> pure SecFrameTooLarge
    "replay-failed"     -> pure SecReplayFailed
    "replay-aborted"    -> pure SecReplayAborted
    "internal"          -> pure SecInternal
    other               -> fail ("unknown stream error code: " <> show other)
