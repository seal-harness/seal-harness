{-# LANGUAGE OverloadedStrings #-}
-- | The Sessions opcode group. The consolidated entry point is
-- 'sessionManageOp' (\"SESSION_MANAGE\"), which dispatches on an @action@
-- field to one of four handlers: @new@, @list@, @search@, @get@.
--
-- The legacy opcodes ('sessionNewOp', 'sessionListOp', 'sessionSearchOp',
-- 'sessionGetOp') remain as thin shims that delegate to the same handlers.
--
-- All session opcodes are 'Trusted' — harness-internal operations that
-- manage the on-disk session store. 'orRecorded' carries secret-free
-- metadata only (session ids, provider/model labels, entry counts);
-- transcript content returned by the @get@ action goes in 'orParts'
-- (agent-visible) but never in 'orRecorded'.
module Seal.ISA.Ops.Session
  ( -- * Consolidated opcode
    sessionManageOp
    -- * Legacy shims
  , sessionNewOp
  , sessionListOp
  , sessionSearchOp
  , sessionGetOp
  ) where

import Control.Monad (join)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value (..), object, withObject, (.:), (.:?), (.=) )
import Data.Aeson qualified as A
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (formatTime, defaultTimeLocale)
import Seal.Types.App (App)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Seal.Config.Paths
  ( SealPaths, sessionConversationPath, sessionDir, sessionMetaPath
  , resolveChildSessionPath )
import Seal.Core.Paging
  ( Page (..), PageParams (..), paginate, paginateDesc )
import Seal.Core.Types
  ( OpName (..), SessionId, TrustLevel (..), mkSessionId, sessionIdText )
import Seal.ISA.Opcode
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), ToolResultPart (..) )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Search (SessionSearchBackend (..))
import Seal.Session.Store
  ( listChildSessions, listSessions, listArchivedSessions, newSession
  , saveSessionMeta )
import Seal.Util.StrictIO (readFileTextStrict, decodeFileStrict)

-- ---------------------------------------------------------------------------
-- Action enum
-- ---------------------------------------------------------------------------

data SessionAction
  = SessNew
  | SessList
  | SessSearch
  | SessGet

