{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | Tests for the @seal serve@ interrupt/shutdown logging: when the operator
-- kills the server with Ctrl-C (SIGINT), the log must carry a marker line plus
-- an inventory of the live sub-agents whose forked threads die with the
-- process. These tests drive the handler directly (no real signal): GHC's RTS
-- delivers SIGINT to the main thread as 'UserInterrupt', so raising that
-- exception is exactly what Ctrl-C does.
module Seal.Command.ShutdownSpec (spec) where

import Control.Concurrent (myThreadId)
import Control.Exception (AsyncException (..), try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Test.Hspec

import Katip (Severity (..), Scribe (..), permitItem, jsonFormat, Verbosity (V2))

import Seal.Agent.Def.Types (AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Delegation (SubagentId (..))
import Seal.Agent.Runtime.Registry
  ( AgentRuntime, newAgentRuntime, registerRunningAgent, listAgents )
import Seal.Command.Shutdown
  ( handleServeInterrupt, isLiveSubagent, renderLiveSubagents, shutdownExitCode )
import Seal.Core.Types (SessionId, mkSystemSessionId)
import Seal.Logging.Logger (SealLogger, closeSealLogger, newSealLoggerWithScribe)

-- Fixed ids — they only need to be distinguishable in the rendered inventory.
sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "reviewer" of
  Right aid -> aid
  Left _    -> AgentDefId "reviewer"

parentSession :: SessionId
parentSession = mkSystemSessionId "20260101-000000-001"

childSession :: SessionId
childSession = mkSystemSessionId "20260101-000100-002"

-- | A capture scribe: collects every rendered log item into an 'IORef'.
mkCaptureScribe :: IO (Scribe, IORef [Text])
mkCaptureScribe = do
  ref <- newIORef []
  let scribe = Scribe
        { liPush = \item ->
            let rendered = jsonFormat False V2 item
            in modifyIORef' ref (T.pack (show rendered) :)
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  pure (scribe, ref)

-- | Run an action with a logger whose output is captured. The logger is
-- closed (flushing katip's scribe queue) before the captured lines are
-- returned, so assertions never race the queue.
withCaptureLogger :: (SealLogger -> IO a) -> IO (a, [Text])
withCaptureLogger action = do
  (scribe, ref) <- mkCaptureScribe
  logger <- newSealLoggerWithScribe scribe DebugS
  result <- action logger
  closeSealLogger logger
  lines_ <- readIORef ref
  pure (result, lines_)

-- | A runtime holding one Running child: 'registerRunningAgent' only stores
-- the thread id, so recording the test's own thread forks nothing.
registerSampleChild :: AgentRuntime -> IO ()
registerSampleChild rt = do
  tid <- myThreadId
  registerRunningAgent rt sampleDefId (SubagentId "reviewer-deadbeef")
    parentSession childSession 1 tid

spec :: Spec
spec = describe "Seal.Command.Shutdown" $ do
  describe "handleServeInterrupt" $ do
    it "logs a shutdown marker naming the live sub-agent, then exits 130" $ do
      rt <- newAgentRuntime
      registerSampleChild rt
      ref <- newIORef (Just rt)
      (exit, logs) <- withCaptureLogger $ \logger ->
        try @ExitCode (handleServeInterrupt logger ref UserInterrupt)
      exit `shouldBe` Left (ExitFailure 130)
      logs `shouldSatisfy` any ("SIGINT received (Ctrl-C)" `T.isInfixOf`)
      logs `shouldSatisfy` any
        ("1 live sub-agent will be killed with this process" `T.isInfixOf`)
      logs `shouldSatisfy` any ("reviewer-deadbeef" `T.isInfixOf`)
      logs `shouldSatisfy` any ("20260101-000100-002" `T.isInfixOf`)

    it "reports 'no live sub-agents' when the runtime has none" $ do
      rt <- newAgentRuntime
      ref <- newIORef (Just rt)
      (exit, logs) <- withCaptureLogger $ \logger ->
        try @ExitCode (handleServeInterrupt logger ref UserInterrupt)
      exit `shouldBe` Left (ExitFailure 130)
      logs `shouldSatisfy` any ("no live sub-agents" `T.isInfixOf`)

    it "says so when interrupted before the runtime existed" $ do
      ref <- newIORef Nothing
      (exit, logs) <- withCaptureLogger $ \logger ->
        try @ExitCode (handleServeInterrupt logger ref UserInterrupt)
      exit `shouldBe` Left (ExitFailure 130)
      logs `shouldSatisfy` any ("startup" `T.isInfixOf`)

    it "re-raises other async exceptions instead of swallowing them" $ do
      ref <- newIORef Nothing
      (raised, _logs) <- withCaptureLogger $ \logger ->
        try @AsyncException (handleServeInterrupt logger ref ThreadKilled)
      raised `shouldBe` Left ThreadKilled

  describe "renderLiveSubagents" $ do
    it "renders one line per live child with its id, sessions, depth and status" $ do
      rt <- newAgentRuntime
      registerSampleChild rt
      insts <- listAgents rt
      renderLiveSubagents insts `shouldBe`
        [ "  sub-agent reviewer-deadbeef parent=20260101-000000-001\
          \ child=20260101-000100-002 depth=1 status=running" ]

    it "counts only children whose worker thread is still alive" $ do
      rt <- newAgentRuntime
      registerSampleChild rt
      insts <- listAgents rt
      map isLiveSubagent insts `shouldBe` [True]

  describe "shutdownExitCode" $ do
    it "is 128 + SIGINT(2), so scripts see an interrupted server, not a clean exit" $
      shutdownExitCode `shouldBe` ExitFailure 130
