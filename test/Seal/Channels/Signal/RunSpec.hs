{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.Signal.RunSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Control.Concurrent (threadDelay)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime(..), fromGregorian)
import Options.Applicative
  ( defaultPrefs, execParserPure, renderFailure, ParserResult (..), info, progDesc )
import Test.Hspec

import Seal.Agent.Env (AgentEnv (..))
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channels.Signal.Run (runSignalLoop)
import Seal.Channels.Signal.Transport (mkMockSignalTransport)
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..), mkRegistry, Registry )
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.MessageSource (mkUserId)
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Config.Paths (SealPaths (..))
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.ISA.Opcode (localBackend)
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class
  ( CompletionResponse (..), ContentBlock (..), Provider (..), SomeProvider (..)
  , StopReason (..), Usage (..) )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Signal.Config (SignalAccount (..), mkSignalAccount)
import Seal.Tabs (newTabsHandle)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Types.App (runApp)
import Seal.Types.Command (Command (..), pCommand)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Ingest (emptyChain)

-- A scripted provider that replies "hi from model" to any plain text.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      []     -> pure (Right (CompletionResponse [CbText "hi from model"] StopEnd (Usage 0 0)))

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
spec = do
  describe "Seal.Types.Command.pCommand" $ do
    let cmdInfo = info pCommand (progDesc "seal subcommand")
    it "parses 'signal' as CommandSignal Supervised" $
      case execParserPure defaultPrefs cmdInfo ["signal"] of
        Success cmd -> cmd `shouldBe` CommandSignal Supervised
        other       -> expectationFailure ("expected CommandSignal Supervised, got: " <> show other)

    it "parses 'telegram' as CommandTelegram Supervised" $
      case execParserPure defaultPrefs cmdInfo ["telegram"] of
        Success cmd -> cmd `shouldBe` CommandTelegram Supervised
        other       -> expectationFailure ("expected CommandTelegram Supervised, got: " <> show other)

    it "renders --help for the signal subcommand" $
      case execParserPure defaultPrefs cmdInfo ["signal", "--help"] of
        Failure f -> T.unpack (T.pack (fst (renderFailure f "seal"))) `shouldContain` "signal"
        other     -> expectationFailure ("expected Failure for --help, got: " <> show other)

  describe "Seal.Channels.Signal.Run.runSignalLoop" $ do
    it "routes /ping (dispatch) and a plain message (runTurn) over a mock Signal channel; threads MessageSource into the transcript erMeta" $ do
      let envPing  = signalEnvelope "+15551234567" (Just "abc") "/ping"
          envHello = signalEnvelope "+15551234567" (Just "abc") "hello"
          envDrop  = signalEnvelope "+19999999999" Nothing "ignored"  -- non-allow-listed
      (transport, getCaptured) <- mkMockSignalTransport [envDrop, envPing, envHello]
      providerRef <- newIORef [CompletionResponse [CbText "hi from model"] StopEnd (Usage 0 0)]
      (tHandle, readTranscript) <- fakeTwoFileTranscript
      let provider = SomeProvider (ScriptProvider providerRef)
          model    = ModelId "test"
          sid      = either (error "sid") id (mkSessionId "sig-test")
          isaReg   = ISA.mkRegistry []
          allow    = AllowOnly (Set.fromList [either (error "uid") id (mkUserId "+15551234567")])
      appEnv <- mkEnv defaultConfig
      approvals <- newApprovalCache
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
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  }
            in runApp appEnv (runTurn agentEnv body)
          plainHandler h mSrc body = case mSrc of
            Just ms -> runOneTurn h ms body
            Nothing -> pure ()
      tabsH <- newTabsHandle
      askReply <- newAskReplyStore 0
      let meta = SessionMeta sid "ollama" "test" "signal" Nothing
                   (UTCTime (fromGregorian 2026 1 1) 0)
                   (UTCTime (fromGregorian 2026 1 1) 0)
      activeRef <- newIORef meta
      let sr = SessionRuntime
            { srPaths = SealPaths
                { spHome = "", spState = "", spConfig = "", spKeys = "" }
            , srConfigPath = ""
            , srActive = activeRef
            }
      runSignalLoop testRegistry emptyChain (allow, 1998) acct transport tabsH askReply sr plainHandler
      -- The plain turn is forked so the loop can keep receiving; give the
      -- forked thread a moment to finish its runTurn + chSend before reading
      -- the captured sends.
      threadDelay 100000  -- 100ms
      -- /ping dispatched → pong sent via the handle
      -- hello routed → "hi from model" sent via the handle
      cap <- getCaptured
      map snd cap `shouldContain` ["pong"]
      map snd cap `shouldContain` ["ollama/test> hi from model"]
      all ((== "+15551234567") . fst) cap `shouldBe` True
      -- the transcript's request entry for hello carries channel=signal + conversationId
      (_, entries) <- readTranscript
      let reqEntries = [e | e <- entries, erKind e == EKRequest]
      reqEntries `shouldSatisfy` any (\e ->
        Map.lookup "channel" (erMeta e) == Just (String "signal") &&
        Map.lookup "conversationId" (erMeta e) == Just (String "sig:+15551234567:abc"))