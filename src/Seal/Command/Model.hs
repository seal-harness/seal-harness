{-# LANGUAGE OverloadedStrings #-}
-- | The @/model@ command group: list known providers/models and set the active
-- session's provider+model (persisted to session.json). Provider+model are named
-- explicitly (unambiguous once providers host arbitrary model names).
module Seal.Command.Model
  ( modelCommandSpec
  ) where

import Data.Either (fromRight)
import Data.IORef (readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File
  ( ProviderConfig (..), defaultFileConfig, loadFileConfig, providerBaseUrl
  , providerDefaultModel, updateFileConfig, upsertProvider )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry
  ( defaultModelFor, knownProviders, listSome, parseProvider, providerLabel
  , resolveDefaultModel, resolveProvider )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.Vault.Commands (VaultRuntime (..))

modelCommandSpec :: ProviderRuntime -> SessionRuntime -> CommandSpec
modelCommandSpec pr sr = CommandSpec
  { csName         = CommandName "model"
  , csAliases      = []
  , csGroup        = GroupModel
  , csSynopsis     = "List models and set the active session's model"
  , csParserInfo   = modelParserInfo pr sr
  , csAvailability = InteractiveOnly
  }

modelParserInfo :: ProviderRuntime -> SessionRuntime -> ParserInfo CommandAction
modelParserInfo pr sr =
  info (modelParser pr sr <**> helper)
    (  progDesc "List known providers/models and choose the session's model"
    <> header   "model — inspect and set the active session's model"
    )

modelParser :: ProviderRuntime -> SessionRuntime -> Parser CommandAction
modelParser pr sr = hsubparser
  (  command "list"
       (info (listCmd pr sr <$> optional listProvArg)
             (progDesc "List known providers, or a provider's live models"))
  <> command "use"
       (info (useCmd pr sr <$> provArg <*> optional modelArg)
             (progDesc "Set the session's provider and model (model optional)"))
  <> command "default"
       (info (defaultCmd pr sr <$> provArg <*> modelArg)
             (progDesc "Set a provider's default model"))
  <> metavar "COMMAND"
  )

provArg :: Parser Text
provArg = T.pack <$> strArgument (metavar "PROVIDER" <> help "Provider id (e.g. anthropic)")

listProvArg :: Parser Text
listProvArg = T.pack <$> strArgument
  (metavar "PROVIDER" <> help "Provider id to list live models for (e.g. ollama)")

modelArg :: Parser Text
modelArg = T.pack <$> strArgument (metavar "MODEL" <> help "Model id")

listCmd :: ProviderRuntime -> SessionRuntime -> Maybe Text -> CommandAction
listCmd pr sr Nothing = CommandAction $ \caps -> do
  eCfg <- loadFileConfig (prConfigPath pr)
  let cfg = fromRight defaultFileConfig eCfg
  mapM_ (ccSend caps . renderKnown cfg) knownProviders
  active <- readIORef (srActive sr)
  ccSend caps ("active: " <> smProvider active <> "/" <> smModel active)
  where
    renderKnown cfg kp =
      let lbl = providerLabel kp
          ModelId dm = resolveDefaultModel (providerDefaultModel cfg lbl) lbl
      in lbl <> " (default model: " <> dm <> ")"
listCmd pr _ (Just provLbl) = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      eCfg <- loadFileConfig (prConfigPath pr)
      let baseUrl = fromMaybe defaultOllamaBaseUrl (either (const Nothing) (`providerBaseUrl` "ollama") eCfg)
      mh <- readIORef (vrHandleRef (prVault pr))
      eProv <- resolveProvider mh (prManager pr) baseUrl kp (defaultModelFor kp) (prCallCounter pr)
      case eProv of
        Left e   -> ccSend caps ("could not list " <> providerLabel kp <> " models: " <> e)
        Right sp -> do
          eModels <- listSome sp
          case eModels of
            Left e   -> ccSend caps ("could not list " <> providerLabel kp <> " models: " <> e)
            Right [] -> ccSend caps (providerLabel kp <> " has no models available")
            Right ms -> do
              ccSend caps (providerLabel kp <> " models (live):")
              mapM_ (\(ModelId m) -> ccSend caps ("  " <> m)) ms

useCmd :: ProviderRuntime -> SessionRuntime -> Text -> Maybe Text -> CommandAction
useCmd pr sr provLbl mModel = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      model <- case mModel of
        Just m  -> pure m
        Nothing -> do
          eCfg <- loadFileConfig (prConfigPath pr)
          let cfg = fromRight defaultFileConfig eCfg
              ModelId m = resolveDefaultModel (providerDefaultModel cfg (providerLabel kp)) (providerLabel kp)
          pure m
      m0 <- readIORef (srActive sr)
      let m1 = m0 { smProvider = providerLabel kp, smModel = model }
      writeIORef (srActive sr) m1
      saveSessionMeta (srPaths sr) m1
      ccSend caps ("session model set to " <> providerLabel kp <> "/" <> model)

defaultCmd :: ProviderRuntime -> SessionRuntime -> Text -> Text -> CommandAction
defaultCmd pr _ provLbl model = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      res <- updateFileConfig (prConfigPath pr)
               (upsertProvider (providerLabel kp) (\p -> p { pcDefaultModel = Just model }))
      case res of
        Left e   -> ccSend caps e
        Right () -> ccSend caps (providerLabel kp <> " default model set to " <> model)

unknownProviderMsg :: Text -> Text
unknownProviderMsg lbl =
  "unknown provider: " <> lbl <> " (known: "
    <> T.intercalate ", " (map providerLabel knownProviders) <> ")"
