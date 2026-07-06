{-# LANGUAGE OverloadedStrings #-}
module Seal.Harness.TmuxSpec (spec) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Harness.Tmux

spec :: Spec
spec = do
  describe "Seal.Harness.Tmux.validateTmuxIdent" $ do
    it "accepts a typical window name" $
      validateTmuxIdent "claude-1" `shouldBe` Right ()
    it "accepts a pane id (%5)" $
      validateTmuxIdent "%5" `shouldBe` Right ()
    it "accepts dots and underscores" $
      validateTmuxIdent "seal.0_win" `shouldBe` Right ()
    it "rejects empty" $ validateTmuxIdent "" `shouldSatisfy` isLeft
    it "rejects leading dash (option injection)" $
      validateTmuxIdent "-x" `shouldSatisfy` isLeft
    it "rejects colon (tmux separator)" $
      validateTmuxIdent "a:b" `shouldSatisfy` isLeft
    it "rejects control chars" $ validateTmuxIdent "a\x1bb" `shouldSatisfy` isLeft
    prop "accepts [A-Za-z0-9_.%-] non-empty, no leading dash, no colon" $
      forAll genGoodIdent $ \t ->
        validateTmuxIdent t === Right ()

  describe "Seal.Harness.Tmux.mkTmuxIdent" $ do
    it "round-trips a good ident" $
      case mkTmuxIdent "claude-1" of
        Right i -> tmuxIdentText i `shouldBe` "claude-1"
        Left e  -> expectationFailure ("unexpected Left: " <> T.unpack e)
    it "rejects a bad ident" $ mkTmuxIdent "-x" `shouldSatisfy` isLeft

  describe "argv builders" $ do
    let win = right (mkTmuxIdent "win")
        win2 = right (mkTmuxIdent "win2")
    it "sendKeysNamedArgs uses -l -- for literal text" $
      sendKeysNamedArgs win "hello"
        `shouldBe` ["send-keys", "-t", "win", "-l", "--", "hello"]
    it "sendEnterNamedArgs sends the Enter key (no -l --)" $
      sendEnterNamedArgs win
        `shouldBe` ["send-keys", "-t", "win", "Enter"]
    it "pasteBufferNamedArgs" $
      pasteBufferNamedArgs win "text"
        `shouldBe` ["paste-buffer", "-t", "win", "-d", "seal-paste"]
    it "captureNamedArgs captures pane content" $
      captureNamedArgs win
        `shouldBe` ["capture-pane", "-t", "win", "-p"]
    it "killWindowNamedArgs" $
      killWindowNamedArgs win
        `shouldBe` ["kill-window", "-t", "win"]
    it "renameWindowNamedArgs" $
      renameWindowNamedArgs win win2
        `shouldBe` ["rename-window", "-t", "win", "win2"]
    it "newWindowNamedArgs" $
      newWindowNamedArgs win win2
        `shouldBe` ["new-window", "-t", "win", "-n", "win2"]
    it "setWindowMarkerArgs stamps the seal_id marker" $
      setWindowMarkerArgs win "seal_id" "abc-uuid"
        `shouldBe` ["set-option", "-t", "win", "@seal_id", "abc-uuid"]
    it "clearWindowMarkerArgs" $
      clearWindowMarkerArgs win "seal_id"
        `shouldBe` ["set-option", "-t", "win", "-u", "@seal_id"]
    it "setRemainOnExitArgs" $
      setRemainOnExitArgs win
        `shouldBe` ["set-option", "-t", "win", "remain-on-exit", "on"]

  describe "sendKeysNamedArgs option-injection defense" $ do
    it "a payload starting with - is still literal (the -- separator guards it)" $
      sendKeysNamedArgs (either (error "ident") id (mkTmuxIdent "w")) "--version"
        `shouldBe` ["send-keys", "-t", "w", "-l", "--", "--version"]

-- | A generator for valid tmux idents.
genGoodIdent :: Gen Text
genGoodIdent =
  T.pack <$> listOf1 (elements (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_.%-"))
            `suchThat` nonDashHead
  where
    nonDashHead s = case s of
      (c:_) -> c /= '-' && c /= ':'
      []    -> False

-- | Unwrap an 'Either' that's expected to be 'Right' (fails with the error
-- message if 'Left'). Used for test fixtures.
right :: Either Text a -> a
right (Right x) = x
right (Left e)  = error ("expected Right, got Left: " <> T.unpack e)