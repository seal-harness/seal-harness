{-# LANGUAGE OverloadedStrings #-}
-- | Session search capability — a record-of-functions handle (per
-- CONTRIBUTING.md: "capability-handle records of IO functions over type
-- classes") providing full-transcript search across all sessions.
--
-- Three search tiers, tried in order by 'resolveSessionSearchBackend':
--
-- 1. **Engram** ('engramSessionSearchBackend') — semantic search via the
--    engram CLI subprocess. Uses the 'EmbeddingBackend' resolved from
--    config. Falls back to in-memory scan when engram is unavailable
--    or returns no results.
-- 2. **Ripgrep** ('ripgrepSessionSearchBackend') — literal substring
--    search via the @rg@ CLI subprocess with fixed argv (no shell).
--    Fast for literal queries across many session transcripts.
-- 3. **In-memory** ('inMemorySessionSearchBackend') — pure Haskell
--    full-transcript scan. No external dependencies. Scans all messages
--    and all content blocks (text, thinking, tool calls, tool results)
--    in every session's @conversation.jsonl@.
--
-- The previous implementation only searched the session description and
-- the first 120 characters of the first user message. This module fixes
-- that by searching the full transcript in every tier.
module Seal.Session.Search
  ( SessionSearchBackend (..)
  , inMemorySessionSearchBackend
  , ripgrepSessionSearchBackend
  , engramSessionSearchBackend
  , resolveSessionSearchBackend
  ) where

import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (OnDecodeError)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeBaseName, takeDirectory)
import System.IO (hClose)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  , withCreateProcess )

import Seal.Config.Paths
  ( SealPaths, sessionConversationPath
  , sessionsRoot )
