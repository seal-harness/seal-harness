{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.StreamProgressSpec (spec) where

import Data.Default (Default (..))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, fromGregorian, secondsToDiffTime)
import Data.Time.Clock (UTCTime(..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf1, (===))

import Seal.Channels.StreamProgress
  ( StreamProgressConfig (..)
  , newStreamProgress
  , onToolCall
  , segmentBreak
  , opEmoji
  , resolveStreamProgressConfig
  , formatToolLine
  , shouldEdit
  , addCursor
  , stripCursor
  )
import Seal.Core.Types (OpName (..))
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))

spec :: Spec
spec = do
  describe "Seal.Channels.StreamProgress.defaultStreamProgressConfig" $ do
    it "is disabled by default" $
      spcEnabled def `shouldBe` False

    it "has tool_progress enabled when enabled" $
      spcToolProgress def `shouldBe` True

    it "has text_streaming enabled when enabled" $
      spcTextStreaming def `shouldBe` True

    it "has a 1500ms edit interval" $
      spcEditIntervalMs def `shouldBe` 1500

    it "has a buffer threshold of 80 codepoints" $
      spcBufferThreshold def `shouldBe` 80

    it "has a block cursor" $
      spcCursor def `shouldBe` "\x2589"

  describe "Seal.Channels.StreamProgress.resolveStreamProgressConfig" $ do
    it "returns disabled config when Nothing" $
      resolveStreamProgressConfig Nothing `shouldBe` def

    it "resolves a fully-populated config" $
      resolveStreamProgressConfig (Just def { spcEnabled = True, spcEditIntervalMs = 2000 })
        `shouldBe` def { spcEnabled = True, spcEditIntervalMs = 2000 }

    it "fills defaults for absent fields" $
      resolveStreamProgressConfig (Just def { spcEnabled = True })
        `shouldBe` def { spcEnabled = True }

  describe "opEmoji" $ do
    it "returns the laptop emoji for SHELL_EXEC" $
      opEmoji (OpName "SHELL_EXEC") `shouldBe` "\x1F4BB"

    it "returns the open book emoji for FILE_READ" $
      opEmoji (OpName "FILE_READ") `shouldBe` "\x1F4D6"

    it "returns the writing hand emoji for FILE_WRITE" $
      opEmoji (OpName "FILE_WRITE") `shouldBe` "\x270D\xFE0F"

    it "returns the wrench emoji for FILE_PATCH" $
      opEmoji (OpName "FILE_PATCH") `shouldBe` "\x1F527"

    it "returns the magnifying glass emoji for WEB_SEARCH" $
      opEmoji (OpName "WEB_SEARCH") `shouldBe` "\x1F50D"

    it "returns the question mark emoji for ASK_HUMAN" $
      opEmoji (OpName "ASK_HUMAN") `shouldBe` "\x2753"

    it "returns the rocket emoji for AGENT_START" $
      opEmoji (OpName "AGENT_START") `shouldBe` "\x1F680"

    it "returns the high-voltage emoji for unknown opcodes" $
      opEmoji (OpName "UNKNOWN_OP") `shouldBe` "\x26A1"

  describe "formatToolLine" $ do
    it "shows the opcode name with the correct emoji and truncated input" $
      formatToolLine Set.empty (OpName "SHELL_EXEC") "{\"command\":\"ls\"}"
        `shouldBe` "\x1F4BB SHELL_EXEC {\"command\":\"ls\"}"

    it "truncates long inputs to 120 chars + ..." $
      let longInput = T.replicate 200 "x"
      in formatToolLine Set.empty (OpName "FILE_READ") longInput
           `shouldBe` "\x1F4D6 FILE_READ " <> T.take 120 longInput <> "..."

    it "redacts input for secret-bearing opcodes" $
      formatToolLine (Set.singleton (OpName "SECRET_GET")) (OpName "SECRET_GET") "vault-key"
        `shouldBe` "\x1F5DD SECRET_GET <redacted>"

    it "does not redact non-secret opcodes" $
      formatToolLine (Set.singleton (OpName "SECRET_GET")) (OpName "SHELL_EXEC") "ls"
        `shouldBe` "\x1F4BB SHELL_EXEC ls"

  describe "shouldEdit" $ do
    let cfg = def { spcEditIntervalMs = 1000, spcBufferThreshold = 80 }
        t0 = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

    it "sends immediately when no prior edit" $
      shouldEdit cfg t0 Nothing 0 `shouldBe` True

    it "sends when buffer threshold is exceeded regardless of time" $
      shouldEdit cfg t0 (Just t0) 100 `shouldBe` True

    it "does not send when below threshold and within edit interval" $
      shouldEdit cfg t0 (Just t0) 10 `shouldBe` False

    it "sends when edit interval has elapsed even below threshold" $
      let t1 = addUTCTime 1.5 t0
      in shouldEdit cfg t1 (Just t0) 10 `shouldBe` True

    it "does not send when within edit interval and below threshold" $
      let t1 = addUTCTime 0.5 t0
      in shouldEdit cfg t1 (Just t0) 10 `shouldBe` False

  describe "addCursor / stripCursor" $ do
    let cfg = def { spcCursor = "\x2589" }

    it "addCursor appends the cursor" $
      addCursor cfg "hello" `shouldBe` "hello\x2589"

    it "stripCursor removes a trailing cursor" $
      stripCursor cfg "hello\x2589" `shouldBe` "hello"

    it "stripCursor leaves text without a cursor unchanged" $
      stripCursor cfg "hello" `shouldBe` "hello"

    it "addCursor then stripCursor is identity" $
      stripCursor cfg (addCursor cfg "hello") `shouldBe` "hello"

    prop "stripCursor . addCursor == id" $
      forAll genText $ \t ->
        stripCursor cfg (addCursor cfg t) === t

  -- The core regression test: multiple tool calls within a single turn
  -- must edit the same message, not send a new message for each call.
  -- This is the notification-spam bug: each tool call produced a separate
  -- chat message, flooding the channel. The fix: the StreamProgress
  -- persists across tool calls within a turn so spToolMsgId is reused.
  describe "onToolCall message reuse" $ do
    let cfg = def { spcEnabled = True, spcToolProgress = True }

    it "sends one message then edits it for subsequent tool calls" $ do
      (h, getSendWithIds, getEdits) <- mockEditChannel
      sp <- newStreamProgress cfg h Set.empty
      onToolCall sp (OpName "SHELL_EXEC") "ls"
      onToolCall sp (OpName "FILE_READ") "README.md"
      onToolCall sp (OpName "FILE_WRITE") "test.hs"

      sends <- getSendWithIds
      edits <- getEdits
      length sends `shouldBe` 1
      length edits `shouldBe` 2

    it "accumulates tool lines in the edited message" $ do
      (h, _getSendWithIds, getEdits) <- mockEditChannel
      sp <- newStreamProgress cfg h Set.empty
      onToolCall sp (OpName "SHELL_EXEC") "ls"
      onToolCall sp (OpName "FILE_READ") "README.md"

      edits <- getEdits
      case edits of
        [] -> expectationFailure "expected at least one edit"
        (_, content) : _ -> do
          T.isInfixOf "SHELL_EXEC" content `shouldBe` True
          T.isInfixOf "FILE_READ" content `shouldBe` True

    it "does not reset tool message id on segmentBreak" $ do
      -- segmentBreak finalizes the text bubble (if any) but must NOT
      -- reset the tool-progress bubble state. The tool bubble persists
      -- across the entire turn so all tool calls edit the same message.
      (h, getSendWithIds, _getEdits) <- mockEditChannel
      sp <- newStreamProgress cfg h Set.empty
      onToolCall sp (OpName "SHELL_EXEC") "ls"
      segmentBreak sp
      onToolCall sp (OpName "FILE_READ") "README.md"

      sends <- getSendWithIds
      -- First call sends, second call edits (segmentBreak did not reset)
      length sends `shouldBe` 1

  describe "onToolCall when disabled" $ do
    it "is a no-op when spcEnabled is False" $ do
      (h, getSendWithIds, _getEdits) <- mockEditChannel
      let cfg' = def { spcEnabled = False }
      sp <- newStreamProgress cfg' h Set.empty
      onToolCall sp (OpName "SHELL_EXEC") "ls"
      sends <- getSendWithIds
      sends `shouldBe` []

    it "is a no-op when spcToolProgress is False" $ do
      (h, getSendWithIds, _getEdits) <- mockEditChannel
      let cfg' = def { spcEnabled = True, spcToolProgress = False }
      sp <- newStreamProgress cfg' h Set.empty
      onToolCall sp (OpName "SHELL_EXEC") "ls"
      sends <- getSendWithIds
      sends `shouldBe` []

