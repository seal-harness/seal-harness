{-# LANGUAGE OverloadedStrings #-}
-- | A custom hspec formatter that wraps the built-in @specdoc@ formatter
-- and collects per-test-case timing information with **streaming
-- output** — every completed test is written to @test-timings.txt@
-- immediately, and a heartbeat logs the currently-running test
-- periodically. This ensures that if the test process is killed (e.g.
-- CI timeout while a test is hung), the timing data collected so far
-- is already on disk and the last-running test is identifiable.
--
-- This exists because CI on @aarch64-darwin@ hung for over an hour with
-- no visibility into which test cases were running or how long they took.
-- A batch-write-at-the-end approach would be useless in exactly that
-- scenario — the @Done@ event never fires. The streaming design ensures:
--
--   * @test-timings.txt@ is appended to after every test completion —
--     partial data survives a kill.
--   * A heartbeat on stderr logs the currently-running test every 10s,
--     so a hang is visible in the raw log without any file.
--   * @currently-running.txt@ records the test that was executing when
--     the process was killed (written on @ItemStarted@, cleared on
--     @ItemDone@).
--   * At the end of a successful run, a sorted "Slowest test cases"
--     summary is printed to stderr for quick scanning.
--
-- The @test-timings.txt@ and @currently-running.txt@ writes are
-- best-effort: if the CWD is read-only (e.g. the Nix store), the file
-- writes are skipped silently — the stderr output still provides
-- visibility.
--
-- The formatter wraps 'specdoc' (the default human-readable formatter)
-- so all existing output is preserved — the timing output is additional.
module Seal.TestHelpers.TimingFormatter
  ( timingFormatter
  , TimingEntry (..)
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless, void, when)
import Data.IORef
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.Clock (getMonotonicTime)
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Test.Hspec.Core.Format
  ( Event (..)
  , Format
  , FormatConfig (..)
  , Item (..)
  , Result (..)
  , Seconds (..)
  )
import Test.Hspec.Core.Formatters.V2 (formatterToFormat, specdoc)

-- | One row of timing data: the test path, its duration in seconds,
-- and its result (success\/pending\/failure).
data TimingEntry = TimingEntry
  { tePath :: !Text
  , teDuration :: !Double
  , teResult :: !Char
  }

-- | Mutable state shared between the formatter and the heartbeat thread.
data TimingState = TimingState
  { tsEntries :: !(TVar [TimingEntry])
    -- ^ Completed test entries (newest first).
  , tsCurrent :: !(TVar (Maybe Text))
    -- ^ The currently-running test path (Nothing if idle).
  , tsCurrentStart :: !(TVar Double)
    -- ^ Monotonic start time of the current test (seconds since run start).
  , tsRunStart :: !(IORef Double)
    -- ^ Wall-clock start time of the entire test run.
  , tsCount :: !(TVar Int)
    -- ^ Number of tests completed so far (for progress display).
  , tsExpectedTotal :: !(TVar Int)
    -- ^ Expected total test count (from config, 0 if unknown).
  }

-- | A 'Format' that delegates to 'specdoc' for human-readable output,
-- streams per-item timing data to @test-timings.txt@ as each test
-- completes, runs a heartbeat thread for hang detection, and prints
-- a sorted summary at the end.
--
-- The number of slow items shown defaults to 20 but can be overridden
-- via the @SEAL_TEST_SLOW_COUNT@ environment variable. The heartbeat
-- interval defaults to 10 seconds but can be overridden via
-- @SEAL_TEST_HEARTBEAT_SECS@.
timingFormat :: TimingState -> Int -> Int -> FormatConfig -> IO Format
timingFormat st slowCount heartbeatSecs cfg = do
  baseFormat <- formatterToFormat specdoc cfg
  -- Start the heartbeat thread.
  hbTid <- forkIO (heartbeat st heartbeatSecs)
  -- Write the TSV header to test-timings.txt (best-effort).
  _ <- try @SomeException $ TIO.writeFile "test-timings.txt"
    "duration_secs\tresult\ttest_path\n"
  pure $ \event -> do
    -- Always delegate to the base formatter first for normal output.
    baseFormat event
    case event of
      Started ->
        atomically $ writeTVar (tsExpectedTotal st)
          (formatConfigExpectedTotalCount cfg)
      ItemStarted path -> do
        let p = formatPath path
        now <- getMonotonicSeconds st
        atomically $ do
          writeTVar (tsCurrent st) (Just p)
          writeTVar (tsCurrentStart st) now
        -- Write currently-running.txt so it survives a kill.
        _ <- try @SomeException $ TIO.writeFile "currently-running.txt" p
        pure ()
      ItemDone path item -> do
        let dur = case itemDuration item of Seconds d -> d
            result = case itemResult item of
              Success -> '.'
              Pending{} -> 'p'
              Failure{} -> 'F'
            entry = TimingEntry
              { tePath = formatPath path
              , teDuration = dur
              , teResult = result
              }
        atomically $ do
          modifyTVar' (tsEntries st) (entry :)
          modifyTVar' (tsCount st) (+ 1)
          writeTVar (tsCurrent st) Nothing
        -- Stream this test's timing to the file immediately.
        appendTimingFile entry
        -- Clear currently-running.txt.
        _ <- try @SomeException $ TIO.writeFile "currently-running.txt" ""
        -- Log slow tests inline (> 1s) for immediate visibility.
        when (dur >= 1.0) $
          hPutStrLn stderr $ "  [slow] " <> formatDuration dur <> "  ["
            <> [result] <> "]  " <> T.unpack (tePath entry)
      Done _allItems -> do
        killThread hbTid
        -- Clear currently-running.txt on successful completion.
        _ <- try @SomeException $ TIO.writeFile "currently-running.txt" ""
        entries <- readTVarIO (tsEntries st)
        let sorted = sortBy (comparing (Down . teDuration)) entries
            topN = take slowCount sorted
        unless (null topN) $ do
          hPutStrLn stderr ""
          hPutStrLn stderr "=== Slowest test cases ==="
          forM_ (zip [1 :: Int ..] topN) $ \(i, e) ->
            hPutStrLn stderr (formatTimingLine i e)
          hPutStrLn stderr ""
      _ -> pure ()

-- | Background thread that logs the currently-running test every
-- @heartbeatSecs@ seconds. If no test is running, it's silent. This
-- makes hangs visible in the raw CI log even if no file is written.
heartbeat :: TimingState -> Int -> IO ()
heartbeat st interval = loop
  where
    loop = do
      threadDelay (interval * 1_000_000)
      mPath <- readTVarIO (tsCurrent st)
      case mPath of
        Nothing -> pure ()
        Just p -> do
          start <- readTVarIO (tsCurrentStart st)
          now <- getMonotonicSeconds st
          let elapsed = now - start
          count <- readTVarIO (tsCount st)
          total <- readTVarIO (tsExpectedTotal st)
          let progress = if total > 0
                then printf " (%d/%d)" count total
                else printf " (%d)" count
          hPutStrLn stderr $ "  [heartbeat] " <> formatDuration elapsed
            <> " running" <> progress <> "  "
            <> T.unpack p
          hFlush stderr
      loop

-- | Append one timing row to @test-timings.txt@ (best-effort).
appendTimingFile :: TimingEntry -> IO ()
appendTimingFile entry =
  void $ try @SomeException $ TIO.appendFile "test-timings.txt" line
  where
    line = T.pack (show (teDuration entry)) <> "\t"
      <> T.singleton (teResult entry) <> "\t"
      <> tePath entry <> "\n"

-- | Get a monotonic time in seconds relative to the test run start.
getMonotonicSeconds :: TimingState -> IO Double
getMonotonicSeconds st = do
  start <- readIORef (tsRunStart st)
  now <- getMonotonicTime
  pure (now - start)

-- | Construct the timing 'Format' factory for use with
-- 'configFormat'. This is the public entry point.
timingFormatter :: IO (FormatConfig -> IO Format)
timingFormatter = do
  entries <- newTVarIO []
  current <- newTVarIO Nothing
  currentStart <- newTVarIO 0
  runStart <- getMonotonicTime >>= newIORef
  count <- newTVarIO 0
  expectedTotal <- newTVarIO 0
  let st = TimingState
        { tsEntries = entries
        , tsCurrent = current
        , tsCurrentStart = currentStart
        , tsRunStart = runStart
        , tsCount = count
        , tsExpectedTotal = expectedTotal
        }
  slowCount <- getSlowCount
  timingFormat st slowCount <$> getHeartbeatSecs

-- | Read the number of slow items to show from the environment, default 20.
getSlowCount :: IO Int
getSlowCount = do
  mVal <- lookupEnv "SEAL_TEST_SLOW_COUNT"
  case mVal of
    Nothing -> pure 20
    Just s -> case readMaybe s of
      Just n | n > 0 -> pure n
      _ -> pure 20

-- | Read the heartbeat interval (seconds) from the environment, default 10.
getHeartbeatSecs :: IO Int
getHeartbeatSecs = do
  mVal <- lookupEnv "SEAL_TEST_HEARTBEAT_SECS"
  case mVal of
    Nothing -> pure 10
    Just s -> case readMaybe s of
      Just n | n > 0 -> pure n
      _ -> pure 10

-- | Format a 'Path' as a single text string: @Group1 > Group2 > test name@.
formatPath :: ([String], String) -> Text
formatPath (groups, name) =
  T.intercalate " > " (map T.pack groups <> [T.pack name])

-- | Format one line of the slowest-tests summary.
formatTimingLine :: Int -> TimingEntry -> String
formatTimingLine rank entry =
  T.unpack $ T.pack (show rank) <> ". "
    <> T.pack (formatDuration (teDuration entry))
    <> "  ["
    <> T.singleton (teResult entry)
    <> "]  "
    <> tePath entry

-- | Format a duration in seconds as a human-readable string:
-- @1.234s@, @12.5s@, @2m03.00s@, @1h30m05.00s@.
formatDuration :: Double -> String
formatDuration secs
  | secs < 60 = printf "%.3fs" secs
  | secs < 3600 =
      let mins = floor (secs / 60) :: Int
          rest = secs - fromIntegral mins * 60
      in printf "%dm%05.2fs" mins rest
  | otherwise =
      let hrs = floor (secs / 3600) :: Int
          rest = secs - fromIntegral hrs * 3600
          mins = floor (rest / 60) :: Int
          secs' = rest - fromIntegral mins * 60
      in printf "%dh%02dm%05.2fs" hrs mins secs'
