{-# LANGUAGE OverloadedStrings #-}
-- | The per-session @derived.json@ sidecar: a materialized cache of values that
-- are pure functions of the transcript but expensive to recompute on every
-- listing.
--
-- Why it exists: @buildListsSnapshot@ calls @sessionInfoJsonWithSnippet@ for
-- every session on every poll (~3s), and @lastUserMessageAtFast@ used to read
-- and JSON-decode the whole @entries.jsonl@ per session — ~90 MB of parsing per
-- snapshot at 704 sessions (see @Gateway\/Transcript.hs@). Materializing the one
-- scalar removes that read from the hot path.
--
-- The sidecar is a **materialized view**, exactly like @conversation.idx@: it is
-- never authoritative, and deleting every @derived.json@ changes nothing
-- observable except latency.
--
-- Validity is by **byte count**, not mtime. Recording
-- @entries_bytes == size(entries.jsonl)@ closes the read-then-write window: an
-- append changes the size, so a sidecar written concurrently with an append
-- cannot certify a stale value.
--
-- Scope note: only 'dmLastUserMessageAt' is cached. The first-user-message
-- snippet is /not/ cached here — it derives from @conversation.jsonl@, so no
-- key over @entries.jsonl@ could validate it.
module Seal.Session.Derived
  ( DerivedMeta (..)
  , derivedVersion
  , renderIso
  , readDerived
  , writeDerived
  , entriesSize
  , derivedIsFresh
  , computeDerived
  ) where

import Control.Exception (IOException, onException, try)
import Control.Monad (void)
import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=) )
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (UTCTime, defaultTimeLocale, formatTime)

import System.Directory (doesDirectoryExist, removeFile, renameFile)
import System.FilePath (takeFileName)
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (FileStatus, fileSize, getFileStatus, setFileMode)

import Seal.Config.Paths (SealPaths, sessionDerivedPath, sessionDir, sessionEntriesPath)
import Seal.Core.Types (SessionId)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))

-- | The sidecar record. The field set is deliberately minimal: one derived
-- value plus the byte count that keys its validity.
data DerivedMeta = DerivedMeta
  { dmVersion           :: !Int
  , dmLastUserMessageAt :: !(Maybe Text)
    -- ^ ISO-8601 with milliseconds + @Z@, exactly as 'renderIso' produces it.
    -- Opaque on read: this module never re-parses it.
  , dmEntriesBytes      :: !Int64
    -- ^ Size of @entries.jsonl@ at the moment the value was computed.
  } deriving stock (Eq, Show)

-- | The only format this module reads or writes. An unknown version is treated
-- as absent (and later overwritten), so a downgrade is safe.
derivedVersion :: Int
derivedVersion = 1

instance ToJSON DerivedMeta where
  toJSON m = object
    [ "version"             .= dmVersion m
    , "last_user_message_at" .= dmLastUserMessageAt m
    , "entries_bytes"       .= dmEntriesBytes m
    ]

instance FromJSON DerivedMeta where
  parseJSON = withObject "DerivedMeta" $ \o ->
    DerivedMeta <$> o .: "version" <*> o .:? "last_user_message_at" <*> o .: "entries_bytes"

-- | ISO-8601 with milliseconds + @Z@ — the frontend's expected timestamp shape.
-- This is the /single/ formatter in the codebase: @Gateway.Transcript.showIso@
-- delegates to it (that module imports this one, so the formatter cannot live
-- there without an import cycle).
renderIso :: UTCTime -> Text
renderIso = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ"

