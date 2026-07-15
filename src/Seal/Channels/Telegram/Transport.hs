{-# LANGUAGE OverloadedStrings #-}
-- | The testability seam over the Telegram Bot API. The real implementation
-- uses HTTP long-polling on @getUpdates@ and sends via @sendMessage@; the
-- mock implementation backs the test suite, so no network is needed for
-- @cabal test@. Mirrors "Seal.Channels.Signal.Transport" in shape:
-- 'tgReceive' pulls the next inbound update, 'tgSend' sends a message,
-- 'tgClose' cleans up.
module Seal.Channels.Telegram.Transport
  ( TelegramTransport (..)
  , TelegramUpdate (..)
  , BotCommand (..)
  , mkMockTelegramTransport
  , mkRealTelegramTransport
  , parseTelegramUpdate
  , chunkMessage
  ) where

import Control.Concurrent.STM
  ( atomically, newTQueueIO, tryReadTQueue, writeTQueue )
import Control.Exception (SomeException, try)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client
  ( Manager, Request (..), httpLbs, parseRequest, requestBody, responseBody
  , responseStatus, responseTimeoutMicro, RequestBody (RequestBodyLBS) )
import Network.HTTP.Types (statusCode, methodPost)

import Seal.Core.MessageSource
  ( ConversationId, UserId, mkConversationId, mkUserId )

-- ---------------------------------------------------------------------------
-- TelegramTransport — the testability seam
-- ---------------------------------------------------------------------------

-- | The testability seam over the Telegram Bot API. The channel layer calls
-- 'tgReceive' to pull the next parsed update (blocks until one arrives or
-- the transport closes), 'tgSend' to send a message (chat id + body),
-- 'tgSetCommands' to register the bot's slash-command menu with BotFather
-- (for auto-completion), and 'tgClose' to clean up.
data TelegramTransport = TelegramTransport
  { tgReceive     :: IO (Either Text TelegramUpdate)
    -- ^ Next inbound update. 'Right' on success; 'Left' diagnostic on
    -- close/failure (the reader thread stops).
  , tgSend        :: Text -> Text -> IO ()
    -- ^ Send a message: chat id, body. Calls the Bot API @sendMessage@.
  , tgSetCommands :: [BotCommand] -> IO ()
    -- ^ Register the bot's command menu via @setMyCommands@ (auto-completion).
  , tgClose       :: IO ()
  }

-- | A BotFather command menu entry: the command name (without the leading
-- @/@) and a short description (≤ 256 chars per Telegram's limit). Derived
-- from the Seal command 'Registry' by 'telegramBotCommands'.
data BotCommand = BotCommand
  { bcName        :: Text   -- ^ command name, lowercase, ≤ 32 chars
  , bcDescription :: Text   -- ^ short description, ≤ 256 chars
  } deriving stock (Eq, Show)

-- | A parsed inbound Telegram update: the conversation id (from chat.id),
-- the sender's user id (from from.id), and the message body. The
-- conversation id is server-derived from authenticated transport metadata
-- (the Telegram @chat.id@ field), never read from the message body. The
-- raw @chatId@ is also carried so the channel can address replies without
-- stripping the @tg:@ conversation-id prefix.
data TelegramUpdate = TelegramUpdate
  { tuConversationId :: ConversationId
  , tuChatId          :: Text
  , tuSender          :: UserId
  , tuBody            :: Text
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Mock transport
-- ---------------------------------------------------------------------------

-- | A mock transport backed by a 'TQueue' of inbound 'TelegramUpdate's and an
-- 'IORef' of captured sends. 'tgReceive' pops the next inbound (or returns
-- @Left "inbox empty"@); 'tgSend' appends @(chatId, body)@ to the capture;
-- 'tgSetCommands' captures the last registered commands; 'tgClose' is a
-- no-op (idempotent). Returns the transport + an action to read captured
-- sends + an IORef holding the last set commands (for test assertions).
mkMockTelegramTransport
  :: [TelegramUpdate] -> IO (TelegramTransport, IO [(Text, Text)], IO [BotCommand])
mkMockTelegramTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  cmdRef <- newIORef []
  let transport = TelegramTransport
        { tgReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just u  -> pure (Right u)
              Nothing -> pure (Left "telegram inbox empty")
        , tgSend = \c b -> modifyIORef' capRef ((c, b) :)
        , tgSetCommands = writeIORef cmdRef
        , tgClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
      getCommands = readIORef cmdRef
  pure (transport, getCaptured, getCommands)

-- ---------------------------------------------------------------------------
-- Real transport — Telegram Bot API over HTTPS
-- ---------------------------------------------------------------------------

-- | The Telegram Bot API base URL.
telegramApiBase :: Text
telegramApiBase = "https://api.telegram.org/bot"

-- | Spawn the real Telegram transport: long-polls @getUpdates@ and sends via
-- @sendMessage@. 'tgReceive' blocks on @getUpdates@ (30s long-poll), parses
-- each update into a 'TelegramUpdate', and advances the @offset@ so
-- acknowledged updates are not re-delivered. 'tgSend' calls @sendMessage@.
-- 'tgSetCommands' calls @setMyCommands@ to register the bot's slash-command
-- menu for auto-completion. 'tgClose' is a no-op (long-polling is stateless;
-- no child process to kill). The transport maintains an internal buffer
-- ('TQueue') of parsed updates from the last @getUpdates@ call, refilling
-- when it drains.
mkRealTelegramTransport :: Text -> Manager -> IO TelegramTransport
mkRealTelegramTransport token mgr = do
  buffer <- newTQueueIO
  offsetRef <- newIORef (0 :: Int)
  pure TelegramTransport
    { tgReceive = fillAndReceive buffer offsetRef
    , tgSend = sendViaApi mgr token
    , tgSetCommands = setMyCommandsViaApi mgr token
    , tgClose = pure ()
    }
  where
    -- If the buffer is empty, call getUpdates to refill it, then pop one.
    fillAndReceive buffer offsetRef = do
      m <- atomically (tryReadTQueue buffer)
      case m of
        Just u  -> pure (Right u)
        Nothing -> do
          offset <- readIORef offsetRef
          eUpdates <- getUpdates mgr token offset
          case eUpdates of
            Left err -> pure (Left err)
            Right [] -> fillAndReceive buffer offsetRef
            Right updates -> do
              let lastId = maximum (map fst updates)
              modifyIORef' offsetRef (const (lastId + 1))
              mapM_ ((atomically . writeTQueue buffer) . snd) updates
              fillAndReceive buffer offsetRef

-- | Call @getUpdates@ with long-polling (30s timeout). Returns the parsed
-- updates as @(update_id, TelegramUpdate)@ pairs — non-message updates
-- (edited messages, callbacks, etc.) are skipped.
getUpdates :: Manager -> Text -> Int -> IO (Either Text [(Int, TelegramUpdate)])
getUpdates mgr token offset = do
  let url = T.unpack (telegramApiBase <> token <> "/getUpdates")
             <> "?offset=" <> show offset <> "&timeout=30"
  eReq <- try @SomeException (parseRequest url)
  case eReq of
    Left ex -> pure (Left ("getUpdates request error: " <> T.pack (show ex)))
    Right req0 -> do
      -- The Telegram long-poll holds the connection for up to 30s; set a
      -- per-request timeout of 60s so the HTTP client doesn't abort before
      -- Telegram responds. The manager default is ~30s which races the
      -- long-poll and causes spurious ResponseTimeout errors.
      let req = req0 { responseTimeout = responseTimeoutMicro 60000000 }
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left ex -> pure (Left ("getUpdates network error: " <> T.pack (show ex)))
        Right resp ->
          let code = statusCode (responseStatus resp)
              body = responseBody resp
          in if code == 200
               then pure (parseGetUpdatesResponse body)
               else pure (Left ("getUpdates returned HTTP " <> T.pack (show code)))

-- | Parse the JSON response from getUpdates. The shape is
-- @{"ok":true,"result":[{"update_id":N,"message":{...}},...]}@. Extracts
-- @(update_id, TelegramUpdate)@ pairs, skipping non-message updates.
parseGetUpdatesResponse :: BL.ByteString -> Either Text [(Int, TelegramUpdate)]
parseGetUpdatesResponse body =
  case A.decode body of
    Nothing -> Left "getUpdates: malformed JSON response"
    Just (A.Object o) -> case KeyMap.lookup (Key.fromString "result") o of
      Just (A.Array arr) ->
        let parsed = [ parseOneUpdate v | v <- V.toList arr ]
        in Right [ (uid, u) | Right (uid, u) <- parsed ]
      _ -> Right []
    Just _ -> Left "getUpdates: response not an object"
  where
    parseOneUpdate v = do
      uid <- updateId v
      u <- parseTelegramUpdate v
      Right (uid, u)

-- | Extract the numeric @update_id@ from a Telegram update object.
updateId :: Value -> Either Text Int
updateId v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "update_id") o of
      Just (A.Number n) -> Right (round n)
      _ -> Left "update missing update_id"
    _ -> Left "update not an object"

-- | Parse a raw Telegram update into a 'TelegramUpdate'. Extracts the
-- @message.chat.id@ (conversation id), @message.from.id@ (sender), and
-- @message.text@ (body). Skips non-message updates (no @message@ field)
-- with a 'Left'.
parseTelegramUpdate :: Value -> Either Text TelegramUpdate
parseTelegramUpdate v =
  case v of
    A.Object o -> do
      msg <- case KeyMap.lookup (Key.fromString "message") o of
        Just m  -> Right m
        Nothing -> Left "update has no message field"
      case msg of
        A.Object mo -> do
          chatId <- requireChatId mo
          cid <- case mkConversationId ("tg:" <> chatId) of
            Right c -> Right c
            Left err -> Left ("conversation id construction failed: " <> err)
          sender <- requireSender mo
          let body = extractText mo
          Right TelegramUpdate
            { tuConversationId = cid
            , tuChatId          = chatId
            , tuSender          = sender
            , tuBody            = body
            }
        _ -> Left "message not an object"
    _ -> Left "update not an object"

-- | Extract @chat.id@ from a message object. Telegram chat ids are integers;
-- we stringify them for the conversation id prefix.
requireChatId :: A.Object -> Either Text Text
requireChatId mo =
  case KeyMap.lookup (Key.fromString "chat") mo of
    Just (A.Object co) -> case KeyMap.lookup (Key.fromString "id") co of
      Just (A.Number n) -> Right (T.pack (show (round n :: Int)))
      _ -> Left "chat.id missing"
    _ -> Left "chat field missing"

-- | Extract @from.id@ from a message object.
requireSender :: A.Object -> Either Text UserId
requireSender mo =
  case KeyMap.lookup (Key.fromString "from") mo of
    Just (A.Object fo) -> case KeyMap.lookup (Key.fromString "id") fo of
      Just (A.Number n) -> case mkUserId (T.pack (show (round n :: Int))) of
        Right u  -> Right u
        Left err -> Left ("telegram sender not a valid UserId: " <> err)
      _ -> Left "from.id missing"
    _ -> Left "from field missing"

-- | Extract @text@ from a message object (empty when absent — non-text
-- messages like stickers produce an empty body, which the caller drops).
extractText :: A.Object -> Text
extractText mo =
  case KeyMap.lookup (Key.fromString "text") mo of
    Just (A.String t) -> t
    _ -> ""

-- | Send a message via the Bot API @sendMessage@.
sendViaApi :: Manager -> Text -> Text -> Text -> IO ()
sendViaApi mgr token chatId body = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/sendMessage")))
  case eReq of
    Left _ -> pure ()  -- silent on send failure; the channel logs elsewhere
    Right req0 -> do
      let payload = A.object
            [ "chat_id" A..= chatId
            , "text"   A..= body
            ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()

-- | Register the bot's command menu via @setMyCommands@ so Telegram shows
-- auto-completion for the bot's slash commands. Calls the Bot API with a
-- JSON array of @{command, description}@ objects. Silent on failure (the
-- channel logs elsewhere; the bot still works without auto-completion).
setMyCommandsViaApi :: Manager -> Text -> [BotCommand] -> IO ()
setMyCommandsViaApi mgr token commands = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/setMyCommands")))
  case eReq of
    Left _ -> pure ()
    Right req0 -> do
      let cmds = [ A.object [ "command" A..= bcName bc
                            , "description" A..= bcDescription bc
                            ]
                 | bc <- commands
                 ]
          payload = A.object [ "commands" A..= cmds ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()

-- ---------------------------------------------------------------------------
-- chunkMessage — split long messages for Telegram's 4096-char limit
-- ---------------------------------------------------------------------------

-- | Split a message into chunks of at most 'limit' characters, preferring
-- paragraph boundaries (@\\n\\n@), then line boundaries (@\\n@), hard-cut
-- as a last resort. Chunks carry their trailing separator (except the last),
-- so 'T.concat' of the chunks is identity. Mirrors
-- 'Seal.Channels.Signal.Transport.chunkMessage'.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit t
  | limit < 1 = error "chunkMessage: limit must be >= 1"
  | T.null t  = []
  | otherwise = go t
  where
    go s
      | T.null s       = []
      | T.length s <= limit = [s]
      | otherwise =
          let (chunk, rest) = nextChunk limit s
          in chunk : if T.null rest then [] else go rest

nextChunk :: Int -> Text -> (Text, Text)
nextChunk limit s =
  case findParagraphBreak limit s of
    Just n -> T.splitAt n s
    Nothing -> case findLineBreak limit s of
      Just n -> T.splitAt n s
      Nothing -> T.splitAt limit s

findParagraphBreak :: Int -> Text -> Maybe Int
findParagraphBreak limit s =
  let window = T.take limit s
  in case T.breakOnEnd "\n\n" window of
       (pre, _post) | not (T.null pre) -> Just (T.length pre)
       _ -> Nothing

findLineBreak :: Int -> Text -> Maybe Int
findLineBreak limit s =
  let window = T.take limit s
  in case T.breakOnEnd "\n" window of
       (pre, _post) | not (T.null pre) -> Just (T.length pre)
       _ -> Nothing