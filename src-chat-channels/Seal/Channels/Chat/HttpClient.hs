{-# LANGUAGE OverloadedStrings #-}
-- | HTTP client for the gateway API. All calls go through @http-client@
-- and return @Either Text a@ — errors are text, never thrown. The chat
-- channel loop uses these to send messages, list tabs, create sessions,
-- answer questions, and fetch transcripts.
module Seal.Channels.Chat.HttpClient
  ( -- * Send a message
    httpSend
  , SendResult (..)
  , parseSendResult
    -- * Tabs
  , httpGetTabs
  , TabJson (..)
    -- * Sessions
  , httpNewSession
  , httpGetTranscript
  , httpStopSession
    -- * Questions (ASK_HUMAN)
  , httpAnswerQuestion
  , httpCancelQuestion
    -- * Helpers
  , parseJsonBody
  ) where

import Control.Exception (try)
import System.IO (hPutStrLn, stderr)
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  (Manager, Request (..), Response, HttpException, httpLbs,
   parseRequest, RequestBody (..), responseBody, responseStatus)
import Network.HTTP.Types (Method, statusCode, methodPost, methodGet)
import Seal.Gateway.Types.Core (SessionId, sessionIdText)

-- | The result of a @POST /api/sessions/:id/send@ call.
data SendResult = SendResult
  { srKind      :: Text       -- ^ @"assistant"@, @"slash"@, or @"error"@
  , srResponse  :: Text       -- ^ the response text (slash output or empty)
  , srSessionId :: Maybe Text -- ^ new session id (from @\/new@)
  , srError     :: Maybe Text -- ^ error message (when kind is @"error"@)
  } deriving stock (Eq, Show)

-- | Parse the JSON response from @POST /api/sessions/:id/send@.
parseSendResult :: BL.ByteString -> Either Text SendResult
parseSendResult body =
  case A.decode body :: Maybe Value of
    Nothing -> Left "failed to parse send response JSON"
    Just (A.Object o) ->
      Right SendResult
        { srKind = fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "kind") o)
        , srResponse = fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "response") o)
        , srSessionId = asText =<< KeyMap.lookup (Key.fromText "session_id") o
        , srError = asText =<< KeyMap.lookup (Key.fromText "error") o
        }
    Just _ -> Left "send response is not a JSON object"

-- | A tab from @GET /api/tabs@.
data TabJson = TabJson
  { tjIndex     :: Int          -- ^ positional index (0-based)
  , tjSessionId :: Maybe Text   -- ^ session id (Nothing for harness tabs)
  , tjKind      :: Text         -- ^ tab kind wire string
  , tjLabel     :: Maybe Text   -- ^ optional user-set label
  } deriving stock (Eq, Show)

-- | @POST /api/sessions/:id/send@ — send a message to a session.
httpSend :: Manager -> Text -> SessionId -> Text -> IO (Either Text SendResult)
httpSend mgr apiBase sid message = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid) <> "/send"
  doRequest mgr url methodPost (Just (A.object ["message" .= message])) >>= \case
    Left e -> pure (Left e)
    Right body -> pure (parseSendResult body)

-- | @GET /api/tabs@ — list all tabs.
httpGetTabs :: Manager -> Text -> IO (Either Text [TabJson])
httpGetTabs mgr apiBase = do
  let url = T.unpack apiBase <> "/tabs"
  doRequest mgr url methodGet Nothing >>= \case
    Left e -> pure (Left e)
    Right body -> pure (parseTabsBody body)

-- | @POST /api/sessions/new@ — create a new session.
httpNewSession :: Manager -> Text -> Value -> IO (Either Text Text)
httpNewSession mgr apiBase body = do
  let url = T.unpack apiBase <> "/sessions/new"
  doRequest mgr url methodPost (Just body) >>= \case
    Left e -> pure (Left e)
    Right respBody -> pure (extractSessionId respBody)

-- | @GET /api/sessions/:id/transcript@ — get the transcript as a JSON array.
httpGetTranscript :: Manager -> Text -> SessionId -> IO (Either Text [Value])
httpGetTranscript mgr apiBase sid = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid) <> "/transcript"
  doRequest mgr url methodGet Nothing >>= \case
    Left e -> pure (Left e)
    Right body ->
      case A.decode body :: Maybe [Value] of
        Just vs -> pure (Right vs)
        Nothing -> pure (Left "failed to parse transcript JSON array")

