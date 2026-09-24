{-# LANGUAGE OverloadedStrings #-}
-- | Tool-call rendering helpers for chat channels. Ports the per-opcode
-- emoji mapping and 'formatToolLine' from
-- 'Seal.Channels.StreamProgress' so the chat-channel package can render
-- tool-progress lines with the same emoji prefixes the old channel
-- implementation used, without depending on server internals.
module Seal.Channels.Chat.ToolRender
  ( opEmoji
  , formatToolLine
  ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- | A local opaque type standing in for 'OpName' — the chat-channel
-- package does not depend on 'Seal.Core.Types', so we use 'Text' wrapped
-- in a newtype to keep the signature self-consistent. The loop passes
-- the raw opcode name text.
newtype OpName = OpName Text
  deriving stock (Eq, Ord, Show)

-- | Format a tool-call progress line: the per-opcode emoji, the opcode
-- name, and a truncated input. For secret-bearing opcodes (in the
-- 'secretOps' set), the input is replaced with @"<redacted>"@. Pure.
formatToolLine :: Set OpName -> Text -> Text -> Text
formatToolLine secretOps name input =
  opEmoji name <> " " <> name <> " " <> inputDisplay
  where
    inputDisplay
      | OpName name `Set.member` secretOps = "<redacted>"
      | otherwise = truncateInput input
    truncateInput t =
      if T.length t > 120
        then T.take 120 t <> "..."
        else t

-- | Map an opcode name to a display emoji for tool-progress lines.
-- Mirrors 'Seal.Channels.StreamProgress.opEmoji' exactly. Unknown
-- opcodes fall back to the high-voltage sign (@⚡@). Pure.
opEmoji :: Text -> Text
opEmoji name = case name of
  "SHELL_EXEC"       -> "\x1F4BB"  -- 💻 laptop
  "BIN_EXEC"         -> "\x2699\xFE0F"  -- ⚙️ gear
  "FILE_READ"        -> "\x1F4D6"  -- 📖 open book
  "FILE_WRITE"       -> "\x270D\xFE0F"  -- ✍️ writing hand
  "FILE_PATCH"       -> "\x1F527"  -- 🔧 wrench
  "SEARCH_FILES"     -> "\x1F50E"  -- 🔎 magnifying glass tilted right
  "WEB_SEARCH"       -> "\x1F50D"  -- 🔍 magnifying glass
  "WEB_FETCH"        -> "\x1F4C4"  -- 📄 page facing up
  "SETUP_REPO"       -> "\x1F4E5"  -- 📥 inbox tray
  "SECRET_GET"       -> "\x1F5DD"  -- 🗝 old key
  "MEMORY_WRITE"     -> "\x1F9E0"  -- 🧠 brain
  "MEMORY_READ"      -> "\x1F9E0"  -- 🧠 brain
  "MEMORY_LIST"      -> "\x1F9E0"  -- 🧠 brain
  "MEMORY_SEARCH"    -> "\x1F9E0"  -- 🧠 brain
  "MEMORY_ARCHIVE"   -> "\x1F9E0"  -- 🧠 brain
  "MEMORY_MANAGE"    -> "\x1F9E0"  -- 🧠 brain
  "SKILL_WRITE"      -> "\x1F4DD"  -- 📝 memo
  "SKILL_LOAD"       -> "\x1F4DA"  -- 📚 books
  "SKILL_LIST"       -> "\x1F4DA"  -- 📚 books
  "SKILL_DELETE"     -> "\x1F4DA"  -- 📚 books
  "SKILL_MANAGE"     -> "\x1F4DA"  -- 📚 books
  "AGENT_DEF_WRITE"  -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_READ"   -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_LIST"   -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_DELETE" -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_MANAGE" -> "\x1F916"  -- 🤖 robot face
  "AGENT_INSTANCES"  -> "\x1F916"  -- 🤖 robot face
  "AGENT_MANAGE"     -> "\x1F916"  -- 🤖 robot face
  "AGENT_START"      -> "\x1F680"  -- 🚀 rocket
  "AGENT_STATUS"     -> "\x1F916"  -- 🤖 robot face
  "AGENT_STOP"       -> "\x1F6D1"  -- 🛑 stop sign
  "AGENT_INTERRUPT"  -> "\x270B"   -- ✋ raised hand
  "SHOW_HUMAN"       -> "\x1F4E2"  -- 📢 loudspeaker
  "ASK_HUMAN"        -> "\x2753"   -- ❓ question mark
  "PROCESS_MANAGE"   -> "\x2699\xFE0F"  -- ⚙️ gear
  "HARNESS_LIST"     -> "\x1F5A5\xFE0F"  -- 🖥️ desktop computer
  "HARNESS_START"    -> "\x1F5A5\xFE0F"  -- 🖥️ desktop computer
  "HARNESS_STOP"     -> "\x1F5A5\xFE0F"  -- 🖥️ desktop computer
  "OPCODE_DESCRIBE"  -> "\x1F50E"  -- 🔎 magnifying glass tilted right
  "OPCODE_LIST"      -> "\x1F4CB"  -- 📋 clipboard
  "SESSION_MANAGE"   -> "\x1F4AC"  -- 💬 speech balloon
  _                  -> "\x26A1"   -- ⚡ high voltage