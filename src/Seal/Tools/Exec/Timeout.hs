-- | The IO-level three-way race + retry wrapper for tool-call timeout/abort.
--
-- This module is the core of the tool-call-timeout-abort-retry mechanism.
-- It is IO-level (no 'App'/'Env' dependency) — the 'App'→'IO' bridge is at
-- the dispatch call site (design Blocker Resolution #1): the dispatcher
-- captures the 'Env' via 'ask', then re-enters 'App' inside the worker
-- thread via @runApp env (uoRun ...)@. The wrapper itself never imports
-- 'Seal.Types.App' — this keeps the race logic testable without a full
-- 'AppEnv'.
--
-- = The three-way race (worker vs timeout vs abort-poll)
--
-- Per-attempt, three 'IO' actions race (via nested 'race'):
--
-- @
-- (worker vs timeoutDelay) vs waitForAbort pollInterval
-- @
--
-- Nesting order: abort wins over timeout (user intent > resource limit). On
-- the worker winning: return the result. On timeout: 'cancel' the worker
-- (which triggers the 'withManagedProcess' bracket cleanup → process-group
-- kill), return 'ToolTimeout'. On abort: 'cancel' the worker, return
-- 'ToolAborted'.
--
-- = Retry logic
--
-- Retry only on 'ToolTimeout' and 'ToolIOError' (transient). Do NOT retry on
-- 'ToolAborted' (user cancelled — respect immediately) or on 'Right'
-- results (success is success, even if the opcode returned a semantic error
-- — that's not a transport failure). Up to 'ttcRetryMax' attempts,
-- exponential backoff via 'computeRetryDelay'. The loop checks 'isAborted'
-- BEFORE sleeping and AFTER sleeping (before the next attempt) so an abort
-- during the retry sleep is detected promptly (design PM question).
module Seal.Tools.Exec.Timeout
  ( runWithTimeoutAbortRetry
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
  ( Async, async, cancel, race, wait, waitCatch )
import Control.Exception (IOException, try)

import Seal.Tools.Exec.Abort (AbortFlag, isAborted)
import Seal.Tools.Timeout
  ( Microseconds (..), ToolError (..), ToolTimeoutConfig
  , computeRetryDelay, shouldRetry, ttcAbortPollMicros, ttcRetryMax
  )

-- | Run an IO action with timeout + abort + retry protection.
--
--   * @cfg@ — the timeout/retry config (default, max, retry count, backoff).
--   * @flag@ — the session abort flag (polled during the race).
--   * @timeout@ — the per-call timeout (microseconds, already clamped by
--     'Seal.Tools.Timeout.extractPerCallTimeout').
--   * @action@ — the opcode action, bridged from 'App' at the call site
--     (via @runApp env (...)@). Returns 'Either ToolError a' — 'Right' for
--     success (including semantic errors), 'Left' for transport failures.
--
-- Returns 'Right a' on success, 'Left ToolError' on timeout/abort/IO-failure
-- (wrapped in 'ToolRetriesExhausted' after 'ttcRetryMax' attempts).
runWithTimeoutAbortRetry
  :: forall a
   . ToolTimeoutConfig
  -> AbortFlag
  -> Microseconds
  -> IO (Either ToolError a)
  -> IO (Either ToolError a)
runWithTimeoutAbortRetry cfg flag (Microseconds timeoutUs) action = go 0
  where
    go :: Int -> IO (Either ToolError a)
    go attempt = do
      -- Check-before-attempt: if already aborted, return immediately.
      aborted <- isAborted flag
      if aborted
        then pure (Left ToolAborted)
        else do
          -- Run the three-way race: worker vs timeout vs abort-poll.
          result <- raceThreeWay cfg flag timeoutUs action
          case result of
            Right _ -> pure result  -- success (or semantic error) — return immediately, no retry
            Left err
              | not (shouldRetry err) -> pure result  -- ToolAborted or already-exhausted
              | attempt + 1 >= ttcRetryMax cfg ->
                  -- Exhausted retries.
                  pure (Left (ToolRetriesExhausted err))
              | otherwise -> do
                  -- Check-before-sleep: abort during the sleep window?
                  preSleep <- isAborted flag
                  if preSleep
                    then pure (Left ToolAborted)
                    else do
                      let Microseconds delayUs = computeRetryDelay cfg attempt
                      threadDelay delayUs
                      -- Check-after-sleep: abort during the sleep?
                      postSleep <- isAborted flag
                      if postSleep
                        then pure (Left ToolAborted)
                        else go (attempt + 1)

-- | The three-way race: worker vs timeout vs abort-poll.
--
-- Nesting: @(worker-vs-timeout) vs abort-poll@. Abort wins over timeout
-- (user intent > resource limit). On the worker winning: return its
-- result. On timeout: the worker async is cancelled (triggering the
-- 'withManagedProcess' bracket cleanup → process-group kill) and we return
-- 'ToolTimeout'. On abort: the worker async is cancelled and we return
-- 'ToolAborted'.
raceThreeWay
  :: forall a
   . ToolTimeoutConfig
  -> AbortFlag
  -> Int  -- ^ timeout (microseconds)
  -> IO (Either ToolError a)
  -> IO (Either ToolError a)
raceThreeWay cfg flag timeoutUs action = do
  worker <- async action
  -- Outer race: (worker-vs-timeout) vs abort-poll.
  -- `race a b` returns Left if `a` wins, Right if `b` wins.
  outer <- race
    (race (wait worker) (threadDelay timeoutUs))  -- inner: Left=worker, Right=timeout
    (abortPoll (ttcAbortPollMicros cfg))
  case outer of
    -- Inner race (worker-vs-timeout) won first.
    Left inner -> case inner of
      Left r -> pure r  -- worker completed: return its result
      Right () -> do
        -- Timeout: cancel the worker (bracket cleanup → process-group kill),
        -- wait for cleanup to finish (bounded by reapBounded's 1s),
        -- return ToolTimeout (seconds for display).
        cancelWorker worker
        pure (Left (ToolTimeout (timeoutUs `div` 1_000_000)))
    -- Abort-poll won first: cancel the worker, return ToolAborted.
    Right _aborted -> do
      cancelWorker worker
      pure (Left ToolAborted)
  where
    -- The abort-poll: loop checking isAborted every @pollUs@ microseconds.
    -- Returns True when aborted (so the outer race's Right branch fires).
    abortPoll :: Int -> IO Bool
    abortPoll pollUs = do
      let loop = do
            a <- isAborted flag
            if a then pure True else do threadDelay pollUs; loop
      loop

-- | Cancel a worker async + wait for its bracket cleanup to finish. The
-- cleanup (killProcessGroup + bounded reap) is bounded, so this returns
-- promptly; the @try@ swallows any async-exception IO errors.
cancelWorker :: Async a -> IO ()
cancelWorker worker = do
  cancel worker
  _ <- try @IOException (waitCatch worker)
  pure ()