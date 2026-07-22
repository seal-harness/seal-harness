{-# LANGUAGE OverloadedStrings #-}
-- | The @/agent@ command group: list defined agent definitions, show one
-- agent def's fields, and view or set the default agent. Agent defs are stored
-- as structured records materialized from the Audited log into the in-memory
-- 'AgentDefBackend'; this command reads that backend (no filesystem
-- discovery). The default agent is persisted in @config.toml@ as
-- @default_agent@.
--
-- Scope (mirrors pureclaw's @\/agent@ surface): discovery over definitions
-- only. The running-agent lifecycle (@AGENT_START@\/@STOP@\/@STATUS@) is
-- reachable via the ISA tool calls, not via slash commands.
module Seal.Command.Agent
  ( agentCommandSpec
  , renderAgentLine
  , renderAgentInfo
  ) where

import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Agent.Def.Backend (AgentDefBackend (..))
import Seal.Agent.Def.Types (AgentDef (..), mkAgentDefId, agentDefIdText)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File (RuntimeConfig (..), loadRuntimeConfig, updateRuntimeConfig)
import Seal.Core.Types (ModelId (..), OpName (..))
import Seal.Security.Policy (AllowList (..))

-- | The @/agent@ command spec. Closes over the 'AgentDefBackend' (for
-- list/info) and the config path (for default get/set).
agentCommandSpec :: AgentDefBackend -> FilePath -> CommandSpec
agentCommandSpec backend cfgPath = CommandSpec
  { csName         = CommandName "agent"
  , csAliases      = []
  , csGroup        = GroupAgent
  , csSynopsis     = "List agent defs, show one, or view/set the default agent"
  , csParserInfo   = agentParserInfo backend cfgPath
  , csAvailability = InteractiveOnly
  }

agentParserInfo :: AgentDefBackend -> FilePath -> ParserInfo CommandAction
agentParserInfo backend cfgPath =
  info (agentParser backend cfgPath <**> helper)
    (  progDesc "Inspect agent definitions and the default agent"
    <> header   "agent — list defs, show one, or view/set the default"
    )

agentParser :: AgentDefBackend -> FilePath -> Parser CommandAction
agentParser backend cfgPath = hsubparser
  (  command "list"
       (info (pure (listCmd backend))
             (progDesc "List all defined agent defs (id + name + provider/model)"))
  <> command "info"
       (info (infoCmd backend <$> agentArg)
             (progDesc "Show one agent def's fields"))
  <> command "default"
       (info (defaultCmd backend cfgPath <$> optional agentArg)
             (progDesc "View or set the default agent"))
  <> metavar "COMMAND"
  )

-- | Required agent-def-id argument.
agentArg :: Parser Text
agentArg = T.pack <$> strArgument (metavar "AGENT" <> help "Agent def id (e.g. worker)")

listCmd :: AgentDefBackend -> CommandAction
listCmd backend = CommandAction $ \caps -> do
  defs <- adbList backend
  if null defs
    then ccSend caps "no agent defs defined"
    else mapM_ (ccSend caps . renderAgentLine) (sortOn adName defs)

infoCmd :: AgentDefBackend -> Text -> CommandAction
infoCmd backend raw = CommandAction $ \caps ->
  case mkAgentDefId raw of
    Left err -> ccSend caps err
    Right aid -> do
      mDef <- adbRead backend aid
      case mDef of
        Nothing -> ccSend caps ("agent def not found: " <> agentDefIdText aid)
        Just d  -> mapM_ (ccSend caps) (renderAgentInfo d)

-- | @/agent default@ with no arg views; with an arg validates-then-persists.
defaultCmd :: AgentDefBackend -> FilePath -> Maybe Text -> CommandAction
defaultCmd backend cfgPath mArg = CommandAction $ \caps ->
  case mArg of
    Nothing -> do
      eCfg <- loadRuntimeConfig cfgPath
      let cur = either (const Nothing) rcDefaultAgent eCfg
      case cur of
        Nothing -> ccSend caps "no default agent set. Use /agent default <id> to set one."
        Just a  -> ccSend caps ("default agent: " <> a)
    Just raw ->
      case mkAgentDefId raw of
        Left err -> ccSend caps err
        Right aid -> do
          mDef <- adbRead backend aid
          case mDef of
            Nothing -> ccSend caps ("agent def not found: " <> agentDefIdText aid)
            Just _ -> do
              res <- updateRuntimeConfig cfgPath
                       (\fc -> fc { rcDefaultAgent = Just (agentDefIdText aid) })
              case res of
                Left e   -> ccSend caps e
                Right () -> ccSend caps ("default agent set to: " <> agentDefIdText aid)

-- | One line per def for @/agent list@. Empty provider/model (e.g. a
-- DirScheme agent with no @AGENTS.md@ frontmatter) render as @default@.
renderAgentLine :: AgentDef -> Text
renderAgentLine d =
  agentDefIdText (adId d) <> "  " <> adName d
    <> "  (" <> providerLabel <> "/" <> modelLabel <> ")"
  where
    ModelId modelName = adModel d
    providerLabel = if T.null (adProvider d) then "default" else adProvider d
    modelLabel = if T.null modelName then "default" else modelName

-- | Multi-line detail for @/agent info@.
renderAgentInfo :: AgentDef -> [Text]
renderAgentInfo d =
  [ "id:          " <> agentDefIdText (adId d)
  , "name:        " <> adName d
  , "provider:    " <> adProvider d
  , "model:       " <> modelName
  , "system:      " <> fromMaybe "(none)" (adSystem d)
  , "tools:       " <> renderTools (adTools d)
  , "updated:     " <> T.pack (show (adUpdatedAt d))
  , "session:     " <> T.pack (show (adSession d))
  ]
  where
    ModelId modelName = adModel d
    renderTools AllowAll       = "all"
    renderTools (AllowOnly xs) =
      T.intercalate ", " [ t | OpName t <- Set.toList xs ]