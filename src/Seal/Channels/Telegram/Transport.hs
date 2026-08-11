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
  , TelegramButton (..)
  , BotCommand (..)
  , mkMockTelegramTransport
  , mkRealTelegramTransport
  , parseTelegramUpdate
  , chunkMessage
  , tgSendWithKeyboardViaApi
  , answerCallbackQueryViaApi
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

import Katip (Severity (..), ls)
import Seal.Core.MessageSource
  ( ConversationId, UserId, mkConversationId, mkUserId )
import Seal.Logging.Global (globalLogIO)

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
  , tgSendWithKeyboard :: Text -> Text -> [[TelegramButton]] -> IO ()
    -- ^ Send a message with an inline keyboard: chat id, body, keyboard
    -- rows. Calls @sendMessage@ with @reply_markup@. Does NOT set
    -- @parse_mode@ (gate: Security #3 — plain text).
  , tgSetCommands :: [BotCommand] -> IO ()
    -- ^ Register the bot's command menu via @setMyCommands@ (auto-completion).
  , tgAnswerCallback :: Text -> IO ()
    -- ^ Acknowledge a @callback_query@ via the Bot API
    -- @answerCallbackQuery@ (stops the button's loading spinner).
    -- Best-effort: never throws. The argument is the
    -- @callback_query_id@.
  , tgClose       :: IO ()
  }

-- | A BotFather command menu entry: the command name (without the leading
-- @/@) and a short description (≤ 256 chars per Telegram's limit). Derived
-- from the Seal command 'Registry' by 'telegramBotCommands'.
data BotCommand = BotCommand
  { bcName        :: Text   -- ^ command name, lowercase, ≤ 32 chars
  , bcDescription :: Text   -- ^ short description, ≤ 256 chars
  } deriving stock (Eq, Show)

-- | One inline-keyboard button: the visible text + the callback_data (sent
-- back to the bot when the human taps the button). The callback_data is
-- @\"<8hexAskIdPrefix>:<label>\"@ (≤ 64 bytes; the label byte-bound is 55).
data TelegramButton = TelegramButton
  { tbText         :: !Text
  , tbCallbackData :: !Text
  } deriving stock (Eq, Show)

-- | ToJSON for 'TelegramButton' — encodes as @{\"text\":..., \"callback_data\":...}@.
instance A.ToJSON TelegramButton where
  toJSON (TelegramButton txt cbd) = A.object
    [ "text" A..= txt
    , "callback_data" A..= cbd
    ]

-- | A parsed inbound Telegram update: the conversation id (from chat.id),
-- the sender's user id (from from.id), and the message body. The
-- conversation id is server-derived from authenticated transport metadata
-- (the Telegram @chat.id@ field), never read from the message body. The
-- raw @chatId@ is also carried so the channel can address replies without
-- stripping the @tg:@ conversation-id prefix.
--
-- When the update is a @callback_query@ (a button tap), 'tuCallbackData'
-- is @Just data@ + 'tuCallbackId' is @Just id@; 'tuBody' is the
-- callback_data (the loop uses it to route). When the update is a regular
-- @message@, both are @Nothing@ + 'tuBody' is the message text.
data TelegramUpdate = TelegramUpdate
  { tuConversationId :: ConversationId
  , tuChatId          :: Text
  , tuSender          :: UserId
  , tuBody            :: Text
  , tuCallbackData    :: Maybe Text  -- ^ @Just data@ for callback_query; @Nothing@ for message
  , tuCallbackId      :: Maybe Text  -- ^ @Just id@ for callback_query (for answerCallbackQuery); @Nothing@ for message
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Mock transport
-- ---------------------------------------------------------------------------

-- | A mock transport backed by a 'TQueue' of inbound 'TelegramUpdate's and an
-- 'IORef' of captured sends. 'tgReceive' pops the next inbound (or returns
-- @Left "inbox empty"@); 'tgSend' appends @(chatId, body)@ to the capture;
-- 'tgSetCommands' captures the last registered commands; 'tgClose' is a
-- no-op (idempotent). 'tgSendWithKeyboard' + 'tgAnswerCallback' capture to
-- separate IORefs (for test assertions). Returns the transport + an action
-- to read captured sends + an action to read captured commands + an action
-- to read captured callback acknowledgements + an action to read captured
-- keyboard sends (each @(chatId, body, keyboard)@).
mkMockTelegramTransport
  :: [TelegramUpdate]
  -> IO ( TelegramTransport, IO [(Text, Text)], IO [BotCommand]
        , IO [Text], IO [(Text, Text, [[TelegramButton]])] )
mkMockTelegramTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  cmdRef <- newIORef []
  kbRef <- newIORef []
  cbRef <- newIORef []
  let transport = TelegramTransport
        { tgReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just u  -> pure (Right u)
              Nothing -> pure (Left "telegram inbox empty")
        , tgSend = \c b -> modifyIORef' capRef ((c, b) :)
        , tgSendWithKeyboard = \c b kb -> modifyIORef' kbRef ((c, b, kb) :)
        , tgSetCommands = writeIORef cmdRef
        , tgAnswerCallback = \cbId -> modifyIORef' cbRef (cbId :)
        , tgClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
      getCommands = readIORef cmdRef
      getCallbacks = reverse <$> readIORef cbRef
      getKeyboards = reverse <$> readIORef kbRef
  pure (transport, getCaptured, getCommands, getCallbacks, getKeyboards)

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
    , tgSendWithKeyboard = tgSendWithKeyboardViaApi mgr token
    , tgSetCommands = \cmds -> do
        eRes <- setMyCommandsViaApi mgr token cmds
        case eRes of
          Left err -> globalLogIO ErrorS ("telegram setMyCommands failed: " <> ls err)
          Right _  -> pure ()
    , tgAnswerCallback = answerCallbackQueryViaApi mgr token
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
-- updates as @(update_id, TelegramUpdate)@ pairs — @message@ and
-- @callback_query@ updates are parsed; other update types are skipped.
-- Explicitly requests @message@ + @callback_query@ via @allowed_updates@
-- so button taps are delivered (without this, Telegram uses the previous
-- setting, which may exclude @callback_query@).
getUpdates :: Manager -> Text -> Int -> IO (Either Text [(Int, TelegramUpdate)])
getUpdates mgr token offset = do
  let url = T.unpack (telegramApiBase <> token <> "/getUpdates")
             <> "?offset=" <> show offset <> "&timeout=30"
             <> "&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D"
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

-- | Parse a raw Telegram update into a 'TelegramUpdate'. Handles two shapes:
--
-- 1. @message@ — a regular text message. 'tuCallbackData'/'tuCallbackId' are
--    @Nothing@; 'tuBody' is the message text.
-- 2. @callback_query@ — a button tap on an inline keyboard.
--    'tuCallbackData' is @Just data@ (the callback_data); 'tuCallbackId' is
--    @Just id@ (the callback_query id, for answerCallbackQuery);
--    'tuBody' is the callback_data (the loop routes by it); the chat id +
--    sender come from @callback_query.message.chat@ / @callback_query.from@.
--
-- Skips non-message/non-callback updates with a 'Left'.
parseTelegramUpdate :: Value -> Either Text TelegramUpdate
parseTelegramUpdate v =
  case v of
    A.Object o ->
      case KeyMap.lookup (Key.fromString "callback_query") o of
        Just cq -> parseCallbackQuery cq
        Nothing -> case KeyMap.lookup (Key.fromString "message") o of
          Just m  -> parseMessage m
          Nothing -> Left "update has no message or callback_query field"
    _ -> Left "update not an object"
  where
    parseMessage msg =
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
            , tuCallbackData    = Nothing
            , tuCallbackId      = Nothing
            }
        _ -> Left "message not an object"
    parseCallbackQuery cq =
      case cq of
        A.Object cqo -> do
          -- callback_query has: id, from, message (with chat), data
          callbackId <- case KeyMap.lookup (Key.fromString "id") cqo of
            Just (A.Number n) -> Right (T.pack (show (round n :: Int)))
            _ -> Left "callback_query.id missing"
          callbackData <- case KeyMap.lookup (Key.fromString "data") cqo of
            Just (A.String t) -> Right t
            _ -> Left "callback_query.data missing"
          -- chat.id comes from callback_query.message.chat.id
          msg <- case KeyMap.lookup (Key.fromString "message") cqo of
            Just m -> Right m
            Nothing -> Left "callback_query has no message field"
          case msg of
            A.Object mo -> do
              chatId <- requireChatId mo
              cid <- case mkConversationId ("tg:" <> chatId) of
                Right c -> Right c
                Left err -> Left ("conversation id construction failed: " <> err)
              sender <- case KeyMap.lookup (Key.fromString "from") cqo of
                Just (A.Object fo) -> case KeyMap.lookup (Key.fromString "id") fo of
                  Just (A.Number n) -> case mkUserId (T.pack (show (round n :: Int))) of
                    Right u  -> Right u
                    Left err -> Left ("telegram callback sender not a valid UserId: " <> err)
                  _ -> Left "callback_query.from.id missing"
                _ -> Left "callback_query.from field missing"
              Right TelegramUpdate
                { tuConversationId = cid
                , tuChatId          = chatId
                , tuSender          = sender
                , tuBody            = callbackData
                , tuCallbackData    = Just callbackData
                , tuCallbackId      = Just callbackId
                }
            _ -> Left "callback_query.message not an object"
        _ -> Left "callback_query not an object"

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
    Left ex -> globalLogIO WarningS ("telegram send: request error: " <> ls (T.pack (show ex)))
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

-- | Send a message with an inline keyboard via the Bot API @sendMessage@.
-- The payload includes @reply_markup: {inline_keyboard: ...}@. **MUST NOT
-- set @parse_mode@** (gate: Security #3 — the question text and button
-- labels are plain text; no markdown/HTML interpretation). The keyboard is
-- an array of rows, each row an array of 'TelegramButton'.
tgSendWithKeyboardViaApi :: Manager -> Text -> Text -> Text -> [[TelegramButton]] -> IO ()
tgSendWithKeyboardViaApi mgr token chatId body keyboard = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/sendMessage")))
  case eReq of
    Left ex -> globalLogIO WarningS ("telegram send+keyboard: request error: " <> ls (T.pack (show ex)))
    Right req0 -> do
      let payload = A.object
            [ "chat_id" A..= chatId
            , "text"   A..= body
            , "reply_markup" A..= A.object
                [ "inline_keyboard" A..= map (map A.toJSON) keyboard
                ]
            ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()

-- | Acknowledge a callback_query via the Bot API @answerCallbackQuery@.
-- Stops the button's loading spinner. Best-effort (logs on failure, never
-- throws). The @callback_query_id@ is from the inbound update's
-- 'tuCallbackId'. (Deferred from the v1 inbound path — the
-- callback_query_id is not currently threaded through the channel loop;
-- this function is ready for the follow-up.)
answerCallbackQueryViaApi :: Manager -> Text -> Text -> IO ()
answerCallbackQueryViaApi mgr token callbackQueryId = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/answerCallbackQuery")))
  case eReq of
    Left _ -> pure ()  -- best-effort: log nothing (no logger in scope)
    Right req0 -> do
      let payload = A.object
            [ "callback_query_id" A..= callbackQueryId
            ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()

-- | Register the bot's command menu via @setMyCommands@ so Telegram shows
-- auto-completion for the bot's slash commands. Calls the Bot API with a
-- JSON array of @{command, description}@ objects. Returns 'Left' with a
-- diagnostic on failure (the bot still works without auto-completion); the
-- caller logs the error.
setMyCommandsViaApi :: Manager -> Text -> [BotCommand] -> IO (Either Text ())
setMyCommandsViaApi mgr token commands = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/setMyCommands")))
  case eReq of
    Left ex -> pure (Left ("request error: " <> T.pack (show ex)))
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
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left ex -> pure (Left ("network error: " <> T.pack (show ex)))
        Right resp -> do
          let code = statusCode (responseStatus resp)
          if code == 200
            then pure (Right ())
            else pure (Left ("HTTP " <> T.pack (show code) <> " — " <> T.pack (show (responseBody resp))))

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