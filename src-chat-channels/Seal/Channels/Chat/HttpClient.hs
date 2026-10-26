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
  , ListsJson (..)
    -- * Sessions list
  , httpGetSessions
    -- * Sessions
  , httpNewSession
  , httpRebindNew
  , NewSessionResult (..)
  , parseNewSessionResult
  , rebindBody
  , mintBody
  , httpSetupRepo
  , setupRepoBody
  , httpGetRepos
  , httpGetTranscript
  , httpStopSession
  , httpGetLists
    -- * Questions (ASK_HUMAN)
  , httpAnswerQuestion
  , answerBodyJson
  , httpCancelQuestion
    -- * Helpers
  , parseJsonBody
  , parseErrorBody
  ) where

import Control.Exception (try)
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
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
  , tjStatus    :: Maybe Text   -- ^ harness liveness: @"running"@ | @"idle"@ | @"exited"@
  } deriving stock (Eq, Show)

-- | The @GET /api/lists@ snapshot, restricted to what @/tab list@ needs: the
-- tabs, the session info of every tab-bound session (for @\<repo\>@ and
-- @\<name\>@), and the set of sessions currently thinking (for @busy@).
data ListsJson = ListsJson
  { ljTabs               :: [TabJson]
  , ljTabSessions        :: [Value]
  , ljThinkingSessionIds :: [Text]
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

-- | @GET /api/sessions@ — list all sessions (the recent, non-archived
-- sessions). Returns the raw JSON array (each element is a session info
-- object with @id@, @description@, @autoSummary@, @firstMessageSnippet@,
-- @agent@, etc.).
httpGetSessions :: Manager -> Text -> IO (Either Text [Value])
httpGetSessions mgr apiBase = do
  let url = T.unpack apiBase <> "/sessions"
  doRequest mgr url methodGet Nothing >>= \case
    Left e -> pure (Left e)
    Right body ->
      case A.decode body :: Maybe [Value] of
        Just vs -> pure (Right vs)
        Nothing -> pure (Left "failed to parse sessions JSON array")

-- | @GET /api/lists@ — the partitioned snapshot. Carries what @GET /api/tabs@
-- cannot: @thinkingSessionIds@ (the only source of the @busy@ state) and
-- @tabSessions@ (the session metadata behind each tab).
httpGetLists :: Manager -> Text -> IO (Either Text ListsJson)
httpGetLists mgr apiBase = do
  let url = T.unpack apiBase <> "/lists"
  doRequest mgr url methodGet Nothing >>= \case
    Left e -> pure (Left e)
    Right body -> pure (parseListsBody body)

-- | @POST /api/sessions/new@ — create a new session.
httpNewSession :: Manager -> Text -> Value -> IO (Either Text Text)
httpNewSession mgr apiBase body = do
  let url = T.unpack apiBase <> "/sessions/new"
  doRequest mgr url methodPost (Just body) >>= \case
    Left e -> pure (Left e)
    Right respBody -> pure (extractSessionId respBody)

-- | The parsed body of @POST \/api\/sessions\/:id\/new@: the minted session
-- plus the rebind outcome. 'nsrRebindError' carries the gateway's raw
-- @rebind_error@ (the tab could not be rebound — the new session exists
-- regardless); 'nsrTabIndex' is 'Nothing' when no tab was bound to the old
-- session.
data NewSessionResult = NewSessionResult
  { nsrSessionId   :: Text
  , nsrTabIndex    :: Maybe Int
  , nsrRebound     :: Bool
  , nsrRebindError :: Maybe Text
  , nsrProvider    :: Text
  , nsrModel       :: Text
  } deriving stock (Eq, Show)

-- | @POST /api/sessions/:id/new@ — mint a fresh session and rebind the tab
-- bound to @sid@ (if any) in one call. One mint, one rebind: the caller must
-- NOT also call 'httpNewSession' for the same @/new@.
httpRebindNew :: Manager -> Text -> SessionId -> Value -> IO (Either Text NewSessionResult)
httpRebindNew mgr apiBase sid body = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid) <> "/new"
  doRequest mgr url methodPost (Just body) >>= \case
    Left e -> pure (Left e)
    Right respBody -> pure (parseNewSessionResult respBody)

