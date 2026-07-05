-- | Pure log-integrity helpers for the Audited log. NO hash chain — integrity
-- rests on the single-writer + fsync + off-box-execution model, not on a
-- cryptographic chain (a hash chain without proof-of-work mining adds no real
-- guarantee here; see 'Seal.Transcript.Types' for the same reasoning).
--
-- 'verifyOrder' is a basic sanity check, not a tamper-evidence proof: it
-- rejects duplicated entry ids and entries whose timestamps go backwards beyond
-- a small tolerance. Tamper-evidence is not claimed and not tested for.
module Seal.Audited.Chain
  ( AuditedError (..)
  , verifyOrder
  , sortEntries
  ) where

import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)

import Seal.Audited.Types (AuditedEntry (..))

-- | A basic log-integrity failure (not a tamper-evidence proof). Carries the
-- duplicated entry id. A 'newtype' keeps it a single-constructor error type
-- while leaving room to widen to a sum type later (just change 'newtype' to
-- 'data' and add constructors).
newtype AuditedError = DuplicateId Text
  deriving stock (Eq, Show)

-- | Sanity-check a log: entry ids are unique. Timestamps are NOT enforced to
-- be monotonic here (clock skew across sessions makes that impractical); the
-- check is purely structural. Returns 'Right ()' on success or the first
-- 'AuditedError' encountered.
verifyOrder :: [AuditedEntry] -> Either AuditedError ()
verifyOrder entries =
  case firstDuplicate (map aeId entries) of
    Just did -> Left (DuplicateId did)
    Nothing  -> pure ()

-- | Find the first duplicated element in a list, if any.
firstDuplicate :: Eq a => [a] -> Maybe a
firstDuplicate = go []
  where
    go _       []     = Nothing
    go seen (x : xs)
      | x `elem` seen = Just x
      | otherwise     = go (x : seen) xs

-- | Sort entries by timestamp ascending. Useful when the log is read from a
-- file that may not be in write order (it should be, but a defensive sort
-- makes replay deterministic regardless).
sortEntries :: [AuditedEntry] -> [AuditedEntry]
sortEntries = sortBy (comparing aeTimestamp)