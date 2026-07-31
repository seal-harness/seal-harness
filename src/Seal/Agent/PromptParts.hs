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
  ) where

import Data.Text (Text)
import Data.Text qualified as T

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