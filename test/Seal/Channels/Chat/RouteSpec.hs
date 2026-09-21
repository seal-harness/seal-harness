{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Route.route' — the pure Layer-1 routing
-- for chat channels. Mirrors the existing 'Seal.Routing.Route' test cases
-- to verify behavioral parity.
module Seal.Channels.Chat.RouteSpec (spec) where

import Control.Monad (when)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Route
  ( ChatRoute (..)
  , route
  , parseTabFocus
  )
import Seal.Gateway.Types.Tab (TabIndex, tabIndexFromChar)

-- | Helper: make a 'TabIndex' from a char, crashing on invalid (test-only).
mkIdxC :: Char -> TabIndex
mkIdxC c = case tabIndexFromChar c of
  Right i -> i
  Left e  -> error ("test mkIdxC: " <> show e)

-- | Helper: make a 'TabIndex' from a digit 0-9 (test-only).
mkIdxD :: Int -> TabIndex
mkIdxD n = mkIdxC (toEnum (fromEnum '0' + n))

spec :: Spec
spec = do
  describe "route" $ do
    it "routes /0 to ChatFocus 0" $
      route "/0" `shouldBe` Right (ChatFocus (mkIdxD 0))

    it "routes /9 to ChatFocus 9" $
      route "/9" `shouldBe` Right (ChatFocus (mkIdxD 9))

    it "routes /a to ChatFocus 10" $
      route "/a" `shouldBe` Right (ChatFocus (mkIdxC 'a'))

    it "routes /z to ChatFocus 35" $
      route "/z" `shouldBe` Right (ChatFocus (mkIdxC 'z'))

    it "routes /0 payload to ChatInject 0 payload" $
      route "/0 hello world" `shouldBe` Right (ChatInject (mkIdxD 0) "hello world")

    it "routes /a payload to ChatInject 10 payload" $
      route "/a do something" `shouldBe` Right (ChatInject (mkIdxC 'a') "do something")

    it "routes /tab to ChatCurrentTab" $
      route "/tab" `shouldBe` Right ChatCurrentTab

    it "routes /new to ChatNewSession with empty args" $
      route "/new" `shouldBe` Right (ChatNewSession "")

    it "routes /new -p anthropic to ChatNewSession with args" $
      route "/new -p anthropic" `shouldBe` Right (ChatNewSession "-p anthropic")

    it "routes /vault to ChatSlash" $
      route "/vault" `shouldBe` Right (ChatSlash "vault")

    it "routes /help to ChatSlash" $
      route "/help" `shouldBe` Right (ChatSlash "help")

    it "routes /tab focus 3 to ChatSlash (deferred)" $
      route "/tab focus 3" `shouldBe` Right (ChatSlash "tab focus 3")

    it "routes /tab list to ChatSlash (deferred)" $
      route "/tab list" `shouldBe` Right (ChatSlash "tab list")

    it "routes plain text to ChatPlain" $
      route "hello world" `shouldBe` Right (ChatPlain "hello world")

    it "routes empty string to ChatPlain empty" $
      route "" `shouldBe` Right (ChatPlain "")

    it "routes bare / to ChatPlain /" $
      route "/" `shouldBe` Right (ChatPlain "/")

    it "routes /0 followed by whitespace to ChatFocus (not Inject)" $
      route "/0 " `shouldBe` Right (ChatFocus (mkIdxD 0))

    it "routes /vault with args to ChatSlash with args" $
      route "/vault unlock" `shouldBe` Right (ChatSlash "vault unlock")

    it "does NOT route /vault as Inject v ault (no space after v)" $
      route "/vault" `shouldNotBe` Right (ChatInject (mkIdxC 'v') "ault")

  describe "parseTabFocus" $ do
    it "parses /tab focus 3" $
      parseTabFocus "/tab focus 3" `shouldBe` Just (mkIdxD 3)

    it "parses /tab focus a (case-insensitive)" $
      parseTabFocus "/TAB FOCUS A" `shouldBe` Just (mkIdxC 'a')

    it "returns Nothing for /tab list" $
      parseTabFocus "/tab list" `shouldBe` Nothing

    it "returns Nothing for plain text" $
      parseTabFocus "hello" `shouldBe` Nothing

    it "returns Nothing for /3 (not /tab focus)" $
      parseTabFocus "/3" `shouldBe` Nothing

-- | A helper that asserts a value is NOT equal to another.
shouldNotBe :: (Show a, Eq a) => a -> a -> IO ()
shouldNotBe actual unexpected =
  when (actual == unexpected) $
    fail ("expected NOT " <> show unexpected <> " but got " <> show actual)
