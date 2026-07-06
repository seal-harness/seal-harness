{-# LANGUAGE OverloadedStrings #-}
-- | The @/skill@ command group: list defined skills and show one skill's
-- full body. Skills are stored as structured records materialized from the
-- Audited log into the in-memory 'SkillBackend'; this command reads that
-- backend (no filesystem discovery). Skills are invoked on demand by agents
-- or by the user — there is no @\/skill default@.
module Seal.Command.Skill
  ( skillCommandSpec
  , renderSkillLine
  , renderSkillInfo
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)

-- | The @/skill@ command spec. Closes over the 'SkillBackend' so @/skill list@
-- and @/skill info@ read the materialized view of the Audited log.
skillCommandSpec :: SkillBackend -> CommandSpec
skillCommandSpec backend = CommandSpec
  { csName         = CommandName "skill"
  , csAliases      = []
  , csGroup        = GroupSkills
  , csSynopsis     = "List defined skills and show one skill's body"
  , csParserInfo   = skillParserInfo backend
  , csAvailability = InteractiveOnly
  }

skillParserInfo :: SkillBackend -> ParserInfo CommandAction
skillParserInfo backend =
  info (skillParser backend <**> helper)
    (  progDesc "Inspect defined agent skills"
    <> header   "skill — list skills and show one skill's body"
    )

skillParser :: SkillBackend -> Parser CommandAction
skillParser backend = hsubparser
  (  command "list"
       (info (pure (listCmd backend)) (progDesc "List all defined skills (id + description)"))
  <> command "info"
       (info (infoCmd backend <$> skillArg)
             (progDesc "Show one skill's full body"))
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