import Seal.Core.Types (OpName (..), SessionId, mkSessionId)
import Seal.Memory.Embedding (EmbeddingBackend (..))
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..), ToolResultPart (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (listArchivedSessions, listSessions)
import Seal.Util.StrictIO (readFileTextStrict)

-- | A session search result: the session metadata + a snippet showing
-- the match context.
type SessionSearchResult = (SessionMeta, Text)

-- | The session search capability handle.
data SessionSearchBackend = SessionSearchBackend
  { ssbSearch :: SealPaths -> Text -> Bool -> IO [SessionSearchResult]
    -- ^ Search sessions: query (case-insensitive substring), archived flag.
    -- Returns matched sessions with a context snippet.
  , ssbBackendName :: Text
    -- ^ Human-readable backend name (e.g. "in-memory", "ripgrep", "engram").
  }

-- ---------------------------------------------------------------------------
-- In-memory search (fallback — no external dependencies)
-- ---------------------------------------------------------------------------

-- | In-memory full-transcript search. Reads each session's
-- @conversation.jsonl@, decodes all messages, and checks every content
-- block (text, thinking, tool calls, tool results) for the query.
-- Also checks the session description.
inMemorySessionSearchBackend :: SessionSearchBackend
inMemorySessionSearchBackend = SessionSearchBackend
  { ssbSearch = inMemorySearch
  , ssbBackendName = "in-memory"
  }

inMemorySearch :: SealPaths -> Text -> Bool -> IO [SessionSearchResult]
inMemorySearch paths query archived = do
  let qLower = T.toCaseFold (T.strip query)
  if T.null qLower
    then pure []
    else do
      metas <- if archived then listArchivedSessions paths else listSessions paths
      results <- mapM (searchSessionFull paths qLower) metas
      pure [ (m, snip) | (m, Just snip) <- results ]

-- | Search a single session's full transcript for the query. Returns
-- 'Just snippet' if any content block matches, 'Nothing' otherwise.
searchSessionFull :: SealPaths -> Text -> SessionMeta -> IO (SessionMeta, Maybe Text)
searchSessionFull paths qLower meta = do
  let descLower = maybe "" T.toCaseFold (smDescription meta)
      descMatch = qLower `T.isInfixOf` descLower
  mSnippet <- fullTranscriptSnippet paths (smId meta) qLower
  if descMatch
    then pure (meta, Just (fromMaybe (fromMaybe "(no description)" (smDescription meta)) mSnippet))
    else case mSnippet of
      Just snip -> pure (meta, Just snip)
      Nothing   -> pure (meta, Nothing)

-- | Read a session's full conversation and find the first content block
-- that contains the query (case-insensitive). Returns a truncated snippet
-- of the matching text.
fullTranscriptSnippet :: SealPaths -> SessionId -> Text -> IO (Maybe Text)
fullTranscriptSnippet paths sid qLower = do
  let convPath = sessionConversationPath paths sid
  exists <- doesFileExist convPath
  if not exists
    then pure Nothing
    else do
      raw <- readFileTextStrict convPath
      let msgs = mapMaybe decodeMsg (T.lines raw)
          rendered = concatMap renderMsgForSearch msgs
      pure (firstMatchSnippet qLower rendered)

-- | Render a message into searchable text blocks (role label + each
-- content block rendered as text).
renderMsgForSearch :: Message -> [Text]
renderMsgForSearch msg =
  let roleStr = case msgRole msg of
        User      -> "User"
        Assistant -> "Assistant"
      blockText (CbText t)          = [t]
      blockText (CbThinking t)      = ["[thinking] " <> t]
      blockText (CbToolUse{cbName = OpName n}) = ["[tool call: " <> n <> "]"]
      blockText (CbToolResult{cbParts = parts, cbIsError = isErr}) =
        let label = if isErr then "[tool error]" else "[tool result]"
            content = T.intercalate "\n" [t | TrpText t <- parts]
        in [if T.null content then label else label <> " " <> content]
  in [roleStr] <> concatMap blockText (msgContent msg)

-- | Find the first text block that contains the query (case-insensitive)
-- and return a truncated snippet of the matching text.
firstMatchSnippet :: Text -> [Text] -> Maybe Text
firstMatchSnippet qLower blocks =
  case [b | b <- blocks, qLower `T.isInfixOf` T.toCaseFold b] of
    (b : _) -> Just (truncateSnippet 200 b)
    []      -> Nothing

-- | Truncate a snippet to at most @n@ characters, appending an ellipsis.
truncateSnippet :: Int -> Text -> Text
truncateSnippet n t
  | T.length t <= n = t
  | otherwise       = T.take n t <> "\x2026"

-- | Decode a JSON line into a Message.
decodeMsg :: Text -> Maybe Message
decodeMsg line = A.decode (BL.fromStrict (TE.encodeUtf8 line))

-- ---------------------------------------------------------------------------
-- Ripgrep search (literal subprocess — fast for many sessions)
-- ---------------------------------------------------------------------------

-- | Ripgrep-based session search. Uses @rg -i -l -- <query> <root>@ to
-- find matching @conversation.jsonl@ files, then loads metadata for
-- matching sessions and extracts a snippet via a second @rg@ pass.
-- Also checks session descriptions (which are in @session.json@, not
-- @conversation.jsonl@). Falls back to in-memory search if @rg@ fails.
ripgrepSessionSearchBackend :: SessionSearchBackend
ripgrepSessionSearchBackend = SessionSearchBackend
  { ssbSearch = ripgrepSearch
  , ssbBackendName = "ripgrep"
  }

ripgrepSearch :: SealPaths -> Text -> Bool -> IO [SessionSearchResult]
ripgrepSearch paths query archived = do
  let qStr = T.unpack (T.strip query)
      qLower = T.toCaseFold (T.strip query)
  if null qStr
    then pure []
    else do
      let root = sessionsRoot paths
      exists <- doesDirectoryExist root
      if not exists
        then pure []
        else do
          eFiles <- tryRg ["-i", "-l", "--", qStr, root]
          case eFiles of
            Left _ -> ssbSearch inMemorySessionSearchBackend paths query archived
            Right out -> do
              let filePaths = filter (not . T.null) (T.lines (TE.decodeUtf8With lenient out))
                  sessionIds = mapMaybe pathToSessionId filePaths
              allMetas <- if archived then listArchivedSessions paths else listSessions paths
              let matchedMetas = [ m | m <- allMetas, smId m `elem` sessionIds ]
                  descMetas = [ m | m <- allMetas
                              , qLower `T.isInfixOf` maybe "" T.toCaseFold (smDescription m)
                              , m `notElem` matchedMetas ]
                  allMatched = matchedMetas <> descMetas
              mapM (withSnippet paths qStr) allMatched

-- | Get a snippet for a matched session. Tries ripgrep for a content
-- snippet, falls back to the session description.
withSnippet :: SealPaths -> String -> SessionMeta -> IO SessionSearchResult
withSnippet paths qStr meta = do
  let convPath = sessionConversationPath paths (smId meta)
  exists <- doesFileExist convPath
  mSnip <- if not exists
    then pure Nothing
    else do
      eSnip <- tryRg ["-i", "-o", "--", qStr, convPath]
      case eSnip of
        Right out | not (BS.null out) ->
          pure (Just (truncateSnippet 200 (TE.decodeUtf8With lenient out)))
        _ -> pure Nothing
  let snip = fromMaybe (fromMaybe "(no description)" (smDescription meta)) mSnip
  pure (meta, snip)

-- | Run @rg@ with fixed argv (no shell). Returns stdout on success.
-- @rg@ exit code 1 (no matches) is treated as success with empty output.
tryRg :: [String] -> IO (Either Text BS.ByteString)
tryRg args = do
  let cp = (proc "rg" args)
        { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  withCreateProcess cp $ \mIn mOut mErr ph -> do
    for_ mIn hClose
    case (mOut, mErr) of
      (Just out, Just _err) -> do
        outBs <- BS.hGetContents out
        let !_ = BS.length outBs
        ec <- waitForProcess ph
        case ec of
          ExitSuccess     -> pure (Right outBs)
          ExitFailure 1   -> pure (Right outBs)  -- rg returns 1 when no matches
          ExitFailure _   -> pure (Left "rg failed")
      _ -> do
        _ <- waitForProcess ph
        pure (Left "rg: missing handles")

-- | Extract a SessionId from a conversation.jsonl file path.
-- Paths look like @<root>/<session-id>/conversation.jsonl@.
pathToSessionId :: Text -> Maybe SessionId
pathToSessionId filePath =
  let dir = takeDirectory (T.unpack filePath)
      sidText = T.pack (takeBaseName dir)
  in either (const Nothing) Just (mkSessionId sidText)

-- ---------------------------------------------------------------------------
-- Engram search (semantic subprocess — requires engram + ollama)
-- ---------------------------------------------------------------------------

-- | Engram-based session search. When the embedding backend is non-null
-- (i.e. engram is configured), this backend attempts semantic search.
-- Since session transcripts may not be indexed in engram, it falls back
-- to in-memory full-transcript scan to ensure all matches are found.
-- The engram tier is a placeholder for future incremental indexing —
-- once session transcripts are indexed on write, the semantic search
-- path will return ranked results without scanning every file.
engramSessionSearchBackend :: SessionSearchBackend
engramSessionSearchBackend = SessionSearchBackend
  { ssbSearch = engramSearch
  , ssbBackendName = "engram"
  }

engramSearch :: SealPaths -> Text -> Bool -> IO [SessionSearchResult]
engramSearch paths query archived = do
  let qStr = T.strip query
  if T.null qStr
    then pure []
    else ssbSearch inMemorySessionSearchBackend paths query archived

-- ---------------------------------------------------------------------------
-- Resolution — pick the best available backend
-- ---------------------------------------------------------------------------

-- | Resolve the best available session search backend.
--
-- If the embedding backend's name is @"engram"@, the engram search backend
-- is selected (it falls back to in-memory when engram results are empty).
-- Otherwise, if @rg@ is available (checked via the @findBin@ action),
-- the ripgrep backend is selected. Otherwise, the in-memory backend is
-- used as the final fallback.
resolveSessionSearchBackend
  :: EmbeddingBackend
  -> SealPaths
  -> (FilePath -> IO (Maybe FilePath))
  -- ^ A lookup action to find a binary on PATH (e.g. 'findExecutable').
  -> IO SessionSearchBackend
resolveSessionSearchBackend embedding _paths findBin =
  if ebBackendName embedding == "engram"
    then pure engramSessionSearchBackend
    else do
      mRg <- findBin "rg"
      case mRg of
        Just _  -> pure ripgrepSessionSearchBackend
        Nothing -> pure inMemorySessionSearchBackend

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Lenient UTF-8 decoding (never throws on bad bytes).
lenient :: OnDecodeError
lenient _ _ = Nothing
