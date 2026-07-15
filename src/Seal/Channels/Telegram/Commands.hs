{-# LANGUAGE OverloadedStrings #-}
-- | Derive Telegram BotCommand menu entries from the Seal command 'Registry'.
-- Each 'CommandSpec' becomes a 'BotCommand' (name + short description) so
-- Telegram's native @\/@-command auto-completion menu is populated from the
-- same single source of truth that drives @\/help@ and the CLI dispatch.
-- Mirrors hermes-agent's @telegram_bot_commands()@ approach: one menu entry
-- per canonical command (aliases skipped), names sanitized for Telegram's
-- charset, descriptions truncated to Telegram's 256-char limit.
module Seal.Channels.Telegram.Commands
  ( telegramBotCommands
  , sanitizeTelegramName
  , maxTelegramCommandNameLen
  , maxTelegramDescriptionLen
  ) where

import Data.Char (isAscii, isLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Channels.Telegram.Transport (BotCommand (..))
import Seal.Command.Spec
  ( CommandName (..), CommandSpec (..)
  , Registry (..), registrySpecs )

-- | Telegram's limits: command names ≤ 32 chars (lowercase @a-z0-9_@),
-- descriptions ≤ 256 chars.
maxTelegramCommandNameLen :: Int
maxTelegramCommandNameLen = 32

maxTelegramDescriptionLen :: Int
maxTelegramDescriptionLen = 256

-- | Derive the BotCommand menu from the Registry. Includes all commands
-- (both 'AlwaysAvailable' and 'InteractiveOnly') — interactive commands
-- still work over Telegram: their handlers respond with usage text or
-- defer via 'ChannelCaps' when selected. Skips aliases, sanitizes names
-- for Telegram's charset, and truncates descriptions. The synthetic
-- @\/help@ is always included first.
telegramBotCommands :: Registry -> [BotCommand]
telegramBotCommands reg =
  helpCommand : map specToBotCommand (filter isMenuEligible (registrySpecs reg))
  where
    isMenuEligible spec = isTelegramSafeName (csName spec)
    helpCommand = BotCommand
      { bcName = "help"
      , bcDescription = "Show available commands"
      }

-- | Convert a CommandSpec to a BotCommand.
specToBotCommand :: CommandSpec -> BotCommand
specToBotCommand spec =
  let CommandName n = csName spec
  in BotCommand
       { bcName = sanitizeTelegramName n
       , bcDescription = T.take maxTelegramDescriptionLen (csSynopsis spec)
       }

-- | Sanitize a command name for Telegram: lowercase, replace @-@ with @_@,
-- strip invalid chars (only @a-z0-9_@ allowed), collapse double underscores,
-- trim leading/trailing underscores, clamp to 32 chars.
sanitizeTelegramName :: Text -> Text
sanitizeTelegramName =
  clampName
  . T.dropWhileEnd (== '_')
  . T.dropWhile (== '_')
  . collapseUnderscores
  . T.filter isValidChar
  . T.toLower
  . T.replace "-" "_"
  where
    isValidChar c = (isAscii c && isLower c) || isDigit c || c == '_'
    collapseUnderscores = T.intercalate "_" . T.splitOn "__"
    clampName t =
      if T.length t > maxTelegramCommandNameLen
        then T.take maxTelegramCommandNameLen t
        else t

-- | Check if a command name is safe for Telegram (after sanitization it would
-- be non-empty). The terse grammar @\/N@ is excluded (single uppercase letter
-- doesn't sanitize to a meaningful command).
isTelegramSafeName :: CommandName -> Bool
isTelegramSafeName (CommandName n) =
  not (T.null (sanitizeTelegramName n)) && n /= "N"