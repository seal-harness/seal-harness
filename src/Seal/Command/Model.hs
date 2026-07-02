{-# LANGUAGE OverloadedStrings #-}
-- | The @/model@ command group: list known providers/models and set the active
-- session's provider+model (persisted to session.json). Provider+model are named
-- explicitly (unambiguous once providers host arbitrary model names).
module Seal.Command.Model
  ( modelCommandSpec
  ) where

import Data.IORef (readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Registry
  ( defaultModelFor, knownProviders, parseProvider, providerLabel )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)

modelCommandSpec :: SessionRuntime -> CommandSpec
modelCommandSpec sr = CommandSpec
  { csName         = CommandName "model"
  , csAliases      = []
  , csGroup        = GroupModel
  , csSynopsis     = "List models and set the active session's model"
  , csParserInfo   = modelParserInfo sr
  , csAvailability = InteractiveOnly
  }

modelParserInfo :: SessionRuntime -> ParserInfo CommandAction
modelParserInfo sr =
  info (modelParser sr <**> helper)
    (  progDesc "List known providers/models and choose the session's model"
    <> header   "model — inspect and set the active session's model"
    )

modelParser :: SessionRuntime -> Parser CommandAction
modelParser sr = hsubparser
  (  command "list"
       (info (pure (listCmd sr)) (progDesc "List known providers and their default models"))
  <> command "use"
       (info (useCmd sr <$> provArg <*> modelArg)
             (progDesc "Set the session's provider and model"))
  <> metavar "COMMAND"
  )

provArg :: Parser Text
provArg = T.pack <$> strArgument (metavar "PROVIDER" <> help "Provider id (e.g. anthropic)")

modelArg :: Parser Text
modelArg = T.pack <$> strArgument (metavar "MODEL" <> help "Model id")

listCmd :: SessionRuntime -> CommandAction
listCmd sr = CommandAction $ \caps -> do
  mapM_ (ccSend caps . renderKnown) knownProviders
  active <- readIORef (srActive sr)
  ccSend caps ("active: " <> smProvider active <> "/" <> smModel active)
  where
    renderKnown kp =
      let ModelId dm = defaultModelFor kp
      in providerLabel kp <> " (default model: " <> dm <> ")"

useCmd :: SessionRuntime -> Text -> Text -> CommandAction
useCmd sr provLbl model = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      m0 <- readIORef (srActive sr)
      let m1 = m0 { smProvider = providerLabel kp, smModel = model }
      writeIORef (srActive sr) m1
      saveSessionMeta (srPaths sr) m1
      ccSend caps ("session model set to " <> providerLabel kp <> "/" <> model)

unknownProviderMsg :: Text -> Text
unknownProviderMsg lbl =
  "unknown provider: " <> lbl <> " (known: "
    <> T.intercalate ", " (map providerLabel knownProviders) <> ")"
