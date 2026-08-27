{-# LANGUAGE OverloadedStrings #-}
-- | The @/skill@ command group: list defined skills, show one skill's
-- full body, and load a skill into the current session. Skills are stored
-- as structured records materialized from the Audited log into the
-- in-memory 'SkillBackend'; @/skill list@ and @/skill info@ read that
-- backend directly (no filesystem discovery, no audit-trail entry).
-- @/skill load@ dispatches the 'SKILL_LOAD' opcode via the channel-supplied
-- 'CallDispatcher' (the same closure @/call@ uses), which records an
-- 'EKHarness' entry to the session transcript with
-- @erMeta.op.name = "SKILL_LOAD"@ and @erMeta.input.id = <id>@ — the
-- audit-trail attribution that distinguishes a skill load from a user
-- pasting the body.
module Seal.Command.Skill
  ( skillCommandSpec
  , PostLoadTurn
  , renderSkillLine
  , renderSkillInfo
  ) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Call
  ( CallDispatcher, renderDispatchError, renderOpResult )
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode (OpResult (..))
import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)

-- | An optional callback invoked after a successful @/skill load@ to trigger
-- an LLM turn on the active session. The callback receives the trailing
-- message text from the @/skill load@ invocation. When the message is
-- non-empty and the callback is 'Just', 'loadCmd' calls it so the LLM
-- processes the skill body + user message immediately (no need for the
-- user to send another message). When the message is empty or the callback
-- is 'Nothing', no turn is triggered (the skill body is in
-- @conversation.jsonl@ and will be seen on the next user message).
--
-- The callback is channel-specific: the CLI wires it to its 'plainHandler',
-- the web gateway to its 'plainTurn', and inbox channels to their
-- 'runTurnOnSession'. This keeps the turn-triggering mechanism in the
-- wiring layer (which has 'TurnDeps' + 'SessionMeta') rather than the
-- command layer (which only has 'ChannelCaps' + 'CallDispatcher').
type PostLoadTurn = Text -> IO ()

-- | The @/skill@ command spec. Closes over the 'SkillBackend' (for
-- @/skill list@ \/ @/skill info@, which read the materialized view of the
-- Audited log directly) and the channel-supplied 'CallDispatcher' (for
-- @/skill load@, which dispatches the 'SKILL_LOAD' opcode against the
-- active session's ISA registry + transcript — the same dispatcher
-- @/call@ uses, so the audit trail records both paths uniformly).
--
-- The optional 'PostLoadTurn' callback (third argument) controls whether
-- @/skill load <id> <msg>@ auto-runs the LLM after loading the skill. When
-- 'Nothing', the behavior is unchanged (no auto-turn). Pass @Just cb@ to
-- trigger a turn with the trailing message after a successful load.
skillCommandSpec :: SkillBackend -> CallDispatcher -> Maybe PostLoadTurn -> CommandSpec
skillCommandSpec backend dispatcher mPostLoad = CommandSpec
  { csName         = CommandName "skill"
  , csAliases      = []
  , csGroup        = GroupSkills
  , csSynopsis     = "List defined skills, show one skill's body, or load one into the session"
  , csParserInfo   = skillParserInfo backend dispatcher mPostLoad
  , csAvailability = InteractiveOnly
  }

skillParserInfo :: SkillBackend -> CallDispatcher -> Maybe PostLoadTurn -> ParserInfo CommandAction
skillParserInfo backend dispatcher mPostLoad =
  info (skillParser backend dispatcher mPostLoad <**> helper)
    (  progDesc "Inspect or load agent skills"
    <> header   "skill — list, show, or load a skill"
    )

skillParser :: SkillBackend -> CallDispatcher -> Maybe PostLoadTurn -> Parser CommandAction
skillParser backend dispatcher mPostLoad = hsubparser
  (  command "list"
       (info (pure (listCmd backend)) (progDesc "List all defined skills (id + description)"))
  <> command "info"
       (info (infoCmd backend <$> skillArg)
             (progDesc "Show one skill's full body"))
  <> command "load"
       (info (loadCmd dispatcher mPostLoad <$> skillArg <*> messageArg)
             (progDesc "Load one skill into the current session, with an optional trailing message"))
  <> metavar "COMMAND"
  )

