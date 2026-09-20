{-# LANGUAGE OverloadedStrings #-}
-- | A custom hspec formatter that wraps the built-in @specdoc@ formatter
-- and collects per-test-case timing information. At the end of the run,
-- it prints a "Slowest test cases" summary to stderr and writes a
-- machine-readable timing report to @test-timings.txt@ in the current
-- directory.
--
-- This exists because CI on @aarch64-darwin@ hung for over an hour with
-- no visibility into which test cases were running or how long they took.
-- With per-item timing data, we can:
--
--   * Identify which test (or group of tests) is slow or hung.
--   * Maintain test suite efficiency by tracking slow tests over time.
--   * Surface the data in the GitHub Actions job summary for quick
--     triage without downloading raw logs.
--
-- The @test-timings.txt@ write is best-effort: if the CWD is read-only
-- (e.g. the Nix store), the file write is skipped silently.
--
-- The formatter wraps 'specdoc' (the default human-readable formatter)
-- so all existing output is preserved — the timing summary is additional.
module Seal.TestHelpers.TimingFormatter
  ( timingFormatter
  , TimingEntry (..)
  ) where

import Control.Concurrent.STM
import Control.Monad (forM_, unless)
import Control.Exception (SomeException, try)
import Data.List (sortBy)
import Data.Ord (comparing, Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Test.Hspec.Core.Format (Format, FormatConfig, Event (..), Item (..), Result (..), Seconds (..))
import Test.Hspec.Core.Formatters.V2 (formatterToFormat, specdoc)

-- | One row of timing data: the test path, its duration in seconds,
-- and its result (success\/pending\/failure).
data TimingEntry = TimingEntry
  { tePath :: !Text
  , teDuration :: !Double
  , teResult :: !Char
  }

-- | A 'Format' that delegates to 'specdoc' for human-readable output,
-- collects per-item durations into a 'TVar', and on 'Done' prints the
-- slowest-N summary and writes @test-timings.txt@.
--
-- The number of slow items shown defaults to 20 but can be overridden
-- via the @SEAL_TEST_SLOW_COUNT@ environment variable.
timingFormat :: TVar [TimingEntry] -> Int -> FormatConfig -> IO Format
timingFormat ref slowCount cfg = do
  baseFormat <- formatterToFormat specdoc cfg
  pure $ \event -> do
    -- Always delegate to the base formatter first for normal output.
    baseFormat event
    case event of
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
        atomically $ modifyTVar' ref (entry :)
      Done _allItems -> do
        entries <- readTVarIO ref
        let sorted = sortBy (comparing (Down . teDuration)) entries
            topN = take slowCount sorted
        unless (null topN) $ do
          hPutStrLn stderr ""
          hPutStrLn stderr "=== Slowest test cases ==="
          forM_ (zip [1 :: Int ..] topN) $ \(i, e) ->
            hPutStrLn stderr (formatTimingLine i e)
          hPutStrLn stderr ""
        -- Write machine-readable timing file for CI to consume.
        -- Best-effort: if the CWD is read-only (e.g. nix store), skip
        -- the file write — the stderr summary is still emitted above.
        let timingText = T.unlines
              ( "rank\tduration_secs\tresult\ttest_path"
              : [ T.pack (show i) <> "\t" <> T.pack (show (teDuration e))
                    <> "\t" <> T.singleton (teResult e) <> "\t" <> tePath e
                | (i, e) <- zip [1 :: Int ..] sorted
                ]
              )
        _ <- try @SomeException (TIO.writeFile "test-timings.txt" timingText)
        pure ()
      _ -> pure ()

-- | Construct the timing 'Format' factory for use with
-- 'configFormat'. This is the public entry point.
--
-- Usage in @test/Main.hs@:
--
-- @
-- import Seal.TestHelpers.TimingFormatter (timingFormatter)
--
-- main :: IO ()
-- main = do
--   fmt <- timingFormatter
--   withNoLeakedSshAgents $
--     hspecWith defaultConfig { configFormat = Just fmt } $ ...
-- @
timingFormatter :: IO (FormatConfig -> IO Format)
timingFormatter = do
  ref <- newTVarIO []
  timingFormat ref <$> getSlowCount

-- | Read the number of slow items to show from the environment, default 20.
getSlowCount :: IO Int
getSlowCount = do
  mVal <- lookupEnv "SEAL_TEST_SLOW_COUNT"
  case mVal of
    Nothing -> pure 20
    Just s -> case readMaybe s of
      Just n | n > 0 -> pure n
      _ -> pure 20

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
