{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
-- | Regression tests for the incremental entry broadcast (issue #198).
--
-- 'Seal.Core.TurnEngine.broadcastNewEntries' historically re-read the
-- ENTIRE transcript from disk on every recorded entry and fanned out every
-- entry as 'BeEntryRecorded'. Within a turn that hook fires once per
-- entry (user message, each response, each tool-result continuation), so
-- a turn with N entries broadcasts O(N²) entry events — the Telegram chat
-- channel saw the full transcript re-arrive after every tool call,
-- re-editing its streaming bubble with stale text (the "infinite loop"
-- churn in output.log). The web frontend dedupes by id so it hid the
-- redundancy; bandwidth + non-deduping subscribers paid for it.
--
-- The fix: a per-session broadcast cursor in the broker.
-- 'takeNewEntries' drops the already-broadcast prefix and advances the
-- cursor so each call fans out only the new tail. A cursor ahead of the
-- transcript length (e.g. after a session rebuild) clamps to zero and
-- resends everything — subscribers see an idempotent replay rather than
-- silently missing entries.
module Seal.Gateway.EntryCursorSpec (spec) where

import Control.Concurrent.STM (readTVarIO)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Core.TurnEngine (broadcastNewEntries)
import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Gateway.StreamBroker
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))

mkSid :: T.Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

-- | A transcript-shaped list for the cursor: positional index + the
-- frontend entry JSON. Only the id matters to the assertions; the cursor
-- itself is positional.
entries :: Int -> [(Int, Value)]
entries n = [(i, object ["id" .= T.pack (show i)]) | i <- [0 .. n - 1]]

-- | Extract the @id@ string from a frontend entry JSON (for assertions).
entryId :: Value -> Maybe T.Text
entryId (A.Object o) = case KM.lookup (Key.fromText "id") o of
  Just (A.String t) -> Just t
  _                 -> Nothing
entryId _ = Nothing

-- | The fixed epoch used by the on-disk fixtures below.
epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 0)

-- | A two-file-transcript 'EntryRecord' (the shape the agent loop writes).
mkEntry :: EntryKind -> Int -> EntryRecord
mkEntry kind len = EntryRecord
  { erId = ""
  , erTimestamp = epoch
  , erKind = kind
  , erConvLen = len
  , erEnvelope = Nothing
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = mempty
  }