-- | The request body for @POST \/api\/sessions\/:id\/new@. Absent overrides
-- are omitted entirely — never sent as JSON @null@.
rebindBody :: Maybe Text -> Maybe Text -> Maybe Text -> Value
rebindBody mProvider mModel mChannel = A.object (catMaybes
  [ ("provider" .=) <$> mProvider
  , ("model" .=) <$> mModel
  , ("channel" .=) <$> mChannel
  ])

-- | The request body for @POST \/api\/sessions\/new@ on the @\/new@ path
-- (no prior session): provider\/model overrides only. The gateway labels
-- such a session @"web"@.
mintBody :: Maybe Text -> Maybe Text -> Value
mintBody mProvider mModel = A.object (catMaybes
  [ ("provider" .=) <$> mProvider
  , ("model" .=) <$> mModel
  ])

-- | The request body of @POST \/api\/sessions\/:id\/setup-repo@.
setupRepoBody :: Text -> Value
setupRepoBody url = A.object ["url" .= url]

-- | @POST /api/sessions/:id/setup-repo@ — clone a repo into the session's
-- workdir before the first turn. Errors carry the gateway's @error@ text
-- when it sent one (e.g. @clone failed: …@), so @repo setup failed: …@ names
-- the real reason.
httpSetupRepo :: Manager -> Text -> SessionId -> Value -> IO (Either Text ())
httpSetupRepo mgr apiBase sid body = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid) <> "/setup-repo"
  doRequest mgr url methodPost (Just body) >>= \case
    Left e  -> pure (Left e)
    Right _ -> pure (Right ())

-- | @GET /api/repos@ — the registered repos. Each element carries @id@ and
-- @url@ (plus credential metadata this client ignores).
httpGetRepos :: Manager -> Text -> IO (Either Text [Value])
httpGetRepos mgr apiBase = do
  let url = T.unpack apiBase <> "/repos"
  doRequest mgr url methodGet Nothing >>= \case
    Left e -> pure (Left e)
    Right body -> case A.decode body :: Maybe [Value] of
      Just vs -> pure (Right vs)
      Nothing -> pure (Left "failed to parse repos JSON array")

