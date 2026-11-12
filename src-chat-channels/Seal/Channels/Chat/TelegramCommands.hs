{-# LANGUAGE OverloadedStrings #-}
-- | The Telegram bot command menu, built from the gateway's slash-command
-- registry.
--
-- The menu is what the Telegram client shows after the user types @\/@. It
-- is registered with @setMyCommands@ at startup (see
-- 'Seal.Command.Serve.forkNewTelegramChatChannel'), not derived by the
-- platform — Telegram remembers the last registration server-side, so a
-- stale menu can look right while nothing re-registers it. That is why the
-- request body is what the tests pin.
--
-- Everything here is pure except 'registerWithRetry'; the HTTP call lives in
-- 'Seal.Channels.Chat.Telegram.tgSetCommandsViaApi'.
module Seal.Channels.Chat.TelegramCommands
  ( BotCommand (..)
  , sanitizeTelegramName
  , telegramMenuCommands
  , commandsPayload
  , registerWithRetry
    -- * Limits (Telegram's, as constants)
  , maxMenuCommands
  , maxCommandNameLength
  , maxDescriptionLength
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Char (isAsciiLower, isDigit)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Data.Aeson (Value, (.=))
import Data.Aeson qualified as A

import Seal.Channels.Chat.HttpClient (CommandJson (..))

-- | One @setMyCommands@ entry: the command name (no leading slash) and the
-- one-line description shown beside it.
data BotCommand = BotCommand
  { bcName        :: !Text
  , bcDescription :: !Text
  } deriving stock (Eq, Show)

-- | Telegram's cap on the number of menu entries.
maxMenuCommands :: Int
maxMenuCommands = 100

-- | Telegram's cap on a command name's length, in characters.
maxCommandNameLength :: Int
maxCommandNameLength = 32

-- | Telegram's cap on a command description's length, in characters.
maxDescriptionLength :: Int
maxDescriptionLength = 256

-- | Reduce an arbitrary command name to something Telegram accepts:
-- lowercase, @-@ becomes @_@, anything outside @[a-z0-9_]@ is dropped, runs of
-- underscores are collapsed, leading\/trailing underscores are trimmed, and
-- the result is clamped to 'maxCommandNameLength'.
--
-- A name that reduces to nothing (e.g. @\"!!!\"@) yields @\"\"@; the caller
-- drops it.
sanitizeTelegramName :: Text -> Text
sanitizeTelegramName =
    T.take maxCommandNameLength
      . trimUnderscores
      . collapseUnderscores
      . T.filter keep
      . T.map dashToUnderscore
      . T.toCaseFold
  where
    dashToUnderscore '-' = '_'
    dashToUnderscore c   = c
    keep c = isAsciiLower c || isDigit c || c == '_'

    collapseUnderscores = T.pack . go . T.unpack
      where
        go (a : b : rest)
          | a == '_' && b == '_' = go (b : rest)
        go (c : rest) = c : go rest
        go []         = []

    trimUnderscores = T.dropWhile (== '_') . T.dropWhileEnd (== '_')

-- | Build the menu: @help@, then the registry (in registry order), then
-- @bg@ and @watch@.
--
-- Registry names are sanitised ('sanitizeTelegramName'); entries that
-- sanitise to nothing, or to a single character, are dropped. A one-character
-- entry would shadow the terse @\/0@–@\/z@ tab grammar (the @\/N@ focus\/inject
-- commands), so it must never be offered in the menu. Duplicates are dropped
-- first-wins, and the list is capped at 'maxMenuCommands' by truncating the
-- tail.
--
-- @telegramMenuCommands []@ is @[help, bg, watch]@: the built-in entries are
-- part of the menu, never appended by 'commandsPayload'.
telegramMenuCommands :: [CommandJson] -> [BotCommand]
telegramMenuCommands registry =
    take maxMenuCommands (dedupe candidates)
  where
    candidates =
      [ BotCommand "help" "Show available commands" ]
        <> fromRegistry
        <> [ BotCommand "bg" "Run a prompt in a background session"
           , BotCommand "watch" "Toggle tab notifications" ]

    fromRegistry =
      [ BotCommand (sanitizeTelegramName (cjName cj))
                   (T.take maxDescriptionLength (cjSynopsis cj))
      | cj <- registry
      ]

    -- Drop the empty and the one-character names (see the doc comment).
    keepCommand b =
      let n = bcName b in not (T.null n) && T.length n > 1

    dedupe = reverse . snd . foldl' step (Set.empty, [])

    step (seen, acc) b
      | not (keepCommand b)        = (seen, acc)
      | Set.member (bcName b) seen = (seen, acc)
      | otherwise = (Set.insert (bcName b) seen, b : acc)

-- | The @setMyCommands@ request body. Pure and exported so the wire shape is
-- pinned by a test (the built-in entries are added by
-- 'telegramMenuCommands', not here).
commandsPayload :: [BotCommand] -> Value
commandsPayload cmds = A.object
  [ "commands" .= [ A.object
      [ "command"     .= bcName c
      , "description" .= bcDescription c
      ] | c <- cmds ]
  ]

-- | Fetch the registry and register the menu, retrying a bounded number of
-- times with a fixed delay between attempts. Returns the last error when
-- every attempt failed.
--
-- The retry exists for startup: the channel listeners are forked before the
-- gateway binds its HTTP port, so an immediate fetch always races the bind.
registerWithRetry
  :: Int
     -- ^ attempts (clamped to at least 1)
  -> Int
     -- ^ delay between attempts, in microseconds
  -> IO (Either Text [CommandJson])
     -- ^ fetch the registry (@GET \/api\/commands@)
  -> ([BotCommand] -> IO (Either Text ()))
     -- ^ register the menu (@setMyCommands@)
  -> IO (Either Text ())
registerWithRetry attempts delayUs fetch register = go (max 1 attempts)
  where
    go :: Int -> IO (Either Text ())
    go remaining = do
      eCmds <- fetch
      eResult <- case eCmds of
        Left e   -> pure (Left e)
        Right cs -> register (telegramMenuCommands cs)
      case eResult of
        Right () -> pure (Right ())
        Left e
          | remaining <= 1 -> pure (Left e)
          | otherwise -> do
              when (delayUs > 0) (threadDelay delayUs)
              go (remaining - 1)
