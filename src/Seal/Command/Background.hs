{-# LANGUAGE OverloadedStrings #-}
-- | The @/bg@ command: run a prompt in a fresh session using the default
-- model + agent, and send the LLM response back on the channel the command
-- was invoked from.
--
-- This module is deliberately thin: the @/bg@ 'CommandAction' just delegates
-- to a channel-supplied 'BgRunner'. Each channel implements its own
-- 'BgRunner' (in 'Seal.Channels.Loop' for inbox-driven channels,
-- 'Seal.Channel.Cli' for the TUI) so that:
--
--   * the turn is forked (the receive loop keeps running so confirmation
--     answers can be delivered asynchronously);
--   * the confirmation prompt (@ccPrompt@) routes through the channel's
--     own approval UX — the same seam a normal turn uses — so the reply
--     and any @Allow SHELL_EXEC ...? [y/N]@ prompts land on the
--     originating channel;
--   * no tab or cursor state is mutated (the fresh @/bg@ session runs
--     headless relative to the tab list).
--
-- The fresh session is persisted to disk (like @/tab new@) so the run
-- appears in @/session list@ and is resumable.
module Seal.Command.Background
  ( BgRunner(..)
  , backgroundCommandSpec
  , runBackground
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
  ( Parser, ParserInfo, (<**>), header, help, helper, info, many, metavar
  , progDesc, strArgument )

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )

-- | A channel-supplied runner for a @/bg@ prompt. The channel builds this
-- closure (minting the fresh session, forking the turn, wiring @ccPrompt@
-- to its own approval UX, and delivering the reply to the invoking
-- 'ChannelCaps'); the @/bg@ action just invokes it. Keeping this as a
-- parameter decouples the command from the channel-specific turn +
-- confirmation machinery so each channel can tailor the approval UX (e.g.
-- Telegram's inline buttons, the CLI's @>@ prompt).
--
-- The confirmation ask is keyed to the /originating conversation's/ active
-- session id (NOT the fresh bg session's) so the channel loop's per-session
-- 'deliverNextAnswer' short-circuit consumes the next inbound message as
-- the answer — producing a modal "answer the pending question before
-- resuming normal turns" state scoped to that conversation. The runner
-- resolves that sid itself (the @/bg@ 'CommandAction' only receives
-- 'ChannelCaps', not conversation context, so the sid cannot be passed in
-- at action-invocation time); channels typically capture a mutable
-- "current conversation sid" cell that the loop updates each turn.
newtype BgRunner = BgRunner { runBg :: Text -> IO () }

-- | The @/bg@ command spec. The action closes over the channel's
-- 'BgRunner'; optparse supplies the prompt as one or more positional
-- words (joined with spaces).
backgroundCommandSpec :: BgRunner -> CommandSpec
backgroundCommandSpec runner = CommandSpec
  { csName         = CommandName "bg"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Run a prompt in a fresh session and reply with the result"
  , csParserInfo   = bgParserInfo runner
  , csAvailability = AlwaysAvailable
  }

bgParserInfo :: BgRunner -> ParserInfo CommandAction
bgParserInfo runner =
  info (bgParser runner <**> helper)
    (  progDesc "Run a prompt in a fresh session and reply with the result"
    <> header "bg — run a prompt in a fresh background session"
    )

-- | One or more positional arguments joined with spaces to form the prompt.
-- The tokenizer already joins quoted spans into a single token, so
-- @/bg "tell me a joke"@ yields one token; @/bg tell me a joke@ yields
-- several tokens that we re-join. A blank prompt (no tokens) is rejected at
-- run time with a usage line.
bgParser :: BgRunner -> Parser CommandAction
bgParser runner =
  runBackground runner . T.intercalate " " <$> many wordArg
  where
    wordArg = strArgument (metavar "PROMPT..." <> help "The prompt to run")

-- | The @/bg@ action: reject a blank prompt, otherwise delegate to the
-- channel's 'BgRunner'. The runner owns session creation, forking,
-- confirmation routing, and reply delivery.
runBackground :: BgRunner -> Text -> CommandAction
runBackground runner prompt = CommandAction $ \caps ->
  if T.null (T.strip prompt)
    then ccSend caps "usage: /bg <prompt>"
    else runBg runner prompt