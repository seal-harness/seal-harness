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

-- | The @/skill@ command spec. Closes over the 'SkillBackend' (for
-- @/skill list@ \/ @/skill info@, which read the materialized view of the
-- Audited log directly) and the channel-supplied 'CallDispatcher' (for
-- @/skill load@, which dispatches the 'SKILL_LOAD' opcode against the
-- active session's ISA registry + transcript — the same dispatcher
-- @/call@ uses, so the audit trail records both paths uniformly).
skillCommandSpec :: SkillBackend -> CallDispatcher -> CommandSpec
skillCommandSpec backend dispatcher = CommandSpec
  { csName         = CommandName "skill"
  , csAliases      = []
  , csGroup        = GroupSkills
  , csSynopsis     = "List defined skills, show one skill's body, or load one into the session"
  , csParserInfo   = skillParserInfo backend dispatcher
  , csAvailability = InteractiveOnly
  }

skillParserInfo :: SkillBackend -> CallDispatcher -> ParserInfo CommandAction
skillParserInfo backend dispatcher =
  info (skillParser backend dispatcher <**> helper)
    (  progDesc "Inspect or load agent skills"
    <> header   "skill — list, show, or load a skill"
    )

skillParser :: SkillBackend -> CallDispatcher -> Parser CommandAction
skillParser backend dispatcher = hsubparser
  (  command "list"
       (info (pure (listCmd backend)) (progDesc "List all defined skills (id + description)"))
  <> command "info"
       (info (infoCmd backend <$> skillArg)
             (progDesc "Show one skill's full body"))
  <> command "load"
       (info (loadCmd dispatcher <$> skillArg)
             (progDesc "Load one skill into the current session (records a SKILL_LOAD audit entry)"))
  <> metavar "COMMAND"
  )

-- | Required skill-id argument.
skillArg :: Parser Text
skillArg = T.pack <$> strArgument (metavar "SKILL" <> help "Skill id (e.g. greet)")

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

-- | @/skill load <id>@ — dispatch the 'SKILL_LOAD' opcode with @{"id": <id>}@
-- via the channel-supplied 'CallDispatcher'. Mirrors @/call@'s pattern:
-- echo a header line first (so the "Command output" bubble is self-contained).
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
loadCmd :: CallDispatcher -> Text -> CommandAction
loadCmd dispatcher raw = CommandAction $ \caps -> do
  ccSend caps ("$ /skill load " <> raw)
  case mkSkillId raw of
    Left err -> ccSend caps err
    Right sid -> do
      let input = object ["id" .= skillIdText sid]
      res <- dispatcher (OpName "SKILL_LOAD") input
      case res of
        Left e  -> ccSend caps (renderDispatchError e)
        Right r
          | orIsError r -> mapM_ (ccSend caps) (renderOpResult r)
          | otherwise   -> pure ()

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