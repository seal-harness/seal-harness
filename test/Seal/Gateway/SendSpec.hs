{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
module Seal.Gateway.SendSpec (spec) where

import Control.Exception (catch, SomeException, throwIO)
import Seal.Session.ExecCache (newSessionExecCache)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void, when)
import Data.Aeson qualified as A
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Vector qualified as V
import Data.Either (isLeft)
import Data.Default (def)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text.Encoding qualified as TE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Options.Applicative qualified as Opt
import Options.Applicative (ParserResult (..))
import Test.Hspec

import Seal.Agent.Def.Types (AgentDefId, mkAgentDefId)
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Channel.Cli (newBackends)
import Seal.Core.Backends (Backends (bRunRecords))
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionWorkdir, sshAgentsDir)
import Seal.Core.Types (ModelId (..), mkSessionId, SessionId)
import Seal.Core.TurnEngine (TurnAdapter (..), TurnDeps (..), TurnOutcome (..), buildStartWiring, runSessionTurn)
import Seal.Gateway.Send
  ( SendDeps (..), SendOutcome (..), ensureTabForSession, handleSend, webAskCaps
  , handleAnswerTextDelivery, parseAnswerBody, newSessionWakeMutex, mkWebTurnDeps )
import Seal.Gateway.StreamBroker
  ( BrokerEvent (..), newStreamBroker, subscribe, thinkingSessions )
import Seal.Logging.Logger (testSealLogger)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.AskReply
  ( QuestionOption (..), deliverAnswer, newAskReplyStore
  , newApprovalCache, pendingForSession, PendingQuestionInfo (..)
  , AskReply (..), ApprovalScope (..), askIdText, askHumanWithOptions )
import Data.ByteString.Lazy qualified as BL
import Seal.Handles.Tab (TabKind (KindAi, KindProvider))
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Ingest (emptyChain)
import Seal.Providers.Class
import Seal.Command.Spec (CommandSpec (..), mkRegistry)
import Seal.Security.Policy qualified as Policy (AutonomyLevel (Full))
import Seal.Security.Vault (VaultHandle)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.Session.Lock (newReplyRegistry, newSessionLocks, sessionTurnInFlight)
import Seal.Tools.Exec.Abort (newSessionAbortRegistry, lookupOrCreateAbortFlag, isAborted, setSessionAbort)
import Seal.Transcript.Conv (readConversation)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))
import Seal.Handles.Transcript
  ( IndexedTranscriptWrite (..), appendCompletionToSidecar, itwRecordAndAck
  , pendingCompletionCount, withIndexedTranscript )
import Data.ByteString qualified as BS
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.Tabs (newTabsHandle, insertTabH, snapshotTabs)
import Seal.Tabs.Types (TabRef (BoundSession), tlTabs, tRef, tabCount)
import Seal.Command.Tab (tabCommandSpec, noTabCloseNotifier)
import Seal.Command.Stop (stopCommandSpecForSession, mkStopTranscriptWriter, noStopTranscriptWriter)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Memory.Embedding (nullEmbeddingBackend)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) 0

mkSid :: String -> SessionId
mkSid s = case mkSessionId (T.pack s) of
  Right x -> x
  Left _  -> error ("bad sid: " <> s)

-- | A fake provider that returns one canned assistant reply per turn.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])
instance Provider ScriptProvider where
  complete (ScriptProvider ref) _ = do
    responses <- readIORef ref
    case responses of
      (r : rest) -> writeIORef ref rest >> pure (Right r)
      []         -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | A fake provider that records every 'CompletionRequest' it receives,
-- so a test can assert what conversation the model was actually given.
-- It can also be gated: the FIRST call blocks until the gate is opened,
-- every later call answers immediately (a post-wake turn must not block
-- again).
data RecordingProvider = RecordingProvider
  { rpRequests :: IORef [CompletionRequest]
  , rpFirst    :: IORef Bool
  , rpGate     :: Maybe (MVar ())
  }

