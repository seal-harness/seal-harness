{-# LANGUAGE OverloadedStrings #-}
-- | The @/model@ command group: list known providers/models and set the active
-- session's provider+model (persisted to session.json). Provider+model are named
-- explicitly (unambiguous once providers host arbitrary model names).
--
-- Two constructors mirror 'Seal.Command.Stop':
--
-- * 'modelCommandSpec' — single-session channels (CLI, TUI). Reads
--   'srActive' at dispatch time and saves back to it + its on-disk
--   @session.json@.
-- * 'modelCommandSpecForSession' — multi-session surfaces (the per-request web
--   gateway rebuild, the inbox channel-loop shadow). Closes over an explicit
--   'SessionId' resolver + 'SealPaths' so a @\/model use@ typed in tab N (or
--   from a Telegram conversation) targets THAT session's @session.json@, not
--   the process-global @srActive@ — which on those surfaces points at an
--   unrelated session and would silently lose the change on the next turn.
--
-- @\/model use@ records an @EKResponse@ audit entry in the target session's
-- transcript (via 'ModelTranscriptWriter', twin of 'StopTranscriptWriter') so
-- the change is visible cross-channel and survives a @seal serve@ restart. It
-- makes NO LLM request — it is pure session-state mutation + one transcript
-- line, like @\/stop@.
module Seal.Command.Model
  ( modelCommandSpec
  , modelCommandSpecForSession
  , ModelTranscriptWriter
  , noModelTranscriptWriter
  , mkModelTranscriptWriter
  ) where

import Data.Either (fromRight)
import Data.IORef (readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig, defaultRuntimeConfig, loadRuntimeConfig
  , providerBaseUrl, providerDefaultModel, updateRuntimeConfig, upsertProvider )
import Seal.Config.Paths (SealPaths, sessionDir)
import Seal.Core.Types (ModelId (..), SessionId)
import Seal.Core.TurnEngine (broadcastNewEntries, loadSessionMeta)
import Seal.Gateway.StreamBroker (StreamBroker)
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..), withTwoFileTranscript)
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry
  ( KnownProvider, configuredProviders, defaultModelFor, knownProviders, listSome
  , parseProvider, providerLabel, resolveDefaultModel, resolveProvider )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Vault.Commands (VaultRuntime (..))

-- | A function that records the @\/model use@ confirmation to the target
-- session's transcript and broadcasts the new entry to WS subscribers. Built
-- at the wiring site from 'SealPaths' + the broker (twin of
-- 'Seal.Command.Stop.StopTranscriptWriter'). 'Nothing' (via
-- 'noModelTranscriptWriter') skips the write — used in tests or contexts
-- without a transcript.
newtype ModelTranscriptWriter = ModelTranscriptWriter (Maybe (SessionId -> Text -> IO ()))

-- | The no-op writer (no transcript write). Used in tests or contexts without
-- a transcript.
noModelTranscriptWriter :: ModelTranscriptWriter
noModelTranscriptWriter = ModelTranscriptWriter Nothing

-- | Build a 'ModelTranscriptWriter' from the shared dependencies. Opens the
-- session's transcript, writes the confirmation as an assistant 'EKResponse'
-- entry, and broadcasts the new entry via the broker. Mirrors
-- 'Seal.Command.Stop.mkStopTranscriptWriter'.
mkModelTranscriptWriter :: SealPaths -> Maybe StreamBroker -> ModelTranscriptWriter
mkModelTranscriptWriter paths mBroker =
  ModelTranscriptWriter $ Just $ \sid msg -> do
    let dir = sessionDir paths sid
    mMeta <- loadSessionMeta paths sid
    now <- getCurrentTime
    let model = maybe "" smModel mMeta
        createdAt = maybe now smCreatedAt mMeta
    withTwoFileTranscript dir $ \h -> do
      let assistantMsg = Message Assistant [CbText msg]
          entry = EntryRecord
            { erId = ""
            , erTimestamp = now
            , erKind = EKResponse
            , erConvLen = 1
            , erEnvelope = Nothing
            , erUsage = Nothing
            , erStop = Nothing
            , erDurationMs = Nothing
            , erHarness = Nothing
            , erCorrelation = Nothing
            , erMeta = mempty
            }
      tfwRecordAndAck h (TwoFileWrite [assistantMsg] entry)
      broadcastNewEntries mBroker paths sid model createdAt

