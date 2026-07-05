{-# LANGUAGE OverloadedStrings #-}
-- | The unified cross-session Audited log entry model. Every mutation to the
-- four evolutionary stores (memory, skills, agent definitions, config) lands
-- here as one 'AuditedEntry'. The log is append-only, cross-session, and
-- canonical for those four stores — stores materialize by replaying it.
--
-- Integrity rests on the append-only single-writer + fsync + keeping untrusted
-- operations off the box that holds the log — NOT on a hash chain. A hash chain
-- without proof-of-work mining adds no real integrity guarantee here; it is
-- omitted deliberately, mirroring 'Seal.Transcript.Types'.
module Seal.Audited.Types
  ( AuditedKind (..)
  , AuditedEntry (..)
  , encodeAuditedEntryRaw
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.=) )
import Data.Aeson qualified as A
import Data.Aeson.Types (withText)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Seal.Core.Types (OpName, SessionId)

-- | Which evolutionary store this entry mutates. The discriminator lets the
-- replay/materializer route each entry to the right store.
data AuditedKind
  = AKMemory
  | AKSkill
  | AKAgentDef
  | AKConfig
  deriving stock (Eq, Show, Generic)

instance ToJSON AuditedKind where
  toJSON AKMemory   = "memory"
  toJSON AKSkill    = "skill"
  toJSON AKAgentDef = "agent_def"
  toJSON AKConfig   = "config"

instance FromJSON AuditedKind where
  parseJSON = withText "AuditedKind" $ \t ->
    case t of
      "memory"    -> pure AKMemory
      "skill"     -> pure AKSkill
      "agent_def" -> pure AKAgentDef
      "config"    -> pure AKConfig
      _           -> fail ("unknown AuditedKind: " <> T.unpack t)

-- | One entry in the Audited log. The payload ('aePayload') is the
-- store-specific mutation record (JSON), secret-free by construction (the
-- dispatcher only writes secret-free payloads; secret values flow only through
-- opcode 'orParts', never to the Audited log). 'aeSession' is the originating
-- session's id (provenance — which session caused this cross-session mutation).
data AuditedEntry = AuditedEntry
  { aeId        :: Text
  -- ^ A unique entry id (UUID, minted by the writer).
  , aeTimestamp :: UTCTime
  -- ^ When the mutation was recorded.
  , aeSession   :: SessionId
  -- ^ The session that caused this mutation (provenance).
  , aeOpcode    :: OpName
  -- ^ The opcode that performed the mutation (e.g. @MEMORY_STORE@).
  , aeKind      :: AuditedKind
  -- ^ Which store this entry mutates.
  , aePayload   :: A.Value
  -- ^ The secret-free mutation record, store-specific shape.
  } deriving stock (Eq, Show)

instance ToJSON AuditedEntry where
  toJSON e = object
    [ "id"        .= aeId e
    , "ts"        .= aeTimestamp e
    , "session"   .= aeSession e
    , "opcode"    .= aeOpcode e
    , "kind"      .= aeKind e
    , "payload"   .= aePayload e
    ]

instance FromJSON AuditedEntry where
  parseJSON = withObject "AuditedEntry" $ \o -> AuditedEntry
    <$> o .:  "id"
    <*> o .:  "ts"
    <*> o .:  "session"
    <*> o .:  "opcode"
    <*> o .:  "kind"
    <*> o .:  "payload"

-- | Canonical strict encoding of one entry, no trailing newline. The writer
-- appends the newline. Stable for any on-disk comparison.
encodeAuditedEntryRaw :: AuditedEntry -> ByteString
encodeAuditedEntryRaw = BL.toStrict . A.encode