{-# LANGUAGE OverloadedStrings #-}
-- | Haskeline-backed CLI TUI channel. Plain (non-slash) input is routed through
-- the agent loop ('runTurn'); slash commands and rejections flow through the
-- existing command registry.
module Seal.Channel.Cli
  ( runCliTui
  , interpretDisposition
  , handlePlain
  , resolveSessionProvider
  , mkSessionAgentEnv
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Console.Haskeline
  ( InputT
  , Settings (..)
  , defaultSettings
  , getInputLine
  , getPassword
  , noCompletion
  , runInputT
  )
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))

import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.File (loadFileConfig, providerBaseUrl, retrievalMaxScanBytes,
                          defaultRetrievalMaxScanBytes)
import Seal.Config.Paths (SealPaths (..), auditedLogPath, sessionDir)
import Seal.Core.Types (ModelId (..), SessionId)
import Seal.Handles.Audited (AuditedHandle, withAuditedLog)
import Seal.Handles.Transcript
  ( TwoFileHandle, TwoFileHandle (..), withTwoFileTranscript )
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Ops.File (fileReadOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class (SomeProvider (..))
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry (parseProvider, resolveProvider)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))

-- | Map a 'Disposition' to its channel effect.
--
-- Extracted for testability: callers supply a 'ChannelCaps' and a handler for
-- plain (agent-bound) text; no Haskeline context is required. Routing plain
-- text through an injected handler keeps this function testable without a live
-- provider.
interpretDisposition :: ChannelCaps -> (Text -> IO ()) -> Disposition -> IO ()
interpretDisposition caps plainHandler = \case
  DispatchAction a -> runCommandAction a caps
  ShowText t       -> ccSend caps t
  PlainMessage t   -> plainHandler t
  Rejected msg     -> ccSend caps msg

-- | Drive one plain-text turn through the agent loop. The seam the wiring test
-- asserts against: a 'PlainMessage' becomes @runApp env (runTurn agentEnv t)@.
handlePlain :: AgentEnv -> Env -> Text -> IO ()
handlePlain agentEnv env t = runApp env (runTurn agentEnv t)

-- | Resolve the active session's provider from the vault, or explain why not.
-- Key bytes never surface: 'resolveProvider' returns an opaque 'SomeProvider'.
resolveSessionProvider
  :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveSessionProvider pr meta =
  case parseProvider (smProvider meta) of
    Nothing -> pure (Left ("unknown provider in session: " <> smProvider meta))
    Just kp -> do
      eCfg <- loadFileConfig (prConfigPath pr)
      let baseUrl = fromMaybe defaultOllamaBaseUrl (either (const Nothing) (`providerBaseUrl` "ollama") eCfg)
          model   = ModelId (smModel meta)
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model)

-- | Build the per-turn 'AgentEnv' for a session's selected provider+model.
mkSessionAgentEnv
  :: ChannelCaps -> SomeProvider -> Text -> ModelId -> SessionId
  -> ISA.Registry -> TwoFileHandle -> AuditedHandle -> AgentEnv
mkSessionAgentEnv caps provider provLabel model sid isaReg tHandle audited = AgentEnv
  { aeProvider   = provider
  , aeProviderLabel = provLabel
  , aeModel      = model
  , aeRegistry   = isaReg
  , aeTranscript = tHandle
  , aeAudited    = audited
  , aeBackend    = localBackend
  , aeCaps       = caps
  , aeSession    = sid
  , aeMaxTurns   = 12
  }

-- | Run the Haskeline TUI loop.
--
-- History is persisted at @\<state\>\/history@; the agent transcript is written
-- under the session directory (@\<state\>\/sessions\/\<id\>\/transcript.jsonl@).
-- EOF (Ctrl-D) exits. The provider and model are resolved from the active
-- session on every turn so mid-session @\/model use@ changes take effect
-- immediately.
runCliTui
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime
  -> Registry -> PreprocessChain -> IO ()
runCliTui paths rt pr sr registry chain = do
  active0 <- readIORef (srActive sr)
  let histFile       = spState paths </> "history"
      sessionDirPath = sessionDir paths (smId active0)
      innerSettings  = (defaultSettings :: Settings IO) { complete = noCompletion }
      hlSettings     = innerSettings { historyFile = Just histFile }
      caps = ChannelCaps
        { ccSend         = putStrLn . T.unpack
        , ccPrompt       = \prompt ->
            runInputT innerSettings $ do
              mLine <- getInputLine (T.unpack prompt)
              pure (maybe "" T.pack mLine)
        , ccPromptSecret = \prompt ->
            runInputT innerSettings $ do
              mPass <- getPassword (Just '*') (T.unpack prompt)
              pure (maybe "" T.pack mPass)
        }
  -- Startup diagnostic: show which provider+model the active session will use
  -- for plain-text turns (resolved from config at session creation).
  ccSend caps ("session: " <> smProvider active0 <> " / " <> smModel active0)
  wsRoot <- WorkspaceRoot <$> getCurrentDirectory
  appEnv <- mkEnv defaultConfig
  -- Resolve the operator-configured retrieval ceiling (the hard upper bound
  -- on bytes scanned per FILE_READ). Falls back to the 128 KiB default when
  -- the [retrieval] section is absent. Loaded once at startup; a config
  -- change takes effect on the next session.
  eCfg <- loadFileConfig (prConfigPath pr)
  let operatorCeiling = either (const defaultRetrievalMaxScanBytes) retrievalMaxScanBytes eCfg
  -- The two-file transcript bracket wraps the whole loop so every turn shares
  -- one writer. The opcodes (and thus the ISA registry) close over `caps`, so
  -- they are built here where both `caps` and the transcript handle are in
  -- scope. Legacy sessions with an existing @transcript.jsonl@ are left
  -- untouched (the legacy read path handles them); new sessions get the
  -- @conversation.jsonl@ + @entries.jsonl@ pair. The Audited log bracket wraps
  -- the same scope so Audited opcodes (Memory/Skills/AgentDef/Config — added in
  -- M2+) write to both the session transcript and the cross-session Audited log.
  withTwoFileTranscript sessionDirPath $ \tHandle ->
    withAuditedLog (auditedLogPath paths) $ \audited -> do
      let isaReg = ISA.mkRegistry
            [ showHumanOp caps
            , askHumanOp caps
            , fileReadOp wsRoot operatorCeiling
            , secretGetOp rt
            ]
          plainHandler t = do
            meta  <- readIORef (srActive sr)
            eprov <- resolveSessionProvider pr meta
            case eprov of
              Left err            -> ccSend caps err
              Right (prov, model) ->
                handlePlain
                  (mkSessionAgentEnv caps prov (smProvider meta) model (smId meta) isaReg tHandle audited)
                  appEnv t
      runInputT hlSettings (loop caps plainHandler)
  where
    loop :: ChannelCaps -> (Text -> IO ()) -> InputT IO ()
    loop caps plainHandler = do
      mLine <- getInputLine "> "
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          d <- liftIO $ ingest registry chain (RawInbound (T.pack line))
          liftIO $ interpretDisposition caps plainHandler d
          loop caps plainHandler