-- | The @\/model@ command spec for single-session channels (CLI, TUI).
-- Reads 'srActive' at dispatch time and saves back to it + its on-disk
-- @session.json@.
modelCommandSpec :: ProviderRuntime -> SessionRuntime -> ModelTranscriptWriter -> CommandSpec
modelCommandSpec pr sr (ModelTranscriptWriter mw) =
  modelCommandSpecWith pr (Just <$> readIORef (srActive sr)) save mw
  where
    save m = do
      writeIORef (srActive sr) m
      saveSessionMeta (srPaths sr) m

-- | The @\/model@ command spec for multi-session surfaces (web per-request,
-- channel loops). Closes over an explicit 'SessionId' resolver + 'SealPaths'.
modelCommandSpecForSession
  :: ProviderRuntime -> SealPaths -> IO SessionId -> ModelTranscriptWriter -> CommandSpec
modelCommandSpecForSession pr paths resolveSid (ModelTranscriptWriter mw) =
  modelCommandSpecWith pr resolveMeta save mw
  where
    resolveMeta = do
      sid <- resolveSid
      loadSessionMeta paths sid
    save = saveSessionMeta paths

-- | The core spec builder, parameterized by a session-meta resolver, a save
-- action, and an optional transcript writer. Both public constructors
-- delegate here.
modelCommandSpecWith
  :: ProviderRuntime
  -> IO (Maybe SessionMeta)
  -> (SessionMeta -> IO ())
  -> Maybe (SessionId -> Text -> IO ())
  -> CommandSpec
modelCommandSpecWith pr resolveMeta save mWriter = CommandSpec
  { csName         = CommandName "model"
  , csAliases      = []
  , csGroup        = GroupModel
  , csSynopsis     = "List models and set the active session's model"
  , csParserInfo   = modelParserInfo pr resolveMeta save mWriter
  , csAvailability = InteractiveOnly
  }

modelParserInfo
  :: ProviderRuntime -> IO (Maybe SessionMeta) -> (SessionMeta -> IO ())
  -> Maybe (SessionId -> Text -> IO ()) -> ParserInfo CommandAction
modelParserInfo pr resolveMeta save mWriter =
  info (modelParser pr resolveMeta save mWriter <**> helper)
    (  progDesc "List known providers/models and choose the session's model"
    <> header   "model — inspect and set the active session's model"
    )

modelParser
  :: ProviderRuntime -> IO (Maybe SessionMeta) -> (SessionMeta -> IO ())
  -> Maybe (SessionId -> Text -> IO ()) -> Parser CommandAction
