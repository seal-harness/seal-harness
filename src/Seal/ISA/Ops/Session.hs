{-# LANGUAGE OverloadedStrings #-}
-- | The Sessions opcode group: SESSION_NEW, SESSION_LIST, SESSION_SEARCH,
-- SESSION_GET. All Trusted — harness-internal operations that manage the
-- on-disk session store. 'orRecorded' carries secret-free metadata only
-- (session ids, provider/model labels, entry counts); transcript content
-- returned by SESSION_GET goes in 'orParts' (agent-visible) but never in
-- 'orRecorded'.
--
-- SESSION_NEW creates a fresh session directory + session.json on disk,
-- reusing 'Seal.Session.Store.newSession'. SESSION_LIST enumerates all
-- sessions (non-archived by default, archived when @archived=true@).
-- SESSION_SEARCH does simple substring matching against session
-- descriptions and first-user-message snippets (no embedding/semantic
-- search — a future enhancement). SESSION_GET reads a session's
-- @conversation.jsonl@ and renders the messages as readable text with
-- offset/limit pagination, so an agent can inspect prior session content
-- for debugging, self-improvement, etc. without blowing its context
-- window on a single call.
module Seal.ISA.Ops.Session
  ( sessionNewOp
  , sessionListOp
  , sessionSearchOp
  , sessionGetOp
  ) where

import Control.Monad (join)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value, object, withObject, (.:?), (.=) )
import Data.Aeson qualified as A
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (formatTime, defaultTimeLocale)
import System.Directory (doesFileExist)

import Seal.Config.Paths
  ( SealPaths, sessionConversationPath, sessionMetaPath )
import Seal.Core.Paging
  ( Page (..), PageParams (..), paginate )
import Seal.Core.Types
  ( OpName (..), SessionId, TrustLevel (..), mkSessionId, sessionIdText )
import Seal.ISA.Opcode
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), ToolResultPart (..) )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( listSessions, listArchivedSessions, newSession, saveSessionMeta )
import Seal.Util.StrictIO (readFileTextStrict, decodeFileStrict)

-- | Page parameters for SESSION_GET transcript pagination. A flat 50-message
-- default with a 200-message hard ceiling — transcripts can be very long, so
-- we start conservatively to avoid context-window pressure.
sessionPageParams :: PageParams
sessionPageParams = PageParams { ppFloor = 50, ppCeiling = 200, ppCoeff = 0.0 }

-- | SESSION_NEW: create a new session directory + session.json on disk.
-- Takes optional provider/model/channel/description. Returns the session
-- id + metadata. The new session is immediately visible to SESSION_LIST
-- and SESSION_SEARCH.
sessionNewOp :: SealPaths -> Opcode
sessionNewOp paths = TrustedOpcode
  { toName = OpName "SESSION_NEW"
  , toTrust = Trusted
  , toDesc = "Create a new session with its own transcript and working directory. Returns the session id and metadata."
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
  , toRun = \_ v -> do
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
  }

-- | SESSION_LIST: enumerate all sessions (non-archived by default, archived
-- when @archived=true@). Returns id, provider, model, channel, description,
-- created_at, last_active for each session, newest first.
sessionListOp :: SealPaths -> Opcode
sessionListOp paths = TrustedOpcode
  { toName = OpName "SESSION_LIST"
  , toTrust = Trusted
  , toDesc = "List all sessions (newest first). Set archived=true to list archived sessions instead of active ones."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "archived" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("When true, list archived sessions instead of active ones. Default: false." :: Text)
              ]
          ]
      ]
  , toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ v -> do
      let archived = fromMaybe False (boolField v "archived")
      metas <- liftIO (if archived then listArchivedSessions paths else listSessions paths)
      let rendered = case metas of
            [] -> "(no sessions found)"
            _ -> T.intercalate "\n" (map renderSessionMeta metas)
          recorded = object
            [ "count" .= length metas
            , "archived" .= archived
            , "session_ids" .= fmap (sessionIdText . smId) metas
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }

