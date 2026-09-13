{-# LANGUAGE OverloadedStrings #-}
-- | Static behavioral guidance blocks injected into the system prompt.
-- Each block is a few sentences of operational guidance that improves
-- model behavior across providers without being model-specific. The
-- blocks are config-gated (see 'Seal.Config.File': @[agent]@
-- @parallel_tool_guidance@, @tool_use_enforcement@,
-- @task_completion_guidance@); each defaults to injected (true).
--
-- The blocks are appended /before/ the dynamic @\<available_skills\>@
-- catalog so the stable text precedes the volatile catalog (cache-
-- friendly ordering: stable identity prefix → static guidance →
-- autoload body → available-skills catalog).
module Seal.Agent.PromptParts
  ( parallelToolGuidance
  , toolUseEnforcement
  , taskCompletionGuidance
  , staticGuidanceBlock
  , injectStaticGuidance
  , availableAgentsBlock
  , injectAvailableAgents
  , leafAgentNote
  ) where

import Data.List (groupBy, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Agent.Def.Types (AgentDef (..), agentDefIdText)

-- | Parallel tool-call guidance. Tells the model to batch independent
-- tool calls into one turn rather than running them sequentially across
-- turns. A real latency/token win with no risk.
parallelToolGuidance :: Text
parallelToolGuidance =
  "## Parallel tool calls\n\n\
  \When several tool calls are independent (no output of one is needed to \
  \call another), batch them into a single turn. Do not call them \
  \sequentially across turns when you could have called them together."

-- | Tool-use enforcement. Tells the model to actually call tools instead
-- of describing actions. Improves reliability on weaker models that tend
-- to narrate instead of act.
toolUseEnforcement :: Text
toolUseEnforcement =
  "## Tool use\n\n\
  \When a task requires a tool, actually call the tool. Do not describe \
  \or narrate the action you would take (\"I would run X\") and then stop \
  \— call it. Do not answer from memory when a current tool call could \
  \get the real state."

-- | Task-completion / anti-fabrication guidance. Tells the model not to
-- stop after a stub and not to fabricate output when a path is blocked.
taskCompletionGuidance :: Text
taskCompletionGuidance =
  "## Task completion\n\n\
  \Do not stop after producing a stub, TODO, or skeleton and report the \
  \task done. Complete the implementation through to working, tested \
  \code. If a path is genuinely blocked (missing input, failed tool, \
  \permission denied), say so explicitly and ask for what you need — do \
  \not fabricate output to fill the gap."

-- | Render the enabled guidance blocks as a single section, joined with
-- blank lines. Returns the empty 'Text' when no block is enabled (so the
-- caller can skip emitting anything). Each enabled block is a
-- @## header@ + body, so the whole section reads as a sequence of
-- short guidance notes.
staticGuidanceBlock :: Bool -> Bool -> Bool -> Text
staticGuidanceBlock parallel toolUse taskCompletion =
  let parts = [ parallelToolGuidance    | parallel ]
           <> [ toolUseEnforcement      | toolUse ]
           <> [ taskCompletionGuidance  | taskCompletion ]
  in if null parts then "" else T.intercalate "\n\n" parts

-- | Append the enabled static guidance blocks to the resolved system
-- prompt. The blocks go /before/ the auto-loaded skill body and the
-- available-skills catalog (the caller runs this first, then
-- 'Seal.Skills.Autoload.injectAutoloadSkill', then
-- 'Seal.Skills.Prompt.injectAvailableSkills'). Returns the prompt
-- unchanged when no block is enabled.
injectStaticGuidance
  :: Bool    -- ^ parallel tool-call guidance
  -> Bool    -- ^ tool-use enforcement
  -> Bool    -- ^ task-completion guidance
  -> Maybe Text
  -> Maybe Text
injectStaticGuidance parallel toolUse taskCompletion mPrompt =
  let block = staticGuidanceBlock parallel toolUse taskCompletion
  in if T.null block
       then mPrompt
       else Just (case mPrompt of
                    Nothing  -> block
                    Just base -> base <> "\n\n" <> block)
-- ---------------------------------------------------------------------------
-- W3 (issue #154): the <available_agents> catalog
-- ---------------------------------------------------------------------------

-- | The per-def catalog budget (chars). Matches the skills catalog
-- (4096) — with repo-prefixed ids and 256-char descriptions, ~19
-- metaswarm agents fit comfortably; truncation is observable via the
-- marker, and AGENT_DEF_LIST always stays complete.
availableAgentsBudget :: Int
availableAgentsBudget = 4096

-- | The one-line note injected into a LEAF child's prompt instead of the
-- catalog (the child's registry has no spawn capability, so advertising
-- agents it cannot delegate to would waste turns).
leafAgentNote :: Text
leafAgentNote = "You are a leaf agent; delegation is not available."

-- | The untruncated @\<available_agents\>@ catalog block: one bullet per
-- def (@- \<full-id\> [\<role\>]: \<description|name-fallback\>@), grouped
-- by 'adGroup' with @## \<group\>@ headers (ungrouped defs fall under
-- @## Agents@), ending with the AGENT_START nudge line. The block is
-- truncated to 'availableAgentsBudget' with the elided-count marker.
-- The empty list renders @\"\"@ (the caller skips injection — no empty
-- tags are ever emitted). Bullets always use the FULL merged-backend id
-- (workdir-prefixed where applicable) — that is what AGENT_START accepts.
availableAgentsBlock :: [AgentDef] -> Text
availableAgentsBlock [] = ""
availableAgentsBlock defs = truncateBlock budget (fullBlock defs)
  where
    budget = availableAgentsBudget
    fullBlock ds =
      "<available_agents>\n"
      <> T.intercalate "\n\n" (map renderGroup grouped)
      <> "\n\nDelegate with AGENT_START using an id before relying on an agent."
      <> "\n</available_agents>"
      where
        sorted = sortOn (\d -> (groupKey d, agentDefIdText (adId d))) ds
        grouped = groupBy (\a b -> groupKey a == groupKey b) sorted
        groupKey d = fromMaybe "" (adGroup d)

-- | Render one group's section: a header line (the group name, or
-- \"Agents\" for the ungrouped section) followed by the @- id [role]: text@
-- bullets.
renderGroup :: [AgentDef] -> Text
renderGroup [] = ""
renderGroup group@(d0:_) =
  header <> "\n" <> T.intercalate "\n" (map bullet group)
  where
    header = case adGroup d0 of
      Just g  -> "## " <> g
      Nothing -> "## Agents"
    bullet d = "- " <> agentDefIdText (adId d) <> roleSuffix (adRole d)
               <> ": " <> primaryText d
    primaryText d = case adDescription d of
      Just desc | not (T.null (T.strip desc)) -> desc
      _         -> adName d
    roleSuffix (Just r) = " [" <> r <> "]"
    roleSuffix Nothing  = ""

-- | Truncate the block to the budget, appending the elided count when
-- truncation occurs (character boundary — 'Text' is Unicode-correct).
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

-- | Append the @\<available_agents\>@ catalog to the resolved system
-- prompt. Pure over the def list (the caller passes 'adbList' from the
-- per-turn union backend). Returns the prompt unchanged (no catalog)
-- when the list is empty, so no empty tags are ever emitted. The catalog
-- is appended AFTER everything else (skills catalog last per the
-- cache-friendly ordering; agents follow).
injectAvailableAgents :: [AgentDef] -> Maybe Text -> Maybe Text
injectAvailableAgents defs mPrompt =
  let block = availableAgentsBlock defs
  in if T.null block
       then mPrompt
       else pure (case mPrompt of
                    Nothing  -> block
                    Just base -> base <> "\n\n" <> block)