modelParser pr resolveMeta save mWriter = hsubparser
  (  command "list"
       (info (listCmd pr resolveMeta <$> optional listProvArg)
             (progDesc "List known providers, or a provider's live models"))
  <> command "use"
       (info (useCmd pr resolveMeta save mWriter <$> provArg <*> optional modelArg)
             (progDesc "Set the session's provider and model (model optional)"))
  <> command "default"
       (info (defaultCmd pr <$> provArg <*> modelArg)
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

listCmd
  :: ProviderRuntime -> IO (Maybe SessionMeta) -> Maybe Text -> CommandAction
listCmd pr resolveMeta Nothing = CommandAction $ \caps -> do
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  let cfg = fromRight defaultRuntimeConfig eCfg
  mh <- readIORef (vrHandleRef (prVault pr))
  configured <- configuredProviders mh cfg
  if null configured
    then ccSend caps "no providers configured — run /provider add <provider>"
    else mapM_ (reportProviderQuiet pr caps cfg) configured
  mActive <- resolveMeta
  let activeLine = case mActive of
        Just a  -> "active: " <> smProvider a <> "/" <> smModel a
        Nothing -> "active: (no session)"
  ccSend caps activeLine
listCmd pr _ (Just provLbl) = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      eCfg <- loadRuntimeConfig (prConfigPath pr)
      let cfg = fromRight defaultRuntimeConfig eCfg
      reportProviderLoud pr caps cfg kp

-- | Render one provider for the bare @/model list@: its label followed by
-- either the live models reachable through a resolved provider, or — if
-- resolution or the live listing fails — the configured default model as a
-- fallback so the line is never empty and never noisy. Unconfigured
-- providers are filtered out before this runs, so a failure here means the
-- daemon is down, not that the provider is unconfigured.
reportProviderQuiet
  :: ProviderRuntime -> ChannelCaps -> RuntimeConfig -> KnownProvider -> IO ()
reportProviderQuiet pr caps cfg kp = do
  let lbl   = providerLabel kp
      baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg lbl)
      ModelId dm = resolveDefaultModel (providerDefaultModel cfg lbl) lbl
  mh <- readIORef (vrHandleRef (prVault pr))
  eProv <- resolveProvider mh (prManager pr) baseUrl kp (defaultModelFor kp) (prCallCounter pr)
  eModels <- case eProv of
    Left _    -> pure (Left "unresolved")
    Right sp -> listSome sp
  case eModels of
    Left _   -> ccSend caps (lbl <> " (default model: " <> dm <> ")")
    Right [] -> ccSend caps (lbl <> " (default model: " <> dm <> ")")
    Right ms -> do
      ccSend caps (lbl <> " models (live):")
      mapM_ (\(ModelId m) -> ccSend caps ("  " <> m)) ms

-- | Render one provider for the explicit @/model list <provider>@: surfaces
-- resolution and listing failures as actionable error lines (the user asked
-- for this specific provider, so a silent fallback would hide the problem).
reportProviderLoud
  :: ProviderRuntime -> ChannelCaps -> RuntimeConfig -> KnownProvider -> IO ()
reportProviderLoud pr caps cfg kp = do
  let lbl   = providerLabel kp
      baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg lbl)
  mh <- readIORef (vrHandleRef (prVault pr))
  eProv <- resolveProvider mh (prManager pr) baseUrl kp (defaultModelFor kp) (prCallCounter pr)
  case eProv of
    Left e   -> ccSend caps ("could not list " <> lbl <> " models: " <> e)
    Right sp -> do
      eModels <- listSome sp
      case eModels of
        Left e   -> ccSend caps ("could not list " <> lbl <> " models: " <> e)
        Right [] -> ccSend caps (lbl <> " has no models available")
        Right ms -> do
          ccSend caps (lbl <> " models (live):")
          mapM_ (\(ModelId m) -> ccSend caps ("  " <> m)) ms

useCmd
  :: ProviderRuntime
  -> IO (Maybe SessionMeta)
  -> (SessionMeta -> IO ())
  -> Maybe (SessionId -> Text -> IO ())
  -> Text
  -> Maybe Text
  -> CommandAction
useCmd pr resolveMeta save mWriter provLbl mModel = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      model <- case mModel of
        Just m  -> pure m
        Nothing -> do
          eCfg <- loadRuntimeConfig (prConfigPath pr)
          let cfg = fromRight defaultRuntimeConfig eCfg
              ModelId m = resolveDefaultModel (providerDefaultModel cfg (providerLabel kp)) (providerLabel kp)
          pure m
      mActive <- resolveMeta
      case mActive of
        Nothing -> ccSend caps "no active session to update"
        Just m0 -> do
          let lbl = providerLabel kp
              m1 = m0 { smProvider = lbl, smModel = model }
              confirm = "session model set to " <> lbl <> "/" <> model
          save m1
          case mWriter of
            Just w  -> w (smId m1) confirm
            Nothing -> pure ()
          ccSend caps confirm

defaultCmd :: ProviderRuntime -> Text -> Text -> CommandAction
defaultCmd pr provLbl model = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      res <- updateRuntimeConfig (prConfigPath pr)
               (upsertProvider (providerLabel kp) (\p -> p { pcDefaultModel = Just model }))
      case res of
        Left e   -> ccSend caps e
        Right () -> ccSend caps (providerLabel kp <> " default model set to " <> model)

unknownProviderMsg :: Text -> Text
unknownProviderMsg lbl =
  "unknown provider: " <> lbl <> " (known: "
    <> T.intercalate ", " (map providerLabel knownProviders) <> ")"
