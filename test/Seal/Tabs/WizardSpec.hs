{-# LANGUAGE OverloadedStrings #-}
module Seal.Tabs.WizardSpec (spec) where

import Data.Either (isLeft)
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab
import Seal.Tabs.Types
import Seal.Tabs.Wizard

sid :: Text -> SessionId
sid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

spec :: Spec
spec = describe "Seal.Tabs.Wizard" $ do
  let targets = [ AttachTarget "claude-1" (BoundSession (sid "a"))
                , AttachTarget "claude-2" (BoundSession (sid "b"))
                ]
      ws = buildWizard KindHarness targets

  it "buildWizard numbers targets 1..n (skipping 0)" $ do
    let idxs = map (tabIndexToInt . fst) (wsTargets ws)
    idxs `shouldBe` [1, 2]

  it "handleReply \"0\" -> WizardCancel" $
    handleReply ws "0" `shouldBe` Right WizardCancel

  it "handleReply \"1\" -> WizardAttach (first target)" $
    handleReply ws "1" `shouldBe` Right (WizardAttach (BoundSession (sid "a")))

  it "handleReply \"2\" -> WizardAttach (second target)" $
    handleReply ws "2" `shouldBe` Right (WizardAttach (BoundSession (sid "b")))

  it "handleReply \"/ping\" -> WizardSlash ping (cancel + run)" $
    handleReply ws "/ping" `shouldBe` Right (WizardSlash "ping")

  it "handleReply \"/tab list\" -> WizardSlash tab list" $
    handleReply ws "/tab list" `shouldBe` Right (WizardSlash "tab list")

  it "handleReply \"99\" -> Left (out of range)" $
    handleReply ws "99" `shouldSatisfy` isLeft

  it "handleReply \"\" -> Left (empty)" $
    handleReply ws "" `shouldSatisfy` isLeft

  it "handleReply \"x\" -> Left (not a number)" $
    handleReply ws "x" `shouldSatisfy` isLeft