parseSessionAction :: Value -> Either Text SessionAction
parseSessionAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "new"    -> Right SessNew
      "list"   -> Right SessList
      "search" -> Right SessSearch
      "get"    -> Right SessGet
      other    -> Left ("unknown session action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- ---------------------------------------------------------------------------
-- Read order (front-to-back vs back-to-front)
-- ---------------------------------------------------------------------------

-- | Controls whether transcript pagination starts from the beginning
-- (front-to-back) or the end (back-to-front) of the session.
data ReadOrder = OrderAsc | OrderDesc
  deriving stock (Eq, Show)

-- | Parse the @order@ field from the input JSON. Absent → 'OrderDesc'
-- (back-to-front is the default, since the end of the session is usually
-- what the caller wants). Unrecognized values also default to 'OrderDesc'.
parseReadOrder :: Value -> ReadOrder
parseReadOrder v =
  case textField v "order" of
    Just "front-to-back" -> OrderAsc
    Just "back-to-front" -> OrderDesc
    _                    -> OrderDesc

-- | Dispatch to 'paginate' (front-to-back) or 'paginateDesc' (back-to-front).
paginateBy :: ReadOrder -> PageParams -> Int -> Maybe Int -> [a] -> Page a
paginateBy OrderAsc = paginate
paginateBy OrderDesc = paginateDesc

-- | Render the order as a JSON string value for the @orRecorded@ metadata.
renderOrderJson :: ReadOrder -> Text
renderOrderJson OrderAsc = "front-to-back"
renderOrderJson OrderDesc = "back-to-front"

-- ---------------------------------------------------------------------------
-- Page parameters
-- ---------------------------------------------------------------------------

-- | Page parameters for the @get@ action transcript pagination. A flat
-- 50-message default with a 200-message hard ceiling.
sessionPageParams :: PageParams
sessionPageParams = PageParams { ppFloor = 50, ppCeiling = 200, ppCoeff = 0.0 }

-- ---------------------------------------------------------------------------
-- Handlers (shared between SESSION_MANAGE and legacy shims)
-- ---------------------------------------------------------------------------

handleNew :: SealPaths -> Value -> App OpResult
handleNew paths v = do
  let provider = fromMaybe "anthropic" (textField v "provider")
      model = fromMaybe "claude-sonnet-4-20250514" (textField v "model")
      channel = fromMaybe "api" (textField v "channel")
      mDesc = textField v "description"
  meta <- liftIO (newSession paths provider model channel Nothing)
  let meta' = case mDesc of
        Just d | not (T.null (T.strip d)) -> meta { smDescription = Just d }
        _ -> meta
  case mDesc of
    Just d | not (T.null (T.strip d)) -> liftIO (saveSessionMeta paths meta')
    _ -> pure ()
  let rendered = renderSessionMeta meta'
      recorded = object
        [ "session_id" .= sessionIdText (smId meta')
        , "provider" .= smProvider meta'
        , "model" .= smModel meta'
        , "channel" .= smChannel meta'
        , "description" .= smDescription meta'
        ]
  pure (OpResult [TrpText rendered] False recorded)

handleList :: SealPaths -> Value -> App OpResult
handleList paths v = do
  let archived = fromMaybe False (boolField v "archived")
      includeChildren = fromMaybe False (boolField v "include_children")
  metas <- liftIO (if archived then listArchivedSessions paths else listSessions paths)
  children <- if includeChildren
                then liftIO (listChildSessions paths)
                else pure []
  let parentLines = map renderSessionMeta metas
      childLines = [ renderChildSummary parentSid childSid
                   | (parentSid, childSid) <- children ]
      allLines = parentLines <> childLines
      rendered = case allLines of
        [] -> "(no sessions found)"
        _ -> T.intercalate "\n" allLines
      recorded = object
        [ "count" .= length metas
        , "archived" .= archived
        , "include_children" .= includeChildren
        , "child_count" .= length children
        , "session_ids" .= fmap (sessionIdText . smId) metas
        ]
  pure (OpResult [TrpText rendered] False recorded)

handleSearch :: SessionSearchBackend -> SealPaths -> Value -> App OpResult
handleSearch searchBackend paths v = do
  let q = fromMaybe "" (textField v "query")
  if T.null (T.strip q)
    then pure (OpResult [TrpText "search: query is empty"] True (object []))
    else do
      let archived = fromMaybe False (boolField v "archived")
          qLower = T.toCaseFold (T.strip q)
      matched <- liftIO (ssbSearch searchBackend paths q archived)
      children <- liftIO (listChildSessions paths)
      childResults <- liftIO (mapM (searchChildSession paths qLower) children)
      let childMatched = [ (p, c, snip) | (p, c, Just snip) <- childResults ]
          rendered
            | null matched && null childMatched = "(no sessions found)"
            | otherwise = T.intercalate "\n\n" $
                 [ renderSessionMeta m <> "\n  snippet: " <> snip
                 | (m, snip) <- matched ]
              <> [ renderChildSummary p c <> "\n  snippet: " <> snip
                 | (p, c, snip) <- childMatched ]
          recorded = object
            [ "query" .= q
            , "archived" .= archived
            , "match_count" .= (length matched + length childMatched)
            , "session_ids" .= fmap (sessionIdText . smId . fst) matched
            ]
      pure (OpResult [TrpText rendered] False recorded)

handleGet :: SealPaths -> Value -> App OpResult
handleGet paths v = do
  let mSidText = textField v "session_id"
      offset = fromMaybe 0 (intField v "offset")
      mLimit = intField v "limit"
      order = parseReadOrder v
  case mSidText >>= either (const Nothing) Just . mkSessionId . T.strip of
    Nothing -> pure (OpResult [TrpText "invalid session id"] True (object []))
    Just sid -> do
      metaExists <- liftIO (doesFileExist (sessionMetaPath paths sid))
      mMeta <- if not metaExists
                 then pure Nothing
                 else liftIO (decodeFileStrict (sessionMetaPath paths sid))
      case mMeta of
        Just meta -> do
          msgs <- liftIO (readSessionMessages paths sid)
          let total = length msgs
              page = paginateBy order sessionPageParams offset mLimit msgs
              windowMsgs = pgItems page
              header = renderSessionMeta meta
              body = T.intercalate "\n\n"
                (zipWith (renderMessage (pgOffset page)) [0..] windowMsgs)
              footer = renderPageFooter order (pgOffset page) offset (length windowMsgs) total (pgHasMore page)
              rendered = T.intercalate "\n\n" (filter (not . T.null) [header, body, footer])
              recorded = object
                [ "session_id" .= sessionIdText sid
                , "provider" .= smProvider meta
                , "model" .= smModel meta
                , "order" .= renderOrderJson order
                , "offset" .= pgOffset page
                , "limit" .= length windowMsgs
                , "total_messages" .= total
                , "has_more" .= pgHasMore page
                ]
          pure (OpResult [TrpText rendered] False recorded)
        Nothing -> do
          mChild <- liftIO (resolveChildSessionPath paths sid)
          case mChild of
            Nothing -> pure (OpResult
              [TrpText ("session not found: " <> sessionIdText sid)] True
              (object ["session_id" .= sessionIdText sid]))
            Just (parentSid, childDir) -> do
              msgs <- liftIO (readMessagesFromDir childDir)
              let total = length msgs
                  page = paginateBy order sessionPageParams offset mLimit msgs
                  windowMsgs = pgItems page
                  header = "[child session of " <> sessionIdText parentSid <> "] " <> sessionIdText sid
                  body = T.intercalate "\n\n"
                    (zipWith (renderMessage (pgOffset page)) [0..] windowMsgs)
                  footer = renderPageFooter order (pgOffset page) offset (length windowMsgs) total (pgHasMore page)
                  rendered = T.intercalate "\n\n" (filter (not . T.null) [header, body, footer])
                  recorded = object
                    [ "session_id" .= sessionIdText sid
                    , "child_of" .= sessionIdText parentSid
                    , "order" .= renderOrderJson order
                    , "offset" .= pgOffset page
                    , "limit" .= length windowMsgs
                    , "total_messages" .= total
                    , "has_more" .= pgHasMore page
                    ]
              pure (OpResult [TrpText rendered] False recorded)

-- ---------------------------------------------------------------------------
-- Authorize gate helpers
-- ---------------------------------------------------------------------------

authorizeSearch :: Value -> Either Text ()
authorizeSearch v =
  case textField v "query" of
    Nothing -> Left "search requires {query:string}"
    Just q
      | T.null (T.strip q) -> Left "search: query is empty"
      | otherwise -> Right ()

authorizeGet :: Value -> Either Text ()
authorizeGet v =
  case textField v "session_id" of
    Nothing -> Left "get requires {session_id:string}"
    Just sid
      | T.null (T.strip sid) -> Left "get: session_id is empty"
      | otherwise -> Right ()

-- | Authorize gate for SESSION_MANAGE — dispatches per-action validation.
authorizeManage :: Value -> Either Text ()
authorizeManage v =
  case parseSessionAction v of
    Left e -> Left e
    Right action -> case action of
      SessNew    -> Right ()
      SessList   -> Right ()
      SessSearch -> authorizeSearch v
      SessGet    -> authorizeGet v

-- ---------------------------------------------------------------------------
-- Consolidated opcode: SESSION_MANAGE
-- ---------------------------------------------------------------------------

-- | SESSION_MANAGE: action-based entry point for all session operations.
sessionManageOp :: SealPaths -> SessionSearchBackend -> Opcode
sessionManageOp paths searchBackend = TrustedOpcode
  { toName = OpName "SESSION_MANAGE"
  , toTrust = Trusted
  , toDesc = "Manage sessions. Use action to select: new (create session), list (enumerate), search (by text), get (read transcript with pagination). For get, order defaults to back-to-front (most recent messages first)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["new", "list", "search", "get"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "provider" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Provider label (new). Default: \"anthropic\"." :: Text)
              ]
          , fromText "model" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Model id (new)." :: Text)
              ]
          , fromText "channel" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Channel label (new). Default: \"api\"." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Session title (new)." :: Text)
              ]
          , fromText "archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("List/search archived sessions (list/search). Default: false." :: Text)
              ]
          , fromText "include_children" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("Also enumerate child (sub-agent) transcripts nested under sessions/*/agents/ (list). Default: false." :: Text)
              ]
          , fromText "query" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Search query (search)." :: Text)
              ]
          , fromText "session_id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Session id to read (get)." :: Text)
              ]
          , fromText "offset" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Message offset, 0-based (get). In front-to-back mode, counts from start; in back-to-front mode, counts from end. Default: 0." :: Text)
              ]
          , fromText "limit" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Max messages to return (get). Default: 50, max: 200." :: Text)
              ]
          , fromText "order" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["front-to-back", "back-to-front"] :: [Text])
              , "description" .= ("Read direction (get). front-to-back: offset from start. back-to-front: offset from end. Default: back-to-front." :: Text)
              ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeManage
  , toBlocking = False
  , toRun = \_ v ->
      case parseSessionAction v of
        Left e -> pure (OpResult [TrpText e] True (object []))
        Right action -> case action of
          SessNew    -> handleNew paths v
          SessList   -> handleList paths v
          SessSearch -> handleSearch searchBackend paths v
          SessGet    -> handleGet paths v
  }

