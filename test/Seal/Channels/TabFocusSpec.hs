{-# LANGUAGE OverloadedStrings #-}
-- | High-level tests for the @\/tab focus <N>@ command across chat channels.
-- Drives 'runChannelLoop' with a 'FakeChannel' to verify the full invariant:
-- @\/tab focus <N>@ updates the per-conversation cursor so subsequent plain
-- messages route to the focused tab's session, the channel receives the last
-- assistant reply from the focused session, and future replies from that
-- session are fanned out to the channel via the reply registry.
module Seal.Channels.TabFocusSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Cli (newBackends)
import Seal.Channels.Cursor (cursorLookup, newCursorStore, cursorSet)
import Seal.Channels.Loop
  ( ChannelDeps (..), newChannelDeps, runChannelLoop )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (mkRegistry)
import Seal.Config.File (defaultRuntimeConfig)
import Seal.Config.Paths (SealPaths (..), sessionConversationPath, sessionDir)
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, mkConversationId, mkMessageSource, mkUserId )
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner (..))
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (TabKind (KindAi))
import Seal.Ingest (emptyChain)
import Seal.Logging.Logger (testSealLogger)
import Seal.Providers.Class (Role (..), textMsg)
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Session.Lock qualified as Lock
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta)
import Seal.Tabs (insertTabH, newTabsHandle)
import Seal.Tabs.Types (TabRef (BoundSession))
import Seal.TestHelpers.FakeChannel
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.Vault.Commands (VaultRuntime (..))

-- | A stub TmuxRunner that always succeeds with empty output.
stubTmux :: TmuxRunner
stubTmux = TmuxRunner (\_args -> pure (Right ""))

-- | A fixed timestamp for test session metas.
testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 1 1) 0

-- | Create a session on disk with the given sid suffix.
mkSession :: SealPaths -> Text -> IO SessionMeta
mkSession paths label = do
  let meta = SessionMeta
        { smId = either (error "sid") id (mkSessionId label)
        , smProvider = "ollama"
        , smModel = "llama3.2"
        , smChannel = "telegram"
        , smAgent = Nothing
        , smSystemOverride = Nothing
        , smAgentName = Nothing
        , smDescription = Nothing
        , smCreatedAt = testTime
        , smLastActive = testTime
        }
  saveSessionMeta paths meta
  pure meta

-- | Write a conversation.jsonl with one user + one assistant message.
seedConversation :: SealPaths -> SessionId -> Text -> IO ()
seedConversation paths sid assistantReply = do
  let convPath = sessionConversationPath paths sid
  createDirectoryIfMissing True (sessionDir paths sid)
  let userMsg = textMsg Seal.Providers.Class.User "previous question"
      asstMsg = textMsg Seal.Providers.Class.Assistant assistantReply
      body = BL.intercalate "\n" (map A.encode [userMsg, asstMsg]) <> "\n"
  BL.writeFile convPath body

-- | Build a minimal ChannelDeps for testing.
mkChannelDeps :: SealPaths -> IO ChannelDeps
mkChannelDeps paths = do
  let cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  backends <- newBackends cfgRoot repo
  harnessReg <- newHarnessRegistry
  let vaultRt = VaultRuntime
        { vrPaths = paths
        , vrConfigPath = cfgRoot </> "config.toml"
        , vrHandleRef = error "vrHandleRef: stubbed — TabFocusSpec does not read the vault"
        }
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef (0 :: Int)
  let pr = ProviderRuntime
        { prConfigPath = cfgRoot </> "config.toml"
        , prVault = vaultRt
        , prManager = mgr
        , prCallCounter = cntRef
        }
  approvals <- newApprovalCache
  tabsH <- newTabsHandle
  cursors <- newCursorStore
  logger <- testSealLogger
  newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
    harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger cursors

