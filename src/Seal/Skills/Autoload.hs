{-# LANGUAGE OverloadedStrings #-}
-- | Skill auto-injection at session start. The harness reads a configured
-- skill id (default @"seal-usage"@, the fresh-workdir contract), loads its
-- body from the skill backend, and appends it to the resolved system prompt
-- so the model is oriented to its per-session workspace from turn one.
--
-- The injected skill is /teaching/, not enforcement: it tells the model the
-- workdir contract so it cooperates. The operator can disable auto-injection
-- by setting @[skills] autoload = ""@ in @config.toml@, or override the
-- injected skill id with any other value.
module Seal.Skills.Autoload
  ( injectAutoloadSkill
  , renderSkillForPrompt
  ) where

import Data.Text (Text)

import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)

-- | Append the auto-loaded skill body to the resolved system prompt.
--
-- * @mSkillId = Nothing@ → no auto-injection; return the prompt unchanged.
-- * @mSkillId = Just sid@ → load the skill body from @backend@; if found,
--   append it under an @## Auto-loaded skill: <id>@ header. If the skill is
--   missing from the backend, fall back to the prompt unchanged (a missing
--   autoload skill is a soft failure — the session proceeds, the model
--   just doesn't get the orientation note).
--
-- The skill body is appended /after/ any existing system prompt (the bound
-- agent's @adSystem@). The header separates the agent's identity/prompt
-- from the harness-injected orientation.
injectAutoloadSkill
  :: SkillBackend
  -- ^ The skill store (reads from @~/.seal/config/skills@).
  -> Maybe Text
  -- ^ The skill id to auto-inject ('Nothing' disables).
  -> Maybe Text
  -- ^ The resolved system prompt (the bound agent's @adSystem@, or
  -- 'Nothing' when no agent is bound).
  -> IO (Maybe Text)
injectAutoloadSkill _ Nothing prompt = pure prompt
injectAutoloadSkill backend (Just skillIdText_) prompt = do
  case mkSkillId skillIdText_ of
    Left _err -> pure prompt  -- invalid id → soft-fail (no injection)
    Right sid -> do
      mSkill <- sbRead backend sid
      case mSkill of
        Nothing    -> pure prompt  -- skill missing → soft-fail
        Just skill -> pure (Just (renderSkillForPrompt prompt skill))

-- | Render the system prompt + auto-loaded skill body as a single text.
-- The skill body is appended under a header; if the existing prompt is
-- 'Nothing', the skill body becomes the entire prompt.
renderSkillForPrompt :: Maybe Text -> Skill -> Text
renderSkillForPrompt mPrompt skill =
  case mPrompt of
    Nothing    -> rendered
    Just base  -> base <> "\n\n" <> rendered
  where
    rendered =
      "# Auto-loaded skill: " <> skillIdText (skId skill) <> "\n\n"
      <> skBody skill