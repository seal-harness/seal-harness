{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.SendSpec (spec) where

import Control.Exception (catch, SomeException, throwIO)
import Seal.Session.ExecCache (newSessionExecCache)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.Aeson qualified as A
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (mapMaybe)
import Data.Text.Encoding qualified as TE
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Types (AgentDefId, mkAgentDefId)
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Channel.Cli (newBackends)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionWorkdir)
import Seal.Core.Types (ModelId (..), mkSessionId, SessionId)
import Seal.Gateway.Send
  ( SendDeps (..), SendOutcome (..), ensureTabForSession, handleSend, webAskCaps
  , handleAnswerTextDelivery, parseAnswerBody )
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
import Seal.Command.Spec (mkRegistry)
import Seal.Security.Policy qualified as Policy (AutonomyLevel (Full))
import Seal.Security.Vault (VaultHandle)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.Session.Lock (newReplyRegistry, newSessionLocks)
import Seal.Tools.Exec.Abort (newSessionAbortRegistry, lookupOrCreateAbortFlag, isAborted)
import Seal.Transcript.Conv (readConversation)
import Data.ByteString qualified as BS
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.Tabs (newTabsHandle, insertTabH, snapshotTabs)
import Seal.Tabs.Types (TabRef (BoundSession), tlTabs, tRef, tabCount)
import Seal.Command.Tab (tabCommandSpec, noTabCloseNotifier)
import Seal.Command.Stop (stopCommandSpecForSession, mkStopTranscriptWriter, noStopTranscriptWriter)
import Seal.Vault.Commands (VaultRuntime (..))

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
  backends <- newBackends configRoot repo
  reg   <- newHarnessRegistry
  tmuxR <- mkRealTmuxRunner
  askReply <- newAskReplyStore 0
  approvals <- newApprovalCache
  testReplies <- newReplyRegistry
  testLocks <- newSessionLocks
  testAbortReg <- newSessionAbortRegistry
  let activeMeta = SessionMeta (mkSid "active") "ollama" "llama3.2" "cli" Nothing Nothing Nothing Nothing sampleTime sampleTime
  activeRef <- newIORef activeMeta
  let sr = SessionRuntime { srPaths = paths, srConfigPath = configRoot </> "config.toml", srActive = activeRef }
  -- A real ProviderRuntime whose config path is nonexistent (loadRuntimeConfig
  -- fails -> defaults). The vault ref holds Nothing so resolveSessionProvider
  -- would fail — but sdResolve is stubbed, so the vault is never consulted.
  vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  execCache <- newSessionExecCache
  let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
      pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
      sendDeps = SendDeps
        { sdPaths      = paths
        , sdVault      = rt
        , sdRepoReg    = fakeRepoRegistryHandle
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
        }
  pure sendDeps

-- | Seed a session.json on disk for the given sid.
seedSession :: SealPaths -> SessionId -> IO ()
seedSession paths sid = do
  let sdir = sessionDir paths sid
  createDirectoryIfMissing True sdir
  let meta = SessionMeta sid "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing sampleTime sampleTime
  saveSessionMeta paths meta

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
        snap <- snapshotTabs tabsH
        case tlTabs snap of
          [t] -> do
            tRef t `shouldBe` BoundSession sid
          _   -> expectationFailure ("expected exactly one auto-tab, got " <> show (tlTabs snap))

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
        -- The turn fails (provider threw), so handleSend returns
        -- SendError 500. The important assertion is below: the idle
        -- broadcast fired despite the death.
        case outcome of
          SendError 500 _ -> pure ()
          other           -> expectationFailure ("expected SendError 500, got " <> show other)
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
        -- Fork the send so we can kill the thread mid-turn.
        tid <- forkIO (void (handleSend sendDeps sid "hello" `catch` \(_ :: SomeException) -> pure SendAssistant))
        threadDelay 100000  -- let the turn start (thinking broadcast)
        -- Verify thinking was broadcast.
        events1 <- readIORef eventsRef
        let statuses1 = mapMaybe harnessStatus events1
        statuses1 `shouldSatisfy` ("thinking" `elem`)
        -- Kill the thread (async exception).
        killThread tid
        threadDelay 100000  -- let the bracket cleanup fire
        -- Verify idle was broadcast despite the kill.
        events2 <- readIORef eventsRef
        let statuses2 = mapMaybe harnessStatus events2
        statuses2 `shouldSatisfy` ("idle" `elem`)
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
        exists <- doesFileExist logFile
        exists `shouldBe` True
        content <- readFile logFile
        content `shouldSatisfy` \s -> "ERROR" `T.isInfixOf` T.pack s

  describe "webAskCaps" $ do
    it "ccPrompt with options registers a pending ask carrying the options" $ do
      store <- newAskReplyStore 0
      let sid = mkSid "ask-opts"
          caps = webAskCaps Nothing store sid
          opts = [ QuestionOption "main" "the default branch"
                 , QuestionOption "develop" "the integration branch"
                 ]
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
              meta = SessionMeta sid "ollama" "llama3.2" "web"
                       (Just zoe) Nothing (Just "zoe") Nothing sampleTime sampleTime
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
        mSys <- readIORef capRef
        case mSys of
          Nothing -> expectationFailure "provider was never called"
          Just sys -> do
            sys `shouldSatisfy` T.isInfixOf "ZOE_SYSTEM_PROMPT_MARKER"
            sys `shouldNotSatisfy` T.isInfixOf "REPO_PROJECT_MARKER"

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
        let stopSpec = stopCommandSpecForSession (sdAbortReg baseDeps) targetSid noStopTranscriptWriter
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
        let stopSpec = stopCommandSpecForSession (sdAbortReg baseDeps) targetSid
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