-- | A MessageSource for the test conversation.
testMsgSource :: MessageSource
testMsgSource =
  case mkMessageSource
         (either (error "cid") id (mkConversationId "test-conv-1"))
         Telegram
         (Just (either (error "uid") id (mkUserId "+15551234567")))
         Map.empty of
    Right ms -> ms
    Left e   -> error ("mkMessageSource: " <> T.unpack e)

-- | The conversation key for the cursor store.
convKey :: (Text, Text)
convKey = ("telegram", "test-conv-1")

-- | A plainHandler that captures which session it was called with.
captureHandler :: MVar SessionId -> ChannelHandle -> SessionMeta -> Maybe MessageSource -> Text -> IO ()
captureHandler mvar _ meta _ _ = putMVar mvar (smId meta)

-- | A no-op plainHandler.
noopHandler :: ChannelHandle -> SessionMeta -> Maybe MessageSource -> Text -> IO ()
noopHandler _ _ _ _ = pure ()

-- | Wait for a condition to become true, polling at 20ms intervals up to 1s.
waitFor :: IO Bool -> IO ()
waitFor p = go (0 :: Int)
  where
    go n
      | n >= 50 = pure ()
      | otherwise = do
          done <- p
          if done then pure () else threadDelay 20000 >> go (n + 1)

