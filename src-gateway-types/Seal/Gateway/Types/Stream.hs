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
  , decodeServerEvent
  , StreamErrorCode (..)
  ) where

import Data.Aeson (Value, (.:), (.:?))
import Data.Aeson qualified as A
import Data.Maybe (fromMaybe)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Control.Applicative ((<|>))

import Seal.Gateway.Types.Core (SessionId, mkSessionId)

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

instance A.ToJSON FocusOp where
  toJSON (FocusOp sess mSince) = A.object
    ( [ "op" A..= ("focus" :: Text)
      , "sessionId" A..= sess
      ]
      <> maybe [] (\s -> ["since" A..= s]) mSince
    )

-- | Decode a WS wire frame (raw JSON bytes) into a 'ServerEvent'. Returns
-- 'Nothing' for unparseable frames. Used by the chat-channel WS client's
-- background reader. Pure.
decodeServerEvent :: BL.ByteString -> Maybe ServerEvent
decodeServerEvent bs = A.decode bs >>= parseServerEvent

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

-- | Parse a raw JSON 'Value' into a 'ServerEvent' by dispatching on the
-- @type@ field. Returns 'Nothing' for unknown types or missing fields.
-- Pure. Used by 'decodeServerEvent'.
parseServerEvent :: Value -> Maybe ServerEvent
parseServerEvent (A.Object o) =
  case KeyMap.lookup (Key.fromText "type") o of
    Just (A.String t) -> case t of
      "hello" -> SeHello
        <$> (asText =<< KeyMap.lookup (Key.fromText "protocolVersion") o)
        <*> (asText =<< KeyMap.lookup (Key.fromText "serverStartedAt") o)
      "entry" -> SeEntry
        <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
        <*> pure (fromMaybe A.Null (KeyMap.lookup (Key.fromText "entry") o))
      "entry-update" -> SeEntryUpdate
        <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
        <*> pure (fromMaybe A.Null (KeyMap.lookup (Key.fromText "entry") o))
      "activity" -> SeActivity
        <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
        <*> pure (fromMaybe A.Null (KeyMap.lookup (Key.fromText "activity") o))
      "replay-end" -> SeReplayEnd
        <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
        <*> pure (asText =<< KeyMap.lookup (Key.fromText "lastEntryId") o)
      "lists" -> Just (SeLists (A.Object o))
      "ask" -> SeAsk
        <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
        <*> pure (fromMaybe A.Null (KeyMap.lookup (Key.fromText "ask") o))
      "ask_resolved" -> SeAskResolved
        <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
        <*> pure (fromMaybe A.Null (KeyMap.lookup (Key.fromText "ask") o))
      "agent-defs-changed" -> Just SeAgentDefsChanged
      "skills-changed" -> Just SeSkillsChanged
      "repos-changed" -> Just SeReposChanged
      "error" -> SeError
        <$> (asErrCode =<< KeyMap.lookup (Key.fromText "code") o)
        <*> pure (fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "message") o))
      _ -> Nothing
    _ -> Nothing
parseServerEvent _ = Nothing

asText :: Value -> Maybe Text
asText (A.String t) = Just t
asText _ = Nothing

asSessionId :: Value -> Maybe SessionId
asSessionId (A.String t) =
  case mkSessionId t of Right s -> Just s; Left _ -> Nothing
asSessionId _ = Nothing

asErrCode :: Value -> Maybe StreamErrorCode
asErrCode v = case A.fromJSON v of
  A.Success c -> Just c
  A.Error _   -> Nothing
