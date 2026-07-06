{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The validated 'TabIndex' (0..35) — the single index type reused
-- everywhere (TabList slots, /N routing, /tab close <N>, /tab focus <N>).
-- Smart-constructed so an out-of-range index fails to compile into any path.
-- Plus 'TabKind', the closed enumeration of tab kinds.
module Seal.Handles.Tab
  ( TabIndex (..)
  , mkTabIndex
  , tabIndexToInt
  , tabIndexToChar
  , tabIndexFromChar
  , maxTabIndex
  , TabKind (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Char (isAsciiLower, isDigit, toLower)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | The maximum tab index (0-based): 35 = 'z'. 36 slots total.
maxTabIndex :: Int
maxTabIndex = 35

-- | A validated tab index: 0..35 (the terse grammar maps 0-9a-z to 0..35).
-- Smart-constructed; the predicate rejects <0 and >35.
newtype TabIndex = TabIndex Int
  deriving stock (Eq, Ord, Show)

mkTabIndex :: Int -> Either Text TabIndex
mkTabIndex n
  | n < 0           = Left ("tab index out of range: " <> T.pack (show n))
  | n > maxTabIndex = Left ("tab index out of range: " <> T.pack (show n))
  | otherwise       = Right (TabIndex n)

tabIndexToInt :: TabIndex -> Int
tabIndexToInt (TabIndex n) = n

-- | 0->'0', 9->'9', 10->'a', 35->'z'.
tabIndexToChar :: TabIndex -> Char
tabIndexToChar (TabIndex n)
  | n < 10   = toEnum (fromEnum '0' + n)
  | otherwise = toEnum (fromEnum 'a' + (n - 10))

-- | Inverse of 'tabIndexToChar', case-insensitive. 'Left' for non-[0-9a-z].
tabIndexFromChar :: Char -> Either Text TabIndex
tabIndexFromChar c =
  let lo = toLower c
  in case lo of
       _ | isDigit lo      -> mkTabIndex (fromEnum lo - fromEnum '0')
         | isAsciiLower lo -> mkTabIndex (fromEnum lo - fromEnum 'a' + 10)
         | otherwise       -> Left ("not a tab index char: " <> T.pack [c])

-- | The closed enumeration of tab kinds.
data TabKind
  = KindAi | KindProvider | KindHarness | KindShell | KindSsh | KindTmux
  deriving stock (Eq, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)