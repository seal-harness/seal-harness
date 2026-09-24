{-# LANGUAGE OverloadedStrings #-}
-- | The Telegram chat-channel adapter. Implements 'ChatChannel' for
-- 'TelegramChatChannel', wrapping the transport + inbox + allow-list.
-- Mirrors the Signal adapter in structure.
module Seal.Channels.Chat.Telegram
  ( TelegramChatChannel (..)
  , withTelegramChatChannel
  , TelegramChatTransport (..)
  , TelegramButton (..)
  , mkMockTelegramChatTransport
  , mkRealTelegramChatTransport
  , chunkMessage
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM
  (TQueue, atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (bracket, SomeException, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text qualified as T

import Seal.Channels.Chat.Class (ChatChannel (..), QuestionOption (..))
import Seal.Channels.Chat.Types
  (InboundMessage (..), ChatMessageId (..), ReceivedMessage (..))
import Seal.Gateway.Types.AllowList (AllowList (..))
import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.MessageSource
  (UserId, mkMessageSource, mkConversationId, mkUserId)

import Data.Aeson (Value, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Vector qualified as V
import Network.HTTP.Client
  ( Manager, Request (..), httpLbs, parseRequest, requestBody, responseBody
  , responseStatus, responseTimeoutMicro, RequestBody (RequestBodyLBS) )
import Network.HTTP.Types (statusCode, methodPost)

-- | The testability seam over the Telegram Bot API. Mirrors the existing
-- 'Seal.Channels.Telegram.Transport.TelegramTransport' but in the
-- chat-channels package namespace.
data TelegramChatTransport = TelegramChatTransport
  { tctReceive :: IO (Either Text ReceivedMessage)
    -- ^ Next inbound message (from Bot API long-poll).
  , tctSend    :: Text -> Text -> IO ()
    -- ^ Send a message: chat id, body.
  , tctSendWithId :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message and return the message_id.
  , tctSendWithKeyboard :: Text -> Text -> [[TelegramButton]] -> IO (Maybe Text)
    -- ^ Send a message with an inline keyboard: chat id, body, keyboard
    -- rows. Returns the message_id (for later keyboard removal).
  , tctAnswerCallback :: Text -> IO ()
    -- ^ Acknowledge a callback_query (dismiss the button's loading spinner).
  , tctEditReplyMarkup :: Text -> Text -> IO ()
    -- ^ Remove the inline keyboard from a message: chat id, message_id.
  , tctEditMessage :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a previously sent message: chat id, message_id, new content.
  , tctClose   :: IO ()
  }

-- | One inline-keyboard button: the visible text + the callback_data (sent
-- back to the bot when the human taps the button). Mirrors
-- 'Seal.Channels.Telegram.Transport.TelegramButton'.
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

-- | Chunk a message to the given character limit. Telegram's hard limit
-- is 4096; we leave headroom.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit msg
  | T.length msg <= limit = [msg]
  | otherwise = go msg
  where
    go t
      | T.null t = []
      | T.length t <= limit = [t]
      | otherwise = T.take limit t : go (T.drop limit t)

-- | A mock transport backed by a 'TQueue' of inbound messages and an
-- 'IORef' of captured sends. For testing.
mkMockTelegramChatTransport :: [ReceivedMessage] -> IO (TelegramChatTransport, IO [Text])
mkMockTelegramChatTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  msgIdRef <- newIORef (0 :: Int)
  let transport = TelegramChatTransport
        { tctReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just msg -> pure (Right msg)
              Nothing -> pure (Left "inbox empty")
        , tctSend = \_c b -> modifyIORef' capRef (b :)
        , tctSendWithId = \_c _b -> do
            n <- readIORef msgIdRef
            writeIORef msgIdRef (n + 1)
            pure (Just (T.pack (show (n + 1))))
        , tctSendWithKeyboard = \_c _b _kb -> do
            n <- readIORef msgIdRef
            writeIORef msgIdRef (n + 1)
            pure (Just (T.pack (show (n + 1))))
        , tctAnswerCallback = \_cbId -> pure ()
        , tctEditReplyMarkup = \_c _mid -> pure ()
        , tctEditMessage = \_c _mid _content -> pure True
        , tctClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
  pure (transport, getCaptured)

-- ---------------------------------------------------------------------------
-- Real transport — Telegram Bot API over HTTPS
-- ---------------------------------------------------------------------------

-- | The Telegram Bot API base URL.
telegramApiBase :: Text
telegramApiBase = "https://api.telegram.org/bot"

-- | Spawn the real Telegram transport: long-polls @getUpdates@ and sends
-- via @sendMessage@. The 'Manager' is the shared TLS-configured HTTP
-- manager from the server. The token is the validated 'TelegramToken'
-- text. Returns 'Left' with a diagnostic if the initial @getUpdates@
-- call fails (the bot still works on retry — this is not fatal).
mkRealTelegramChatTransport :: Text -> Network.HTTP.Client.Manager -> IO TelegramChatTransport
mkRealTelegramChatTransport token mgr = do
  buffer <- newTQueueIO
  offsetRef <- newIORef (0 :: Int)
  pure TelegramChatTransport
    { tctReceive = fillAndReceive buffer offsetRef
    , tctSend = sendViaApi mgr token
    , tctSendWithId = tgSendWithIdViaApi mgr token
    , tctSendWithKeyboard = tgSendWithKeyboardViaApi mgr token
    , tctAnswerCallback = answerCallbackQueryViaApi mgr token
    , tctEditReplyMarkup = editReplyMarkupViaApi mgr token
    , tctEditMessage = tgEditMessageViaApi mgr token
    , tctClose = pure ()
    }
  where
    fillAndReceive buffer offsetRef = do
      m <- atomically (tryReadTQueue buffer)
      case m of
        Just msg -> pure (Right msg)
        Nothing -> do
          offset <- readIORef offsetRef
          eResult <- getUpdates mgr token offset
          case eResult of
            Left err -> pure (Left err)
            Right (updates, rawIds) ->
              if null updates
                then
                  if null rawIds
                    then fillAndReceive buffer offsetRef
                    else do
                      let lastId = maximum rawIds
                      modifyIORef' offsetRef (const (lastId + 1))
                      fillAndReceive buffer offsetRef
                else do
                  let lastId = maximum (map fst updates)
                  modifyIORef' offsetRef (const (lastId + 1))
                  mapM_ ((atomically . writeTQueue buffer) . snd) updates
                  fillAndReceive buffer offsetRef

-- | The live Telegram chat channel state.
data TelegramChatChannel = TelegramChatChannel
  { tccAllowList  :: AllowList UserId
  , tccChunkLimit :: Int
  , tccInbox      :: TQueue InboundMessage
  , tccTransport  :: TelegramChatTransport
  , tccLastChat   :: IORef (Maybe Text)
  , tccReaderAlive :: IORef Bool
  }

instance ChatChannel TelegramChatChannel where
  ccReceive ch = do
    mMsg <- atomically (tryReadTQueue (tccInbox ch))
    case mMsg of
      Just msg -> pure (Just msg)
      Nothing -> do
        alive <- readIORef (tccReaderAlive ch)
        if alive
          then threadDelay 1000 >> ccReceive ch
          else pure Nothing

  ccSend ch t =
    mapM_ (sendRaw ch) (chunkMessage (tccChunkLimit ch) t)

  ccSendWithId ch t = do
    mChat <- readIORef (tccLastChat ch)
    case mChat of
      Nothing -> pure Nothing
      Just chatId -> do
        mId <- tctSendWithId (tccTransport ch) chatId t
        pure (ChatMessageId <$> mId)

  ccEditMessage ch (ChatMessageId msgId) content = do
    mChat <- readIORef (tccLastChat ch)
    case mChat of
      Nothing -> pure False
      Just chatId -> tctEditMessage (tccTransport ch) chatId msgId content

  ccLabel _ = "telegram"

  ccSendWithOptions ch body opts askIdPrefix = do
    mChat <- readIORef (tccLastChat ch)
    case mChat of
      Nothing -> pure Nothing
      Just chatId -> do
        let keyboard = buildKeyboard askIdPrefix opts
        mId <- tctSendWithKeyboard (tccTransport ch) chatId body keyboard
        pure (ChatMessageId <$> mId)

  ccAnswerCallback ch = tctAnswerCallback (tccTransport ch)

  ccEditReplyMarkup ch (ChatMessageId msgId) = do
    mChat <- readIORef (tccLastChat ch)
    case mChat of
      Nothing -> pure ()
      Just chatId -> tctEditReplyMarkup (tccTransport ch) chatId msgId

  ccLastChatId ch = readIORef (tccLastChat ch)

-- | Send one chunk verbatim to the last chat.
sendRaw :: TelegramChatChannel -> Text -> IO ()
sendRaw ch t = do
  mChat <- readIORef (tccLastChat ch)
  case mChat of
    Nothing -> pure ()
    Just chatId -> tctSend (tccTransport ch) chatId t

-- | Build the inline keyboard: one row per option (button label = the
-- option's 'qoLabel', callback_data = @\"<prefix>:<idx>\"@). Pure. The
-- callback_data is always ≤ 64 bytes (8 hex + 1 colon + ≤ 1 char = ≤ 10
-- bytes). Mirrors the old 'Seal.Channels.Telegram.Run.buildKeyboard'.
buildKeyboard :: Text -> [QuestionOption] -> [[TelegramButton]]
buildKeyboard prefix opts =
  [ [TelegramButton (qoLabel o) (prefix <> ":" <> T.pack (show i))]
  | (i, o) <- zip [0 :: Int ..] opts
  ]

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'tctReceive', allow-lists the sender, and pushes 'InboundMessage's
-- to 'tccInbox'. On transport close or exception, the thread exits.
withTelegramChatChannel
  :: AllowList UserId
  -> Int
  -> TelegramChatTransport
  -> (TelegramChatChannel -> IO a)
  -> IO a
withTelegramChatChannel allow chunkLimit transport action =
  bracket before after (action . snd)
  where
    before = do
      inbox <- newTQueueIO
      lastChat <- newIORef (Nothing :: Maybe Text)
      alive <- newIORef True
      let ch = TelegramChatChannel
            { tccAllowList = allow
            , tccChunkLimit = chunkLimit
            , tccInbox = inbox
            , tccTransport = transport
            , tccLastChat = lastChat
            , tccReaderAlive = alive
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _) = do
      killThread tid
      tctClose transport

-- | The background reader: loop 'tctReceive', construct a 'MessageSource'
-- from the received conversation id + sender, update the last chat id,
-- and push to the inbox. Exits when 'tctReceive' returns 'Left'.
readerLoop :: TelegramChatChannel -> IO ()
readerLoop ch = go
  where
    go = do
      eVal <- try (tctReceive (tccTransport ch)) :: IO (Either SomeException (Either Text ReceivedMessage))
      case eVal of
        Left _ -> writeIORef (tccReaderAlive ch) False
        Right (Left _) -> writeIORef (tccReaderAlive ch) False
        Right (Right (ReceivedMessage cid mSender replyTo body mCbData _mCbId _mCbMsgId))
          | not (T.null body) -> do
              case mkMessageSource cid Telegram (mkSender <$> mSender) mempty of
                Right ms -> do
                  writeIORef (tccLastChat ch) (Just replyTo)
                  atomically (writeTQueue (tccInbox ch) (InboundMessage ms body mCbData))
                Left _ -> pure ()
              go
          | otherwise -> go

-- | Construct a 'UserId' from a sender text, best-effort.
mkSender :: Text -> UserId
mkSender t = case mkUserId t of
  Right u -> u
  Left _ -> case mkUserId "unknown" of Right u -> u; Left _ -> error "unreachable"

-- ---------------------------------------------------------------------------
-- Telegram Bot API HTTP functions
-- ---------------------------------------------------------------------------

-- | Call @getUpdates@ with long-polling (30s timeout). Returns the parsed
-- updates as @(update_id, ReceivedMessage)@ pairs + all raw update ids
-- (so the caller can advance the offset even when some updates fail to
-- parse).
getUpdates :: Manager -> Text -> Int -> IO (Either Text ([(Int, ReceivedMessage)], [Int]))
getUpdates mgr token offset = do
  let url = T.unpack (telegramApiBase <> token <> "/getUpdates")
             <> "?offset=" <> show offset <> "&timeout=30&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D"
  eReq <- try @SomeException (parseRequest url)
  case eReq of
    Left ex -> pure (Left ("getUpdates request error: " <> T.pack (show ex)))
    Right req0 -> do
      let req = req0 { responseTimeout = responseTimeoutMicro 60000000 }
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left ex -> pure (Left ("getUpdates network error: " <> T.pack (show ex)))
        Right resp ->
          let code = statusCode (responseStatus resp)
              body = responseBody resp
          in if code == 200
               then pure (parseGetUpdatesResponse body)
               else pure (Left ("getUpdates returned HTTP " <> T.pack (show code)
                              <> " — " <> T.pack (show body)))

-- | Parse the JSON response from @getUpdates@.
parseGetUpdatesResponse :: BL.ByteString -> Either Text ([(Int, ReceivedMessage)], [Int])
parseGetUpdatesResponse body =
  case A.decode body of
    Nothing -> Left "getUpdates: malformed JSON response"
    Just (A.Object o) -> case KeyMap.lookup (Key.fromString "result") o of
      Just (A.Array arr) ->
        let raws = V.toList arr
            allIds = [ uid | v <- raws, Just uid <- [rawUpdateId v] ]
            parsed = [ parseOneUpdate v | v <- raws ]
            okUpdates = [ (uid, u) | Right (uid, u) <- parsed ]
        in Right (okUpdates, allIds)
      _ -> Right ([], [])
    Just _ -> Left "getUpdates: response not an object"
  where
    parseOneUpdate v = do
      uid <- updateId v
      case parseTelegramUpdate v of
        Left err -> Left err
        Right u  -> Right (uid, u)

-- | Extract the raw @update_id@ from an update object.
rawUpdateId :: Value -> Maybe Int
rawUpdateId v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "update_id") o of
      Just (A.Number n) -> Just (round n)
      _ -> Nothing
    _ -> Nothing

-- | Extract the numeric @update_id@.
updateId :: Value -> Either Text Int
updateId v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "update_id") o of
      Just (A.Number n) -> Right (round n)
      _ -> Left "update missing update_id"
    _ -> Left "update not an object"

-- | Parse a Telegram update into a 'ReceivedMessage'. Handles @message@
-- updates (text messages). Skips non-message updates with a 'Left'.
parseTelegramUpdate :: Value -> Either Text ReceivedMessage
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
          let mSender = extractSenderId mo
              body = extractText mo
          Right ReceivedMessage
            { rmConversationId = cid
            , rmSender = mSender
            , rmReplyTo = chatId
            , rmBody = body
            , rmCallbackData = Nothing
            , rmCallbackId = Nothing
            , rmCallbackMessageId = Nothing
            }
        _ -> Left "message not an object"
    parseCallbackQuery cq =
      case cq of
        A.Object cqo -> do
          callbackId <- case KeyMap.lookup (Key.fromString "id") cqo of
            Just (A.String t) -> Right t
            Just (A.Number n) -> Right (T.pack (show (round n :: Int)))
            _ -> Left "callback_query.id missing"
          callbackData <- case KeyMap.lookup (Key.fromString "data") cqo of
            Just (A.String t) -> Right t
            _ -> Left "callback_query.data missing"
          msg <- case KeyMap.lookup (Key.fromString "message") cqo of
            Just m -> Right m
            Nothing -> Left "callback_query has no message field"
          case msg of
            A.Object mo -> do
              chatId <- requireChatId mo
              cid <- case mkConversationId ("tg:" <> chatId) of
                Right c -> Right c
                Left err -> Left ("conversation id construction failed: " <> err)
              let mSender = extractSenderId cqo
                  mMsgId = case KeyMap.lookup (Key.fromString "message_id") mo of
                    Just (A.Number n) -> Just (T.pack (show (round n :: Int)))
                    _ -> Nothing
              Right ReceivedMessage
                { rmConversationId = cid
                , rmSender = mSender
                , rmReplyTo = chatId
                , rmBody = callbackData
                , rmCallbackData = Just callbackData
                , rmCallbackId = Just callbackId
                , rmCallbackMessageId = mMsgId
                }
            _ -> Left "callback_query.message not an object"
        _ -> Left "callback_query not an object"

-- | Extract @chat.id@ from a message object.
requireChatId :: A.Object -> Either Text Text
requireChatId mo =
  case KeyMap.lookup (Key.fromString "chat") mo of
    Just (A.Object co) -> case KeyMap.lookup (Key.fromString "id") co of
      Just (A.Number n) -> Right (T.pack (show (round n :: Int)))
      _ -> Left "chat.id missing"
    _ -> Left "chat field missing"

-- | Extract @from.id@ from a message object as text.
extractSenderId :: A.Object -> Maybe Text
extractSenderId mo =
  case KeyMap.lookup (Key.fromString "from") mo of
    Just (A.Object fo) -> case KeyMap.lookup (Key.fromString "id") fo of
      Just (A.Number n) -> Just (T.pack (show (round n :: Int)))
      _ -> Nothing
    _ -> Nothing

-- | Extract @text@ from a message object.
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
    Left _ -> pure ()
    Right req0 -> do
      let payload = A.object [ "chat_id" .= chatId, "text" .= body ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()

-- | Send a message and return the @message_id@.
tgSendWithIdViaApi :: Manager -> Text -> Text -> Text -> IO (Maybe Text)
tgSendWithIdViaApi mgr token chatId body = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/sendMessage")))
  case eReq of
    Left _ -> pure Nothing
    Right req0 -> do
      let payload = A.object [ "chat_id" .= chatId, "text" .= body ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left _ -> pure Nothing
        Right resp ->
          if statusCode (responseStatus resp) == 200
            then pure (parseMessageId (responseBody resp))
            else pure Nothing

-- | Edit a previously sent message via @editMessageText@.
tgEditMessageViaApi :: Manager -> Text -> Text -> Text -> Text -> IO Bool
tgEditMessageViaApi mgr token chatId messageId content = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/editMessageText")))
  case eReq of
    Left _ -> pure False
    Right req0 -> do
      let payload = A.object
            [ "chat_id" .= chatId
            , "message_id" .= messageId
            , "text" .= content
            ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left _ -> pure False
        Right resp ->
          if statusCode (responseStatus resp) == 200
            then pure (parseOk (responseBody resp))
            else
              let errText = TE.decodeUtf8 (BL.toStrict (responseBody resp))
              in if "not modified" `T.isInfixOf` errText
                   then pure True
                   else pure False

-- | Parse the @result.message_id@ from a @sendMessage@ response.
parseMessageId :: BL.ByteString -> Maybe Text
parseMessageId bs =
  case A.decode bs of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromString "result") o of
      Just (A.Object ro) -> case KeyMap.lookup (Key.fromString "message_id") ro of
        Just (A.Number n) -> Just (T.pack (show (round n :: Int)))
        _ -> Nothing
      _ -> Nothing
    _ -> Nothing

-- | Parse the @ok@ boolean from a Bot API JSON response.
parseOk :: BL.ByteString -> Bool
parseOk bs =
  case A.decode bs of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromString "ok") o of
      Just (A.Bool b) -> b
      _ -> False
    _ -> False

-- ---------------------------------------------------------------------------
-- Inline keyboard + callback API functions
-- ---------------------------------------------------------------------------

-- | Send a message with an inline keyboard via @sendMessage@. The payload
-- includes @reply_markup: {inline_keyboard: ...}@. MUST NOT set
-- @parse_mode@ (plain text — no markdown/HTML interpretation). Returns the
-- @message_id@ so the caller can remove the keyboard later.
tgSendWithKeyboardViaApi :: Manager -> Text -> Text -> Text -> [[TelegramButton]] -> IO (Maybe Text)
tgSendWithKeyboardViaApi mgr token chatId body keyboard = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/sendMessage")))
  case eReq of
    Left _ -> pure Nothing
    Right req0 -> do
      let payload = A.object
            [ "chat_id" .= chatId
            , "text" .= body
            , "reply_markup" A..= A.object
                [ "inline_keyboard" A..= map (map A.toJSON) keyboard
                ]
            ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left _ -> pure Nothing
        Right resp ->
          if statusCode (responseStatus resp) == 200
            then pure (parseMessageId (responseBody resp))
            else pure Nothing

-- | Acknowledge a @callback_query@ via @answerCallbackQuery@. Stops the
-- button's loading spinner. Best-effort: never throws.
answerCallbackQueryViaApi :: Manager -> Text -> Text -> IO ()
answerCallbackQueryViaApi mgr token callbackQueryId = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/answerCallbackQuery")))
  case eReq of
    Left _ -> pure ()
    Right req0 -> do
      let payload = A.object [ "callback_query_id" .= callbackQueryId ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()

-- | Remove the inline keyboard from a message via
-- @editMessageReplyMarkup@ with an empty @reply_markup@. Disables buttons
-- after a tap. Best-effort: never throws.
editReplyMarkupViaApi :: Manager -> Text -> Text -> Text -> IO ()
editReplyMarkupViaApi mgr token chatId messageId = do
  eReq <- try @SomeException
    (parseRequest (T.unpack (telegramApiBase <> token <> "/editMessageReplyMarkup")))
  case eReq of
    Left _ -> pure ()
    Right req0 -> do
      let payload = A.object
            [ "chat_id" .= chatId
            , "message_id" .= messageId
            , "reply_markup" A..= A.object [ "inline_keyboard" A..= ([] :: [[A.Value]]) ]
            ]
          req = req0 { method = methodPost
                     , requestBody = RequestBodyLBS (A.encode payload)
                     , requestHeaders = [("Content-Type", "application/json")]
                     }
      _ <- try @SomeException (httpLbs req mgr)
      pure ()
