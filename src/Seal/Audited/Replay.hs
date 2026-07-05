-- | Pure replay: fold the Audited log into a store-agnostic event stream that
-- the store materializers (Memory / Skills / AgentDef) consume to populate
-- their backends. Replay trusts the log bytes — integrity is protected by the
-- single-writer + off-box-execution model, not a cryptographic chain, so there
-- is no chain-verification step before replay.
module Seal.Audited.Replay
  ( AuditedEvent (..)
  , replay
  ) where

import Data.Aeson (Value)
import Data.Time (UTCTime)

import Seal.Audited.Types
  ( AuditedEntry (..), AuditedKind (..) )
import Seal.Core.Types (OpName, SessionId)

-- | A store-agnostic mutation: the opcode, the store kind, the secret-free
-- payload, the originating session, and the timestamp. The materializer folds
-- these into its backend.
data AuditedEvent = AuditedEvent
  { aeEvOpcode  :: OpName
  , aeEvKind    :: AuditedKind
  , aeEvPayload :: Value
  , aeEvSession :: SessionId
  , aeEvTs      :: UTCTime
  } deriving stock (Eq, Show)

-- | Fold the Audited log into an event stream, in log order. Each entry
-- becomes one event; the materializer dispatches on 'aeEvKind' to route the
-- payload to the right store.
replay :: [AuditedEntry] -> [AuditedEvent]
replay = map toEvent
  where
    toEvent e = AuditedEvent
      { aeEvOpcode  = aeOpcode e
      , aeEvKind    = aeKind e
      , aeEvPayload = aePayload e
      , aeEvSession = aeSession e
      , aeEvTs      = aeTimestamp e
      }