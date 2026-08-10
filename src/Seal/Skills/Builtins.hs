{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- | Built-in skills shipped with the Seal Harness binary. The markdown
-- sources live under @config/skills/\<group\>/@ in the repo and are embedded
-- into the binary at compile time via 'file-embed' so the harness is
-- self-contained: no first-run materialization, no install-layout
-- dependency, no staleness across upgrades (the embedded copy is always the
-- version the binary shipped with).
--
-- A user can override any built-in by dropping a same-id markdown file at
-- @~/.seal/config/skills/<group>/<id>.md@ (or the flat
-- @~/.seal/config/skills/<id>.md@); the union backend
-- ('Seal.Skills.Backend.unionSkillBackend') checks the user layer first
-- and falls back to the embedded built-in. To bring in upstream changes
-- after an upgrade, the user diffs their override against the new
-- built-in (visible via @SKILL_LIST@ or @\/skill list@ — both surface
-- built-ins) and does the desired merge manually.
module Seal.Skills.Builtins
  ( builtinSkills
  , builtinSkillMap
  , lookupBuiltinSkill
  , builtinSkillIds
  ) where

import Data.FileEmbed (embedFile)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Language.Haskell.TH.Syntax (qAddDependentFile)

import Seal.Skills.Codec (decodeSkill)
import Seal.Skills.Types (Skill (..), SkillId)

-- | The compiled-in provenance stamp for built-in skills. A fixed epoch
-- instant so the embedded data is deterministic (no per-build timestamp
-- churn in the binary). A user override's @updated_at@ will always be
-- later, which is the right signal for "this is a user-modified copy."
builtinStamp :: UTCTime
builtinStamp = UTCTime (fromGregorian 2026 7 24) (secondsToDiffTime 0)

-- | The raw markdown bytes of each built-in skill source, embedded at
-- compile time. Add a tuple here to ship another built-in skill. The first
-- element is the skill id (must match the @id:@ frontmatter inside the
-- file); the second is the embedded file content (via 'embedFile'); the
-- third is the group the built-in belongs to (stamped into 'skGroup' so
-- the @\<available_skills\>@ catalog groups built-ins consistently with
-- their on-disk location).
--
-- Each 'embedFile' splice is paired with a 'qAddDependentFile' call so
-- GHC recompiles this module when an embedded source changes (plain
-- 'embedFile' alone does not register the file as a build dependency, so
-- editing the markdown would not trigger a rebuild — a subtle footgun
-- we close here). The splice must use a literal path (GHC stage
-- restriction: a top-level splice cannot reference a locally-bound
-- variable), so each entry inlines its own splice rather than sharing a
-- single one parameterized by @path@.
builtinRaw :: [(Text, Text, Text)]
builtinRaw =
  [ ( "seal-usage"
    , TE.decodeUtf8 $(do
          qAddDependentFile "config/skills/core/seal-usage.md"
          embedFile "config/skills/core/seal-usage.md")
    , "core"
    )
  ]

-- | The decoded built-in skills, with provenance stamped to 'builtinStamp'
-- (the decoded @session@ defaults to @"unknown"@ per 'decodeSkill'; we
-- leave it — built-ins are not user-authored, so the originating-session
-- field is conventional, not meaningful) and 'skGroup' stamped to the
-- group declared in 'builtinRaw' (so built-ins are always grouped
-- consistently, regardless of any @group:@ frontmatter in the file).
-- Malformed sources are skipped (a malformed built-in is an authoring
-- error caught at the first test run, not a runtime condition the binary
-- should paper over).
builtinSkills :: [Skill]
builtinSkills = mapMaybe decodeAndStamp builtinRaw
  where
    decodeAndStamp (_expectedId, raw, group) =
      case decodeSkill raw of
        Nothing    -> Nothing
        Just skill -> Just skill
          { skCreatedAt = builtinStamp
          , skUpdatedAt = builtinStamp
          , skGroup     = Just group
          }

-- | 'builtinSkills' keyed by id for O(log n) lookups.
builtinSkillMap :: Map SkillId Skill
builtinSkillMap = Map.fromList [(skId s, s) | s <- builtinSkills]

-- | The ids of all built-in skills (for listing / override detection).
builtinSkillIds :: [SkillId]
builtinSkillIds = map skId builtinSkills

-- | Look up a built-in skill by id. 'Nothing' if no built-in has that id.
lookupBuiltinSkill :: SkillId -> Maybe Skill
lookupBuiltinSkill sid = Map.lookup sid builtinSkillMap