-- | SESSION_SEARCH: search sessions by text query. Matches against session
-- descriptions and first-user-message snippets (the first @CbText@ block of
-- the first @User@ message in @conversation.jsonl@). Simple case-insensitive
-- substring match — no embedding/semantic search. Returns matching sessions
-- with the matched snippet for context.
sessionSearchOp :: SealPaths -> Opcode
sessionSearchOp paths = TrustedOpcode
  { toName = OpName "SESSION_SEARCH"
  , toTrust = Trusted
  , toDesc = "Search sessions by text query. Matches session descriptions and first user message snippets. Case-insensitive substring match."
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
  , toAuthorize = \v ->
      case textField v "query" of
        Nothing -> Left "SESSION_SEARCH requires {query:string}"
        Just q
          | T.null (T.strip q) -> Left "SESSION_SEARCH: query is empty"
          | otherwise -> Right ()
  , toBlocking = False
  , toRun = \_ v -> do
      let q = fromMaybe "" (textField v "query")
      if T.null (T.strip q)
       then pure (OpResult [TrpText "SESSION_SEARCH: query is empty"] True (object []))
       else do
         let qLower = T.toCaseFold (T.strip q)
             archived = fromMaybe False (boolField v "archived")
         metas <- liftIO (if archived then listArchivedSessions paths else listSessions paths)
         results <- liftIO (mapM (searchSession paths qLower) metas)
         let matched = [ (m, snip) | (m, Just snip) <- results ]
             rendered = case matched of
               [] -> "(no sessions found)"
               _ -> T.intercalate "\n\n" $
                      [ renderSessionMeta m <> "\n  snippet: " <> snip
                      | (m, snip) <- matched ]
             recorded = object
               [ "query" .= q
               , "archived" .= archived
               , "match_count" .= length matched
               , "session_ids" .= fmap (sessionIdText . smId . fst) matched
               ]
         pure (OpResult [TrpText rendered] False recorded)
  }

