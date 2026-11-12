{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.TelegramCommands' — the pure menu builder,
-- the @setMyCommands@ payload, and the startup retry. The HTTP call itself
-- ('tgSetCommandsViaApi') is not exercised here: pinning the request body is
-- the contract that matters (Telegram keeps the previous registration
-- server-side, so "the menu looks right" proves nothing).
module Seal.Channels.Chat.TelegramCommandsSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

import Seal.Channels.Chat.HttpClient (CommandJson (..))
import Seal.Channels.Chat.TelegramCommands

spec :: Spec
spec = do
  describe "sanitizeTelegramName" $ do
    it "lowercases and maps dashes to underscores" $
      sanitizeTelegramName "Skill-Load" `shouldBe` "skill_load"
    it "drops characters outside [a-z0-9_]" $
      sanitizeTelegramName "repo info!" `shouldBe` "repoinfo"
    it "collapses runs of underscores" $
      sanitizeTelegramName "a--b_-_c" `shouldBe` "a_b_c"
    it "trims leading and trailing underscores" $
      sanitizeTelegramName "-repo-" `shouldBe` "repo"
    it "clamps to 32 characters" $
      sanitizeTelegramName (Text.replicate 40 "a") `shouldBe` Text.replicate 32 "a"
    it "yields an empty name when nothing survives" $
      sanitizeTelegramName "!!!" `shouldBe` ""

  describe "telegramMenuCommands" $ do
    it "is [help, bg, watch] for an empty registry" $
      telegramMenuCommands [] `shouldBe`
        [ BotCommand "help" "Show available commands"
        , BotCommand "bg" "Run a prompt in a background session"
        , BotCommand "watch" "Toggle tab notifications"
        ]

    it "puts the registry between help and bg/watch, in registry order" $
      telegramMenuCommands
        [ CommandJson "session" "List sessions"
        , CommandJson "model" "Switch model"
        ] `shouldBe`
        [ BotCommand "help" "Show available commands"
        , BotCommand "session" "List sessions"
        , BotCommand "model" "Switch model"
        , BotCommand "bg" "Run a prompt in a background session"
        , BotCommand "watch" "Toggle tab notifications"
        ]

    it "sanitises registry names" $
      map bcName (telegramMenuCommands [CommandJson "Repo-Info" "Repo info"])
        `shouldBe` ["help", "repo_info", "bg", "watch"]

    it "drops names that sanitise to nothing or to a single character" $
      map bcName (telegramMenuCommands
        [ CommandJson "!!!" "nothing left"
        , CommandJson "x" "shadows /x"
        , CommandJson "ok" "kept"
        ]) `shouldBe` ["help", "ok", "bg", "watch"]

    it "dedupes first-wins (a registry 'help' cannot displace the built-in)" $
      telegramMenuCommands [CommandJson "help" "from the registry"]
        `shouldBe`
          [ BotCommand "help" "Show available commands"
          , BotCommand "bg" "Run a prompt in a background session"
          , BotCommand "watch" "Toggle tab notifications"
          ]

    it "truncates synopses to 256 characters" $
      case telegramMenuCommands [CommandJson "long" (Text.replicate 300 "y")] of
        (BotCommand _ _ : BotCommand _ desc : _) ->
          Text.length desc `shouldBe` 256
        other -> fail ("unexpected menu: " <> show other)

    it "caps the menu at 100 entries by truncating the tail" $ do
      let registry = [ CommandJson (Text.pack ("cmd" <> show n)) "syn"
                     | n <- [1 .. 150 :: Int] ]
      length (telegramMenuCommands registry) `shouldBe` 100
      -- help + cmd1..cmd99 fill the cap; the tail (bg, watch) is dropped.
      bcName (last (telegramMenuCommands registry)) `shouldBe` "cmd99"

  describe "commandsPayload" $ do
    it "encodes the exact setMyCommands body" $
      commandsPayload [BotCommand "help" "Show available commands"]
        `shouldBe` A.object
          [ "commands" .= [ A.object
              [ "command" .= ("help" :: Text)
              , "description" .= ("Show available commands" :: Text)
              ] ] ]
    it "does not append the built-in entries (the builder does)" $
      commandsPayload [] `shouldBe` A.object ["commands" .= ([] :: [A.Value])]

  describe "registerWithRetry" $ do
    it "registers on the first attempt without retrying" $ do
      calls <- newIORef (0 :: Int)
      registrations <- newIORef ([] :: [[BotCommand]])
      let fetch = modifyIORef' calls (+ 1) >> pure (Right [CommandJson "model" "Switch model"])
          register cmds = modifyIORef' registrations (cmds :) >> pure (Right ())
      res <- registerWithRetry 3 0 fetch register
      res `shouldBe` Right ()
      readIORef calls `shouldReturn` 1
      readIORef registrations `shouldReturn`
        [[ BotCommand "help" "Show available commands"
         , BotCommand "model" "Switch model"
         , BotCommand "bg" "Run a prompt in a background session"
         , BotCommand "watch" "Toggle tab notifications"
         ]]

    it "retries a failing fetch and succeeds on a later attempt" $ do
      calls <- newIORef (0 :: Int)
      let fetch = do
            n <- readIORef calls
            modifyIORef' calls (+ 1)
            pure (if n < 2 then Left "connection refused" else Right [])
          register _ = pure (Right ())
      res <- registerWithRetry 5 0 fetch register
      res `shouldBe` Right ()
      readIORef calls `shouldReturn` 3

    it "retries a failing registration" $ do
      attempts <- newIORef (0 :: Int)
      let fetch = pure (Right [])
          register _ = do
            n <- readIORef attempts
            modifyIORef' attempts (+ 1)
            pure (if n < 1 then Left "Too Many Requests: retry after 1" else Right ())
      res <- registerWithRetry 3 0 fetch register
      res `shouldBe` Right ()
      readIORef attempts `shouldReturn` 2

    it "returns the last error once the attempts are exhausted" $ do
      calls <- newIORef (0 :: Int)
      registrations <- newIORef (0 :: Int)
      let fetch = do
            modifyIORef' calls (+ 1)
            pure (Left "connection refused")
          register _ = modifyIORef' registrations (+ 1) >> pure (Right ())
      res <- registerWithRetry 3 0 fetch register
      res `shouldBe` Left "connection refused"
      readIORef calls `shouldReturn` 3
      -- A failed fetch never reaches the register step (an empty menu would
      -- otherwise be registered, wiping the bot's menu).
      readIORef registrations `shouldReturn` 0

    it "treats a non-positive attempt count as one attempt" $ do
      calls <- newIORef (0 :: Int)
      let fetch = modifyIORef' calls (+ 1) >> pure (Left "boom")
          register _ = pure (Right ())
      res <- registerWithRetry 0 0 fetch register
      res `shouldBe` Left "boom"
      readIORef calls `shouldReturn` 1
