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

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (SessionId, sessionIdText)
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
    else mapM_ (ccSend caps . renderSessionLine (smId active)) metas

infoCmd :: SessionRuntime -> CommandAction
infoCmd sr = CommandAction $ \caps -> do
  active <- readIORef (srActive sr)
  mapM_ (ccSend caps) (renderSessionInfo active)

-- | One line per session for @/session list@, marking the active one.
renderSessionLine :: SessionId -> SessionMeta -> Text
renderSessionLine active m =
  let mark = if smId m == active then "  (active)" else ""
  in sessionIdText (smId m)
       <> "  " <> smProvider m <> "/" <> smModel m
       <> "  " <> T.pack (show (smLastActive m)) <> mark

-- | Multi-line detail for @/session info@.
renderSessionInfo :: SessionMeta -> [Text]
renderSessionInfo m =
  [ "id:          " <> sessionIdText (smId m)
  , "provider:    " <> smProvider m
  , "model:       " <> smModel m
  , "channel:     " <> smChannel m
  , "created:     " <> T.pack (show (smCreatedAt m))
  , "last active: " <> T.pack (show (smLastActive m))
  ]
