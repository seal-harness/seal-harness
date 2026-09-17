{-# LANGUAGE OverloadedStrings #-}
-- | The streaming progress manager for chat channels. When enabled, the
-- agent loop routes text deltas and tool-call notifications through this
-- module, which sends progressive edits to the chat platform (Telegram via
-- @editMessageText@, Signal via @send@ with @editTimestamp@). Both
-- platforms support message editing, so the same edit-based algorithm
-- works for both — the message identifier is an opaque 'Text' to the
-- caller (a Telegram @message_id@ string or a Signal @timestamp@ string).
--
-- The module is in the library (not a channel-specific sub-module) because
-- the streaming logic is platform-agnostic; only the 'ChannelHandle' /
-- transport methods differ. Mirrors Hermes' @GatewayStreamConsumer@ but
-- adapted to Seal's @ReaderT AppEnv IO@ + handle pattern.
module Seal.Channels.StreamProgress
  ( StreamProgressConfig (..)
  , defaultStreamProgressConfig
  , resolveStreamProgressConfig
  , StreamProgress (..)
  , newStreamProgress
  , onToolCall
  , opEmoji
  , onTextDelta
  , finalizeText
  , segmentBreak
  , formatToolLine
  , shouldEdit
  , addCursor
  , stripCursor
  ) where

import Control.Monad (unless, void, when)
import Data.Default (Default (..))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)

import Seal.Core.Types (OpName (..))
import Seal.Handles.Channel (ChannelHandle (..))

-- | Configuration for the stream progress manager. Loaded from the
-- @[chat_streaming]@ section of @config.toml@. When @spcEnabled@ is
-- 'False', the manager is inert (the existing behavior: no streaming,
-- no tool progress, final text sent once via 'replyFanout').
data StreamProgressConfig = StreamProgressConfig
  { spcEnabled         :: !Bool
    -- ^ Master switch. 'False' = existing behavior (no streaming).
  , spcToolProgress    :: !Bool
    -- ^ Send tool-call notifications as an editable progress bubble.
  , spcTextStreaming   :: !Bool
    -- ^ Progressive text edits as tokens arrive.
  , spcEditIntervalMs  :: !Int
    -- ^ Minimum milliseconds between edits (rate limiting).
  , spcBufferThreshold :: !Int
    -- ^ Codepoints accumulated before forcing an edit (debounce).
  , spcCursor          :: !Text
    -- ^ Cursor character appended to intermediate edits (removed on
    -- the final edit). Default: @▉@ (U+2589 LEFT ONE QUARTER BLOCK).
  } deriving stock (Eq, Show)

-- | The default config: disabled, with sensible defaults for the other
-- fields. When the operator enables @spcEnabled@, the rest of the fields
-- are already populated.
instance Default StreamProgressConfig where
  def = StreamProgressConfig
    { spcEnabled         = False
    , spcToolProgress    = True
    , spcTextStreaming   = True
    , spcEditIntervalMs  = 1500
    , spcBufferThreshold = 80
    , spcCursor          = "\x2589"
    }

-- | The canonical default for re-export. Same as 'def'.
defaultStreamProgressConfig :: StreamProgressConfig
defaultStreamProgressConfig = def

-- | Resolve an optional 'StreamProgressConfig' from the config file into a
-- fully-populated one. 'Nothing' (the @[chat_streaming]@ section is absent)
-- returns the disabled default. A present-but-partial section fills
-- missing fields from 'def'. Pure.
resolveStreamProgressConfig :: Maybe StreamProgressConfig -> StreamProgressConfig
resolveStreamProgressConfig = fromMaybe def

-- | The mutable streaming state for one turn. Lives in 'IORef's so the
-- agent loop can call 'onToolCall' / 'onTextDelta' / 'finalizeText'
-- without passing the state around.
data StreamProgress = StreamProgress
  { spConfig        :: !StreamProgressConfig
  , spHandle        :: !ChannelHandle
  , spTextMsgId     :: !(IORef (Maybe Text))
    -- ^ The message id of the current text bubble ('Nothing' = no
    -- message sent yet for this segment).
  , spToolMsgId     :: !(IORef (Maybe Text))
    -- ^ The message id of the current tool-progress bubble.
  , spAccumulated   :: !(IORef Text)
    -- ^ Accumulated text deltas for the current text segment.
  , spToolLines     :: !(IORef [Text])
    -- ^ Accumulated tool-call lines for the current tool bubble.
  , spLastEdit      :: !(IORef (Maybe UTCTime))
    -- ^ Wall-clock time of the last edit (for rate limiting).
  , spEditSupported :: !(IORef Bool)
    -- ^ 'False' once edits start failing (fall back to new messages).
  , spSecretOps     :: !(Set OpName)
    -- ^ Opcodes whose input must be redacted from tool-progress lines.
  }

