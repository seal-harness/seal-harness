{-# LANGUAGE OverloadedStrings #-}
-- | The skill entry model. A *skill* is a named Markdown bundle (name +
-- description + body) the agent can read into a prompt or update. 'SkillId' is
-- a smart-constructed newtype with the same charset predicate as
-- 'Seal.Core.Types.SessionId' (@[A-Za-z0-9_-]+@, non-empty, no leading dot). The
-- skill body is agent-visible data (not a vault secret); it is recorded in full
-- in both the session transcript and the Audited log.
module Seal.Skills.Types
  ( SkillId (..)
  , mkSkillId
  , isValidSkillId
  , skillIdText
  , Skill (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Seal.Core.Types (SessionId)

-- | Opaque skill key. Smart-constructed via 'mkSkillId'; the charset predicate
-- guards every Audited-log / path / SQL-parameter position.
newtype SkillId = SkillId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | @[A-Za-z0-9_-]+@, non-empty, no leading dot. Mirrors 'isValidMemoryId'.
isValidSkillId :: Text -> Bool
isValidSkillId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all (`elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

mkSkillId :: Text -> Either Text SkillId
mkSkillId t
  | isValidSkillId t = Right (SkillId t)
  | otherwise        = Left ("invalid skill id: " <> T.pack (show t))

skillIdText :: SkillId -> Text
skillIdText (SkillId t) = t

-- | One agent skill. The body is agent-visible data (not a vault secret); it is
-- recorded in full in both the session transcript and the Audited log.
-- 'skSession' is the originating session (provenance).
data Skill = Skill
  { skId          :: SkillId
  , skDescription :: Text
  , skBody        :: Text
  , skCreatedAt   :: UTCTime
  , skUpdatedAt   :: UTCTime
  , skSession     :: SessionId
  } deriving stock (Eq, Show, Generic)

instance ToJSON Skill
instance FromJSON Skill