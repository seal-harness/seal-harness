{-# LANGUAGE OverloadedStrings #-}
module Seal.Routing.RouteSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Handles.Tab
import Seal.Routing.Route
import Seal.Tabs.Types
import Seal.Core.Types (mkSessionId, SessionId)
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

mk :: Int -> TabIndex
mk n = case mkTabIndex n of
  Right i -> i
  Left _  -> error ("mkTabIndex " <> show n <> " failed")

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

spec :: Spec
spec = describe "Seal.Routing.Route" $ do
  describe "terse /N grammar" $ do
    it "/0 -> Focus 0" $ route "/0" `shouldBe` Right (Focus (mk 0))
    it "/z -> Focus 35" $ route "/z" `shouldBe` Right (Focus (mk 35))
    it "/1 -> Focus 1" $ route "/1" `shouldBe` Right (Focus (mk 1))
    it "/1 hello -> Inject 1 hello" $ route "/1 hello" `shouldBe` Right (Inject (mk 1) "hello")
    it "/a payload -> Inject 10 payload" $ route "/a payload" `shouldBe` Right (Inject (mk 10) "payload")
    it "/0  -> Focus 0 (trailing space ignored)" $ route "/0 " `shouldBe` Right (Focus (mk 0))
    it "/1  multiple   spaces -> Inject 1 (preserved)" $
      route "/1  multiple   spaces" `shouldBe` Right (Inject (mk 1) " multiple   spaces")

  describe "/tab commands" $ do
    it "/tab -> TabListCmd" $ route "/tab" `shouldBe` Right (TabCommand TabListCmd)
    it "/tab list -> TabListCmd" $ route "/tab list" `shouldBe` Right (TabCommand TabListCmd)
    it "/tab new -> TabNewCmd Nothing" $ route "/tab new" `shouldBe` Right (TabCommand (TabNewCmd Nothing))
    it "/tab new harness -> TabNewCmd (Just TkaHarness)" $
      route "/tab new harness" `shouldBe` Right (TabCommand (TabNewCmd (Just TkaHarness)))
    it "/tab new ai -> TabNewCmd (Just TkaAi)" $
      route "/tab new ai" `shouldBe` Right (TabCommand (TabNewCmd (Just TkaAi)))
    it "/tab close 2 -> TabCloseCmd 2 NoForce" $
      route "/tab close 2" `shouldBe` Right (TabCommand (TabCloseCmd (mk 2) NoForce))
    it "/tab close 2 --force -> TabCloseCmd 2 Force" $
      route "/tab close 2 --force" `shouldBe` Right (TabCommand (TabCloseCmd (mk 2) Force))
    it "/tab focus 3 -> TabFocusCmd 3" $
      route "/tab focus 3" `shouldBe` Right (TabCommand (TabFocusCmd (mk 3)))
    it "/tab resume my-session -> TabResumeCmd" $
      route "/tab resume my-session" `shouldBe` Right (TabCommand (TabResumeCmd (mkSid "my-session")))
    it "/tab rename 1 work -> TabRenameCmd 1 work" $
      route "/tab rename 1 work" `shouldBe` Right (TabCommand (TabRenameCmd (mk 1) "work"))

  describe "other /commands" $ do
    it "/help -> SlashCommand help" $ route "/help" `shouldBe` Right (SlashCommand "help")
    it "/ping -> SlashCommand ping" $ route "/ping" `shouldBe` Right (SlashCommand "ping")
    it "/vault setup -> SlashCommand vault (with args)" $
      route "/vault setup" `shouldBe` Right (SlashCommand "vault setup")

  describe "/new" $ do
    it "/new -> NewSession" $ route "/new" `shouldBe` Right NewSession
    it "/new with trailing args still NewSession (args ignored by the route)" $
      route "/new anything" `shouldBe` Right NewSession
    it "/newbot -> SlashCommand (not NewSession; /new must be alone or space-delimited)" $
      route "/newbot" `shouldBe` Right (SlashCommand "newbot")

  describe "plain text" $ do
    it "hello -> Plain hello" $ route "hello" `shouldBe` Right (Plain "hello")
    it "empty -> Plain empty" $ route "" `shouldBe` Right (Plain "")
    it "text with slashes inside -> Plain" $
      route "a/b/c" `shouldBe` Right (Plain "a/b/c")

  describe "multi-char disambiguation" $ do
    it "/vault -> SlashCommand vault (not Inject, no space after v)" $
      route "/vault" `shouldBe` Right (SlashCommand "vault")
    it "/vault setup -> SlashCommand vault setup" $
      route "/vault setup" `shouldBe` Right (SlashCommand "vault setup")
    it "/36 -> SlashCommand 36 (two digits, not a single tab char)" $
      route "/36" `shouldBe` Right (SlashCommand "36")
    it "/! -> SlashCommand !" $
      route "/!" `shouldBe` Right (SlashCommand "!")
    it "/tabx -> SlashCommand tabx (tab prefix but not a whole word)" $
      route "/tabx" `shouldBe` Right (SlashCommand "tabx")

  describe "QuickCheck" $ do
    prop "/N for valid N never routes to Plain or SlashCommand" $
      forAll (elements ['0'..'9']) $ \c ->
        case route (T.singleton '/' <> T.singleton c) of
          Right (Focus _) -> True
          _               -> False
    prop "/N payload for valid N always routes to Inject" $
      \c payload ->
        (c `elem` ("0123456789abcdefghij" :: String))
          && not (T.null payload)
          && not (T.null (T.strip payload)) ==>
        case route (T.singleton '/' <> T.singleton c <> " " <> payload) of
          Right (Inject _ _) -> True
          _                  -> False
    prop "plain text (no leading /) always routes to Plain" $
      \t -> not (T.isPrefixOf "/" t) ==> route t === Right (Plain t)