{-# LANGUAGE OverloadedStrings #-}
-- | The memory entry model. 'MemoryId' is a smart-constructed newtype with the
-- same charset predicate as 'Seal.Core.Types.SessionId' (@[A-Za-z0-9_-]+@,
-- non-empty, no leading dot). 'MemoryEntry' is the agent's own persistent
-- memory — content the agent chooses to remember across sessions. It is NOT a
-- vault secret (those live in 'Seal.Security.Secrets'); memory content is
-- agent-visible data, recorded in full as a Markdown file under
-- @config\/memory\/@ (disk is canonical; git is the versioning layer).
module Seal.Memory.Types
  ( MemoryId (..)
  , mkMemoryId
  , isValidMemoryId
  , memoryIdText
  , MemoryEntry (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Seal.Core.Types (SessionId)

-- | Opaque memory key. Smart-constructed via 'mkMemoryId'; the charset
-- predicate guards every path / filename position.
newtype MemoryId = MemoryId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | @[A-Za-z0-9_-]+@, non-empty, no leading dot. Mirrors 'isValidSessionId'.
isValidMemoryId :: Text -> Bool
isValidMemoryId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all (`elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

mkMemoryId :: Text -> Either Text MemoryId
mkMemoryId t
  | isValidMemoryId t = Right (MemoryId t)
  | otherwise         = Left ("invalid memory id: " <> T.pack (show t))

memoryIdText :: MemoryId -> Text
memoryIdText (MemoryId t) = t

-- | One agent memory entry. The content is agent-visible data (not a vault
-- secret); it is recorded in full as a Markdown file. 'meSession' is the
-- originating session (provenance).
data MemoryEntry = MemoryEntry
  { meId        :: MemoryId
  , meContent   :: Text
  , meTags      :: [Text]
  , meCreatedAt :: UTCTime
  , meUpdatedAt :: UTCTime
  , meSession   :: SessionId
  } deriving stock (Eq, Show, Generic)

instance ToJSON MemoryEntry
instance FromJSON MemoryEntry