{-# LANGUAGE OverloadedStrings #-}
-- | System-prompt construction for skills. This module renders the
-- @\<available_skills\>@ catalog — a grouped listing of every skill's id +
-- description — and appends it to the resolved system prompt so the model
-- discovers and uses skills. The catalog is built from 'sbList' (the
-- unioned backend: user ⊕ builtin, and later workdir ⊕ user ⊕ builtin),
-- grouped by 'skGroup', and truncated to a token-safe budget.
--
-- The catalog is /teaching/, not enforcement: it tells the model which
-- skills exist and that it should call @SKILL_LOAD@ to read one. It does
-- not auto-load skill bodies (only the operator-configured @autoload@ id
-- is auto-injected, via 'Seal.Skills.Autoload').
module Seal.Skills.Prompt
  ( availableSkillsBlock
  , injectAvailableSkills
  , availableSkillsBudget
  ) where

import Data.List (groupBy, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), skillIdText, bareSkillIdText)

-- | A soft character budget for the whole @\<available_skills\>@ block.
-- Keeps the catalog token-safe even when a deployment has many skills;
-- once the budget is exhausted, the block is truncated with a count of the
-- remaining skills. Large enough that a typical deployment's full catalog
-- fits intact.
availableSkillsBudget :: Int
availableSkillsBudget = 4096

-- | Render the @\<available_skills\>@ catalog from a list of skills.
-- Skills are grouped by 'skGroup' (a header per group; ungrouped skills
-- fall under a default \"Skills\" header), each entry is
-- @\- \<id\>: \<description\>@, and the whole block is wrapped in
-- @\<available_skills\>@ \/ @\<\/available_skills\>@ tags. Returns the
-- empty 'Text' when the list is empty (the caller skips injection in that
-- case so no empty tags are emitted). The block is truncated to
-- 'availableSkillsBudget' characters with a tail count when exceeded.
--
-- The block ends with a one-line note nudging the model to load a skill's
-- full body via @SKILL_LOAD@ before relying on it.
availableSkillsBlock :: [Skill] -> Text
availableSkillsBlock [] = ""
availableSkillsBlock skills =
  truncateBlock availableSkillsBudget (fullBlock skills)

-- | The untruncated catalog block.
fullBlock :: [Skill] -> Text
fullBlock skills =
  "<available_skills>\n"
  <> T.intercalate "\n\n" (map renderGroup grouped)
  <> "\n\nCall SKILL_LOAD with an id to read a skill's full body before relying on it."
  <> "\n</available_skills>"
  where
    -- Sort by (group, id) then group by group. Ungrouped (Nothing) sorts
    -- first under a generic header; grouped skills follow in alphabetical
    -- group order.
    sorted = sortOn (\s -> (groupKey s, skillIdText (skId s))) skills
    grouped = groupBy (\a b -> groupKey a == groupKey b) sorted
    groupKey s = fromMaybe "" (skGroup s)

-- | Render one group's section: a header line (the group name, or
-- \"Skills\" for the ungrouped section) followed by the @\- id: desc@
-- lines for each skill in the group.
renderGroup :: [Skill] -> Text
renderGroup [] = ""
renderGroup group@(s:_) =
  header <> "\n" <> T.intercalate "\n" [ "- " <> entryId x <> ": " <> desc x | x <- group ]
  where
    header = case skGroup s of
      Just g  -> "## " <> g
      Nothing -> "## Skills"
    desc x = let d = skDescription x in if T.null d then "(no description)" else d
    -- Within a grouped section, show the bare id (the group is already
    -- the header). For ungrouped skills, show the full id.
    entryId x = case skGroup x of
      Just _  -> bareSkillIdText (skId x)
      Nothing -> skillIdText (skId x)

-- | Truncate @block@ to @budget@ characters, appending a tail notice with
-- the number of characters elided when truncation occurs. Strings at or
-- under the budget are returned as-is. Truncation happens on a character
-- boundary (Haskell 'Text' is Unicode-correct).
truncateBlock :: Int -> Text -> Text
truncateBlock budget block
  | T.length block <= budget = block
  | otherwise =
      T.take budget block
        <> "\n[...catalog truncated at "
        <> T.pack (show budget)
        <> " chars; "
        <> T.pack (show (T.length block - budget))
        <> " more chars elided...]"

-- | Append the @\<available_skills\>@ catalog to the resolved system
-- prompt. Calls 'sbList' on the backend, renders the block, and appends it
-- after any existing prompt. Returns the prompt unchanged (no catalog)
-- when the backend lists no skills, so no empty tags are ever emitted.
--
-- The catalog is appended /after/ the auto-loaded skill body (the caller
-- runs 'Seal.Skills.Autoload.injectAutoloadSkill' first, then this). This
-- ordering keeps the stable identity prefix first, the auto-loaded
-- orientation next, and the dynamic catalog last — so prefix-cache hits
-- are maximized and the most volatile content is at the tail.
injectAvailableSkills
  :: SkillBackend
  -- ^ The skill store (typically the unioned backend).
  -> Maybe Text
  -- ^ The resolved system prompt so far (base + autoload body, or
  -- 'Nothing' when no agent is bound and no autoload skill injected).
  -> IO (Maybe Text)
injectAvailableSkills backend mPrompt = do
  skills <- sbList backend
  let block = availableSkillsBlock skills
  if T.null block
    then pure mPrompt
    else pure (Just (case mPrompt of
                        Nothing  -> block
                        Just base -> base <> "\n\n" <> block))
