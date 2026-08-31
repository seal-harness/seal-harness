{-# LANGUAGE OverloadedStrings #-}
-- | The skill entry model. A *skill* is a named Markdown bundle (name +
-- description + body) the agent can read into a prompt or update. 'SkillId' is
-- a smart-constructed newtype with the charset predicate
-- (@[A-Za-z0-9_\/-]+@, non-empty, no leading dot, no double\/trailing slash). The
-- skill body is agent-visible data (not a vault secret); it is recorded in full
-- in both the session transcript and the Audited log.
module Seal.Skills.Types
  ( SkillId (..)
  , mkSkillId
  , isValidSkillId
  , skillIdText
  , skillIdSeparator
  , qualifiedSkillId
  , skillIdGroup
  , bareSkillIdText
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

-- | @[A-Za-z0-9_\/-]+@, non-empty, no leading dot, no double slash, no
-- trailing slash. The forward slash is allowed so a skill id can carry its
-- group as a prefix (e.g. @core\/dummy-test@), making the fully-qualified
-- id unique across groups. A bare id (no slash) is also valid for ungrouped
-- skills or when the group is unambiguous. Mirrors 'isValidMemoryId' but
-- adds @\/@.
isValidSkillId :: Text -> Bool
isValidSkillId t =
  not (T.null t)
    && T.head t /= '.'
    && not (T.isInfixOf "//" t)
    && T.last t /= '/'
    && T.all (`elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-/"

-- | The forward slash separator used to join a group and a bare id into a
-- fully-qualified skill id.
skillIdSeparator :: Char
skillIdSeparator = '/'

mkSkillId :: Text -> Either Text SkillId
mkSkillId t
  | isValidSkillId t = Right (SkillId t)
  | otherwise        = Left ("invalid skill id: " <> T.pack (show t))

-- | Construct a fully-qualified 'SkillId' from a group and a bare id.
-- Returns the bare id as-is when the group is 'Nothing' or empty.
qualifiedSkillId :: Maybe Text -> SkillId -> SkillId
qualifiedSkillId Nothing sid = sid
qualifiedSkillId (Just g) sid
  | T.null (T.strip g) = sid
  | otherwise = case mkSkillId (g <> T.singleton skillIdSeparator <> skillIdText sid) of
      Right fq -> fq
      Left _   -> sid  -- fail-soft: return bare id if the qualified form is invalid

-- | Extract the group component from a 'SkillId' (the text before the
-- first @\/@). Returns 'Nothing' for a bare id with no slash.
skillIdGroup :: SkillId -> Maybe Text
skillIdGroup (SkillId t) =
  case T.breakOn (T.singleton skillIdSeparator) t of
    (g, rest) | not (T.null rest) -> Just g
    _ -> Nothing

-- | The bare (unqualified) id component — the text after the last @\/@.
-- For a bare id (no slash), returns the id unchanged.
bareSkillIdText :: SkillId -> Text
bareSkillIdText (SkillId t) = snd (T.breakOnEnd (T.singleton skillIdSeparator) t)

skillIdText :: SkillId -> Text
skillIdText (SkillId t) = t

-- | One agent skill. The body is agent-visible data (not a vault secret); it is
-- recorded in full in both the session transcript and the Audited log.
-- 'skSession' is the originating session (provenance).
--
-- 'skGroup' is an optional category for display grouping in the
-- @\<available_skills\>@ catalog. It is derived from the on-disk parent
-- directory name (@config\/skills\/\<group\>\/\<id\>.md@) and may be
-- overridden via a @group:@ frontmatter key. 'Nothing' means the skill
-- belongs to the default (ungrouped) section. The skill id may be either
-- bare (e.g. @greet@) or fully-qualified with a group prefix
-- (e.g. @core\/greet@) so two skills with the same bare name in different
-- groups are distinct. The 'skGroup' field mirrors the group component of
-- the id for display grouping when present.
data Skill = Skill
  { skId          :: SkillId
  , skDescription :: Text
  , skBody        :: Text
  , skGroup       :: Maybe Text
  , skCreatedAt   :: UTCTime
  , skUpdatedAt   :: UTCTime
  , skSession     :: SessionId
  } deriving stock (Eq, Show, Generic)

instance ToJSON Skill
instance FromJSON Skill