instance Provider RecordingProvider where
  complete rp req = do
    modifyIORef' (rpRequests rp) (++ [req])
    isFirst <- atomicModifyIORef' (rpFirst rp) (False,)
    when isFirst $ for_ (rpGate rp) takeMVar
    pure (Right (CompletionResponse [CbText "ok"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | The text blocks of a completion request's messages.
requestTexts :: CompletionRequest -> [T.Text]
requestTexts req = [t | Message _ bs <- crMessages req, CbText t <- bs]

-- | Seed a session's on-disk conversation with @n@ messages of @size@
-- characters each. A realistic size matters: the reader that builds the
-- model's context loses the race to the writer only when the
-- conversation is big enough for the two to be close (see the diagnosis
-- doc §2).
seedConversation :: SealPaths -> SessionId -> Int -> Int -> IO ()
seedConversation paths sid n size =
  withIndexedTranscript (sessionDir paths sid) $ \h -> do
    let msgs = [Message User [CbText (T.replicate size "x")] | _ <- [1 .. n]]
        entry = EntryRecord
          { erId = ""
          , erTimestamp = sampleTime
          , erKind = EKRequest
          , erConvLen = length msgs
          , erEnvelope = Nothing
          , erUsage = Nothing
          , erStop = Nothing
          , erDurationMs = Nothing
          , erHarness = Nothing
          , erCorrelation = Nothing
          , erMeta = Map.empty
          }
    itwRecordAndAck h (IndexedTranscriptWrite msgs entry)

-- | A fake provider that always throws a synchronous exception. Used to
-- test that the bracket-based idle broadcast fires even when the turn dies.
data ThrowingProvider = ThrowingProvider
instance Provider ThrowingProvider where
  complete _ _ = throwIO (userError "simulated provider crash")
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | A fake provider that blocks forever on `complete`. Used to test that
-- the bracket-based idle broadcast fires when the turn thread is killed
-- (async exception) mid-turn.
newtype BlockingProvider = BlockingProvider (MVar ())
instance Provider BlockingProvider where
  complete (BlockingProvider mv) _ = takeMVar mv >> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | A fake provider that captures the CompletionRequest's crSystem field
-- (the system prompt that actually drove the turn) into an IORef, then
-- returns one canned assistant reply. Used by the repo agents.md auto-bind
-- integration test to assert which system prompt won — zoe's or the repo's.
newtype CapturingProvider = CapturingProvider (IORef (Maybe T.Text))
instance Provider CapturingProvider where
  complete (CapturingProvider ref) req = do
    writeIORef ref (crSystem req)
    pure (Right (CompletionResponse [CbText "ok"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | Extract the "status" field from a BeActivity's Value, if it's a
-- harness-status activity. Used to assert thinking/idle broadcasts.
harnessStatus :: BrokerEvent -> Maybe T.Text
harnessStatus (BeActivity _ v) = do
  o <- asObject v
  A.String "harness-status" <- KeyMap.lookup (fromText "kind") o
  A.String status <- KeyMap.lookup (fromText "status") o
  pure status
harnessStatus _ = Nothing

-- | Check whether any collected event carries the given harness status.
hasStatus :: T.Text -> [BrokerEvent] -> Bool
hasStatus expected = any (\e -> harnessStatus e == Just expected)

-- | Poll an IO action until the predicate holds, or timeout after the
-- given microseconds (retrying every 10ms).
waitFor :: Int -> IO a -> (a -> Bool) -> IO Bool
waitFor totalWaitUs readAction predicate = go totalWaitUs
  where
    stepUs = 10000
    go remaining
      | remaining <= 0 = pure False
      | otherwise = do
          val <- readAction
          if predicate val
            then pure True
            else do
              threadDelay stepUs
              go (remaining - stepUs)

-- | Local alias for mkAgentDefId (avoids an extra import line in the test).
mkAgentDefId' :: T.Text -> Either T.Text AgentDefId
mkAgentDefId' = mkAgentDefId

asObject :: A.Value -> Maybe A.Object
asObject (A.Object o) = Just o
asObject _ = Nothing

-- | Build a minimal SendDeps with the script provider + a fresh tabsH
-- rooted at the temp dir. The sdTabsHandle is left unset (use record
-- update in the test: `baseDeps { sdTabsHandle = tabsH }`).
mkSendDeps :: SealPaths -> IORef [CompletionResponse] -> IO SendDeps
mkSendDeps paths providerRef = mkSendDepsWith paths resolveStub
  where
    resolveStub _ = pure (Right (SomeProvider (ScriptProvider providerRef), ModelId "llama3.2"))

-- | Build SendDeps with a custom provider resolve function. Used by tests
-- that need a specific provider (e.g. a throwing provider to test the
-- bracket-based idle broadcast).
mkSendDepsWith :: SealPaths -> (SessionMeta -> IO (Either T.Text (SomeProvider, ModelId))) -> IO SendDeps
mkSendDepsWith paths resolveStub = do
  logger <- testSealLogger
  let configRoot = spConfig paths
      stateRoot  = spState paths
      sessionRoot = stateRoot </> "sessions"
  createDirectoryIfMissing True stateRoot
  createDirectoryIfMissing True configRoot
  createDirectoryIfMissing True sessionRoot
  ensureConfigRepo configRoot
  let repo = openConfigRepo configRoot
  backends <- newBackends (SealPaths { spHome = configRoot, spState = configRoot </> "state", spConfig = configRoot, spKeys = configRoot </> "keys", spCache = configRoot </> "cache" }) repo nullEmbeddingBackend
  wakeMutex <- newSessionWakeMutex
  reg   <- newHarnessRegistry
  tmuxR <- mkRealTmuxRunner
  askReply <- newAskReplyStore 0
  approvals <- newApprovalCache
  testReplies <- newReplyRegistry
  testLocks <- newSessionLocks
  testAbortReg <- newSessionAbortRegistry
  let activeMeta = SessionMeta (mkSid "active") "ollama" "llama3.2" "cli" Nothing Nothing Nothing Nothing True Nothing sampleTime sampleTime
  activeRef <- newIORef activeMeta
  let sr = SessionRuntime { srPaths = paths, srConfigPath = configRoot </> "config.toml", srActive = activeRef }
  -- A real ProviderRuntime whose config path is nonexistent (loadRuntimeConfig
  -- fails -> defaults). The vault ref holds Nothing so resolveSessionProvider
  -- would fail — but sdResolve is stubbed, so the vault is never consulted.
  vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  execCache <- newSessionExecCache
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir paths)
  let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
      pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
      sendDeps = SendDeps
        { sdPaths      = paths
        , sdVault      = rt
        , sdRepoReg    = fakeRepoRegistryHandle
        , sdAgentReg   = agentRegH
        , sdProvider   = pr
        , sdSession    = sr
        , sdBackends   = backends
        , sdConfigRepo = repo
        , sdPreprocess = emptyChain
        , sdRegistry   = mkRegistry []
        , sdResolve    = resolveStub
        , sdAutonomy   = Policy.Full
        , sdBroker     = Nothing
        , sdHarnessRegistry = reg
        , sdTmuxRunner  = tmuxR
        , sdHttpManager = Just mgr
        , sdAskReply    = askReply
        , sdApprovals   = approvals
        , sdReplies     = testReplies
        , sdLocks       = testLocks
        , sdAbortReg    = testAbortReg
        , sdTabsHandle  = error "sdTabsHandle: set via record update in the test"
        , sdLogger      = logger
        , sdIsRemote    = False
        , sdExecCache   = execCache
        , sdRemoteRunner = Nothing
        , sdHostKeyAdoption = Nothing
        , sdMkWorker    = Nothing
        , sdResolveProviderOverride = Nothing
        , sdMkWorkerStubDepth = 2
        , sdWakeMutex = wakeMutex
        , sdEnableIdleWake = True
        }
  pure sendDeps

-- | Seed a session.json on disk for the given sid, created on the given
-- channel. Used by the auto-tab tests to build a @channel="bg"@ (headless)
-- session as well as the usual @web@ one.
seedSessionChannel :: SealPaths -> Text -> SessionId -> IO ()
seedSessionChannel paths channel sid = do
  let sdir = sessionDir paths sid
  createDirectoryIfMissing True sdir
  let meta = SessionMeta sid "ollama" "llama3.2" channel Nothing Nothing Nothing Nothing True Nothing sampleTime sampleTime
  saveSessionMeta paths meta

-- | Seed a session.json on disk for the given sid (channel @web@).
seedSession :: SealPaths -> SessionId -> IO ()
seedSession paths = seedSessionChannel paths "web"

spec :: Spec
spec = describe "Seal.Gateway.Send auto-tab" $ do
  describe "ensureTabForSession" $ do
    it "inserts a BoundSession tab when none exists" $ do
      h <- newTabsHandle
      let sid = mkSid "s1"
      ensureTabForSession h KindProvider sid
      snap <- snapshotTabs h
      map tRef (tlTabs snap) `shouldBe` [BoundSession sid]

    it "is idempotent — no-op when a tab already binds the sid" $ do
      h <- newTabsHandle
      let sid = mkSid "s1"
      _ <- insertTabH h (BoundSession sid) KindAi Nothing
      ensureTabForSession h KindProvider sid
      snap <- snapshotTabs h
      length (tlTabs snap) `shouldBe` 1
      map tRef (tlTabs snap) `shouldBe` [BoundSession sid]

    it "uses the given TabKind (KindProvider vs KindAi)" $ do
      h <- newTabsHandle
      let sid = mkSid "s1"
      ensureTabForSession h KindProvider sid
      snap <- snapshotTabs h
      case tlTabs snap of
        [t] -> tRef t `shouldBe` BoundSession sid
        _   -> expectationFailure "expected exactly one tab"

    it "is race-safe: two threads, exactly one tab" $ do
      h <- newTabsHandle
      let sid = mkSid "s1"
      _ <- concurrently (ensureTabForSession h KindProvider sid) (ensureTabForSession h KindProvider sid)
        `catch` (\(_e :: SomeException) -> pure ((), ()))
      snap <- snapshotTabs h
      length (tlTabs snap) `shouldBe` 1

  describe "handleSend auto-tab" $ do
    it "Plain route -> auto-tabs after a successful turn (KindProvider)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef
          [ CompletionResponse [CbText "ok"] StopEnd (Usage 0 0) ]
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-120000-101"
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        -- The turn runs async; auto-tab happens after the turn completes.
        -- Poll for the tab to appear (up to 5 seconds).
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (case tlTabs snap of [t] -> Just (tRef t); _ -> Nothing))
          (\mRef -> mRef == Just (BoundSession sid))
        tabSeen `shouldBe` True

    it "Plain route on a channel=bg session -> runs the turn but does NOT auto-tab (shouldAutoTab)" $
      -- /bg sessions run headless: TurnEngine.shouldAutoTab keeps them out of
      -- the sidebar. The gateway's own post-turn auto-tab must respect the
      -- same predicate, or the /bg session leaks back into Active Tabs.
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef
          [ CompletionResponse [CbText "ok"] StopEnd (Usage 0 0) ]
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20261025-120000-bg01"
            convPath = sessionDir paths sid </> "conversation.jsonl"
        seedSessionChannel paths "bg" sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        -- Positive proof the turn actually ran: the scripted reply lands in
        -- the transcript. Without this, "no tab" could pass vacuously (a turn
        -- that never started cannot tab).
        replied <- waitFor 5000000
          (do exists <- doesFileExist convPath
              if not exists
                then pure False
                else do
                  raw <- BS.readFile convPath
                  let texts = [t | Message _ bs <- readConversation raw, CbText t <- bs]
                  pure ("ok" `elem` texts))
          id
        replied `shouldBe` True
        -- Now give a (buggy) post-turn auto-tab ample time to land, then
        -- assert it never does: a bg session stays headless.
        tabbed <- waitFor 1500000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (not . null)
        tabbed `shouldBe` False

    it "Plain route on a channel=web session still auto-tabs (regression guard)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef
          [ CompletionResponse [CbText "ok"] StopEnd (Usage 0 0) ]
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20261025-120000-web01"
        seedSessionChannel paths "web" sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True

    it "web /bg pin -> still an unknown command for a web session (no bg command on the gateway)" $
      -- DoD 7: /bg stays a chat-channel affordance. POST /send must keep
      -- answering "unknown command: bg" (the slash route's auto-tab
      -- behaviour for web sessions is unchanged and deliberately not
      -- asserted here).
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20261025-120000-web02"
        seedSessionChannel paths "web" sid
        outcome <- handleSend sendDeps sid "/bg hi"
        outcome `shouldBe` SendSlash "unknown command: bg" Nothing

    it "SendError (404 missing session) -> no auto-tab" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-120000-102"
        -- No session.json seeded -> 404
        outcome <- handleSend sendDeps sid "hello"
        case outcome of
          SendError 404 _ -> pure ()
          other           -> expectationFailure ("expected 404, got " <> show other)
        snap <- snapshotTabs tabsH
        tlTabs snap `shouldBe` []

    it "TabCommand route -> no auto-tab" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH, sdRegistry = mkRegistry [tabCommandSpec paths tabsH noTabCloseNotifier] }
            sid = mkSid "20260701-120000-103"
        seedSession paths sid
        outcome <- handleSend sendDeps sid "/tab list"
        case outcome of
          SendSlash _ _ -> pure ()
          other         -> expectationFailure ("expected SendSlash, got " <> show other)
        snap <- snapshotTabs tabsH
        tlTabs snap `shouldBe` []

    it "Focus route -> no auto-tab" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-120000-104"
        seedSession paths sid
        -- /0 is the terse-grammar Focus route (single tab-char)
        outcome <- handleSend sendDeps sid "/0"
        case outcome of
          SendSlash _ _ -> pure ()
          other         -> expectationFailure ("expected SendSlash, got " <> show other)
        snap <- snapshotTabs tabsH
        tlTabs snap `shouldBe` []

    it "Inject route -> no auto-tab" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-120000-105"
        seedSession paths sid
        -- /0 hello is the terse-grammar Inject route (tab-char + space + payload)
        outcome <- handleSend sendDeps sid "/0 hello"
        case outcome of
          SendSlash _ _ -> pure ()
          other         -> expectationFailure ("expected SendSlash, got " <> show other)
        snap <- snapshotTabs tabsH
        tlTabs snap `shouldBe` []

    it "CurrentTab route -> replies with the tab binding the session (no auto-tab)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-120000-106"
        seedSession paths sid
        _ <- insertTabH tabsH (BoundSession sid) KindAi Nothing
        outcome <- handleSend sendDeps sid "/tab"
        case outcome of
          SendSlash msg _ -> msg `shouldSatisfy` ("0" `T.isInfixOf`)
          other           -> expectationFailure ("expected SendSlash, got " <> show other)
        snap <- snapshotTabs tabsH
        tabCount snap `shouldBe` 1

    it "CurrentTab route with no binding tab -> 'no current tab' (no auto-tab)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-120000-107"
        seedSession paths sid
        outcome <- handleSend sendDeps sid "/tab"
        case outcome of
          SendSlash "no current tab" _ -> pure ()
          other -> expectationFailure ("expected SendSlash 'no current tab', got " <> show other)
        snap <- snapshotTabs tabsH
        tlTabs snap `shouldBe` []

    it "/tab close N does NOT auto-tab (no resurrection) and broadcasts the close" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH, sdRegistry = mkRegistry [tabCommandSpec paths tabsH noTabCloseNotifier] }
            sid = mkSid "20260701-120000-108"
        seedSession paths sid
        _ <- insertTabH tabsH (BoundSession sid) KindAi Nothing
        outcome <- handleSend sendDeps sid "/tab close 0"
        case outcome of
          SendSlash msg _ -> msg `shouldSatisfy` ("closed" `T.isInfixOf`)
          other           -> expectationFailure ("expected SendSlash, got " <> show other)
        snap <- snapshotTabs tabsH
        tabCount snap `shouldBe` 0

  describe "handleSend idle broadcast on turn death" $ do
    it "broadcasts idle (not just thinking) when the provider throws a synchronous exception" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        let throwingResolve _ = pure (Right (SomeProvider ThrowingProvider, ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths throwingResolve
        tabsH <- newTabsHandle
        broker <- newStreamBroker 10
        eventsRef <- newIORef ([] :: [BrokerEvent])
        _ <- subscribe broker (mkSid "any") (\e -> modifyIORef' eventsRef (e :)) (pure ())
        let sendDeps = baseDeps { sdTabsHandle = tabsH, sdBroker = Just broker }
            sid = mkSid "20260701-130000-201"
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        -- handleSend returns SendAssistant immediately (async). The
        -- turn runs in a background thread and will crash (throwing
        -- provider). We wait for the idle broadcast to confirm the
        -- bracket cleanup fired despite the death.
        case outcome of
          SendAssistant   -> pure ()
          other           -> expectationFailure ("expected SendAssistant, got " <> show other)
        -- Wait for the background turn to crash + broadcast idle.
        idleSeen <- waitFor 5000000 (readIORef eventsRef) (hasStatus "idle")
        idleSeen `shouldBe` True
        -- The broker should have received BOTH a thinking and an idle
        -- activity event. The idle broadcast must fire even though the
        -- turn died, because the bracket cleanup is guaranteed.
        events <- readIORef eventsRef
        let statuses = mapMaybe harnessStatus events
        statuses `shouldSatisfy` ("thinking" `elem`)
        statuses `shouldSatisfy` ("idle" `elem`)
        -- The broker's in-memory thinking set should be empty (idle
        -- was broadcast, which clears the session from the set).
        thinking <- thinkingSessions broker
        thinking `shouldBe` mempty

    it "broadcasts idle when the turn thread is killed (async exception)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        -- A provider whose complete blocks forever (so we can kill the
        -- thread from outside, simulating a process shutdown).
        blockMVar <- newEmptyMVar
        let blockingResolve _ = pure (Right (SomeProvider (BlockingProvider blockMVar), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths blockingResolve
        tabsH <- newTabsHandle
        broker <- newStreamBroker 10
        eventsRef <- newIORef ([] :: [BrokerEvent])
        _ <- subscribe broker (mkSid "any") (\e -> modifyIORef' eventsRef (e :)) (pure ())
        let sendDeps = baseDeps { sdTabsHandle = tabsH, sdBroker = Just broker }
            sid = mkSid "20260701-130000-202"
        seedSession paths sid
        -- handleSend returns immediately (async). The turn runs in a
        -- background thread with a blocking provider. We wait for the
        -- thinking broadcast, then unblock the provider to let the
        -- turn complete and broadcast idle.
        _ <- handleSend sendDeps sid "hello"
        -- Verify thinking was broadcast.
        thinkingSeen <- waitFor 5000000 (readIORef eventsRef) (hasStatus "thinking")
        thinkingSeen `shouldBe` True
        -- Unblock the provider so the turn completes and broadcasts idle.
        putMVar blockMVar ()
        -- Verify idle was broadcast despite the kill.
        idleSeen <- waitFor 5000000 (readIORef eventsRef) (hasStatus "idle")
        idleSeen `shouldBe` True
        thinking <- thinkingSessions broker
        thinking `shouldBe` mempty

    it "writes to seal.log when the turn dies (session log records the death)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        let throwingResolve _ = pure (Right (SomeProvider ThrowingProvider, ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths throwingResolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260701-130000-203"
        seedSession paths sid
        _ <- handleSend sendDeps sid "hello"
        let logFile = sessionDir paths sid </> "seal.log"
        -- The turn runs async; wait for the log file to appear (the
        -- throwing provider crashes quickly, but we need to give the
        -- background thread time to write the log entry).
        logExists <- waitFor 5000000 (doesFileExist logFile) id
        logExists `shouldBe` True
        content <- readFile logFile
        content `shouldSatisfy` \s -> "ERROR" `T.isInfixOf` T.pack s

  describe "handleSend async plain turn" $ do
    it "returns SendAssistant immediately without waiting for the LLM turn" $ do
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        -- A provider that blocks until we fill the MVar. This lets us
        -- verify handleSend returns BEFORE the turn completes.
        blockMVar <- newEmptyMVar
        let blockingResolve _ = pure (Right (SomeProvider (BlockingProvider blockMVar), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths blockingResolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260922-140000-301"
        seedSession paths sid
        -- handleSend should return immediately (async) with SendAssistant.
        outcome <- handleSend sendDeps sid "hello"
        case outcome of
          SendAssistant -> pure ()
          other -> expectationFailure ("expected SendAssistant, got " <> show other)
        -- The turn is still running (provider is blocked). Unblock it
        -- so the background thread can complete and clean up.
        putMVar blockMVar ()
        threadDelay 100000  -- let the background turn finish

  describe "webAskCaps" $ do
    it "ccPrompt with options registers a pending ask carrying the options" $ do
      store <- newAskReplyStore 0
      let sid = mkSid "ask-opts"
          opts = [ QuestionOption "main" "the default branch"
                 , QuestionOption "develop" "the integration branch"
                 ]
      caps <- webAskCaps Nothing store sid
      -- Fork the ccPrompt call (it blocks until the answer is delivered).
      done <- newEmptyMVar
      _ <- forkIO $ do
        _reply <- ccPrompt caps (AskPrompt "which branch?" opts)
        putMVar done ()
      threadDelay 10000
      -- The pending ask should carry the options.
      ps <- pendingForSession store sid
      length ps `shouldBe` 1
      case ps of
        [info] -> do
          info `shouldSatisfy` (not . T.null . pqiQuestion)
          pqiQuestion info `shouldBe` "which branch?"
          pqiOptions info `shouldBe` opts
          -- Deliver an answer to unblock the forked thread.
          _accepted <- deliverAnswer store (pqiId info) (AskReply ScopeOnce "main")
          pure ()
        _ -> expectationFailure "expected exactly one pending ask"
      takeMVar done

  describe "webAskCaps ccSend streaming (rate-limited BeEntryUpdate)" $ do
    it "ccSend coalesces rapid deltas into one BeEntryUpdate (time-gated)" $ do
      -- Regression (issue #198, part 2): webAskCaps.ccSend fired a
      -- BeEntryUpdate per provider text delta, unthrottled — each frame
      -- carrying the FULL accumulated text. A ~40-word reply produced 43
      -- WS frames (the log's small-update flood). The fix gates the
      -- broadcast on the stream-progress limiter (shouldEdit: 1500ms
      -- interval / 80-codepoint threshold), so back-to-back deltas within
      -- the interval coalesce into a single frame.
      broker <- newStreamBroker 10
      ref <- newIORef ([] :: [BrokerEvent])
      void $ subscribe broker (mkSid "stream-sid") (\e -> modifyIORef' ref (e :)) (pure ())
      store <- newAskReplyStore 0
      let sid = mkSid "stream-sid"
      caps <- webAskCaps (Just broker) store sid
      -- Fire deltas back-to-back (no wall-clock delay between them):
      -- "Hello", " ", "world", " and", " more" — 5 deltas in well under
      -- the 1500ms interval.
      mapM_ (ccSend caps) ["Hello", " ", "world", " and", " more" :: Text]
      events <- readIORef ref
      -- The first delta broadcasts immediately (no last-edit time); the
      -- remaining four coalesce into it. ONE broadcast carrying "Hello".
      length events `shouldBe` 1
      case events of
        [BeEntryUpdate _ v] -> extractContentText v `shouldBe` Just ("Hello" :: Text)
        _ -> expectationFailure ("expected one BeEntryUpdate event, got " <> show events)

    it "ccSend forces an edit once the buffer threshold is exceeded" $ do
      -- The 80-codepoint threshold must still force intermediate edits
      -- within the interval so long responses stream visibly rather than
      -- arriving as one lump at the end.
      broker <- newStreamBroker 10
      ref <- newIORef ([] :: [BrokerEvent])
      void $ subscribe broker (mkSid "stream-sid") (\e -> modifyIORef' ref (e :)) (pure ())
      store <- newAskReplyStore 0
      let sid = mkSid "stream-sid"
      caps <- webAskCaps (Just broker) store sid
      -- 3 deltas of 40 chars each: 40 (<80, no), 80 (>=80, forced), 120.
      let chunk = T.replicate 40 "x"
      mapM_ (ccSend caps) [chunk, chunk, chunk]
      events <- readIORef ref
      -- Threshold crossings force broadcasts: delta 2 hits 80 codepoints.
      -- (delta 3 arrives immediately after the forced edit, within the
      -- interval, and coalesces.)
      length events `shouldBe` 2

    it "ccSend is a no-op when the broker is Nothing" $ do
      store <- newAskReplyStore 0
      let sid = mkSid "no-broker"
      caps <- webAskCaps Nothing store sid
      -- Should not throw; the ccSend is a no-op.
      ccSend caps ("anything" :: Text)

  describe "parseAnswerBody" $ do
    it "accepts {scope: once} → Left (Left ScopeOnce)" $
      parseAnswerBody (BL.fromStrict (TE.encodeUtf8 "{\"scope\":\"once\"}"))
        `shouldBe` Right (Left ScopeOnce)
    it "accepts {answer: main} → Left (Right main)" $
      parseAnswerBody (BL.fromStrict (TE.encodeUtf8 "{\"answer\":\"main\"}"))
        `shouldBe` Right (Right "main")
    it "rejects {scope, answer} (both) → Left" $
      parseAnswerBody (BL.fromStrict (TE.encodeUtf8 "{\"scope\":\"once\",\"answer\":\"main\"}"))
        `shouldSatisfy` isLeft
    it "rejects {} (neither) → Left" $
      parseAnswerBody (BL.fromStrict (TE.encodeUtf8 "{}"))
        `shouldSatisfy` isLeft

  describe "handleAnswerTextDelivery" $ do
    it "delivers a text answer to a pending ASK_HUMAN question" $ do
      withSystemTempDirectory "ask-text" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache"
              }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        let sid = mkSid "ask-text"
            store = sdAskReply baseDeps
            opts = [QuestionOption "main" "the default branch"]
        -- Register a pending ask with options.
        done <- newEmptyMVar
        _ <- forkIO $ do
          _r <- askHumanWithOptions store sid "which branch?" opts (\_ -> pure ())
          putMVar done ()
        threadDelay 10000
        ps <- pendingForSession store sid
        case ps of
          [info] -> do
            let qidText = askIdText (pqiId info)
            res <- handleAnswerTextDelivery baseDeps sid qidText "main"
            res `shouldBe` Right True
          _ -> expectationFailure "expected one pending ask"
        takeMVar done

  -- Integration test for the repo agents.md auto-bind feature. This is the
  -- gateway-level end-to-end test the user asked for: it exercises the SAME
  -- handleSend → plainTurn → autoBindRepoAgent → resolveSystemPrompt path the
  -- web frontend triggers when a user sends a message to a session whose
  -- workdir contains a repo shipping .agents/agents.md. The unit tests in
  -- RepoDiscoverySpec verified autoBindRepoAgent in isolation; this test
  -- verifies the wiring actually fires inside a real turn, so a regression
  -- in the integration (e.g. the hook being placed after resolveSystemPrompt,
  -- or meta not being reloaded, or the workdir not being seeded before the
  -- turn) is caught here, not just at the unit level.
  describe "repo agents.md auto-bind (gateway integration)" $ do
    -- A provider that captures the CompletionRequest's crSystem so the test
    -- can assert WHICH system prompt actually drove the turn. Returns one
    -- canned reply so the turn completes.
    let capturingDeps :: SealPaths -> IO (SendDeps, IORef (Maybe T.Text))
        capturingDeps paths = do
          capRef <- newIORef (Nothing :: Maybe T.Text)
          let resolveStub _ = pure (Right
                ( SomeProvider (CapturingProvider capRef)
                , ModelId "llama3.2" ))
          deps <- mkSendDepsWith paths resolveStub
          tabsH <- newTabsHandle
          pure (deps { sdTabsHandle = tabsH }, capRef)
        seedZoe :: SealPaths -> IO ()
        seedZoe paths = do
          -- A flat-scheme user agent "zoe" with a distinctive system prompt
          -- so we can tell it apart from the repo's agents.md marker.
          let agentsDir = spConfig paths </> "agents"
          createDirectoryIfMissing True agentsDir
          writeFile (agentsDir </> "zoe.md")
            "---\nid: zoe\nname: zoe\nprovider: ollama\nmodel: llama3\ntools: all\ncreated_at: 2026-07-01T00:00:00Z\nupdated_at: 2026-07-01T00:00:00Z\nsession: s1\n---\nZOE_SYSTEM_PROMPT_MARKER\n"
        seedSessionWithZoe :: SealPaths -> SessionId -> IO ()
        seedSessionWithZoe paths sid = do
          let sdir = sessionDir paths sid
          createDirectoryIfMissing True sdir
          let zoe = case mkAgentDefId' "zoe" of Right a -> a; Left _ -> error "bad zoe id"
              meta = SessionMeta sid "ollama" "llama3.2" "web" (Just zoe) Nothing (Just "zoe") Nothing True Nothing sampleTime sampleTime
          saveSessionMeta paths meta
        seedRepoAgentsMd :: SealPaths -> SessionId -> T.Text -> IO ()
        seedRepoAgentsMd paths sid marker = do
          -- Seed the session workdir (the same path mkSessionExec uses in
          -- mode=local) with a repo carrying .agents/agents.md whose body is
          -- the distinctive marker.
          let wd = sessionWorkdir paths sid
              repoDir = wd </> "seal-test-repo" </> ".agents"
          createDirectoryIfMissing True repoDir
          writeFile (repoDir </> "agents.md")
            ("---\nkind: agents\n---\n" <> T.unpack marker <> "\n")

    it "a session bound to the user default (zoe) uses the repo's agents.md after a clone" $ do
      withSystemTempDirectory "auto-bind-int" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        seedZoe paths
        (baseDeps, capRef) <- capturingDeps paths
        let sid = mkSid "20260817-151158-281"
        seedSessionWithZoe paths sid
        seedRepoAgentsMd paths sid "REPO_PROJECT_MARKER"
        let sendDeps = baseDeps
        outcome <- handleSend sendDeps sid "tell me about yourself"
        outcome `shouldBe` SendAssistant
        -- The turn runs async; poll for the captured system prompt.
        sysSeen <- waitFor 5000000 (readIORef capRef) isJust
        sysSeen `shouldBe` True
        mSys <- readIORef capRef
        case mSys of
          Nothing -> expectationFailure "provider was never called — turn did not reach the LLM"
          Just sys -> do
            sys `shouldSatisfy` T.isInfixOf "REPO_PROJECT_MARKER"
            sys `shouldNotSatisfy` T.isInfixOf "ZOE_SYSTEM_PROMPT_MARKER"

    it "a session with no repo in its workdir stays on the user default (zoe)" $ do
      withSystemTempDirectory "auto-bind-norepo" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        seedZoe paths
        (baseDeps, capRef) <- capturingDeps paths
        let sid = mkSid "20260817-151158-282"
        seedSessionWithZoe paths sid
        -- No repo seeded in the workdir.
        outcome <- handleSend baseDeps sid "tell me about yourself"
        outcome `shouldBe` SendAssistant
        sysSeen <- waitFor 5000000 (readIORef capRef) isJust
        sysSeen `shouldBe` True
        mSys <- readIORef capRef
        case mSys of
          Nothing -> expectationFailure "provider was never called"
          Just sys -> do
            sys `shouldSatisfy` T.isInfixOf "ZOE_SYSTEM_PROMPT_MARKER"
            sys `shouldNotSatisfy` T.isInfixOf "REPO_PROJECT_MARKER"

  -- The "Add Seal Harness front matter" toggle, end to end: with the front
  -- matter OFF, the system prompt the model actually receives is the
  -- selected agent's prompt and NOTHING else — no static guidance blocks,
  -- no auto-loaded skill, no skills/agents catalogs. This exercises the
  -- same handleSend → plainTurn → resolveSystemPrompt path the web
  -- frontend drives, so a regression in the wiring (not just in the
  -- resolver) is caught here.
  describe "seal front matter toggle (gateway integration)" $ do
    let seedZoeAgent paths = do
          let agentsDir = spConfig paths </> "agents"
          createDirectoryIfMissing True agentsDir
          writeFile (agentsDir </> "zoe.md")
            "---\nid: zoe\nname: zoe\nprovider: ollama\nmodel: llama3\ntools: all\ncreated_at: 2026-07-01T00:00:00Z\nupdated_at: 2026-07-01T00:00:00Z\nsession: s1\n---\nZOE_SYSTEM_PROMPT_MARKER\n"

    it "the model receives ONLY the agent's prompt when the front matter is off" $ do
      withSystemTempDirectory "front-matter-off" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        seedZoeAgent paths
        capRef <- newIORef (Nothing :: Maybe T.Text)
        let resolveStub _ = pure (Right
              ( SomeProvider (CapturingProvider capRef)
              , ModelId "llama3.2" ))
        baseDeps <- mkSendDepsWith paths resolveStub
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260817-151158-290"
            sdir = sessionDir paths sid
            zoe = case mkAgentDefId' "zoe" of Right a -> a; Left _ -> error "bad zoe id"
            -- The front matter is OFF for this session.
            meta = SessionMeta sid "ollama" "llama3.2" "web" (Just zoe) Nothing (Just "zoe") Nothing False Nothing sampleTime sampleTime
        createDirectoryIfMissing True sdir
        saveSessionMeta paths meta
        outcome <- handleSend sendDeps sid "tell me about yourself"
        outcome `shouldBe` SendAssistant
        sysSeen <- waitFor 5000000 (readIORef capRef) isJust
        sysSeen `shouldBe` True
        mSys <- readIORef capRef
        case mSys of
          Nothing -> expectationFailure "provider was never called — turn did not reach the LLM"
          Just sys -> do
            -- The agent's prompt is present...
            sys `shouldSatisfy` T.isInfixOf "ZOE_SYSTEM_PROMPT_MARKER"
            -- ...and nothing else was added.
            sys `shouldSatisfy` (not . T.isInfixOf "Parallel tool calls")
            sys `shouldSatisfy` (not . T.isInfixOf "Tool use")
            sys `shouldSatisfy` (not . T.isInfixOf "Task completion")
            sys `shouldSatisfy` (not . T.isInfixOf "Credential-bearing tools")
            sys `shouldSatisfy` (not . T.isInfixOf "<available_skills>")
            sys `shouldSatisfy` (not . T.isInfixOf "<available_agents>")
            sys `shouldSatisfy` (not . T.isInfixOf "Auto-loaded skill")

    it "the model receives the harness front matter when the toggle is on" $ do
      withSystemTempDirectory "front-matter-on" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        seedZoeAgent paths
        capRef <- newIORef (Nothing :: Maybe T.Text)
        let resolveStub _ = pure (Right
              ( SomeProvider (CapturingProvider capRef)
              , ModelId "llama3.2" ))
        baseDeps <- mkSendDepsWith paths resolveStub
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
            sid = mkSid "20260817-151158-291"
            sdir = sessionDir paths sid
            zoe = case mkAgentDefId' "zoe" of Right a -> a; Left _ -> error "bad zoe id"
            -- The front matter is ON (the default).
            meta = SessionMeta sid "ollama" "llama3.2" "web" (Just zoe) Nothing (Just "zoe") Nothing True Nothing sampleTime sampleTime
        createDirectoryIfMissing True sdir
        saveSessionMeta paths meta
        outcome <- handleSend sendDeps sid "tell me about yourself"
        outcome `shouldBe` SendAssistant
        sysSeen <- waitFor 5000000 (readIORef capRef) isJust
        sysSeen `shouldBe` True
        mSys <- readIORef capRef
        case mSys of
          Nothing -> expectationFailure "provider was never called"
          Just sys -> do
            sys `shouldSatisfy` T.isInfixOf "ZOE_SYSTEM_PROMPT_MARKER"
            sys `shouldSatisfy` T.isInfixOf "Parallel tool calls"

  -- The /stop slash command must target the request's session (the sid
  -- from the URL), NOT the process-global srActive ref. The web is
  -- multi-session: a /stop typed in tab 3 must abort tab 3's session,
  -- even if srActive points at tab 1. This is the slash-command
  -- equivalent of the stop-button's POST /api/sessions/:id/stop.
  describe "/stop slash command targets the request session" $ do
    it "aborts the request's session, not srActive" $
      withSystemTempDirectory "stop-cmd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let targetSid = mkSid "20260819-120000-stop-target"
            activeSid = mkSid "active"
        seedSession paths targetSid
        -- The production runSlash rebuilds the stop spec per-request via
        -- stopCommandSpecForSession closing over the request's sid. Simulate
        -- that here: the registry carries the per-request stop spec for
        -- targetSid, so the command aborts targetSid (not srActive).
        let stopSpec = stopCommandSpecForSession (sdAbortReg baseDeps) (bRunRecords (sdBackends baseDeps)) targetSid noStopTranscriptWriter
            sendDeps = baseDeps
              { sdTabsHandle = tabsH
              , sdRegistry = mkRegistry [stopSpec]
              }
        -- Sanity: srActive points at "active", NOT targetSid.
        activeMeta <- readIORef (srActive (sdSession sendDeps))
        smId activeMeta `shouldBe` activeSid
        outcome <- handleSend sendDeps targetSid "/stop"
        case outcome of
          SendSlash _ _ -> pure ()
          other         -> expectationFailure ("expected SendSlash, got " <> show other)
        -- The target session's abort flag must be set.
        targetFlag <- lookupOrCreateAbortFlag (sdAbortReg sendDeps) targetSid
        isAborted targetFlag `shouldReturn` True
        -- srActive's session ("active") must NOT be aborted — the command
        -- must not read srActive on the multi-session web.
        activeFlag <- lookupOrCreateAbortFlag (sdAbortReg sendDeps) activeSid
        isAborted activeFlag `shouldReturn` False

    it "writes a stop entry to the transcript so it appears cross-channel" $
      withSystemTempDirectory "stop-transcript" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
        providerRef <- newIORef []
        baseDeps <- mkSendDeps paths providerRef
        tabsH <- newTabsHandle
        let targetSid = mkSid "20260819-130000-stop-transcript"
        seedSession paths targetSid
        let stopSpec = stopCommandSpecForSession (sdAbortReg baseDeps) (bRunRecords (sdBackends baseDeps)) targetSid
                         (mkStopTranscriptWriter paths Nothing)
            sendDeps = baseDeps
              { sdTabsHandle = tabsH
              , sdRegistry = mkRegistry [stopSpec]
              }
        outcome <- handleSend sendDeps targetSid "/stop"
        case outcome of
          SendSlash _ _ -> pure ()
          other         -> expectationFailure ("expected SendSlash, got " <> show other)
        -- The transcript's conversation.jsonl must contain the stop
        -- message as an assistant entry so the web frontend (and any
        -- other channel) sees it on reload/poll.
        let convPath = sessionDir paths targetSid </> "conversation.jsonl"
        raw <- BS.readFile convPath
        let msgs = readConversation raw
        -- The stop message should be the last assistant message.
        case reverse (filter (\m -> msgRole m == Assistant) msgs) of
          (m : _) -> case [t | CbText t <- msgContent m] of
            (t : _) -> t `shouldSatisfy` ("stopped" `T.isInfixOf`)
            []      -> expectationFailure "last assistant message has no text"
          []      -> expectationFailure "no assistant message in the transcript — /stop did not write to the transcript"

    it "/stop -h renders full help (regression: stopParserInfo must include helper)" $ do
      -- On main, stopParserInfo omitted optparse's `helper`, so /stop -h
      -- printed "Invalid option '--help'". With the fix, -h/--help renders
      -- the full help (Usage + description + the -h,--help line).
      let targetSid = mkSid "20260825-120000-stop-help"
      let stopSpec = stopCommandSpecForSession undefined undefined targetSid noStopTranscriptWriter
          -- undefined SessionAbortRegistry is never forced: -h short-circuits
          -- to help before the action runs.
      case Opt.execParserPure Opt.defaultPrefs (csParserInfo stopSpec) ["-h"] of
        Opt.Failure f -> do
          let (msg, _) = Opt.renderFailure f "/stop"
              out = T.pack msg
          out `shouldSatisfy` ("Usage" `T.isInfixOf`)
          out `shouldSatisfy` ("Abort the active session's in-flight tool call" `T.isInfixOf`)
          out `shouldSatisfy` ("-h,--help" `T.isInfixOf`)
          out `shouldNotSatisfy` ("Invalid option" `T.isInfixOf`)
        other -> expectationFailure ("expected Failure (help), got: " <> show (isSuccess other))

  describe "sub-agent completion delivery" $ do
    -- The three tests below are the reproduction for the bug analysed in
    -- docs/plans/2026-10-22-subagent-completion-delivery-diagnosis.md:
    -- a completed sub-agent's message is delivered to the parent
    -- session's model, and the parent's own messages are not lost from
    -- the transcript on the way.

    it "R1: the parent model is given the sub-agent's verdict" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261022-200000-r1"
            verdict = "[subagent vtag--architect-agent-abc123 completed] verdict NEEDS_REVISION"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        let resolve _ = pure (Right (SomeProvider (RecordingProvider recorded firstRef Nothing), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        -- A production-sized conversation: the reader that builds the
        -- model's context only loses the race to the writer when the
        -- conversation is big enough for the two to be close (diagnosis 2).
        seedConversation paths sid 300 5000
        -- The harness delivered a completed sub-agent's message.
        appendCompletionToSidecar paths sid verdict
        outcome <- handleSend sendDeps sid "hello"
        case outcome of
          SendAssistant -> pure ()
          other         -> expectationFailure ("expected SendAssistant, got " <> show other)
        -- Wait for the turn to have reached the provider.
        seen <- waitFor 5000000 (readIORef recorded) (not . null)
        seen `shouldBe` True
        -- The model must have been given the verdict. Today the turn
        -- engine injects the completion asynchronously and the reader
        -- that builds the model's context beats the writer, so the
        -- verdict is missing (diagnosis 9.1: 21 of 21 completions were
        -- missed on a live gateway).
        reqs <- readIORef recorded
        let allTexts = concatMap requestTexts reqs
            sawVerdict = any (T.isInfixOf verdict) allTexts
        sawVerdict `shouldBe` True

    it "R2: the transcript keeps the verdicts and everything the parent wrote" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261022-200000-r2"
            verdictA = "[subagent vtag--architect-agent-aaa111 completed] verdict A"
            verdictB = "[subagent vtag--architect-agent-bbb222 completed] verdict B"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        let resolve _ = pure (Right (SomeProvider (RecordingProvider recorded firstRef Nothing), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        seedConversation paths sid 300 5000
        appendCompletionToSidecar paths sid verdictA
        appendCompletionToSidecar paths sid verdictB
        outcome <- handleSend sendDeps sid "hello"
        case outcome of
          SendAssistant -> pure ()
          other         -> expectationFailure ("expected SendAssistant, got " <> show other)
        seen <- waitFor 5000000 (readIORef recorded) (not . null)
        seen `shouldBe` True
        -- The transcript must hold the two verdicts AND the parent's own
        -- user message AND the parent's reply. Today the writer is ahead
        -- of the caller's conversation by the number of injected
        -- completions, so the caller's writes are sliced against the
        -- wrong offset and the parent's messages are dropped from the
        -- file (diagnosis 9.2).
        raw <- BS.readFile (sessionDir paths sid </> "conversation.jsonl")
        let msgs = readConversation raw
            texts = [t | Message _ bs <- msgs, CbText t <- bs]
            has needle = any (T.isInfixOf needle) texts
        -- Report which part is missing, not the whole conversation.
        let missing = [n | n <- [verdictA, verdictB, "hello", "ok"], not (has n)]
        missing `shouldBe` []

    it "R3: a verdict that arrives while the parent is mid-turn is delivered when the turn ends" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261022-200000-r3"
            verdict = "[subagent vtag--cto-agent-ccc333 completed] verdict C"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        gate <- newEmptyMVar
        let resolve _ = pure (Right (SomeProvider (RecordingProvider recorded firstRef (Just gate)), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        case outcome of
          SendAssistant -> pure ()
          other         -> expectationFailure ("expected SendAssistant, got " <> show other)
        -- Wait for the turn to be in flight (the provider is blocked).
        inFlight <- waitFor 5000000 (readIORef recorded) (not . null)
        inFlight `shouldBe` True
        -- The sub-agent finishes while the parent is still working.
        appendCompletionToSidecar paths sid verdict
        -- Let the turn end.
        putMVar gate ()
        -- The verdict must be delivered: a later turn must see it.
        delivered <- waitFor 5000000 (readIORef recorded) ((> 1) . length)
        delivered `shouldBe` True
        reqs <- readIORef recorded
        let allTexts = concatMap requestTexts reqs
            sawVerdict = any (T.isInfixOf verdict) allTexts
        sawVerdict `shouldBe` True

  -- WU-3 (plan §3 D2): a completion that arrives while a turn is in
  -- flight is delivered when the turn ends. The engine gained 'tdOnTurnEnd'
  -- (called from the turn bracket's release action); the gateway wakes the
  -- session when the sidecar still holds completions. These tests drive
  -- the whole path through the public surface (handleSend) and observe it
  -- through the provider calls the recording providers receive — the wake
  -- internals are deliberately not exported.
  describe "end-of-turn completion delivery" $ do

    it "a completion that arrives during a wake-up turn is delivered by a follow-up wake-up turn" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-090000-w3a"
            verdictA = "[subagent vtag--architect-agent-w3a completed] verdict A"
            verdictB = "[subagent vtag--designer-agent-w3b completed] verdict B"
        recorded <- newIORef ([] :: [CompletionRequest])
        gate1 <- newEmptyMVar
        gate2 <- newEmptyMVar
        gatesRef <- newIORef [gate1, gate2]
        let resolve _ = pure (Right (SomeProvider (ChainProvider recorded gatesRef), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        -- The parent turn is in flight (parked on the first gate).
        seen1 <- waitFor 5000000 (readIORef recorded) (not . null)
        seen1 `shouldBe` True
        -- The first sub-agent finishes while the parent is mid-turn.
        appendCompletionToSidecar paths sid verdictA
        putMVar gate1 ()
        -- The turn's end-of-turn hook wakes the session; the wake-up
        -- turn is now in flight (parked on the second gate).
        seen2 <- waitFor 5000000 (readIORef recorded) ((>= 2) . length)
        seen2 `shouldBe` True
        -- The second sub-agent finishes while the WAKE-UP turn is
        -- mid-turn. That turn's own end-of-turn hook cannot deliver it
        -- (the nested wake skips: the outer frame holds the wake mutex),
        -- so the outer frame's follow-up wake-up turn must.
        appendCompletionToSidecar paths sid verdictB
        putMVar gate2 ()
        -- The whole chain runs inside the parent turn's release action;
        -- the tab appears only once the parent turn returns.
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True
        (n1, n2) <- unchangedAfter 200000 (length <$> readIORef recorded)
        n1 `shouldBe` n2
        -- Exactly three turns: the user turn, the first wake-up turn
        -- (which delivers verdict A), and the follow-up (verdict B).
        n2 `shouldBe` 3
        reqs <- readIORef recorded
        let textsOf i = case drop i reqs of
              (r : _) -> requestTexts r
              []      -> []
        any (T.isInfixOf verdictA) (textsOf 1) `shouldBe` True
        any (T.isInfixOf verdictB) (textsOf 2) `shouldBe` True

    it "the wake chain terminates: a turn that ends with an empty sidecar starts no synthetic turn" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-090000-w3b"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        let resolve _ = pure (Right (SomeProvider (RecordingProvider recorded firstRef Nothing), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True
        -- No completion ever arrived: the turn count must settle at one
        -- (the user turn), with no synthetic turn behind it.
        (n1, n2) <- unchangedAfter 200000 (length <$> readIORef recorded)
        n1 `shouldBe` n2
        n1 `shouldBe` 1

    it "the wake chain is bounded: a provider that cannot be resolved produces no unbounded sequence of wake turns, and the completions stay pending" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-090000-w3c"
            verdict = "[subagent vtag--cto-agent-w3c completed] verdict C"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        gate <- newEmptyMVar
        resolveCalls <- newIORef (0 :: Int)
        let resolve _ = do
              -- The user turn resolves a working provider; every later
              -- resolution (the wake turns) fails — the early return
              -- that never fires the end-of-turn hook and never drains
              -- the sidecar. Only the chain's bound can stop the loop.
              n <- atomicModifyIORef' resolveCalls (\c -> (c + 1, c))
              if n == 0
                then pure (Right (SomeProvider (RecordingProvider recorded firstRef (Just gate)), ModelId "llama3.2"))
                else pure (Left "provider resolution failure (test)")
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        seen <- waitFor 5000000 (readIORef recorded) (not . null)
        seen `shouldBe` True
        appendCompletionToSidecar paths sid verdict
        putMVar gate ()
        -- The user turn succeeds and its end-of-turn hook starts the
        -- chain. The tab appears only when the whole chain returns — an
        -- unbounded chain would hang the turn and this wait would fail.
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True
        (c1, c2) <- unchangedAfter 300000 (readIORef resolveCalls)
        c1 `shouldBe` c2
        c1 `shouldSatisfy` (> 1)    -- the chain really ran wake attempts
        c1 `shouldSatisfy` (<= 12)  -- ... and it stopped: bounded
        -- No wake turn ever reached the provider, and the completion is
        -- still pending in the sidecar (delivered on the next user turn).
        reqs <- readIORef recorded
        length reqs `shouldBe` 1
        pendingCount <- pendingCompletionCount paths sid
        pendingCount `shouldBe` 1

    it "the no-session-meta branch of the wake loop releases the wake mutex and starts no turn" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-090000-w3d"
            verdictA = "[subagent vtag--sre-agent-w3d completed] verdict D1"
            verdictB = "[subagent vtag--sre-agent-w3e completed] verdict D2"
        recorded <- newIORef ([] :: [CompletionRequest])
        gate1 <- newEmptyMVar
        gate2 <- newEmptyMVar
        gatesRef <- newIORef [gate1, gate2]
        let resolve _ = pure (Right (SomeProvider (ChainProvider recorded gatesRef), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "one"
        outcome `shouldBe` SendAssistant
        seen1 <- waitFor 5000000 (readIORef recorded) (not . null)
        seen1 `shouldBe` True
        -- The session's meta disappears while the turn is in flight;
        -- the completion then arrives with nothing to run a turn against.
        removeFile (sessionDir paths sid </> "session.json")
        appendCompletionToSidecar paths sid verdictA
        putMVar gate1 ()
        -- The turn ends, the hook fires, the wake takes the mutex — and
        -- the no-meta branch releases it and runs NO turn.
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True
        (n1, n2) <- unchangedAfter 200000 (length <$> readIORef recorded)
        n1 `shouldBe` n2
        n1 `shouldBe` 1
        -- The mutex must have been released by the no-meta branch: a
        -- LATER wake still works. Restore the meta and repeat the
        -- mid-turn delivery — the wake for verdict B can only acquire
        -- the mutex if the first wake released it.
        seedSession paths sid
        outcome2 <- handleSend sendDeps sid "two"
        outcome2 `shouldBe` SendAssistant
        seen2 <- waitFor 5000000 (readIORef recorded) ((>= 2) . length)
        seen2 `shouldBe` True
        -- Turn two delivers verdict A at its start (the no-meta wake
        -- left it pending in the sidecar, by design).
        appendCompletionToSidecar paths sid verdictB
        putMVar gate2 ()
        seen3 <- waitFor 5000000 (readIORef recorded) ((>= 3) . length)
        seen3 `shouldBe` True
        (m1, m2) <- unchangedAfter 200000 (length <$> readIORef recorded)
        m1 `shouldBe` m2
        reqs <- readIORef recorded
        let textsOf i = case drop i reqs of
              (r : _) -> requestTexts r
              []      -> []
        any (T.isInfixOf verdictA) (textsOf 1) `shouldBe` True
        any (T.isInfixOf verdictB) (textsOf 2) `shouldBe` True

    it "a wake for a session with no open tab still delivers the completion (the turn runs headless)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-090000-w3e"
            verdict = "[subagent vtag--pm-agent-w3e completed] verdict E"
        recorded <- newIORef ([] :: [CompletionRequest])
        gate <- newEmptyMVar
        gatesRef <- newIORef [gate]
        let resolve _ = pure (Right (SomeProvider (ChainProvider recorded gatesRef), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        seen1 <- waitFor 5000000 (readIORef recorded) (not . null)
        seen1 `shouldBe` True
        appendCompletionToSidecar paths sid verdict
        putMVar gate ()
        -- No tab binds the session when the wake fires; the synthetic
        -- turn runs anyway and delivers the verdict.
        seen2 <- waitFor 5000000 (readIORef recorded) ((>= 2) . length)
        seen2 `shouldBe` True
        reqs <- readIORef recorded
        any (any (T.isInfixOf verdict) . requestTexts) (drop 1 reqs) `shouldBe` True
        -- The wake turn re-inserts the tab itself (the headless turn
        -- ends by auto-tabbing the session).
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True

    it "a synthetic wake-up turn that throws still releases the wake mutex (a later completion can wake the session)" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-100000-w4a"
            verdictA = "[subagent vtag--architect-agent-w4a completed] verdict A"
            verdictB = "[subagent vtag--designer-agent-w4b completed] verdict B"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        gate1 <- newEmptyMVar
        gate2 <- newEmptyMVar
        resolveCalls <- newIORef (0 :: Int)
        phase2Ref <- newIORef False
        let resolve _ = do
              phase2 <- readIORef phase2Ref
              if phase2
                then do
                  -- Phase 2: every resolution yields a fresh one-shot gated
                  -- provider (one putMVar unblocks exactly one call).
                  fr <- newIORef True
                  pure (Right (SomeProvider (RecordingProvider recorded fr (Just gate2)), ModelId "llama3.2"))
                else do
                  n <- atomicModifyIORef' resolveCalls (\c -> (c + 1, c))
                  if n == 0
                    then pure (Right (SomeProvider (RecordingProvider recorded firstRef (Just gate1)), ModelId "llama3.2"))
                    else throwIO (userError "simulated provider-resolution crash (test)")
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "one"
        outcome `shouldBe` SendAssistant
        seen1 <- waitFor 5000000 (readIORef recorded) (not . null)
        seen1 `shouldBe` True
        -- The first sub-agent finishes mid-turn.
        appendCompletionToSidecar paths sid verdictA
        putMVar gate1 ()
        -- The turn's end-of-turn hook wakes the session; the WAKE turn's
        -- provider resolution throws. Without the finally-bracketed
        -- release, the wake mutex would leak here and no later wake-up
        -- could ever acquire it.
        threw <- waitFor 5000000 (readIORef resolveCalls) (>= 2)
        threw `shouldBe` True
        -- The completion stayed pending (the crashed wake never drained
        -- the sidecar).
        pendingA <- pendingCompletionCount paths sid
        pendingA `shouldBe` 1
        -- Phase 2: the resolver works again. A second mid-turn completion
        -- triggers a second wake — which can only acquire the wake mutex
        -- if the crashed one released it.
        writeIORef phase2Ref True
        outcome2 <- handleSend sendDeps sid "two"
        outcome2 `shouldBe` SendAssistant
        seen2 <- waitFor 5000000 (readIORef recorded) ((>= 2) . length)
        seen2 `shouldBe` True
        appendCompletionToSidecar paths sid verdictB
        putMVar gate2 ()
        -- The wake turn runs and parks on its own one-shot gate.
        seen3 <- waitFor 5000000 (readIORef recorded) ((>= 3) . length)
        seen3 `shouldBe` True
        putMVar gate2 ()
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True
        reqs <- readIORef recorded
        let textsOf i = case drop i reqs of
              (r : _) -> requestTexts r
              []      -> []
        -- Turn two drained verdict A (left pending by the crashed wake);
        -- the second wake delivered verdict B.
        any (T.isInfixOf verdictA) (textsOf 1) `shouldBe` True
        any (T.isInfixOf verdictB) (textsOf 2) `shouldBe` True

    it "a skipped wake-up is logged at Warning level with the pending count" $
      withSystemTempDirectory "seal-send" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-100000-w4b"
            verdictA = "[subagent vtag--cto-agent-w4b completed] verdict A"
            verdictB = "[subagent vtag--sre-agent-w4c completed] verdict B"
        recorded <- newIORef ([] :: [CompletionRequest])
        gate1 <- newEmptyMVar
        gate2 <- newEmptyMVar
        gatesRef <- newIORef [gate1, gate2]
        let resolve _ = pure (Right (SomeProvider (ChainProvider recorded gatesRef), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let sendDeps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        outcome <- handleSend sendDeps sid "hello"
        outcome `shouldBe` SendAssistant
        seen1 <- waitFor 5000000 (readIORef recorded) (not . null)
        seen1 `shouldBe` True
        appendCompletionToSidecar paths sid verdictA
        putMVar gate1 ()
        -- The wake-up turn is now in flight (parked on the second gate).
        seen2 <- waitFor 5000000 (readIORef recorded) ((>= 2) . length)
        seen2 `shouldBe` True
        appendCompletionToSidecar paths sid verdictB
        putMVar gate2 ()
        -- The wake-up turn ends; its own end-of-turn hook tries to wake
        -- again and is skipped (the outer frame holds the wake mutex) —
        -- the skip must be visible at WARN level with the pending count.
        seen3 <- waitFor 5000000 (readIORef recorded) ((>= 3) . length)
        seen3 `shouldBe` True
        tabSeen <- waitFor 5000000
          (do snap <- snapshotTabs tabsH; pure (map tRef (tlTabs snap)))
          (elem (BoundSession sid))
        tabSeen `shouldBe` True
        logContent <- readFile (sessionDir paths sid </> "seal.log")
        let logText = T.pack logContent
        logText `shouldSatisfy` ("[WARN]" `T.isInfixOf`)
        logText `shouldSatisfy` ("skipping (wake mutex held)" `T.isInfixOf`)
        logText `shouldSatisfy` ("pendingCompletions=1" `T.isInfixOf`)

  describe "end-of-turn hook (engine call-site semantics)" $ do
    -- These drive 'runSessionTurn' directly with 'tdOnTurnEnd' replaced
    -- by a recorder, pinning WHERE and WHEN the engine calls the hook.
    -- The recorder stores what 'sessionTurnInFlight' observed at the
    -- moment the hook fired ('Nothing' = the hook never fired).

    it "the hook fires after the session lock is released (the wake is not skipped as 'turn in flight')" $
      withSystemTempDirectory "seal-turn-end" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-091000-w3f"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        let resolve _ = pure (Right (SomeProvider (RecordingProvider recorded firstRef Nothing), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let deps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        (outcome, hookRef) <- runWithRecordedHook deps sid
        toError outcome `shouldBe` Nothing
        readIORef hookRef `shouldReturn` Just False

    it "the hook fires on a turn that threw" $
      withSystemTempDirectory "seal-turn-end" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-091000-w3g"
        let resolve _ = pure (Right (SomeProvider ThrowingProvider, ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let deps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        (outcome, hookRef) <- runWithRecordedHook deps sid
        toError outcome `shouldSatisfy` isJust
        readIORef hookRef `shouldReturn` Just False

    it "the hook does not fire on the provider-resolution early return" $
      withSystemTempDirectory "seal-turn-end" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-091000-w3h"
        let resolve _ = pure (Left "no provider (test)")
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let deps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        (outcome, hookRef) <- runWithRecordedHook deps sid
        toError outcome `shouldSatisfy` isJust
        readIORef hookRef `shouldReturn` Nothing

    it "the hook does not fire when the turn was aborted by the user" $
      withSystemTempDirectory "seal-turn-end" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
              , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
            sid = mkSid "20261023-091000-w3i"
        recorded <- newIORef ([] :: [CompletionRequest])
        firstRef <- newIORef True
        gate <- newEmptyMVar
        let resolve _ = pure (Right (SomeProvider (RecordingProvider recorded firstRef (Just gate)), ModelId "llama3.2"))
        baseDeps <- mkSendDepsWith paths resolve
        tabsH <- newTabsHandle
        let deps = baseDeps { sdTabsHandle = tabsH }
        seedSession paths sid
        hookRef <- newIORef (Nothing :: Maybe Bool)
        let td = (mkWebTurnDeps deps)
              { tdOnTurnEnd = Just (\_ ->
                  sessionTurnInFlight (sdLocks deps) sid >>= writeIORef hookRef . Just) }
            meta = SessionMeta sid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing True Nothing sampleTime sampleTime
        done <- newEmptyMVar
        _ <- forkIO (void (runSessionTurn td (testTurnAdapter td) meta Nothing "hello") >> putMVar done ())
        seen <- waitFor 5000000 (readIORef recorded) (not . null)
        seen `shouldBe` True
        -- The user aborts mid-turn (the /stop button). The abort flag is
        -- only cleared at the NEXT turn's entry, so it is still set when
        -- the turn's release action runs.
        setSessionAbort (sdAbortReg deps) sid
        putMVar gate ()
        _ <- takeMVar done
        readIORef hookRef `shouldReturn` Nothing

-- | Discriminate a ParserResult Success for informative failure messages.
isSuccess :: ParserResult a -> Bool
isSuccess (Success _) = True
isSuccess _           = False

-- | Extract the first content block's text from a streaming entry-update JSON.
-- Used by the ccSend streaming test to assert the accumulated text.
extractContentText :: A.Value -> Maybe Text
extractContentText v = do
  A.Object o <- Just v
  A.Object payload <- KeyMap.lookup (fromText "payload") o
  A.Array arr <- KeyMap.lookup (fromText "content") payload
  A.Object first_ <- case V.toList arr of (x : _) -> Just x; _ -> Nothing
  A.String t <- KeyMap.lookup (fromText "text") first_
  Just t

-- | A fake provider that records every 'CompletionRequest' it receives
-- and parks the first N calls on queued gates (one 'MVar' per gated
-- call), answering every un-gated call immediately. The wake-chain
-- tests use it to deliver a completion \"while the parent is still
-- working\" at any depth of the chain: each gate holds one provider
-- call mid-turn, so a completion can be delivered between two turns no
-- matter which turn is running.
data ChainProvider = ChainProvider
  { cpRequests :: IORef [CompletionRequest]
  , cpGates    :: IORef [MVar ()]
  }

instance Provider ChainProvider where
  complete p req = do
    modifyIORef' (cpRequests p) (++ [req])
    mGate <- atomicModifyIORef' (cpGates p) (\case
      []       -> ([], Nothing)
      (g : gs') -> (gs', Just g))
    for_ mGate takeMVar
    pure (Right (CompletionResponse [CbText "ok"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | Read a value, wait the given microseconds, read it again: the pair is
-- returned so a test can assert the two reads agree — i.e. that whatever
-- produces the value (a wake chain) has terminated.
unchangedAfter :: Int -> IO a -> IO (a, a)
unchangedAfter delayUs readAction = do
  a <- readAction
  threadDelay delayUs
  a' <- readAction
  pure (a, a')

-- | A minimal 'TurnAdapter' for the tests that drive 'runSessionTurn'
-- directly (the gateway's 'mkWebTurnAdapter' is not exported). Every
-- hook is a no-op; the start-wiring builder is the engine's own.
testTurnAdapter :: TurnDeps -> TurnAdapter
testTurnAdapter td = TurnAdapter
  { taCaps = def
  , taPreTurn = \_ _ _ -> pure ()
  , taChannelLabel = const "test"
  , taOnStop = const Nothing
  , taOnToolCall = Nothing
  , taOnTextDelta = Nothing
  , taOnUserMessage = const Nothing
  , taPostTurn = \_ _ -> pure ()
  , taStartWiring = \sessionBackends s appEnv eCfg operatorCeiling _meta ->
      buildStartWiring td sessionBackends s appEnv eCfg operatorCeiling "web"
  }

-- | Run one turn synchronously through the engine with 'tdOnTurnEnd'
-- replaced by a recorder: the hook stores what 'sessionTurnInFlight'
-- observed at the moment it fired ('Nothing' = the hook never fired).
-- Used to pin the hook's call-site semantics in 'runSessionTurn' (the
-- turn bracket's release action).
runWithRecordedHook :: SendDeps -> SessionId -> IO (TurnOutcome, IORef (Maybe Bool))
runWithRecordedHook deps sid = do
  hookRef <- newIORef (Nothing :: Maybe Bool)
  let td = (mkWebTurnDeps deps)
        { tdOnTurnEnd = Just (\_ ->
            sessionTurnInFlight (sdLocks deps) sid >>= writeIORef hookRef . Just) }
      meta = SessionMeta sid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing True Nothing sampleTime sampleTime
  outcome <- runSessionTurn td (testTurnAdapter td) meta Nothing "hello"
  pure (outcome, hookRef)
