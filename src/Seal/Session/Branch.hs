{-# LANGUAGE OverloadedStrings #-}
-- | Seeding a branched session: copy the first @N@ conversation lines of a
-- parent session into a new child session directory.
--
-- The transcript is the only thing a branch inherits. The workdir is
-- deliberately /not/ copied: the transcript records tool inputs and
-- outputs, never filesystem snapshots, so a historical workdir cannot be
-- reconstructed — and copying the /current/ one would be misleading the
-- moment the branch point is earlier than the present. A new session id
-- already gets a fresh empty workdir via 'ensureSessionWorkdir', so the
-- correct behaviour is the default.
module Seal.Session.Branch
  ( branchSession
  , clampBranchLen
  , foldEntryPrefix
  ) where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
  , removeDirectoryRecursive )

import Seal.Config.Paths
  ( SealPaths, sessionConversationIndexPath, sessionConversationPath
  , sessionDir, sessionEntriesPath )
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Session.Meta (readSessionMeta)
import Seal.Transcript.ConvIndex (ensureIndex)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..), encodeEntryRecordRaw)
import Seal.Util.StrictIO (readFileTextStrict)

-- | Clamp a client-supplied branch length into @[0, parentLen]@.
--
-- The value reaches us from the browser, so it is untrusted. Clamping
-- (rather than rejecting) means a stale frontend whose transcript view is
-- ahead of the parent's file is harmless: the branch simply copies what
-- exists.
clampBranchLen :: Int -> Int -> Int
clampBranchLen parentLen n = max 0 (min parentLen n)

-- | Select the prefix of @entries.jsonl@ that belongs to the first @n@
-- conversation lines.
--
-- This replicates the /writer's/ @erConvLen@ convention, which is not
-- uniform per kind ('Seal.Handles.Transcript.writeOne'):
--
--   * 'EKRequest', 'EKResponse', 'EKCompaction' — @erConvLen@ is the
--     conversation length after the entry (absolute).
--   * 'EKHarness' — @erConvLen@ is a delta: how many lines that entry
--     contributed (0 for a plain opcode invocation, 1 for a skill load or
--     setup-repo result).
--
-- An entry is included iff its cursor-after is @<= n@. Entries are
-- append-ordered, so the first entry that overflows ends the prefix.
foldEntryPrefix :: Int -> [EntryRecord] -> [EntryRecord]
foldEntryPrefix n = go 0
  where
    go _ [] = []
    go cursor (e : es)
      | after > n = []
      | otherwise = e : go after es
      where
        after = case erKind e of
          EKHarness -> cursor + erConvLen e
          _         -> erConvLen e

-- | Copy the parent's transcript prefix into a new child session directory.
--
-- Copies @conversation.jsonl@ byte-exactly (so the inherited lines are
-- identical to the parent's) and the matching @entries.jsonl@ prefix, then
-- builds @conversation.idx@. Writes no @session.json@ — the caller does
-- that last, so a failed seed leaves nothing that 'listSessions' would
-- surface.
--
-- The anchor count is derived from the /newline-terminated/ lines actually
-- present rather than from the index, which also makes a torn trailing
-- line (an in-flight turn mid-write) harmless: a partial final line has no
-- newline, so it never counts toward @n@ and is never copied.
branchSession
  :: SealPaths
  -> SessionId   -- ^ parent
  -> SessionId   -- ^ child
  -> Int         -- ^ requested conversation length
  -> IO (Either Text ())
branchSession paths parentSid childSid requestedLen = do
  mParentMeta <- readSessionMeta paths parentSid
  case mParentMeta of
    Nothing -> pure (Left ("parent session not found: " <> sessionIdText parentSid))
    Just _  -> do
      let parentConv  = sessionConversationPath paths parentSid
          parentEntry = sessionEntriesPath paths parentSid
          childDir    = sessionDir paths childSid
          childConv   = sessionConversationPath paths childSid
          childEntry  = sessionEntriesPath paths childSid
          childIdx    = sessionConversationIndexPath paths childSid

      eConv <- readConversationByLines parentConv
      case eConv of
        Left err -> pure (Left err)
        Right convBytes -> do
          let n = clampBranchLen (length convBytes) requestedLen
              copiedBytes = take n convBytes
          eResult <- try @IOException $ do
            createDirectoryIfMissing True childDir
            when (n > 0) $ do
              BS.writeFile childConv (BS.concat copiedBytes)
              eEntries <- readEntryPrefix parentEntry n
              case eEntries of
                Right er -> BS.writeFile childEntry er
                Left err -> ioError (userError (T.unpack err))
              -- Build-if-missing, matching 'withIndexedTranscript'. Only
              -- when the conversation file exists: a zero-length branch
              -- must look exactly like a fresh session (no conversation
              -- file, no index), because a lone [0] offset is rejected by
              -- 'validateIndex' as corrupt.
              _ <- ensureIndex childConv childIdx
              pure ()
          case eResult :: Either IOException () of
            Right () -> pure (Right ())
            Left ioe -> do
              -- Leave no partial child directory behind.
              exists <- doesDirectoryExist childDir
              when exists (ignoreIO (removeDirectoryRecursive childDir))
              pure (Left ("could not seed branch: " <> T.pack (show ioe)))

-- | Read a conversation file as (per-line bytes, per-line bytes). The
-- line list is used for counting; the byte list is what we copy verbatim.
--
-- An absent file is @Right ([], [])@ — a brand-new parent has nothing to
-- inherit, which is not an error.
readConversationByLines :: FilePath -> IO (Either Text [BS.ByteString])
readConversationByLines path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right [])
    else do
      eBs <- try @IOException (BS.readFile path)
      pure $ case eBs of
        Left ioe -> Left ("could not read parent conversation: " <> T.pack (show ioe))
        Right bs ->
          -- Split on newlines (0x0a). A trailing partial line (no final
          -- newline) is DROPPED: it belongs to an in-flight write.
          let complete = dropTrailingPartial (BS.split 0x0a bs)
          in Right [ p <> "\n" | p <- complete ]

-- | 'BS.split' on a file ending with a newline yields a final empty
-- element. That empty element is the artifact of the trailing newline, not
-- a line; drop it. Any /other/ final element is a genuinely partial line
-- and is dropped too.
dropTrailingPartial :: [BS.ByteString] -> [BS.ByteString]
dropTrailingPartial pieces = case reverse pieces of
  ("" : rest) -> reverse rest   -- file ended with '\n': no partial line
  (_  : rest) -> reverse rest   -- partial line mid-write: drop it
  []          -> []

-- | Read the parent's @entries.jsonl@ and encode the prefix for the child.
readEntryPrefix :: FilePath -> Int -> IO (Either Text BS.ByteString)
readEntryPrefix path n = do
  exists <- doesFileExist path
  if not exists
    then pure (Right BS.empty)
    else do
      eRaw <- try @IOException (readFileTextStrict path)
      pure $ case eRaw of
        Left ioe -> Left ("could not read parent entries: " <> T.pack (show ioe))
        Right raw ->
          let decoded = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                                (filter (not . T.null) (T.lines raw))
          in Right (BS.concat (map (\e -> encodeEntryRecordRaw e <> "\n")
                                   (foldEntryPrefix n decoded)))

ignoreIO :: IO () -> IO ()
ignoreIO action = do
  _ <- try @IOException action
  pure ()