-- | Create a new 'StreamProgress' for a turn. The 'secretOps' set is the
-- set of opcode names whose input must not be shown in tool-progress
-- messages (e.g. @SECRET_GET@). The caller passes it from the registry's
-- 'secretOpcodes'.
newStreamProgress :: StreamProgressConfig -> ChannelHandle -> Set OpName -> IO StreamProgress
newStreamProgress cfg h secretOps = do
  textMsgId  <- newIORef Nothing
  toolMsgId  <- newIORef Nothing
  accum      <- newIORef ""
  toolLns    <- newIORef []
  lastEdit   <- newIORef Nothing
  editOk     <- newIORef True
  pure StreamProgress
    { spConfig        = cfg
    , spHandle        = h
    , spTextMsgId     = textMsgId
    , spToolMsgId     = toolMsgId
    , spAccumulated   = accum
    , spToolLines     = toolLns
    , spLastEdit      = lastEdit
    , spEditSupported = editOk
    , spSecretOps     = secretOps
    }

-- | Called when the agent is about to dispatch a tool call. Sends or
-- edits the tool-progress bubble with the new tool line appended. When
-- the config has @spcToolProgress = False@ or @spcEnabled = False@, this
-- is a no-op. IO.
onToolCall :: StreamProgress -> OpName -> Text -> IO ()
onToolCall sp opName input =
  when (spcToolProgress cfg && spcEnabled cfg) $ do
    let line = formatToolLine (spSecretOps sp) opName input
    currentLines <- readIORef (spToolLines sp)
    let newLines = currentLines <> [line]
    writeIORef (spToolLines sp) newLines
    msgId <- readIORef (spToolMsgId sp)
    let content = T.intercalate "\n" newLines
    case msgId of
      Nothing -> do
        mId <- chSendWithId (spHandle sp) content
        case mId of
          Just id' -> writeIORef (spToolMsgId sp) (Just id')
          Nothing  -> pure ()
      Just id' -> do
        editOk <- editOrFallback sp id' content
        unless editOk $ writeIORef (spEditSupported sp) False
  where cfg = spConfig sp

