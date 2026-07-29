{-# LANGUAGE OverloadedStrings #-}
module Seal.Logging.ExceptionsSpec (spec) where

import Control.Exception (throwIO, AsyncException (..))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Logging.Logger
  (testSealLogger, closeSealLogger, newSealLoggerWithScribe)
import Seal.Handles.Transcript (TranscriptError (..))

import Katip (Severity (..), Scribe (..), permitItem, jsonFormat, Verbosity (V2))

-- | A capture scribe for asserting log output.
mkCaptureScribe :: IO (Scribe, IORef [Text])
mkCaptureScribe = do
  ref <- newIORef []
  let scribe = Scribe
        { liPush = \item -> modifyIORef' ref (T.pack (show (jsonFormat False V2 item)) :)
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  pure (scribe, ref)

spec :: Spec
spec = describe "Seal.Logging.Exceptions" $ do
  describe "withExceptionLogging" $ do
    it "returns Right result on success" $ do
      logger <- testSealLogger
      result <- withExceptionLogging logger Nothing "test" (pure (42 :: Int))
      closeSealLogger logger
      result `shouldBe` Right 42

    it "returns Left sanitized text on synchronous exception" $ do
      logger <- testSealLogger
      result <- withExceptionLogging logger Nothing "test" $
        throwIO (userError "something broke")
      closeSealLogger logger
      case result of
        Left msg -> do
          msg `shouldSatisfy` T.isInfixOf "internal error"
          msg `shouldSatisfy` T.isInfixOf "test"
          msg `shouldNotSatisfy` T.isInfixOf "something broke"
        Right _ -> expectationFailure "expected Left"

    it "passes TranscriptError text through (not sanitized)" $ do
      logger <- testSealLogger
      result <- withExceptionLogging logger Nothing "test" $
        throwIO (TranscriptError "transcript is dead")
      closeSealLogger logger
      case result of
        Left msg ->
          msg `shouldSatisfy` T.isInfixOf "transcript is dead"
        Right _ -> expectationFailure "expected Left"

    it "rethrows AsyncException (does not swallow ThreadKilled)" $ do
      logger <- testSealLogger
      -- This should rethrow ThreadKilled, not return Left
      withExceptionLogging logger Nothing "test" (throwIO ThreadKilled)
        `shouldThrow` (== ThreadKilled)
      closeSealLogger logger

    it "includes a correlation id in the sanitized text" $ do
      logger <- testSealLogger
      result <- withExceptionLogging logger Nothing "turn" $
        throwIO (userError "disk full")
      closeSealLogger logger
      case result of
        Left msg ->
          msg `shouldSatisfy` T.isInfixOf "ref:"
        Right _ -> expectationFailure "expected Left"

    it "logs the full exception to the operator log" $ do
      (scribe, ref) <- mkCaptureScribe
      logger <- newSealLoggerWithScribe scribe DebugS
      _ <- withExceptionLogging logger Nothing "test" $
        throwIO (userError "internal disk failure")
      closeSealLogger logger
      lines_ <- readIORef ref
      let allText = T.unlines lines_
      allText `shouldSatisfy` T.isInfixOf "internal disk failure"

    it "escapes newlines in exception text (log injection defense)" $ do
      (scribe, ref) <- mkCaptureScribe
      logger <- newSealLoggerWithScribe scribe DebugS
      _ <- withExceptionLogging logger Nothing "test" $
        throwIO (userError "line1\nFAKE [ERROR] injected")
      closeSealLogger logger
      lines_ <- readIORef ref
      length lines_ `shouldBe` 1