{-# LANGUAGE OverloadedStrings #-}
module Seal.Harness.TmuxIOSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec

import Seal.Handles.Harness (HarnessError (..))
import Seal.Harness.Tmux

-- | Unwrap an Either expected to be Right.
right :: Show e => Either e a -> a
right (Right x) = x
right (Left e)  = error ("expected Right, got Left: " <> show e)

spec :: Spec
spec = describe "Seal.Harness.Tmux IO wrappers" $ do
  it "sendToWindowNamed passes the expected argv and returns Right ()" $ do
    (runner, getArgs) <- mkFakeTmuxRunner ["ok"]
    let win = right (mkTmuxIdent "win")
    r <- sendToWindowNamed runner win "hello"
    r `shouldBe` Right ()
    args <- getArgs
    args `shouldBe` [["send-keys", "-t", "win", "-l", "--", "hello"]]

  it "captureWindowNamed returns the scripted lines" $ do
    (runner, _) <- mkFakeTmuxRunner ["line one\nline two\n"]
    let win = right (mkTmuxIdent "win")
    r <- captureWindowNamed runner win
    r `shouldBe` Right ["line one", "line two"]

  it "stopHarnessWindowNamed passes kill-window argv" $ do
    (runner, getArgs) <- mkFakeTmuxRunner ["ok"]
    let win = right (mkTmuxIdent "win")
    r <- stopHarnessWindowNamed runner win
    r `shouldBe` Right ()
    args <- getArgs
    args `shouldBe` [["kill-window", "-t", "win"]]

  it "setWindowMarker passes the seal_id marker argv" $ do
    (runner, getArgs) <- mkFakeTmuxRunner ["ok"]
    let win = right (mkTmuxIdent "win")
    r <- setWindowMarker runner win "seal_id" "abc-uuid"
    r `shouldBe` Right ()
    args <- getArgs
    args `shouldBe` [["set-option", "-t", "win", "@seal_id", "abc-uuid"]]

  it "readMarkers parses the show-options output into a map" $ do
    (runner, _) <- mkFakeTmuxRunner ["@seal_id \"abc-uuid\"\n@other \"x\"\n"]
    let win = right (mkTmuxIdent "win")
    r <- readMarkers runner win
    r `shouldBe` Right (Map.fromList [("seal_id", "abc-uuid"), ("other", "x")])

  it "returns HeTmuxMissing when the fake scripts a 127" $ do
    (runner, _) <- mkFakeTmuxRunner ["__EXIT__127__"]
    let win = right (mkTmuxIdent "win")
    r <- sendToWindowNamed runner win "x"
    r `shouldBe` Left HeTmuxMissing

-- | A fake TmuxRunner: scripts a queue of stdout replies (popped in order),
-- records every argv passed. The sentinel "__EXIT__127__" in the scripted
-- queue makes the runner return HeTmuxMissing (simulating tmux absent).
mkFakeTmuxRunner :: [Text] -> IO (TmuxRunner, IO [[String]])
mkFakeTmuxRunner scripted = do
  queueRef <- newIORef scripted
  argsRef <- newIORef []
  let runner = TmuxRunner $ \argv -> do
        modifyIORef' argsRef (argv :)
        qs <- readIORef queueRef
        case qs of
          [] -> pure (Right "")
          (q:rest) -> do
            writeIORef queueRef rest
            if q == "__EXIT__127__"
              then pure (Left HeTmuxMissing)
              else pure (Right q)
      getArgs = reverse <$> readIORef argsRef
  pure (runner, getArgs)