{-# LANGUAGE OverloadedStrings #-}
-- | Haskeline-backed CLI TUI channel. Plain (non-slash) input is routed through
-- the agent loop ('runTurn'); slash commands and rejections flow through the
-- existing command registry.
module Seal.Channel.Cli
  ( runCliTui
  , interpretDisposition
  , handlePlain
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Either (fromRight)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client.TLS (newTlsManager)
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
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Handles.Transcript (withTranscript)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Ops.File (fileReadOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Anthropic (mkAnthropic)
import Seal.Providers.Class (SomeProvider (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Secrets (mkApiKey)
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)
import Seal.Vault.Commands (VaultRuntime)

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

-- | Run the Haskeline TUI loop.
--
-- History is persisted at @\<state\>\/history@; the agent transcript is appended
-- to @\<state\>\/transcript.jsonl@. EOF (Ctrl-D) exits.
--
-- The provider is resolved best-effort from @ANTHROPIC_API_KEY@: when present a
-- TLS-backed Anthropic provider drives plain text; when absent, plain text gets
-- a one-line hint instead so the REPL still runs.
runCliTui :: SealPaths -> VaultRuntime -> Registry -> PreprocessChain -> IO ()
runCliTui paths rt registry chain = do
  let histFile       = spState paths </> "history"
      transcriptPath = spState paths </> "transcript.jsonl"
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
  -- Resolve the provider once, before the loop. Key acquisition + manager
  -- creation belong in startup, not in the per-turn handler.
  mProvider <- lookupEnv "ANTHROPIC_API_KEY" >>= \case
    Nothing     -> pure Nothing
    Just keyStr -> do
      mgr <- newTlsManager
      let apiKey = mkApiKey (TE.encodeUtf8 (T.pack keyStr))
      pure (Just (SomeProvider (mkAnthropic mgr apiKey model)))
  wsRoot <- WorkspaceRoot <$> getCurrentDirectory
  appEnv <- mkEnv defaultConfig
  -- The transcript bracket wraps the whole loop so every turn shares one writer.
  -- The opcodes (and thus the ISA registry) close over `caps`, so they are built
  -- here where both `caps` and the transcript handle are in scope.
  withTranscript transcriptPath $ \tHandle -> do
    let isaReg = ISA.mkRegistry
          [ showHumanOp caps
          , askHumanOp caps
          , fileReadOp wsRoot
          , secretGetOp rt
          ]
        plainHandler t = case mProvider of
          Nothing ->
            ccSend caps
              "No provider configured — set ANTHROPIC_API_KEY to chat with the agent."
          Just provider ->
            handlePlain (mkAgentEnv caps provider isaReg tHandle) appEnv t
    runInputT hlSettings (loop caps plainHandler)
  where
    model = ModelId "claude-opus-4-8"
    -- "cli" is a literal valid session id, so the Left case is unreachable.
    sid = fromRight (error "unreachable: literal session id")
                    (mkSessionId "cli")
    mkAgentEnv caps provider isaReg tHandle = AgentEnv
      { aeProvider   = provider
      , aeModel      = model
      , aeRegistry   = isaReg
      , aeTranscript = tHandle
      , aeBackend    = localBackend
      , aeCaps       = caps
      , aeSession    = sid
      , aeMaxTurns   = 12
      }
    loop :: ChannelCaps -> (Text -> IO ()) -> InputT IO ()
    loop caps plainHandler = do
      mLine <- getInputLine "> "
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          d <- liftIO $ ingest registry chain (RawInbound (T.pack line))
          liftIO $ interpretDisposition caps plainHandler d
          loop caps plainHandler