-- ---------------------------------------------------------------------------
-- Legacy shims (backward compatibility)
-- ---------------------------------------------------------------------------

-- | SESSION_NEW (legacy shim): delegates to the new handler.
sessionNewOp :: SealPaths -> Opcode
sessionNewOp paths = TrustedOpcode
  { toName = OpName "SESSION_NEW"
  , toTrust = Trusted
  , toDesc = "Create a new session with its own transcript and working directory. Returns the session id and metadata. (Legacy — prefer SESSION_MANAGE with action=\"new\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "provider" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Provider label (e.g. \"anthropic\", \"ollama\"). Defaults to \"anthropic\"." :: Text)
              ]
          , fromText "model" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Model id (e.g. \"claude-sonnet-4-20250514\"). Defaults to the provider's default model." :: Text)
              ]
          , fromText "channel" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Channel label for the session (e.g. \"cli\", \"web\"). Defaults to \"api\"." :: Text)
              ]
          , fromText "description" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Optional human-readable description / title for the session." :: Text)
              ]
          ]
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ v -> handleNew paths v
  }

-- | SESSION_LIST (legacy shim): delegates to the list handler.
sessionListOp :: SealPaths -> Opcode
sessionListOp paths = TrustedOpcode
  { toName = OpName "SESSION_LIST"
  , toTrust = Trusted
  , toDesc = "List all sessions (newest first). Set archived=true to list archived sessions instead of active ones. (Legacy — prefer SESSION_MANAGE with action=\"list\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("When true, list archived sessions instead of active ones. Default: false." :: Text)
              ]
          , fromText "include_children" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("Also enumerate child (sub-agent) transcripts nested under sessions/*/agents/. Default: false." :: Text)
              ]
          ]
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ v -> handleList paths v
  }

