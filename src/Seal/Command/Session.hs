{-# LANGUAGE OverloadedStrings #-}
-- | The @/session@ command group: list sessions and show the active one.
-- (@/session resume@ is a follow-on milestone.)
module Seal.Command.Session
  ( sessionCommandSpec
  , renderSessionLine
  , renderSessionInfo
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Agent.Def.Types (agentDefIdText)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Gateway.Transcript (firstUserMessageSnippet)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), listSessions)
import Data.IORef (readIORef)

sessionCommandSpec :: SessionRuntime -> CommandSpec
sessionCommandSpec sr = CommandSpec
  { csName         = CommandName "session"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "List sessions and show the active one"
  , csParserInfo   = sessionParserInfo sr
  , csAvailability = InteractiveOnly
  }

sessionParserInfo :: SessionRuntime -> ParserInfo CommandAction
sessionParserInfo sr =
  info (sessionParser sr <**> helper)
    (  progDesc "Inspect chat sessions"
    <> header   "session — list sessions and show the active one"
    )

sessionParser :: SessionRuntime -> Parser CommandAction
sessionParser sr = hsubparser
  (  command "list"
       (info (pure (listCmd sr)) (progDesc "List all sessions (newest first)"))
  <> command "info"
       (info (pure (infoCmd sr)) (progDesc "Show the active session's details"))
  <> metavar "COMMAND"
  )

listCmd :: SessionRuntime -> CommandAction
listCmd sr = CommandAction $ \caps -> do
  active <- readIORef (srActive sr)
  metas  <- listSessions (srPaths sr)
  if null metas
    then ccSend caps "no sessions yet"
    else do
      snippets <- mapM (firstUserMessageSnippet (srPaths sr) . smId) metas
      mapM_ (ccSend caps . uncurry (renderSessionLine (smId active)))
            (zip snippets metas)

infoCmd :: SessionRuntime -> CommandAction
infoCmd sr = CommandAction $ \caps -> do
  active <- readIORef (srActive sr)
  mapM_ (ccSend caps) (renderSessionInfo active)

-- | One line per session for @/session list@, marking the active one.
-- Shows the session id, provider/model, the bound agent (if any), and the
-- first user message snippet (if any) — the same title cascade the web
-- frontend uses, minus the timestamp (which is redundant with the id).
renderSessionLine :: SessionId -> Maybe Text -> SessionMeta -> Text
renderSessionLine active mSnippet m =
  let mark = if smId m == active then "  (active)" else ""
      agentLabel = case (smAgentName m, smAgent m) of
        (Just name, _)   -> name
        (Nothing, Just a) -> agentDefIdText a
        (Nothing, Nothing) -> ""
      agentPart = if T.null agentLabel then "" else "  " <> agentLabel
      snippetPart = case mSnippet of
        Just s  -> "  " <> s
        Nothing -> ""
  in sessionIdText (smId m)
       <> "  " <> smProvider m <> "/" <> smModel m
       <> agentPart
       <> snippetPart
       <> mark

-- | Multi-line detail for @/session info@.
renderSessionInfo :: SessionMeta -> [Text]
renderSessionInfo m =
  [ "id:          " <> sessionIdText (smId m)
  , "provider:    " <> smProvider m
  , "model:       " <> smModel m
  , "channel:     " <> smChannel m
  , "agent:       " <> maybe "(none)" agentDefIdText (smAgent m)
  , "created:     " <> T.pack (show (smCreatedAt m))
  , "last active: " <> T.pack (show (smLastActive m))
  ]
