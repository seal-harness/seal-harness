{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Signal' — the Signal chat-channel adapter.
module Seal.Channels.Chat.SignalAdapterSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (newTVarIO)
import Control.Exception (bracket)
import Data.Aeson qualified as A
import Data.Aeson ((.=))
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Data.Vector qualified as V
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory
  ( doesFileExist, findExecutable, getPermissions, setOwnerExecutable
  , setPermissions )
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldSatisfy)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Loop
  ( ChatChannelConfig (..)
  , defaultChatChannelConfig
  , newWatchState
  , newThinkingTabs
  , newBgSessions
  , newPendingAsks
  , handleServerEvent
  )
import Seal.Channels.Chat.RateLimit (defaultStreamProgressConfig)
import Seal.Channels.Chat.Signal
  ( SignalChatTransport (..)
  , withSignalChatChannel
  , mkMockSignalChatTransport
  , mkRealSignalChatTransport
  , chunkMessage
  )
import Seal.Channels.Chat.Types
  ( InboundMessage (..)
  , defaultGatewayConfig, convKeyFromSource, newStreamingState
  , ChatMessageId (..), ReceivedMessage (..) )
import Seal.Channels.Chat.WsClient (WsClient (..))
import Seal.Gateway.Types.AllowList (AllowList (..))
import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.Core (mkSessionId, SessionId)
import Seal.Gateway.Types.MessageSource
  ( mkConversationId, mkMessageSource, MessageSource )
import Seal.Gateway.Types.Stream (ServerEvent (..))

-- | Build a MessageSource for a conversation id (test helper).
mkMessageSourceFor :: T.Text -> MessageSource
mkMessageSourceFor cid =
  case mkConversationId cid of
    Left _   -> error "bad cid"
    Right c  -> case mkMessageSource c Signal Nothing mempty of
      Right ms -> ms
      Left _   -> error "MessageSource construction failed"

-- | Test sid helper.
mkSid :: T.Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

-- | A dummy received message for seeding the last-sender in tests.
dummyMsg :: ReceivedMessage
dummyMsg = ReceivedMessage
  { rmConversationId = case mkConversationId "sig:+15551234567" of Right c -> c; Left _ -> error "bad cid"
  , rmSender = Just "+15551234567"
  , rmReplyTo = "+15551234567"
  , rmBody = "init"
  , rmCallbackData = Nothing
  , rmCallbackId = Nothing
  , rmCallbackMessageId = Nothing
  }

-- | Wait briefly for the reader thread to process the seed message.
waitForSeed :: IO ()
waitForSeed = threadDelay 50000  -- 50ms

-- | Test backoff: 1ms — keeps the retry test sub-second.
testBackoff :: Int
testBackoff = 1000