-- | Read the sidecar. Returns 'Nothing' — never throws — for a missing file, a
-- non-object value, malformed JSON, or any version other than
-- 'derivedVersion'.
readDerived :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
readDerived paths sid = do
  r <- try (A.decodeFileStrict' (sessionDerivedPath paths sid))
         :: IO (Either IOException (Maybe DerivedMeta))
  pure $ case r of
    Right (Just m) | dmVersion m == derivedVersion -> Just m
    _                                              -> Nothing

-- | Size of @entries.jsonl@, or 'Nothing' when it does not exist (or cannot be
-- stat'd). 'System.Posix.Files.getFileStatus' throws on a missing path, so the
-- existence check is not redundant. A zero-byte file yields @Just 0@.
entriesSize :: SealPaths -> SessionId -> IO (Maybe Int64)
entriesSize paths sid = do
  r <- try (getFileStatus (sessionEntriesPath paths sid))
         :: IO (Either IOException FileStatus)
  pure $ case r of
    Left _   -> Nothing
    Right st -> Just (fromIntegral (fileSize st))

-- | Trust the sidecar only when its recorded byte count equals the current size
-- of @entries.jsonl@. A negative recorded count is never trusted, and an absent
-- @entries.jsonl@ always yields 'False'.
derivedIsFresh :: SealPaths -> SessionId -> IO Bool
derivedIsFresh paths sid = do
  m <- readDerived paths sid
  case m of
    Nothing -> pure False
    Just d
      | dmEntriesBytes d < 0 -> pure False
      | otherwise -> do
          sz <- entriesSize paths sid
          pure (sz == Just (dmEntriesBytes d))

-- | Compute the current value from @entries.jsonl@, applying the
-- stat &#x2192; read &#x2192; stat rule: if an append lands during the read the
-- two sizes differ, so the value is discarded ('Nothing') rather than recorded
-- against a byte count it does not match.
--
-- This is the /single/ producer of 'DerivedMeta'; the read path and
-- @\/session reindex@ both call it, so the parse and the race rule exist once.
computeDerived :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
computeDerived paths sid = do
  s1 <- entriesSize paths sid
  case s1 of
    Nothing   -> pure Nothing
    Just n1 -> do
      raw <- try (BS.readFile (sessionEntriesPath paths sid))
               :: IO (Either IOException BS.ByteString)
      case raw of
        Left _   -> pure Nothing
        Right bs -> do
          s2 <- entriesSize paths sid
          let v = lastRequestTs (TE.decodeUtf8With lenientDecode bs)
          pure $ case s2 of
            Just n2 | n2 == n1 -> Just (DerivedMeta derivedVersion v n1)
            _                  -> Nothing

-- | The timestamp of the last request-direction entry, rendered by 'renderIso'.
lastRequestTs :: Text -> Maybe Text
lastRequestTs raw = go Nothing (entriesOf raw)
  where
    entriesOf =
      mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
        . filter (not . T.null)
        . T.lines
    go acc [] = fmap renderIso acc
    go acc (e : es) = case erKind e of
      EKRequest -> go (Just (erTimestamp e)) es
      _         -> go acc es

-- | Persist the sidecar. Total: returns 'False' on any failure (absent session
-- directory, unwritable path, failed rename) and never throws. Never creates a
-- directory — an absent session dir is a silent @False@ so a read path can never
-- materialize a session out of nothing.
writeDerived :: SealPaths -> SessionId -> DerivedMeta -> IO Bool
writeDerived paths sid meta = do
  dirOk <- doesDirectoryExist (sessionDir paths sid)
  if not dirOk
    then pure False
    else do
      r <- try (writeAtomic paths sid meta) :: IO (Either IOException ())
      pure (case r of Left _ -> False; Right _ -> True)

-- | Temp file (unique name — a fixed @.tmp@ races concurrent writers, see
-- @Session.Store@'s note) → explicit @0600@ (@openBinaryTempFile@ alone is
-- @0600 & ~umask@) → atomic rename. On any exception the temp file is removed.
writeAtomic :: SealPaths -> SessionId -> DerivedMeta -> IO ()
writeAtomic paths sid meta = do
  let path = sessionDerivedPath paths sid
      dir  = sessionDir paths sid
  (tmp, h) <- openBinaryTempFile dir (takeFileName path <> ".tmp")
  ( do
      BL.hPut h (A.encode meta)
      hClose h
      setFileMode tmp 0o600
      renameFile tmp path
    ) `onException` do
      void (try (hClose h) :: IO (Either IOException ()))
      void (try (removeFile tmp) :: IO (Either IOException ()))
