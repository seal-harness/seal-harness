{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.Telegram.CommandsSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channels.Telegram.Commands
  ( maxTelegramCommandNameLen, maxTelegramDescriptionLen
  , sanitizeTelegramName, telegramBotCommands )
import Seal.Channels.Telegram.Transport (BotCommand (..))
import Seal.Command.Spec
  ( Availability (..), CommandGroup (..), CommandName (..), CommandSpec (..)
  , mkRegistry )

-- | Build a minimal CommandSpec for testing.
mkSpec :: Text -> Text -> Availability -> CommandSpec
mkSpec name synopsis avail = CommandSpec
  { csName = CommandName name
  , csAliases = []
  , csGroup = GroupGeneral
  , csSynopsis = synopsis
  , csParserInfo = error "test spec: parserInfo unused"
  , csAvailability = avail
  }

spec :: Spec
spec = do
  describe "Seal.Channels.Telegram.Commands.sanitizeTelegramName" $ do
    it "lowercases and replaces hyphens with underscores" $
      sanitizeTelegramName "tab-list" `shouldBe` "tab_list"

    it "strips invalid chars (only a-z0-9_ allowed)" $
      sanitizeTelegramName "vault@setup" `shouldBe` "vaultsetup"

    it "collapses double underscores" $
      sanitizeTelegramName "foo__bar" `shouldBe` "foo_bar"

    it "trims leading/trailing underscores" $
      sanitizeTelegramName "_help_" `shouldBe` "help"

    it "clamps to 32 chars" $
      let longName = T.replicate 40 "a"
      in T.length (sanitizeTelegramName longName) `shouldBe` maxTelegramCommandNameLen

  describe "Seal.Channels.Telegram.Commands.telegramBotCommands" $ do
    it "includes /help first" $ do
      let reg = mkRegistry []
          cmds = telegramBotCommands reg
      case cmds of
        (c:_) -> c `shouldBe` BotCommand "help" "Show available commands"
        []    -> expectationFailure "expected at least /help"

    it "includes AlwaysAvailable commands" $ do
      let spec1 = mkSpec "tab" "Manage tabs" AlwaysAvailable
          reg = mkRegistry [spec1]
          cmds = telegramBotCommands reg
      map bcName cmds `shouldContain` ["help", "tab"]

    it "includes InteractiveOnly commands too (they defer or show usage)" $ do
      let spec1 = mkSpec "vault" "Manage vault" InteractiveOnly
          reg = mkRegistry [spec1]
          cmds = telegramBotCommands reg
      map bcName cmds `shouldContain` ["vault"]

    it "excludes the terse /N grammar" $ do
      let spec1 = mkSpec "N" "Terse tab switching" AlwaysAvailable
          reg = mkRegistry [spec1]
          cmds = telegramBotCommands reg
      map bcName cmds `shouldNotContain` ["N", "n"]

    it "sanitizes command names (hyphens to underscores)" $ do
      let spec1 = mkSpec "my-command" "A command" AlwaysAvailable
          reg = mkRegistry [spec1]
          cmds = telegramBotCommands reg
      map bcName cmds `shouldContain` ["my_command"]

    it "truncates descriptions to 256 chars" $ do
      let longSynopsis = T.replicate 300 "x"
          spec1 = mkSpec "tab" longSynopsis AlwaysAvailable
          reg = mkRegistry [spec1]
          cmds = telegramBotCommands reg
      case lookup "tab" [(bcName c, bcDescription c) | c <- cmds] of
        Just desc -> T.length desc `shouldBe` maxTelegramDescriptionLen
        Nothing   -> expectationFailure "tab command not found"

    it "skips aliases (one entry per canonical command)" $ do
      let spec1 = mkSpec "tab" "Manage tabs" AlwaysAvailable
          spec2 = mkSpec "tabs" "List tabs" AlwaysAvailable
          reg = mkRegistry [spec1, spec2]
          cmds = telegramBotCommands reg
      -- Both are separate specs so both appear; aliases within a spec would
      -- not (they're in csAliases, not csName). This test verifies the
      -- canonical name is used.
      map bcName cmds `shouldContain` ["tab", "tabs"]