spec :: Spec
spec = describe "Seal.Channels.TabFocus" $ do
  it "/tab focus <N> updates the conversation cursor so the next plain message routes to the focused tab's session" $
    withSystemTempDirectory "seal-tabfocus" $ \tmp -> do
      let paths = SealPaths
            { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
            , spKeys = tmp </> "keys", spCache = tmp </> "cache"
            }
      deps <- mkChannelDeps paths
      let tabsH = cdTabs deps
          cursors = cdCursors deps

      -- Create two sessions + tabs.
      metaA <- mkSession paths "session-a"
      metaB <- mkSession paths "session-b"
      _ <- insertTabH tabsH (BoundSession (smId metaA)) KindAi Nothing
      _ <- insertTabH tabsH (BoundSession (smId metaB)) KindAi Nothing

      -- Set the conversation's cursor to session A (tab 0).
      cursorSet cursors convKey (BoundSession (smId metaA))

      -- Capture which session the plainHandler is called with.
      handlerSid <- newEmptyMVar :: IO (MVar SessionId)
      let plainHandler = captureHandler handlerSid

      -- Build a FakeChannel with the inbox: /tab focus 1, then "hello".
      fc <- newFakeChannelWith False
              [ (testMsgSource, "/tab focus 1")
              , (testMsgSource, "hello")
              ]
              []
      let withCh action = action fc
      ar <- newAskReplyStore 0

      -- Run the loop (it terminates when the inbox is drained).
      runChannelLoop deps withCh plainHandler (mkRegistry []) emptyChain ar tabsH Nothing Nothing

      -- The plainHandler is forked, so wait for it to be called.
      waitFor (fmap (const True) (tryTakeMVar handlerSid))

      -- The plainHandler should have been called with session B's sid.
      routedSid <- takeMVar handlerSid
      routedSid `shouldBe` smId metaB

      -- The cursor should now point at session B.
      mCursor <- cursorLookup cursors convKey
      mCursor `shouldBe` Just (BoundSession (smId metaB))

  it "/tab focus <N> sends the last assistant reply from the focused session to the channel" $
    withSystemTempDirectory "seal-tabfocus-reply" $ \tmp -> do
      let paths = SealPaths
            { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
            , spKeys = tmp </> "keys", spCache = tmp </> "cache"
            }
      deps <- mkChannelDeps paths
      let tabsH = cdTabs deps
          cursors = cdCursors deps

      -- Create two sessions + tabs.
      metaA <- mkSession paths "session-a-reply"
      metaB <- mkSession paths "session-b-reply"
      _ <- insertTabH tabsH (BoundSession (smId metaA)) KindAi Nothing
      _ <- insertTabH tabsH (BoundSession (smId metaB)) KindAi Nothing

      -- Seed session B's conversation with a prior assistant reply.
      let expectedReply = "Here is the answer from session B"
      seedConversation paths (smId metaB) expectedReply

      -- Set the conversation's cursor to session A (tab 0).
      cursorSet cursors convKey (BoundSession (smId metaA))

      -- Build a FakeChannel with just /tab focus 1.
      fc <- newFakeChannelWith False
              [ (testMsgSource, "/tab focus 1")
              ]
              []
      let withCh action = action fc
      ar <- newAskReplyStore 0

      runChannelLoop deps withCh noopHandler (mkRegistry []) emptyChain ar tabsH Nothing Nothing

      -- The channel should have received the last assistant reply from session B.
      sends <- getSent fc
      sends `shouldSatisfy` any (expectedReply `T.isInfixOf`)

  it "/tab focus <N> subscribes the channel to the focused session so future replies are fanned out" $
    withSystemTempDirectory "seal-tabfocus-subscribe" $ \tmp -> do
      let paths = SealPaths
            { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
            , spKeys = tmp </> "keys", spCache = tmp </> "cache"
            }
      deps <- mkChannelDeps paths
      let tabsH = cdTabs deps
          cursors = cdCursors deps
          replies = cdReplies deps

      -- Create two sessions + tabs.
      metaA <- mkSession paths "session-a-sub"
      metaB <- mkSession paths "session-b-sub"
      _ <- insertTabH tabsH (BoundSession (smId metaA)) KindAi Nothing
      _ <- insertTabH tabsH (BoundSession (smId metaB)) KindAi Nothing

      -- Seed session B's conversation with a prior assistant reply.
      seedConversation paths (smId metaB) "prior reply from B"

      -- Set the conversation's cursor to session A (tab 0).
      cursorSet cursors convKey (BoundSession (smId metaA))

      -- Build a FakeChannel with just /tab focus 1.
      fc <- newFakeChannelWith False
              [ (testMsgSource, "/tab focus 1")
              ]
              []
      let withCh action = action fc
      ar <- newAskReplyStore 0

      runChannelLoop deps withCh noopHandler (mkRegistry []) emptyChain ar tabsH Nothing Nothing

      -- The /tab focus command should have subscribed the channel handle to
      -- session B's replies. Simulate a reply fanout (as would happen after
      -- a web-originated turn on session B) and verify the channel receives it.
      Lock.replyFanout replies (smId metaB) "new reply from session B"

      sends <- getSent fc
      sends `shouldSatisfy` any ("new reply from session B" `T.isInfixOf`)

  it "/tab focus on an out-of-range index does not change the cursor" $
    withSystemTempDirectory "seal-tabfocus-oob" $ \tmp -> do
      let paths = SealPaths
            { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
            , spKeys = tmp </> "keys", spCache = tmp </> "cache"
            }
      deps <- mkChannelDeps paths
      let tabsH = cdTabs deps
          cursors = cdCursors deps

      -- Create one session + tab.
      metaA <- mkSession paths "session-a-oob"
      _ <- insertTabH tabsH (BoundSession (smId metaA)) KindAi Nothing

      -- Set the conversation's cursor to session A (tab 0).
      cursorSet cursors convKey (BoundSession (smId metaA))

      -- /tab focus 5 — no tab at index 5 (only tab 0 exists).
      fc <- newFakeChannelWith False
              [ (testMsgSource, "/tab focus 5")
              ]
              []
      let withCh action = action fc
      ar <- newAskReplyStore 0

      runChannelLoop deps withCh noopHandler (mkRegistry []) emptyChain ar tabsH Nothing Nothing

      -- The cursor should still point at session A.
      mCursor <- cursorLookup cursors convKey
      mCursor `shouldBe` Just (BoundSession (smId metaA))

      -- The channel should have received a focus-failed message.
      sends <- getSent fc
      sends `shouldSatisfy` any ("focus failed" `T.isInfixOf`)