-- | Parse the @POST \/api\/sessions\/:id\/new@ response body.
parseNewSessionResult :: BL.ByteString -> Either Text NewSessionResult
parseNewSessionResult body =
  case A.decode body :: Maybe Value of
    Just (A.Object o) ->
      case asText =<< KeyMap.lookup (Key.fromText "session_id") o of
        Nothing -> Left "new-session response missing 'session_id' field"
        Just sid
          | T.null sid -> Left "new-session response has an empty 'session_id'"
          | otherwise  -> Right NewSessionResult
              { nsrSessionId   = sid
              , nsrTabIndex    = asInt =<< KeyMap.lookup (Key.fromText "tab_index") o
              , nsrRebound     = fromMaybe False
                                   (asBool =<< KeyMap.lookup (Key.fromText "rebound") o)
              , nsrRebindError = asText =<< KeyMap.lookup (Key.fromText "rebind_error") o
              , nsrProvider    = fromMaybe ""
                                   (asText =<< KeyMap.lookup (Key.fromText "provider") o)
              , nsrModel       = fromMaybe ""
                                   (asText =<< KeyMap.lookup (Key.fromText "model") o)
              }
    Just _  -> Left "new-session response is not a JSON object"
    Nothing -> Left "failed to parse new-session response JSON"
  where
    asInt (A.Number n) = Just (round n)
    asInt _            = Nothing
    asBool (A.Bool b)  = Just b
    asBool _           = Nothing

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
-- ASK_HUMAN question (or the confirmation gate) with free text.
--
-- The body carries an @answer@ and nothing else: the server's parser rejects
-- a body that carries both @answer@ and @scope@ with 400 ("ambiguous: send
-- either {scope} or {answer}, not both", 'parseAnswerBody'). The
-- confirmation gate parses the text itself — @y@/@yes@ approve once,
-- anything else rejects — so one shape serves both ask kinds.
--
-- The endpoint answers @200 {ok:true, accepted:<bool>}@; @accepted:false@
-- means the question was already answered, cancelled, or unknown, which is
-- a resolution but not an accepted answer.
httpAnswerQuestion :: Manager -> Text -> SessionId -> Text -> Text -> IO (Either Text Bool)
httpAnswerQuestion mgr apiBase sid qid answer = do
  let url = T.unpack apiBase <> "/sessions/" <> T.unpack (sessionIdText sid)
            <> "/questions/" <> T.unpack qid <> "/answer"
  doRequest mgr url methodPost (Just (answerBodyJson answer)) >>= \case
    Left e -> pure (Left e)
    Right body -> pure (Right (acceptedFrom body))

-- | Read the @accepted@ flag from an answer response. Absent/malformed
-- (e.g. a server that predates the flag) counts as accepted.
acceptedFrom :: BL.ByteString -> Bool
acceptedFrom body =
  case A.decode body :: Maybe Value of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromText "accepted") o of
      Just (A.Bool b) -> b
      _               -> True
    _ -> True

-- | The request body for answering a pending question: the answer only.
-- Pure and exported so the wire shape is pinned by a test.
answerBodyJson :: Text -> Value
answerBodyJson answer = A.object ["answer" .= answer]

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
        Right resp ->
          let code = statusCode (responseStatus resp)
          in if code >= 200 && code <= 299
               then pure (Right (responseBody resp))
               else pure (Left (parseErrorBody code (responseBody resp)))

-- | The text of a failed HTTP response. Prefers the gateway's
-- @{\"error\": \"…\"}@ shape ('errJson' in 'Seal.Gateway.API') so callers can
-- surface the real reason (e.g. @clone failed: …@); falls back to
-- @HTTP \<code\>@ for a non-JSON or shapeless body (a proxy, a plain-text
-- 5xx).
parseErrorBody :: Int -> BL.ByteString -> Text
parseErrorBody code body =
  case A.decode body :: Maybe Value of
    Just (A.Object o) -> case asText =<< KeyMap.lookup (Key.fromText "error") o of
      Just msg | not (T.null msg) -> msg
      _                           -> fallback
    _ -> fallback
  where
    fallback = "HTTP " <> T.pack (show code)

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

-- | Parse the @GET /api/lists@ response body.
parseListsBody :: BL.ByteString -> Either Text ListsJson
parseListsBody body =
  case A.decode body :: Maybe Value of
    Just (A.Object o) -> do
      tabs <- case KeyMap.lookup (Key.fromText "tabs") o of
        Just (A.Array arr) -> traverse parseTabJson (foldr (:) [] arr)
        _                  -> Left "lists response missing 'tabs' array"
      let arrOf k = case KeyMap.lookup (Key.fromText k) o of
            Just (A.Array arr) -> foldr (:) [] arr
            _                  -> []
      pure ListsJson
        { ljTabs               = tabs
        , ljTabSessions        = arrOf "tabSessions"
        , ljThinkingSessionIds = mapMaybe asText (arrOf "thinkingSessionIds")
        }
    _ -> Left "failed to parse lists response JSON object"

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
    , tjStatus = asText =<< KeyMap.lookup (Key.fromText "status") o
    }
parseTabJson _ = Left "tab is not a JSON object"

-- | Extract text from a JSON string value.
asText :: Value -> Maybe Text
asText (A.String t) = Just t
asText _ = Nothing
