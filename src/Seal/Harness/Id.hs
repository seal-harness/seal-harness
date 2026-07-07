{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | A UUID-backed durable harness identity (the registry key). Minted at
-- spawn time; stamped as a tmux @seal_id marker on the harness window so a
-- window can be re-identified after a rename or reconnect. The UUID is
-- generated in-repo from 'System.Random' (the repo has @uuid-types@ but
-- not the full @uuid@ package, so v4 generation is hand-rolled from two
-- random 'Word64's with the v4 version/variant bits set).
module Seal.Harness.Id
  ( HarnessId (..)
  , newHarnessId
  , parseHarnessId
  , harnessIdToText
  , isValidHarnessIdText
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Bits ((.&.), (.|.), complement)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID.Types qualified as U
import Data.Word (Word64)
import GHC.Generics (Generic)
import System.Random (randomIO)

-- | A UUID-backed durable harness identity.
newtype HarnessId = HarnessId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Mint a fresh random HarnessId (UUID v4). IO because it reads randomness.
newHarnessId :: IO HarnessId
newHarnessId = do
  w1 <- randomIO
  w2 <- randomIO
  -- Set version (4) in the high nibble of byte 6 (bits 48-51 of w1) and
  -- variant (10) in the high bits of byte 8 (bits 56-57 of w2).
  let v1 = (w1 .&. complement 0x0000F000) .|. (0x4000 :: Word64)   -- version 4
      v2 = (w2 .|. 0x8000000000000000) .&. complement 0x4000000000000000  -- variant 10
  pure (HarnessId (T.pack (U.toString (U.fromWords64 v1 v2))))

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