-- | SESSION_GET: read a session's transcript (@conversation.jsonl@) and
-- render the messages as readable text with offset/limit pagination. The
-- output includes a metadata header (session id, provider, model,
-- description, timestamps) followed by the paginated message list. Each
-- message is rendered as @## [role] content...@. The pagination footer
-- tells the model how to page forward (offset/limit/total). Transcript
-- content goes in 'orParts' only; 'orRecorded' carries only metadata
-- (session id, entry count, offset, limit) — never message content.
sessionGetOp :: SealPaths -> Opcode
sessionGetOp paths = TrustedOpcode
  { toName = OpName "SESSION_GET"
  , toTrust = Trusted
  , toDesc = "Read a session's transcript (conversation messages) with pagination. Returns a metadata header followed by rendered messages. Use offset/limit to page through long transcripts."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "session_id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The session id to read." :: Text)
              ]
          , fromText "offset" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("0-based message offset to start reading from. Default: 0." :: Text)
              ]
          , fromText "limit" .= object
              [ "type" .= ("integer" :: Text)
              , "description" .= ("Maximum number of messages to return. Default: 50, max: 200." :: Text)
              ]
          ]
      , "required" .= (["session_id"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = \v ->
      case textField v "session_id" of
        Nothing -> Left "SESSION_GET requires {session_id:string}"
        Just sid
          | T.null (T.strip sid) -> Left "SESSION_GET: session_id is empty"
          | otherwise -> Right ()
  , toBlocking = False
  , toRun = \_ v -> do
      let mSidText = textField v "session_id"
          offset = fromMaybe 0 (intField v "offset")
          mLimit = intField v "limit"
      case mSidText >>= either (const Nothing) Just . mkSessionId . T.strip of
        Nothing -> pure (OpResult [TrpText "invalid session id"] True (object []))
        Just sid -> do
          metaExists <- liftIO (doesFileExist (sessionMetaPath paths sid))
          mMeta <- if not metaExists
                     then pure Nothing
                     else liftIO (decodeFileStrict (sessionMetaPath paths sid))
          case mMeta of
            Nothing -> pure (OpResult
              [TrpText ("session not found: " <> sessionIdText sid)] True
              (object ["session_id" .= sessionIdText sid]))
            Just meta -> do
              msgs <- liftIO (readSessionMessages paths sid)
              let total = length msgs
                  page = paginate sessionPageParams offset mLimit msgs
                  windowMsgs = pgItems page
                  header = renderSessionMeta meta
                  body = T.intercalate "\n\n"
                    (zipWith (renderMessage (pgOffset page)) [0..] windowMsgs)
                  footer = renderPageFooter (pgOffset page) (length windowMsgs) total (pgHasMore page)
                  rendered = T.intercalate "\n\n" (filter (not . T.null) [header, body, footer])
                  recorded = object
                    [ "session_id" .= sessionIdText sid
                    , "provider" .= smProvider meta
                    , "model" .= smModel meta
                    , "offset" .= pgOffset page
                    , "limit" .= length windowMsgs
                    , "total_messages" .= total
                    , "has_more" .= pgHasMore page
                    ]
              pure (OpResult [TrpText rendered] False recorded)
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

-- | Search a single session for the query string. Returns 'Just snippet'
-- if the session matches (description or first user message), 'Nothing'
-- otherwise. The snippet is the matched text for context.
searchSession :: SealPaths -> Text -> SessionMeta -> IO (SessionMeta, Maybe Text)
searchSession paths qLower meta = do
  let descLower = maybe "" T.toCaseFold (smDescription meta)
      descMatch = qLower `T.isInfixOf` descLower
  mSnippet <- firstUserSnippet paths (smId meta)
  let snippetLower = maybe "" T.toCaseFold mSnippet
      snippetMatch = qLower `T.isInfixOf` snippetLower
  if descMatch || snippetMatch
    then pure (meta, Just (fromMaybe (fromMaybe "(no description)" (smDescription meta)) mSnippet))
    else pure (meta, Nothing)

-- | Extract the first user message's text from a session's
-- @conversation.jsonl@. Returns 'Nothing' when the session has no
-- conversation or no user message with text content.
firstUserSnippet :: SealPaths -> SessionId -> IO (Maybe Text)
firstUserSnippet paths sid = do
  let convPath = sessionConversationPath paths sid
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
-- when the session has no conversation file.
readSessionMessages :: SealPaths -> SessionId -> IO [Message]
readSessionMessages paths sid = do
  let convPath = sessionConversationPath paths sid
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
renderBlock (CbToolUse{cbName = OpName n}) = "[tool call: " <> n <> "]"
renderBlock (CbToolResult{cbParts = parts, cbIsError = isErr}) =
  let label = if isErr then "[tool error]" else "[tool result]"
      content = T.intercalate "\n" [t | TrpText t <- parts]
  in if T.null content then label else label <> " " <> content

-- | Render the pagination footer, telling the model how to page forward.
renderPageFooter :: Int -> Int -> Int -> Bool -> Text
renderPageFooter offset count total hasMore
  | total == 0 = "(0 messages in transcript)"
  | offset >= total && count == 0
  = "[offset " <> T.pack (show offset) <> " is past end of transcript ("
       <> T.pack (show total) <> " messages); read with offset=0 to start over]"
  | hasMore
  = "[messages " <> T.pack (show (offset + 1)) <> "-" <> T.pack (show (offset + count))
       <> " of " <> T.pack (show total) <> "; " <> T.pack (show (total - offset - count))
       <> " more - read with offset=" <> T.pack (show (offset + count)) <> " for the next window]"
  | otherwise
  = "[messages " <> T.pack (show (offset + 1)) <> "-" <> T.pack (show (offset + count))
       <> " of " <> T.pack (show total) <> " (end of transcript)]"