spec :: Spec
spec = do
  describe "Seal.Gateway.StreamBroker.takeNewEntries" $ do
    it "first broadcast sends the whole transcript and records the count" $ do
      broker <- newStreamBroker 10
      new <- takeNewEntries broker (mkSid "a") (entries 3)
      length new `shouldBe` 3
      mapM_ (\(i, v) -> entryId v `shouldBe` Just (T.pack (show i))) new
      cursor <- readEntryCursor broker (mkSid "a")
      cursor `shouldBe` 3

    it "second broadcast after one new entry sends ONLY the new entry" $ do
      broker <- newStreamBroker 10
      _ <- takeNewEntries broker (mkSid "a") (entries 3)
      new <- takeNewEntries broker (mkSid "a") (entries 4)
      map fst new `shouldBe` [3]
      mapM_ (\(_, v) -> entryId v `shouldBe` Just "3") new

    it "broadcast with no new entries sends nothing" $ do
      broker <- newStreamBroker 10
      _ <- takeNewEntries broker (mkSid "a") (entries 3)
      new <- takeNewEntries broker (mkSid "a") (entries 3)
      new `shouldBe` []

    it "cursors are per-session: growth in one session does not affect another" $ do
      broker <- newStreamBroker 10
      _ <- takeNewEntries broker (mkSid "a") (entries 3)
      newB <- takeNewEntries broker (mkSid "b") (entries 2)
      map fst newB `shouldBe` [0, 1]
      curA <- readEntryCursor broker (mkSid "a")
      curA `shouldBe` 3

    it "cursor ahead of the transcript clamps to zero and resends everything" $ do
      broker <- newStreamBroker 10
      _ <- takeNewEntries broker (mkSid "a") (entries 6)
      -- The transcript "shrank" (rebuilt session): everything must resend
      -- rather than silently skipping entries the broker thinks were sent.
      new <- takeNewEntries broker (mkSid "a") (entries 2)
      map fst new `shouldBe` [0, 1]
      cursor <- readEntryCursor broker (mkSid "a")
      cursor `shouldBe` 2

    it "readEntryCursor on an unknown session is zero (never broadcast)" $ do
      broker <- newStreamBroker 10
      cursor <- readEntryCursor broker (mkSid "never-seen")
      cursor `shouldBe` 0

    it "the cursor map only tracks sessions that have broadcast" $ do
      broker <- newStreamBroker 10
      _ <- takeNewEntries broker (mkSid "a") (entries 2)
      m <- readTVarIO (sbEntryCursors broker)
      Map.keys m `shouldBe` [mkSid "a"]
      Map.lookup (mkSid "a") m `shouldBe` Just 2

    it "end-to-end shape: per-entry broadcasts within one turn never repeat an entry" $ do
      -- The regression shape from output.log: within one turn, aeOnEntry
      -- fires after every recorded entry (user msg, response, tool result,
      -- next response, ...). Successive takeNewEntries + broadcast calls
      -- with a growing transcript must deliver each entry exactly once —
      -- linear volume, ascending order, no duplicates.
      broker <- newStreamBroker 10
      seen <- newIORef ([] :: [T.Text])
      _ <- subscribe broker (mkSid "a")
             (\case
                 BeEntryRecorded _ v ->
                   modifyIORef' seen (\acc -> maybe acc (: acc) (entryId v))
                 _ -> pure ())
             (pure ())
      let send n = do
            new <- takeNewEntries broker (mkSid "a") (entries n)
            mapM_ (\(_, v) -> broadcast broker (BeEntryRecorded (mkSid "a") v)) new
      mapM_ send [1 .. 5]
      got <- reverse <$> readIORef seen
      got `shouldBe` ["0", "1", "2", "3", "4"]

  describe "Seal.Core.TurnEngine.broadcastNewEntries (issue #198 regression)" $ do
    it "per-entry hook firings within a turn deliver each entry exactly once" $ do
      withSystemTempDirectory "seal-cursor" $ \stateDir -> do
        let paths = SealPaths
              { spHome = stateDir, spConfig = stateDir, spState = stateDir
              , spKeys = stateDir </> "keys", spCache = stateDir </> "cache" }
            sid = mkSid "20260701-120000-042"
            sdir = sessionDir paths sid
        createDirectoryIfMissing True sdir
        -- conversation.jsonl: 4 messages (user, assistant, tool-result,
        -- assistant) — the tool-call turn shape from output.log.
        let convLine :: Message -> BL.ByteString
            convLine m = A.encode m <> "\n"
        BC.writeFile (sdir </> "conversation.jsonl")
          (BL.toStrict (mconcat (map convLine
            [ Message User [CbText "Telegram test 2"]
            , Message Assistant [CbText "reply 1"]
            , Message User [CbText "tool result"]
            , Message Assistant [CbText "reply 2"]
            ])))
        -- entries.jsonl: the exact issue-198 sequence (request, response,
        -- request, response — each convLen marking the cumulative end).
        let entryLine :: EntryRecord -> BL.ByteString
            entryLine e = A.encode e <> "\n"
        BC.writeFile (sdir </> "entries.jsonl")
          (BL.toStrict (mconcat (map entryLine
            [ mkEntry EKRequest 1
            , mkEntry EKResponse 2
            , mkEntry EKRequest 3
            , mkEntry EKResponse 4
            ])))
        broker <- newStreamBroker 10
        seen <- newIORef ([] :: [Int])
        _ <- subscribe broker sid
               (\case
                   BeEntryRecorded _ v -> case entryId v of
                     Just t -> modifyIORef' seen (read (T.unpack t) :)
                     Nothing -> pure ()
                   _ -> pure ())
               (pure ())
        -- Fire the hook the way the agent loop does: after EVERY recorded
        -- entry. Each firing reads the (unchanged) transcript from disk —
        -- the pre-fix code re-broadcast all 4 entries on every firing.
        mapM_ (\_ -> broadcastNewEntries (Just broker) paths sid "" epoch)
              [1 .. 4 :: Int]
        got <- reverse <$> readIORef seen
        -- Each entry broadcast exactly once: linear, no repeats. The
        -- pre-fix behavior delivered [0,1,0,1,2,0,1,2,3,0,1,2,3] (14 events).
        got `shouldBe` [0, 1, 2, 3]
        cursor <- readEntryCursor broker sid
        cursor `shouldBe` 4