-- | A mock channel handle that records sendWithId and editMessage calls.
-- Returns unique ids for each sendWithId so edits can reference them.
-- The edit function always succeeds (returns True).
mockEditChannel :: IO (ChannelHandle, IO [Text], IO [(Text, Text)])
mockEditChannel = do
  sendIdRef <- newIORef (0 :: Int)
  sendCapRef <- newIORef [] :: IO (IORef [Text])
  editCapRef <- newIORef [] :: IO (IORef [(Text, Text)])
  let h = ChannelHandle
        { chLabel       = "mock"
        , chSend        = \_ -> pure ()
        , chSendError   = \_ -> pure ()
        , chSendChunk   = \_ -> pure ()
        , chSendWithId  = \_content -> do
            n <- readIORef sendIdRef
            let n' = n + 1
            writeIORef sendIdRef n'
            let id' = T.pack (show n')
            modifyIORef' sendCapRef (id' :)
            pure (Just id')
        , chEditMessage = Just $ \msgId content -> do
            modifyIORef' editCapRef ((msgId, content) :)
            pure True
        , chDeleteMessage = Just $ \_ -> pure True
        , chPrompt      = \_ -> pure (Left Deferred)
        , chPromptSecret = \_ -> pure (Left Deferred)
        , chStreaming   = False
        , chReadSecret  = pure Nothing
        , chReceive     = pure (Nothing, "")
        , chLastChatId  = pure Nothing
        }
      getSendWithIds = reverse <$> readIORef sendCapRef
      getEdits = reverse <$> readIORef editCapRef
  pure (h, getSendWithIds, getEdits)

genText :: Gen Text
genText = T.pack <$> listOf1 (elements ['a'..'z'])