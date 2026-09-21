-- | The append-only audit-entry model. Integrity comes from the append-only
-- handle plus keeping untrusted actions off the box that holds the log — not
-- from a hash chain. 'encodeEntryRaw' guarantees the on-disk JSONL line is the
-- canonical encoding, so a future "view raw" hides nothing.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.Transcript'
-- (the canonical home in the 'seal-gateway-types' library stanza).
module Seal.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , encodeEntryRaw
  ) where

import Seal.Gateway.Types.Transcript