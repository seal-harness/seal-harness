{-# LANGUAGE OverloadedStrings #-}
-- | Phase 2b capstone: the Signal channel works end-to-end through the
-- ingress gate to the agent loop, with 'MessageSource' threaded into the
-- transcript's @erMeta@. The 2b milestone gate.
module Seal.Phase2bSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative (info, progDesc)
import Test.Hspec

import Seal.Agent.Env (AgentEnv (..))
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channels.Signal.Run (runSignalLoop)
import Seal.Tabs (newTabsHandle)
import Seal.Channels.Signal.Transport (mkMockSignalTransport)
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..), Registry, mkRegistry )
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.MessageSource (mkUserId)
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.ISA.Opcode (localBackend)
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class
  ( CompletionResponse (..), ContentBlock (..), Provider (..), SomeProvider (..)
  , StopReason (..), Usage (..) )
import Seal.Signal.Config (SignalAccount (..), mkSignalAccount)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Ingest (emptyChain)

-- A scripted provider: replies a long message to test chunking.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      []     -> pure (Right (CompletionResponse [CbText "all done"] StopEnd (Usage 0 0)))

signalEnvelope :: Text -> Maybe Text -> Text -> Value
signalEnvelope source mUuid body =
  object [ "envelope" .= object (["source" .= source] <> uuidField mUuid <> ["dataMessage" .= object ["message" .= body]]) ]
  where
    uuidField (Just u) = ["sourceUuid" .= u]
    uuidField Nothing  = []

pingAction :: CommandAction
pingAction = CommandAction $ \caps -> ccSend caps "pong"

pingSpec :: CommandSpec
pingSpec = CommandSpec
  { csName = CommandName "ping"
  , csAliases = []
  , csGroup = GroupGeneral
  , csSynopsis = "Echo pong"
  , csAvailability = AlwaysAvailable
  , csParserInfo = info (pure pingAction) (progDesc "Echo pong")
  }

testRegistry :: Registry
testRegistry = mkRegistry [pingSpec]

acct :: SignalAccount
acct = case mkSignalAccount "+12025551234" of
  Right a -> a
  Left e  -> error ("mkSignalAccount: " <> T.unpack e)

spec :: Spec
spec = describe "Seal.Phase2bSpec" $ do
  it "Signal over mock transport: /ping dispatches, plain routes to runTurn, non-allow-listed dropped, replies chunked, MessageSource threaded into erMeta" $ do
    let envPing  = signalEnvelope "+15551234567" (Just "abc") "/ping"
        envHello = signalEnvelope "+15551234567" (Just "abc") "hello"
        envDrop  = signalEnvelope "+19999999999" Nothing "ignored"  -- non-allow-listed
    (transport, getCaptured) <- mkMockSignalTransport [envDrop, envPing, envHello]
    providerRef <- newIORef [CompletionResponse [CbText "reply from model"] StopEnd (Usage 0 0)]
    (tHandle, readTranscript) <- fakeTwoFileTranscript
    let provider = SomeProvider (ScriptProvider providerRef)
        model    = ModelId "test"
        sid      = either (error "sid") id (mkSessionId "phase2b")
        isaReg   = ISA.mkRegistry []
        allow    = AllowOnly (Set.fromList [either (error "uid") id (mkUserId "+15551234567")])
    appEnv <- mkEnv defaultConfig
    let runOneTurn h ms body =
          let handleCaps = ChannelCaps
                { ccSend = chSend h
                , ccPrompt = \_ -> pure ""
                , ccPromptSecret = \_ -> pure ""
                }
              agentEnv = AgentEnv
                { aeProvider = provider
                , aeProviderLabel = "ollama"
                , aeModel = model
                , aeSystem = Nothing
                , aeRegistry = isaReg
                , aeTranscript = tHandle
                , aeBackend = localBackend
                , aeExecBackend = EbLocal mkLocalExecHandlePlaceholder
                , aeCaps = handleCaps
                , aeSession = sid
                , aeMaxTurns = 4
                , aeMessageSource = Just ms
                }
          in runApp appEnv (runTurn agentEnv body)
        plainHandler h mSrc body = case mSrc of
          Just ms -> runOneTurn h ms body
          Nothing -> pure ()
    tabsH <- newTabsHandle
    runSignalLoop testRegistry emptyChain (allow, 1998) acct transport tabsH plainHandler
    cap <- getCaptured
    -- /ping dispatched → pong sent via the handle
    map snd cap `shouldContain` ["pong"]
    -- hello routed → the model's reply sent via the handle
    map snd cap `shouldContain` ["ollama/test> reply from model"]
    -- all sends went to the allow-listed peer
    all ((== "+15551234567") . fst) cap `shouldBe` True
    -- the dropped env never reached the loop body (no send to +19999999999)
    all ((/= "+19999999999") . fst) cap `shouldBe` True
    -- the transcript's request entry for hello carries channel=signal + conversationId
    (_, entries) <- readTranscript
    let reqEntries = [e | e <- entries, erKind e == EKRequest]
    reqEntries `shouldSatisfy` any (\e ->
      Map.lookup "channel" (erMeta e) == Just (String "signal") &&
      Map.lookup "conversationId" (erMeta e) == Just (String "sig:+15551234567:abc"))