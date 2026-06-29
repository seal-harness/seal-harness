{-# LANGUAGE OverloadedStrings #-}
module Seal.IngestSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T

import Options.Applicative (info, progDesc)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..)
  , CommandAction (..)
  , CommandGroup (..)
  , CommandName (..)
  , CommandSpec (..)
  , Registry
  , mkRegistry
  )
import Seal.Ingest

-- ---------------------------------------------------------------------------
-- Fake registry
-- ---------------------------------------------------------------------------

-- | Records every 'ccSend' call (prepended; reverse for chronological order).
recordingCaps :: IORef [Text] -> ChannelCaps
recordingCaps ref = ChannelCaps
  { ccSend         = \t -> modifyIORef' ref (t :)
  , ccPrompt       = \_ -> pure ""
  , ccPromptSecret = \_ -> pure ""
  }

-- | The fake "ping" command: sends "pong" via 'ccSend'.
pingAction :: CommandAction
pingAction = CommandAction $ \caps -> ccSend caps "pong"

pingSpec :: CommandSpec
pingSpec = CommandSpec
  { csName         = CommandName "ping"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Echo pong"
  , csParserInfo   = info (pure pingAction) (progDesc "Echo pong")
  , csAvailability = AlwaysAvailable
  }

testRegistry :: Registry
testRegistry = mkRegistry [pingSpec]

-- ---------------------------------------------------------------------------
-- Helper: describe a Disposition without a Show instance for CommandAction
-- ---------------------------------------------------------------------------

showShape :: Disposition -> String
showShape (DispatchAction _) = "DispatchAction"
showShape (ShowText t)       = "ShowText " <> show t
showShape (PlainMessage t)   = "PlainMessage " <> show t
showShape (Rejected t)       = "Rejected " <> show t

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "runChain" $ do
    it "emptyChain passes input through unchanged" $ do
      let r = RawInbound "hello"
      result <- runChain emptyChain r
      result `shouldBe` Right r

    it "a rejecting stage short-circuits with Left" $ do
      let rejectStage :: PreprocessStage
          rejectStage _ = pure (Left "blocked")
          chain = PreprocessChain [rejectStage]
      result <- runChain chain (RawInbound "anything")
      result `shouldBe` Left "blocked"

    it "a passing stage can transform the value" $ do
      let appendBang :: PreprocessStage
          appendBang (RawInbound t) = pure (Right (RawInbound (t <> "!")))
          chain = PreprocessChain [appendBang]
      result <- runChain chain (RawInbound "hi")
      result `shouldBe` Right (RawInbound "hi!")

    it "stages run in order; Left from stage 1 skips stage 2" $ do
      probeRef <- newIORef (0 :: Int)
      let stage1 :: PreprocessStage
          stage1 _ = modifyIORef' probeRef (+ 1) >> pure (Left "stop")
          stage2 :: PreprocessStage
          stage2 r = modifyIORef' probeRef (+ 10) >> pure (Right r)
          chain = PreprocessChain [stage1, stage2]
      _ <- runChain chain (RawInbound "x")
      count <- readIORef probeRef
      count `shouldBe` 1   -- stage2 must NOT have run

  describe "ingest" $ do
    it "returns PlainMessage for non-slash input" $ do
      d <- ingest testRegistry emptyChain (RawInbound "hello there")
      case d of
        PlainMessage t -> t `shouldBe` "hello there"
        other          -> expectationFailure $
          "expected PlainMessage, got: " <> showShape other

    it "returns DispatchAction for a known slash command and runs it" $ do
      ref <- newIORef []
      d   <- ingest testRegistry emptyChain (RawInbound "/ping")
      case d of
        DispatchAction a -> do
          runCommandAction a (recordingCaps ref)
          sent <- readIORef ref
          sent `shouldBe` ["pong"]
        other -> expectationFailure $
          "expected DispatchAction, got: " <> showShape other

    it "returns ShowText (help index) for /help" $ do
      d <- ingest testRegistry emptyChain (RawInbound "/help")
      case d of
        ShowText t -> T.unpack t `shouldContain` "ping"
        other      -> expectationFailure $
          "expected ShowText (help index), got: " <> showShape other

    it "returns ShowText (command help) for /help ping" $ do
      d <- ingest testRegistry emptyChain (RawInbound "/help ping")
      case d of
        ShowText t -> T.unpack t `shouldContain` "ping"
        other      -> expectationFailure $
          "expected ShowText (command help), got: " <> showShape other

    it "returns ShowText for an unknown slash command" $ do
      d <- ingest testRegistry emptyChain (RawInbound "/nonexistent")
      case d of
        ShowText _ -> pure ()
        other      -> expectationFailure $
          "expected ShowText (parse failure), got: " <> showShape other

    it "chain runs BEFORE dispatch — Rejected when chain rejects /ping" $ do
      let probe :: PreprocessStage
          probe _ = pure (Left "chain ran first")
          chain   = PreprocessChain [probe]
      d <- ingest testRegistry chain (RawInbound "/ping")
      case d of
        Rejected msg -> msg `shouldBe` "chain ran first"
        other        -> expectationFailure $
          "expected Rejected, got: " <> showShape other