-- | @POST /api/sessions/:id/stop@ — abort the session's in-flight turn.
httpStopSession :: Manager -> Text -> SessionId -> IO (Either Text ())
httpStopSession mgr apiBase sid = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid) <> "/stop"
  doRequest mgr url methodPost Nothing >>= \case
    Left e -> pure (Left e)
    Right _ -> pure (Right ())

-- | @POST /api/sessions/:id/questions/:qid/answer@ — answer a pending
-- ASK_HUMAN question.
httpAnswerQuestion :: Manager -> Text -> SessionId -> Text -> Text -> Text -> IO (Either Text ())
httpAnswerQuestion mgr apiBase sid qid answer scope = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid)
            <> "/questions/" <> T.unpack qid <> "/answer"
  doRequest mgr url methodPost (Just (A.object ["answer" .= answer, "scope" .= scope])) >>= \case
    Left e -> pure (Left e)
    Right _ -> pure (Right ())

-- | @POST /api/sessions/:id/questions/:qid/cancel@ — cancel a pending
-- ASK_HUMAN question.
httpCancelQuestion :: Manager -> Text -> SessionId -> Text -> IO (Either Text ())
httpCancelQuestion mgr apiBase sid qid = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid)
            <> "/questions/" <> T.unpack qid <> "/cancel"
  doRequest mgr url methodPost Nothing >>= \case
    Left e -> pure (Left e)
    Right _ -> pure (Right ())

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Parse a JSON body into a 'Value'. Returns 'Left' on parse failure.
parseJsonBody :: BL.ByteString -> Either Text Value
parseJsonBody body =
  case A.decode body :: Maybe Value of
    Just v  -> Right v
    Nothing -> Left "failed to parse JSON"

-- | Perform an HTTP request with a method, optional JSON body, and return
-- the response body on success (2xx). Returns 'Left' on network or HTTP
-- errors.
doRequest :: Manager -> String -> Method -> Maybe Value -> IO (Either Text BL.ByteString)
doRequest mgr url m mBody = do
  eReq <- try (parseRequest url) :: IO (Either HttpException Request)
  case eReq of
    Left _ -> pure (Left ("invalid URL: " <> T.pack url))
    Right req0 -> do
      let req1 = req0 { method = m }
          req2 = case mBody of
            Just bodyVal ->
              req1 { requestBody = RequestBodyLBS (A.encode bodyVal)
                   , requestHeaders = [("content-type", "application/json")]
                   }
            Nothing -> req1
      eResp <- try (httpLbs req2 mgr) :: IO (Either HttpException (Response BL.ByteString))
      case eResp of
        Left _ -> pure (Left "HTTP request failed")
        Right resp -> do
          let code = statusCode (responseStatus resp)
          if code >= 200 && code <= 299
            then pure (Right (responseBody resp))
            else do
              hPutStrLn stderr ("[chat-channel] HTTP " <> show code <> " from " <> url <> ": " <> show (responseBody resp))
              pure (Left ("HTTP " <> T.pack (show code)))

-- | Extract the @id@ field from a session info JSON object.
extractSessionId :: BL.ByteString -> Either Text Text
extractSessionId body =
  case A.decode body :: Maybe Value of
    Just (A.Object o) ->
      case asText =<< KeyMap.lookup (Key.fromText "session_id") o of
        Just sid -> Right sid
        Nothing  -> Left "session response missing 'session_id' field"
    Just _ -> Left "session response is not a JSON object"
    Nothing -> Left "failed to parse session response JSON"

-- | Parse the @GET /api/tabs@ response body.
parseTabsBody :: BL.ByteString -> Either Text [TabJson]
parseTabsBody body =
  case A.decode body :: Maybe [Value] of
    Nothing -> Left "failed to parse tabs JSON array"
    Just vs -> traverse parseTabJson vs

-- | Parse one tab JSON object.
parseTabJson :: Value -> Either Text TabJson
parseTabJson (A.Object o) =
  Right TabJson
    { tjIndex = case KeyMap.lookup (Key.fromText "index") o of
        Just (A.Number n) -> round n
        _ -> 0
    , tjSessionId = asText =<< KeyMap.lookup (Key.fromText "session_id") o
    , tjKind = fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "kind") o)
    , tjLabel = asText =<< KeyMap.lookup (Key.fromText "label") o
    }
parseTabJson _ = Left "tab is not a JSON object"

-- | Extract text from a JSON string value.
asText :: Value -> Maybe Text
asText (A.String t) = Just t
asText _ = Nothing