-- | SESSION_SEARCH (legacy shim): delegates to the search handler.
sessionSearchOp :: SealPaths -> SessionSearchBackend -> Opcode
sessionSearchOp paths searchBackend = TrustedOpcode
  { toName = OpName "SESSION_SEARCH"
  , toTrust = Trusted
  , toDesc = "Search sessions by text query. Full-transcript search across all messages (user, assistant, tool calls, tool results) and session descriptions. Case-insensitive. Uses engram semantic search when available, falls back to ripgrep literal search, then in-memory scan. (Legacy — prefer SESSION_MANAGE with action=\"search\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "query" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The search query (case-insensitive substring match)." :: Text)
              ]
          , fromText "archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("When true, search archived sessions instead of active ones. Default: false." :: Text)
              ]
          ]
      , "required" .= (["query"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeSearch
  , toBlocking = False
  , toRun = \_ v -> handleSearch searchBackend paths v
  }

-- | SESSION_GET (legacy shim): delegates to the get handler.
sessionGetOp :: SealPaths -> Opcode
sessionGetOp paths = TrustedOpcode
  { toName = OpName "SESSION_GET"
  , toTrust = Trusted
  , toDesc = "Read a session's transcript (conversation messages) with pagination. Returns a metadata header followed by rendered messages. Use offset/limit to page through long transcripts. (Legacy — prefer SESSION_MANAGE with action=\"get\".)"
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "session_id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The session id to read." :: Text)
              ]
          , fromText "offset" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("0-based message offset. In front-to-back mode, counts from start; in back-to-front mode, counts from end. Default: 0." :: Text)
              ]
          , fromText "limit" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Maximum number of messages to return. Default: 50, max: 200." :: Text)
              ]
          , fromText "order" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["front-to-back", "back-to-front"] :: [Text])
              , "description" .= ("Read direction. front-to-back: offset from start. back-to-front: offset from end. Default: back-to-front." :: Text)
              ]
          ]
      , "required" .= (["session_id"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeGet
  , toBlocking = False
  , toRun = \_ v -> handleGet paths v
  }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Extract a string field from a JSON object. Returns 'Nothing' when the
-- field is absent or the value is not a string.
textField :: Value -> Text -> Maybe Text
textField v key = join (parseMaybe (withObject "in" (.:? fromText key)) v)

-- | Extract a boolean field from a JSON object.
boolField :: Value -> Text -> Maybe Bool
boolField v key = join (parseMaybe (withObject "in" (.:? fromText key)) v)

-- | Extract an integer field from a JSON object.
intField :: Value -> Text -> Maybe Int
intField v key = join (parseMaybe (withObject "in" (.:? fromText key)) v)

-- | Render a SessionMeta as a compact one-line summary.
renderSessionMeta :: SessionMeta -> Text
renderSessionMeta m =
  let sid = sessionIdText (smId m)
      desc = fromMaybe "(no description)" (smDescription m)
      created = T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M" (smCreatedAt m))
      active = T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M" (smLastActive m))
  in sid <> " | " <> smProvider m <> "/" <> smModel m
       <> " | " <> desc
       <> " | created: " <> created <> " | last active: " <> active

-- | Search a child (sub-agent) session's transcript for the query string.
-- Returns 'Just snippet' when the first user message matches, 'Nothing'
-- otherwise. The child is identified by its parent + child SessionId pair.
searchChildSession
  :: SealPaths -> Text -> (SessionId, SessionId) -> IO (SessionId, SessionId, Maybe Text)
searchChildSession paths qLower (parentSid, childSid) = do
  mSnippet <- firstUserSnippet paths childSid
  let snippetLower = maybe "" T.toCaseFold mSnippet
      snippetMatch = qLower `T.isInfixOf` snippetLower
  pure (parentSid, childSid, if snippetMatch then mSnippet else Nothing)

-- | Render a one-line summary for a child (sub-agent) session, attributing it
-- to its parent. The marker @[child of \<parent\>]@ distinguishes child
-- sessions from top-level ones in SESSION_LIST / SESSION_SEARCH output.
renderChildSummary :: SessionId -> SessionId -> Text
renderChildSummary parentSid childSid =
  "[child of " <> sessionIdText parentSid <> "] " <> sessionIdText childSid

-- | Extract the first user message's text from a session's
-- @conversation.jsonl@. Returns 'Nothing' when the session has no
-- conversation or no user message with text content. Falls back to the
-- child (sub-agent) transcript path when the top-level conversation file
-- does not exist.
firstUserSnippet :: SealPaths -> SessionId -> IO (Maybe Text)
firstUserSnippet paths sid = do
  let convPath = sessionConversationPath paths sid
  exists <- doesFileExist convPath
  if exists
    then firstUserSnippetFromDir (sessionDir paths sid)
    else do
      mChild <- resolveChildSessionPath paths sid
      case mChild of
        Just (_, childDir) -> firstUserSnippetFromDir childDir
        Nothing            -> pure Nothing

-- | Extract the first user message's text from a @conversation.jsonl@ in the
-- given directory. Returns 'Nothing' when the file is absent or has no user
-- message with text content.
firstUserSnippetFromDir :: FilePath -> IO (Maybe Text)
firstUserSnippetFromDir dir = do
  let convPath = dir </> "conversation.jsonl"
  exists <- doesFileExist convPath
  if not exists
    then pure Nothing
    else do
      raw <- readFileTextStrict convPath
      let msgs = mapMaybe decodeMsg (T.lines raw)
      pure (snippetFromMessages msgs)

-- | Extract the first user message's text from a list of messages.
snippetFromMessages :: [Message] -> Maybe Text
snippetFromMessages msgs =
  case filter (\m -> msgRole m == User) msgs of
    (m : _) -> case [t | CbText t <- msgContent m] of
      (t : _) -> Just (truncateSnippet 120 t)
      []      -> Nothing
    [] -> Nothing

-- | Truncate a snippet to at most @n@ characters, appending an ellipsis.
truncateSnippet :: Int -> Text -> Text
truncateSnippet n t
  | T.length t <= n = t
  | otherwise       = T.take n t <> "…"

-- | Read all messages from a session's @conversation.jsonl@. Returns @[]@
-- when the session has no conversation file. Falls back to the child
-- (sub-agent) transcript path when the top-level conversation file does not
-- exist.
readSessionMessages :: SealPaths -> SessionId -> IO [Message]
readSessionMessages paths sid = do
  let convPath = sessionConversationPath paths sid
  exists <- doesFileExist convPath
  if exists
    then readMessagesFromDir (sessionDir paths sid)
    else do
      mChild <- resolveChildSessionPath paths sid
      case mChild of
        Just (_, childDir) -> readMessagesFromDir childDir
        Nothing            -> pure []

-- | Read all messages from a @conversation.jsonl@ in the given directory.
-- Returns @[]@ when the file is absent.
readMessagesFromDir :: FilePath -> IO [Message]
readMessagesFromDir dir = do
  let convPath = dir </> "conversation.jsonl"
  exists <- doesFileExist convPath
  if not exists
    then pure []
    else do
      raw <- readFileTextStrict convPath
      pure (mapMaybe decodeMsg (T.lines raw))

-- | Decode a JSON line into a Message.
decodeMsg :: Text -> Maybe Message
decodeMsg line = A.decode (BL.fromStrict (TE.encodeUtf8 line))

-- | Render a single message as readable text. The index is the 0-based
-- position within the full transcript (offset + relative index), shown
-- so the model can reference specific messages.
renderMessage :: Int -> Int -> Message -> Text
renderMessage offset relIdx msg =
  let globalIdx = offset + relIdx
      roleStr = case msgRole msg of
        User      -> "User"
        Assistant -> "Assistant"
      contentText = T.intercalate "\n" (map renderBlock (msgContent msg))
  in "## [" <> roleStr <> "] (#" <> T.pack (show globalIdx) <> ")\n" <> contentText

-- | Render a content block as readable text.
renderBlock :: ContentBlock -> Text
renderBlock (CbText t) = t
renderBlock (CbThinking t) = "[thinking] " <> t
renderBlock (CbToolUse{cbName = OpName n}) = "[tool call: " <> n <> "]"
renderBlock (CbToolResult{cbParts = parts, cbIsError = isErr}) =
  let label = if isErr then "[tool error]" else "[tool result]"
      content = T.intercalate "\n" [t | TrpText t <- parts]
  in if T.null content then label else label <> " " <> content

-- | Render the pagination footer, telling the model how to page further.
-- The @displayOffset@ is the 0-based index in the transcript where the
-- window starts (used for "messages X-Y"). The @userOffset@ is the offset
-- value the caller passed (used for "read with offset=Z" guidance) — in
-- front-to-back mode these are the same; in back-to-front mode they differ.
renderPageFooter :: ReadOrder -> Int -> Int -> Int -> Int -> Bool -> Text
renderPageFooter order displayOffset userOffset count total hasMore
  | total == 0 = "(0 messages in transcript)"
  | count == 0 = pastEndMsg
  | hasMore    = moreMsg
  | otherwise  = endMsg
  where
    nextOffset = userOffset + count
    rangeText  = T.pack (show (displayOffset + 1)) <> "-"
                   <> T.pack (show (displayOffset + count))
    totalText  = T.pack (show total)
    pastEndMsg = case order of
      OrderAsc ->
        "[offset " <> T.pack (show userOffset) <> " is past end of transcript ("
          <> totalText <> " messages); read with offset=0 to start over]"
      OrderDesc ->
        "[offset " <> T.pack (show userOffset) <> " is past the beginning of transcript ("
          <> totalText <> " messages); read with offset=0 to start from the end]"
    moreMsg = case order of
      OrderAsc ->
        "[messages " <> rangeText <> " of " <> totalText <> "; "
          <> T.pack (show (total - displayOffset - count))
          <> " more - read with offset=" <> T.pack (show nextOffset)
          <> " for the next window]"
      OrderDesc ->
        "[messages " <> rangeText <> " of " <> totalText <> "; "
          <> T.pack (show displayOffset)
          <> " earlier - read with offset=" <> T.pack (show nextOffset)
          <> " for the next page back]"
    endMsg = case order of
      OrderAsc ->
        "[messages " <> rangeText <> " of " <> totalText <> " (end of transcript)]"
      OrderDesc ->
        "[messages " <> rangeText <> " of " <> totalText <> " (beginning of transcript)]"
