{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.LogSpec (spec) where

import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Session.Log

spec :: Spec
spec = describe "Seal.Session.Log" $ do

  it "appendSessionLog Nothing is a no-op (no file written)" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "seal.log"
      appendSessionLog Nothing "INFO" "hello"
      doesFileExist path `shouldReturn` False

  it "appendSessionLog Just writes a timestamped line to the file" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "seal.log"
      appendSessionLog (Just path) "INFO" "hello world"
      doesFileExist path `shouldReturn` True

  it "appendSessionLog is append-only (multiple calls accumulate)" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "seal.log"
      appendSessionLog (Just path) "TURN" "start"
      appendSessionLog (Just path) "TURN" "end"
      appendSessionLog (Just path) "ERROR" "boom"
      content <- readFile path
      length (lines content) `shouldBe` 3
      -- Each line has the [LEVEL] tag
      content `shouldContain` "[TURN]"
      content `shouldContain` "[ERROR]"

  it "appendSessionLog swallows IO errors (best-effort, never throws)" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "nonexistent_subdir" </> "seal.log"
      appendSessionLog (Just path) "INFO" "should not throw"
      doesFileExist path `shouldReturn` False

  it "logTurnStart writes a TURN start line with turn count" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "seal.log"
      logTurnStart (Just path) 12
      content <- readFile path
      content `shouldContain` "[TURN]"
      content `shouldContain` "start"
      content `shouldContain` "12"

  it "logTurnError writes an ERROR line with the exception text" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "seal.log"
      logTurnError (Just path) "some exception: divide by zero"
      content <- readFile path
      content `shouldContain` "[ERROR]"
      content `shouldContain` "turn failed"
      content `shouldContain` "divide by zero"

  it "logMaxTurns writes a WARN line" $
    withSystemTempDirectory "seal-log" $ \tmp -> do
      let path = tmp </> "seal.log"
      logMaxTurns (Just path)
      content <- readFile path
      content `shouldContain` "[WARN]"
      content `shouldContain` "too many tool turns"