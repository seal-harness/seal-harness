{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | A UUID-backed durable harness identity (the registry key). Minted at
-- spawn time; stamped as a tmux @seal_id marker on the harness window so a
-- window can be re-identified after a rename or reconnect. The UUID is
-- generated in-repo from 'System.Random' (the repo has @uuid-types@ but
-- not the full @uuid@ package, so v4 generation is hand-rolled from two
-- random 'Word64's with the v4 version/variant bits set).
--
-- Canonical home for the gateway API contract; 'Seal.Harness.Id' in the
-- server re-exports from here. The 'newHarnessId' IO action stays in the
-- server (it requires 'System.Random'); only the type + pure functions
-- live here.
module Seal.Gateway.Types.HarnessId
  ( HarnessId (..)
  , parseHarnessId
  , harnessIdToText
  , isValidHarnessIdText
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID.Types qualified as U
import GHC.Generics (Generic)

-- | A UUID-backed durable harness identity.
newtype HarnessId = HarnessId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | The text form (a UUID string) — the value stamped as the @seal_id marker.
harnessIdToText :: HarnessId -> Text
harnessIdToText (HarnessId t) = t

-- | Parse a HarnessId from its text form. 'Left' on malformed input.
parseHarnessId :: Text -> Either Text HarnessId
parseHarnessId t
  | isValidHarnessIdText t = Right (HarnessId t)
  | otherwise              = Left ("invalid HarnessId: " <> t)

-- | True if the text is a valid UUID (8-4-4-4-12 hex, case-insensitive).
-- Used to defend the @seal_id marker stamp against a malformed id.
isValidHarnessIdText :: Text -> Bool
isValidHarnessIdText t =
  case U.fromString (T.unpack t) of
    Just _  -> True
    Nothing -> False