-- | Required skill-id argument.
skillArg :: Parser Text
skillArg = T.pack <$> strArgument (metavar "SKILL" <> help "Skill id (e.g. greet)")

-- | Optional trailing message (everything after the skill id). Joined with
-- spaces so @/skill load foo do something@ yields the message @do something@.
-- Empty when no trailing text is supplied (just a skill load, no message).
messageArg :: Parser Text
messageArg = T.intercalate " " . map T.pack <$> many (strArgument (metavar "MESSAGE..." <> help "Optional message appended after the skill body"))

listCmd :: SkillBackend -> CommandAction
listCmd backend = CommandAction $ \caps -> do
  skills <- sbList backend
  if null skills
    then ccSend caps "no skills defined"
    else mapM_ (ccSend caps . renderSkillLine) skills

infoCmd :: SkillBackend -> Text -> CommandAction
infoCmd backend raw = CommandAction $ \caps ->
  case mkSkillId raw of
    Left err -> ccSend caps err
    Right sid -> do
      mSkill <- sbRead backend sid
      case mSkill of
        Nothing -> ccSend caps ("skill not found: " <> skillIdText sid)
        Just s  -> mapM_ (ccSend caps) (renderSkillInfo s)

-- | @/skill load <id> [message...]@ — dispatch the 'SKILL_LOAD' opcode with
-- @{"id": <id>, "message": <message>}@ via the channel-supplied
-- 'CallDispatcher'. Mirrors @/call@'s pattern: echo a header line first (so
-- the "Command output" bubble is self-contained).
--
-- The optional trailing @message@ is forwarded to the dispatcher as a
-- @message@ field in the opcode input. 'recordSkillLoadResult' appends it to
-- @conversation.jsonl@ as a separate 'User' message AFTER the skill body, so
-- the model sees the skill followed by the user's request on the next turn
-- (e.g. @/skill load start #123@ loads the @start@ skill then sends
-- @#123@ as the user's message). When no message is supplied, the input
-- omits the @message@ key and the load behaves as before (skill body only).
--
-- When a 'PostLoadTurn' callback is supplied and the trailing message is
-- non-empty, the callback is invoked after a successful load so the LLM
-- immediately processes the skill body + user message. This avoids the need
-- for the user to send another message after @/skill load@. When the message
-- is empty or no callback is supplied, no turn is triggered (the skill body
-- is in @conversation.jsonl@ and will be picked up on the next user message).
--
-- On success, the skill body is NOT rendered via 'ccSend' — the dispatcher
-- records a second 'EKHarness' entry to the transcript carrying the
-- @orRecorded@ value (which includes the body), and the frontend renders
-- that entry as a collapsible tool-call box. This keeps the slash bubble
-- to just the echo line and avoids duplicating the body in the "command
-- output — not saved" transient bubble.
--
-- On error (dispatch 'Left' or 'Right' with the error flag set), the error
-- text IS rendered via 'ccSend' so the user sees it in the slash bubble —
-- error paths produce no transcript body entry, so the slash bubble is
-- the only surface for the error message.
loadCmd :: CallDispatcher -> Maybe PostLoadTurn -> Text -> Text -> CommandAction
loadCmd dispatcher mPostLoad raw message = CommandAction $ \caps -> do
  ccSend caps ("$ /skill load " <> raw)
  case mkSkillId raw of
    Left err -> ccSend caps err
    Right sid -> do
      let input = object
            [ "id" .= skillIdText sid
            , "message" .= message
            ]
      res <- dispatcher (OpName "SKILL_LOAD") input
      case res of
        Left e  -> ccSend caps (renderDispatchError e)
        Right r
          | orIsError r -> mapM_ (ccSend caps) (renderOpResult r)
          | otherwise   -> case mPostLoad of
              Just postLoad | not (T.null (T.strip message)) -> postLoad message
              _ -> pure ()

-- | One line per skill for @/skill list@.
renderSkillLine :: Skill -> Text
renderSkillLine s = skillIdText (skId s) <> "  " <> skDescription s

-- | Multi-line detail for @/skill info@.
renderSkillInfo :: Skill -> [Text]
renderSkillInfo s =
  [ "id:          " <> skillIdText (skId s)
  , "description: " <> skDescription s
  , "updated:     " <> T.pack (show (skUpdatedAt s))
  , "session:     " <> T.pack (show (skSession s))
  , ""
  , skBody s
  ]