spec :: Spec
spec = do
  describe "chunkMessage" $ do
    it "returns the message as-is when under the limit" $
      chunkMessage 100 "hello" `shouldBe` ["hello"]

    it "splits a long message at the limit" $
      chunkMessage 5 "abcdefghij" `shouldBe` ["abcde", "fghij"]

    it "handles empty string" $
      chunkMessage 5 "" `shouldBe` [""]

    it "handles exactly the limit" $
      chunkMessage 5 "abcde" `shouldBe` ["abcde"]

  describe "ChatChannel SignalChatChannel" $ do
    it "has label 'signal'" $ do
      (transport, _, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        ccLabel ch `shouldBe` "signal"

    it "sends messages via the transport" $ do
      (transport, getCaptured, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        ccSend ch "hello world"
        captured <- getCaptured
        captured `shouldBe` ["hello world"]

    it "sends with id and returns a ChatMessageId" $ do
      (transport, _, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        mId <- ccSendWithId ch "test"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected a message id"

    it "edits messages via the transport" $ do
      (transport, _, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        ok <- ccEditMessage ch (ChatMessageId "123") "new content"
        ok `shouldBe` True

    it "chunks long sends" $ do
      (transport, getCaptured, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 5 testBackoff transport $ \ch -> do
        waitForSeed
        ccSend ch "abcdefghij"
        captured <- getCaptured
        captured `shouldBe` ["abcde", "fghij"]

  describe "chunkMessage word awareness" $ do
    it "keeps a numbered option line whole instead of cutting mid-word" $ do
      let q = "Which branch?\n\n1) main \8212 the default branch\n2) develop \8212 integration\n\nReply with a number or type your own answer."
          chunks = chunkMessage 60 q
      T.concat chunks `shouldBe` q
      chunks `shouldSatisfy` all (\c -> T.length c <= 60)

    it "hard-splits only a token longer than the limit" $ do
      chunkMessage 10 "abcdefghijklmno" `shouldBe` ["abcdefghij", "klmno"]

  describe "edit timestamp parsing" $ do
    it "returns False for a non-numeric timestamp instead of throwing" $ do
      -- The timestamp reaches a subprocess argument; a partial 'read' would
      -- throw here rather than failing the edit.
      let transport = SignalChatTransport
            { sctReceive = pure (Left "inbox empty")
            , sctSend = \_c _b -> pure ()
            , sctSendWithId = \_c _b -> pure (Just "1")
            , sctEditMessage = \_c ts _content ->
                case TR.decimal ts of
                  Right (n, rest) | T.null rest, n >= (0 :: Int) -> pure True
                  _ -> pure False
            , sctClose = pure ()
            }
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        ok <- ccEditMessage ch (ChatMessageId "not-a-number") "x"
        ok `shouldBe` False

  describe "reader loop retry" $ do
    it "retries after a transient error and delivers subsequent messages" $ do
      -- The reader loop must NOT die on a transient error (Left from
      -- sctReceive).  It should log, back off, and retry — eventually
      -- delivering messages that arrive after the error.
      callCount <- newIORef (0 :: Int)
      let transport = SignalChatTransport
            { sctReceive = do
                n <- readIORef callCount
                modifyIORef' callCount (+1)
                case n of
                  0 -> pure (Left "transient network error")
                  1 -> pure (Right dummyMsg)
                  _ -> pure (Left "inbox empty")
            , sctSend = \_c _b -> pure ()
            , sctSendWithId = \_c _b -> pure (Just "1")
            , sctEditMessage = \_c _ts _content -> pure True
            , sctClose = pure ()
            }
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        mMsg <- ccReceive ch
        mMsg `shouldSatisfy` isJust
        case mMsg of
          Just (InboundMessage _ body _) -> body `shouldBe` "init"
          Nothing -> fail "expected a message after retry"

    it "does not die on repeated transient errors" $ do
      -- Even after multiple consecutive errors, the reader should still
      -- be alive and deliver a message once one becomes available.
      callCount <- newIORef (0 :: Int)
      let transport = SignalChatTransport
            { sctReceive = do
                n <- readIORef callCount
                modifyIORef' callCount (+1)
                if n < 3
                  then pure (Left "transient error")
                  else if n == 3 then pure (Right dummyMsg) else pure (Left "inbox empty")
            , sctSend = \_c _b -> pure ()
            , sctSendWithId = \_c _b -> pure (Just "1")
            , sctEditMessage = \_c _ts _content -> pure True
            , sctClose = pure ()
            }
      withSignalChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        mMsg <- ccReceive ch
        mMsg `shouldSatisfy` isJust
        case mMsg of
          Just (InboundMessage _ body _) -> body `shouldBe` "init"
          Nothing -> fail "expected a message after repeated retries"

  describe "single-edited-bubble progress (Signal)" $ do
    it "sends a pure-text turn once, with no edits" $ do
      -- Signal used to run with streaming disabled, so every text segment
      -- and every tool call was flushed as a NEW message. It now opts into
      -- the single-bubble style: tool progress goes in one edited bubble, and
      -- the answer is delivered as its own message so it notifies.
      (transport, getCaptured, getEdits) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 4000 testBackoff transport $ \ch -> do
        waitForSeed
        let key = convKeyFromSource (mkMessageSourceFor "sig:+15551234567")
            stubWs = WsClient
              { wcFocus = \_ -> pure ()
              , wcFocusSince = \_ _ -> pure ()
              , wcClose = pure ()
              }
        ss <- newStreamingState
        conns <- newTVarIO (Map.singleton key (mkSid "stream", stubWs, ss))
        mgr <- newManager defaultManagerSettings
        let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                      { cccStreamCfg = defaultStreamProgressConfig }
            sid = mkSid "stream"
            frameLen i = 79 + 5 * (i - 1)
            frame i = streamingJsonFor (T.replicate (frameLen i) "x")
        pendingAsks <- newPendingAsks
        tabTracker <- newTVarIO Map.empty
        watchState <- newWatchState
        thinkingTabs <- newThinkingTabs
        bg <- newBgSessions
        let fire = handleServerEvent cfg ch key conns pendingAsks bg
                     tabTracker watchState thinkingTabs sid
        fire (SeActivity sid (A.object
          ["kind" .= ("harness-status" :: T.Text), "status" .= ("thinking" :: T.Text)]))
        mapM_ (fire . SeEntryUpdate sid . frame) [1 .. 40]
        -- The answer comes from the RECORDED entry, not the preview frames.
        fire (SeEntry sid (A.object
          [ "id" .= ("e1" :: T.Text)
          , "direction" .= ("response" :: T.Text)
          , "payload" .= A.object
              [ "content" .= A.Array
                  (V.fromList [A.object ["text" .= T.replicate 274 "x", "type" .= ("text" :: T.Text)]])
              ]
          ]))
        fire (SeActivity sid (A.object
          ["kind" .= ("harness-status" :: T.Text), "status" .= ("idle" :: T.Text)]))
        edits <- getEdits
        sends <- getCaptured
        -- A pure-text turn has no tool call, so no progress bubble is
        -- created and nothing is edited: the answer is delivered once, as its
        -- own (notifying) message.
        length edits `shouldBe` 0
        length sends `shouldBe` 1
        case reverse sends of
          (final : _) -> final `shouldBe` T.replicate 274 "x"
          [] -> expectationFailure "expected the answer to be delivered"

  -- Chunked-send ordering, exercised against a fake parallel-executing
  -- signal-cli (see 'spec_chunkOrdering' below).
  spec_chunkOrdering

-- | A streaming @entry-update@ frame carrying @t@ as the accumulated turn text.
streamingJsonFor :: T.Text -> A.Value
streamingJsonFor t = A.object
  [ "id" .= ("streaming" :: T.Text)
  , "direction" .= ("response" :: T.Text)
  , "payload" .= A.object
      [ "content" .= A.Array
          (V.fromList [A.object ["text" .= t, "type" .= ("text" :: T.Text)]])
      ]
  ]

-- ---------------------------------------------------------------------------
-- Chunked-send ordering against a parallel-executing signal-cli
-- ---------------------------------------------------------------------------

-- | A stand-in @signal-cli@ that reproduces the upstream behaviour this fix
-- exists for, so the ordering contract is asserted against a real subprocess
-- rather than a mock that cannot exhibit the race.
--
-- signal-cli >= 0.12.3 executes JSON-RPC requests /in parallel/ (its CHANGELOG
-- says so; 0.13.16 then added "ensure every sent message gets a unique
-- timestamp" after #1783 reported concurrent sends sharing one and being
-- dropped by the apps). The timestamp it assigns is the message id, so two
-- concurrent sends can commit out of order.
--
-- This fake models that: every @send@ is handled on its own thread, and a send
-- that starts while another is still in flight is recorded as an OVERLAP — the
-- observable symptom of the bug. Recording overlaps, rather than only the final
-- order, is what keeps the assertion non-vacuous: a transport that awaits each
-- response can never produce one, while a fire-and-forget transport produces
-- one per extra chunk.
--
-- The log path is baked into the script because @argv[1]@ is the transport's
-- own @--output=json@ flag. @--version@ is answered so the preflight probe
-- passes; the loop exits when stdin closes.
signalCliShim :: FilePath -> String
signalCliShim logPath = unlines
  [ "#!/bin/sh"
  , "case \"$1\" in"
  , "  --version) echo 'signal-cli 0.14.7'; exit 0 ;;"
  , "esac"
  , "lock='" <> logPath <> ".lock'"
  , "log='" <> logPath <> "'"
  , ""
  , "handle_send() {"
  , "  if mkdir \"$lock\" 2>/dev/null; then"
  , "    echo START >> \"$log\""
  , "  else"
  , "    echo OVERLAP >> \"$log\""
  , "  fi"
  , "  # Widen the window so a client that does not await reliably overlaps."
  , "  sleep 0.05"
  , "  echo END >> \"$log\""
  , "  rmdir \"$lock\" 2>/dev/null"
  , "  id=$(printf '%s' \"$1\" | sed -n 's/.*\"id\":[ ]*\\([0-9][0-9]*\\).*/\\1/p')"
  , "  printf '{\"jsonrpc\":\"2.0\",\"result\":{\"timestamp\":%s},\"id\":%s}\\n' \\"
  , "         \"$((1000 + ${id:-0}))\" \"${id:-0}\""
  , "}"
  , ""
  , "# Emit one inbound message so the channel records a reply target;"
  , "# 'sctSend' is addressed to the last sender and is a no-op without one."
  , "# Run it in a subshell: a pipe's stdout is block-buffered, so a bare"
  , "# printf in the main shell would not reach the client until this"
  , "# process exits. A subshell flushes on exit."
  , "( printf '{\"jsonrpc\":\"2.0\",\"method\":\"receive\",\"params\":{\"envelope\":{\"source\":\"+15551234567\",\"dataMessage\":{\"message\":\"init\"}}}}\\n' )"
  , ""
  , "# Dispatch each send on its own thread, exactly like signal-cli."
  , "while IFS= read -r line; do"
  , "  case \"$line\" in"
  , "    *'\"method\"'*'\"send\"'*) handle_send \"$line\" & ;;"
  , "  esac"
  , "done"
  , "wait"
  ]

-- | Poll the shim's log until it holds @n@ completed sends (@START@ plus
-- @OVERLAP@ entries are each logged before the corresponding @END@) or the
-- bounded attempt budget runs out, then return whatever is on disk.
--
-- Bounded so a genuinely broken shim fails the assertions quickly instead of
-- hanging the suite; the budget is generous relative to the shim's 50 ms
-- per-send delay.
waitForSends :: FilePath -> Int -> Int -> IO [String]
waitForSends logPath n attemptsLeft = do
  present <- doesFileExist logPath
  entries <- if present
    then filter (not . null) . lines <$> readFile logPath
    else pure []
  if length (filter (== "END") entries) >= n || attemptsLeft <= 0
    then pure entries
    else threadDelay 5000 >> waitForSends logPath n (attemptsLeft - 1)

-- | Write the fake into a temp dir and run @action@ with it first on @PATH@,
-- restoring @PATH@ afterwards so it cannot leak into other specs.
withSignalCliShim :: (FilePath -> IO a) -> IO a
withSignalCliShim action = withSystemTempDirectory "seal-sig-shim" $ \dir -> do
  let shimPath = dir </> "signal-cli"
      logPath  = dir </> "calls.log"
  writeFile shimPath (signalCliShim logPath)
  perms <- getPermissions shimPath
  setPermissions shimPath (setOwnerExecutable True perms)
  origPath <- lookupEnv "PATH"
  bracket
    (setEnv "PATH" (maybe dir (\p -> dir <> ":" <> p) origPath) >> pure origPath)
    (setEnv "PATH" . fromMaybe "/usr/bin:/bin")
    (\_ -> action logPath)

spec_chunkOrdering :: Spec
spec_chunkOrdering = describe "chunked send ordering (real transport)" $ do
  it "sends chunks strictly sequentially, never overlapping" $ do
    -- The bug: ccSend chunks a long answer and mapM_ walks the chunks. With a
    -- fire-and-forget sctSend every chunk frame was written back-to-back, so
    -- signal-cli (parallel since 0.12.3) committed them concurrently, which
    -- split the answer across messages and delivered the parts out of order.
    -- Awaiting each response makes that mapM_ a strict sequence.
    mSh <- findExecutable "sh"
    case mSh of
      Nothing -> pendingWith "sh not on PATH"
      Just _ -> withSignalCliShim $ \logPath -> do
        eTransport <- mkRealSignalChatTransport "+15551234567"
        case eTransport of
          Left e -> expectationFailure ("transport failed: " <> T.unpack e)
          Right transport ->
            withSignalChatChannel AllowAll 5 testBackoff transport $ \ch -> do
              waitForSeed
              ccSend ch "abcdefghijklmno"   -- 3 chunks at limit 5
              -- Wait (bounded) for the shim to finish all three sends.
              --
              -- This is load-bearing. With the fix each send is awaited, so
              -- the log is already complete when ccSend returns. Under the
              -- bug ccSend returns as soon as the frames are written, while
              -- the shim's handlers are still running -- reading immediately
              -- would see an empty log and fail on the START count, which is
              -- a torn-down-shim artifact rather than the ordering violation
              -- this test exists to catch. Waiting lets the concurrent
              -- handlers finish so the OVERLAP assertion is the one that
              -- fires.
              entries <- waitForSends logPath 3 (200 :: Int)
              -- Non-vacuity: the fake really was driven once per chunk. A
              -- send is logged as either START (claimed the in-flight slot) or
              -- OVERLAP (found it taken), so the two together count the sends.
              length (filter (`elem` ["START", "OVERLAP"]) entries) `shouldBe` 3
              -- The fix: no send began while another was in flight. Under the
              -- bug this is ["OVERLAP", "OVERLAP"] - the chunks racing.
              filter (== "OVERLAP") entries `shouldBe` []
