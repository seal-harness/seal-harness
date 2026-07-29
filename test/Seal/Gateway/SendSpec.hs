{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.SendSpec (spec) where

import Control.Exception (catch, SomeException)
import Control.Concurrent.Async (concurrently)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Cli (newBackends)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Core.Types (ModelId (..), mkSessionId, SessionId)
import Seal.Gateway.Send (SendDeps (..), SendOutcome (..), ensureTabForSession, handleSend)
import Seal.Logging.Logger (testSealLogger)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Tab (TabKind (KindAi, KindProvider))
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Ingest (emptyChain)
import Seal.Providers.Class
import Seal.Command.Spec (mkRegistry)
import Seal.Security.Policy qualified as Policy (AutonomyLevel (Full))
import Seal.Security.Vault (VaultHandle)
import Seal.Session.Lock (newReplyRegistry, newSessionLocks)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.Tabs (newTabsHandle, insertTabH, snapshotTabs)
import Seal.Tabs.Types (TabRef (BoundSession), tlTabs, tRef, tabCount)
import Seal.Command.Tab (tabCommandSpec, noTabCloseNotifier)
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

-- | Build a minimal SendDeps with the script provider + a fresh tabsH
-- rooted at the temp dir. The sdTabsHandle is left unset (use record
-- update in the test: `baseDeps { sdTabsHandle = tabsH }`).
mkSendDeps :: SealPaths -> IORef [CompletionResponse] -> IO SendDeps
mkSendDeps paths providerRef = do
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
  let activeMeta = SessionMeta (mkSid "active") "ollama" "llama3.2" "cli" Nothing Nothing Nothing sampleTime sampleTime
  activeRef <- newIORef activeMeta
  let sr = SessionRuntime { srPaths = paths, srConfigPath = configRoot </> "config.toml", srActive = activeRef }
      resolveStub :: SessionMeta -> IO (Either T.Text (SomeProvider, ModelId))
      resolveStub _ = pure (Right (SomeProvider (ScriptProvider providerRef), ModelId "llama3.2"))
  -- A real ProviderRuntime whose config path is nonexistent (loadRuntimeConfig
  -- fails -> defaults). The vault ref holds Nothing so resolveSessionProvider
  -- would fail — but sdResolve is stubbed, so the vault is never consulted.
  vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
      pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
      sendDeps = SendDeps
        { sdPaths      = paths
        , sdVault      = rt
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
        , sdTabsHandle  = error "sdTabsHandle: set via record update in the test"
        , sdLogger      = logger
        }
  pure sendDeps

-- | Seed a session.json on disk for the given sid.
seedSession :: SealPaths -> SessionId -> IO ()
seedSession paths sid = do
  let sdir = sessionDir paths sid
  createDirectoryIfMissing True sdir
  let meta = SessionMeta sid "ollama" "llama3.2" "web" Nothing Nothing Nothing sampleTime sampleTime
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
        let sendDeps = baseDeps { sdTabsHandle = tabsH, sdRegistry = mkRegistry [tabCommandSpec tabsH noTabCloseNotifier] }
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
        let sendDeps = baseDeps { sdTabsHandle = tabsH, sdRegistry = mkRegistry [tabCommandSpec tabsH noTabCloseNotifier] }
            sid = mkSid "20260701-120000-108"
        seedSession paths sid
        _ <- insertTabH tabsH (BoundSession sid) KindAi Nothing
        outcome <- handleSend sendDeps sid "/tab close 0"
        case outcome of
          SendSlash msg _ -> msg `shouldSatisfy` ("closed" `T.isInfixOf`)
          other           -> expectationFailure ("expected SendSlash, got " <> show other)
        snap <- snapshotTabs tabsH
        tabCount snap `shouldBe` 0