-- | Called for each text delta from the provider stream. Accumulates
-- the text and sends/edits the text bubble when the rate-limit /
-- threshold conditions are met. IO.
onTextDelta :: StreamProgress -> Text -> IO ()
onTextDelta sp delta =
  when (spcTextStreaming cfg && spcEnabled cfg) $ do
    accum <- readIORef (spAccumulated sp)
    let accum' = accum <> delta
    writeIORef (spAccumulated sp) accum'
    now <- getCurrentTime
    mLastEdit <- readIORef (spLastEdit sp)
    msgId <- readIORef (spTextMsgId sp)
    when (shouldEdit cfg now mLastEdit (T.length accum')) $ do
      let content = addCursor cfg accum'
      case msgId of
        Nothing -> do
          mId <- chSendWithId (spHandle sp) content
          case mId of
            Just id' -> do
              writeIORef (spTextMsgId sp) (Just id')
              writeIORef (spLastEdit sp) (Just now)
            Nothing  -> pure ()
        Just id' -> do
          editOk <- editOrFallback sp id' content
          when editOk $ writeIORef (spLastEdit sp) (Just now)
  where cfg = spConfig sp

-- | Finalize the text stream: edit the message without the cursor. If
-- the edit fails, send the full text as a new message. Returns 'True' if
-- the final text was delivered (via edit or new message), 'False' if
-- nothing was sent (the caller should fall back to 'replyFanout'). IO.
finalizeText :: StreamProgress -> Text -> IO Bool
finalizeText sp finalText =
  if spcTextStreaming cfg && spcEnabled cfg
    then do
      accum <- readIORef (spAccumulated sp)
      let text = if T.null accum then finalText else accum
      msgId <- readIORef (spTextMsgId sp)
      case msgId of
        Nothing -> do
          mId <- chSendWithId (spHandle sp) text
          pure (isJust mId)
        Just id' -> do
          editOk <- editOrFallback sp id' text
          if editOk
            then pure True
            else do
              mId <- chSendWithId (spHandle sp) text
              pure (isJust mId)
    else pure False
  where cfg = spConfig sp

-- | Signal a segment break: the current text message is finalized (edit
-- without cursor) and the state is reset so the next text delta starts a
-- new message below any tool-progress messages. IO.
segmentBreak :: StreamProgress -> IO ()
segmentBreak sp =
  when (spcTextStreaming cfg && spcEnabled cfg) $ do
    msgId <- readIORef (spTextMsgId sp)
    accum <- readIORef (spAccumulated sp)
    case (msgId, T.null accum) of
      (Just id', False) -> voidEditOrFallback sp id' accum
      _                 -> pure ()
    writeIORef (spTextMsgId sp) Nothing
    writeIORef (spAccumulated sp) ""
    writeIORef (spToolMsgId sp) Nothing
    writeIORef (spToolLines sp) []
  where cfg = spConfig sp

-- | Edit a message via 'chEditMessage'. Returns 'True' on success,
-- 'False' if editing is not supported or the edit fails. IO.
editOrFallback :: StreamProgress -> Text -> Text -> IO Bool
editOrFallback sp msgId content =
  case chEditMessage (spHandle sp) of
    Just editFn -> editFn msgId content
    Nothing     -> pure False

-- | Like 'editOrFallback' but discards the result. IO.
voidEditOrFallback :: StreamProgress -> Text -> Text -> IO ()
voidEditOrFallback sp msgId content =
  void (editOrFallback sp msgId content)

-- | Format a tool-call progress line. Shows the opcode name and a
-- truncated input. The opcode name is prefixed with a per-opcode emoji
-- (see 'opEmoji'). For secret-bearing opcodes (in the 'secretOps' set),
-- the input is replaced with @"<redacted>"@. Pure.
formatToolLine :: Set OpName -> OpName -> Text -> Text
formatToolLine secretOps (OpName name) input =
  opEmoji (OpName name) <> " " <> name <> " " <> inputDisplay
  where
    inputDisplay
      | OpName name `Set.member` secretOps = "<redacted>"
      | otherwise = truncateInput input
    truncateInput t =
      if T.length t > 120
        then T.take 120 t <> "..."
        else t

-- | Map an opcode name to a display emoji for tool-progress lines.
-- Inspired by the per-tool emoji mapping in hermes-agent's tool registry.
-- Unknown opcodes fall back to the high-voltage sign (@⚡@), matching
-- the convention for generic tool activity. Pure.
opEmoji :: OpName -> Text
opEmoji (OpName name) = case name of
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
  "MEMORY_RECALL"    -> "\x1F9E0"  -- 🧠 brain
  "MEMORY_DELETE"    -> "\x1F9E0"  -- 🧠 brain
  "SKILL_WRITE"      -> "\x1F4DD"  -- 📝 memo
  "SKILL_LOAD"       -> "\x1F4DA"  -- 📚 books
  "SKILL_LIST"       -> "\x1F4DA"  -- 📚 books
  "SKILL_DELETE"     -> "\x1F4DA"  -- 📚 books
  "AGENT_DEF_WRITE"  -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_READ"   -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_LIST"   -> "\x1F916"  -- 🤖 robot face
  "AGENT_DEF_DELETE" -> "\x1F916"  -- 🤖 robot face
  "AGENT_INSTANCES"  -> "\x1F916"  -- 🤖 robot face
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
  _                  -> "\x26A1"   -- ⚡ high voltage

-- | Should the manager send an edit now? Returns 'True' when enough
-- time has passed since the last edit, or the buffer threshold is
-- exceeded. Pure (takes the current time as an argument).
shouldEdit :: StreamProgressConfig -> UTCTime -> Maybe UTCTime -> Int -> Bool
shouldEdit cfg now mLastEdit accumLen =
  accumLen >= spcBufferThreshold cfg || timeElapsed
  where
    timeElapsed = case mLastEdit of
      Nothing -> True
      Just lastEdit ->
        diffUTCTime now lastEdit * 1000
          >= fromIntegral (spcEditIntervalMs cfg)

-- | Append the cursor to the text for intermediate edits. Pure.
addCursor :: StreamProgressConfig -> Text -> Text
addCursor cfg text =
  if T.null (spcCursor cfg) then text else text <> spcCursor cfg

-- | Strip the cursor from the text for the final edit. Pure.
stripCursor :: StreamProgressConfig -> Text -> Text
stripCursor cfg text =
  if T.null (spcCursor cfg)
    then text
    else fromMaybe text (T.stripSuffix (spcCursor cfg) text)
