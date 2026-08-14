{-# LANGUAGE OverloadedStrings #-}
-- | Pure configuration types and retry logic for tool-call timeout/abort/retry.
--
-- This module is pure (no IO) and has no dependency on 'App'/'Env'. The
-- IO-level race wrapper lives in 'Seal.Tools.Exec.Timeout'; this module
-- provides the config types, the 'ToolError' ADT, the per-call timeout
-- extraction (from the LLM-facing JSON, where the @timeout@ field is in
-- SECONDS — converted to microseconds internally via the 'Microseconds'
-- newtype), the retry-delay computation, the retry predicate, and the
-- model-visible error rendering.
--
-- The JSON wire unit is seconds (matching Claude Code / OpenCode); the
-- internal 'Microseconds' newtype carries the unit in the type to prevent
-- micros/seconds confusion across the boundary.
module Seal.Tools.Timeout
  ( Microseconds (..)
  , ToolTimeoutConfig (..)
  , ToolError (..)
  , defaultToolTimeoutConfig
  , extractPerCallTimeout
  , computeRetryDelay
  , shouldRetry
  , errorClass
  , renderToolError
  ) where

import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))

-- | A timeout value in microseconds. The newtype carries the unit in the
-- type to prevent micros/seconds confusion across the JSON boundary (the
-- JSON @timeout@ field is in seconds; this is the internal representation).
newtype Microseconds = Microseconds
  { unMicroseconds :: Int
  } deriving stock (Eq, Ord, Show)

-- | Configuration for tool call timeout/retry behavior. Loaded from
-- @config.toml@ under @[tool_timeout]@ (in 'Seal.Config.File.RuntimeConfig').
data ToolTimeoutConfig = ToolTimeoutConfig
  { ttcDefaultSeconds  :: !Int    -- ^ default per-call timeout (default: 120)
  , ttcMaxSeconds      :: !Int    -- ^ hard cap (default: 600)
  , ttcRetryMax        :: !Int    -- ^ max retry attempts (default: 3)
  , ttcRetryBaseMicros :: !Int   -- ^ base delay between retries (default: 2_000_000 = 2s)
  , ttcRetryFactor     :: !Double -- ^ backoff multiplier (default: 2.0)
  , ttcKillGraceMicros :: !Int   -- ^ SIGTERM→SIGKILL grace period (default: 5_000_000 = 5s)
  , ttcMaxOutputBytes  :: !Int    -- ^ bounded output cap (default: 50_000)
  , ttcAbortPollMicros :: !Int   -- ^ abort-poll interval (default: 100_000 = 100ms)
  } deriving stock (Eq, Show)

-- | The default config — matches the design doc defaults.
defaultToolTimeoutConfig :: ToolTimeoutConfig
defaultToolTimeoutConfig = ToolTimeoutConfig
  { ttcDefaultSeconds  = 120
  , ttcMaxSeconds      = 600
  , ttcRetryMax        = 3
  , ttcRetryBaseMicros = 2_000_000
  , ttcRetryFactor     = 2.0
  , ttcKillGraceMicros = 5_000_000
  , ttcMaxOutputBytes  = 50_000
  , ttcAbortPollMicros = 100_000
  }

-- | The error type for the timeout/abort/retry lifecycle. Kept separate
-- from 'Seal.ISA.Dispatch.DispatchError' (which is about the dispatch
-- decision — op not found, denied, exec failed); 'ToolError' is about
-- the execution lifecycle (timeout, abort, retry). The dispatcher maps
-- 'ToolError' → 'DispatchError (ExecFailed (renderToolError ...))' at the
-- boundary.
data ToolError
  = ToolTimeout Int          -- ^ the timeout that was in effect (seconds, for display)
  | ToolAborted              -- ^ user/session cancellation
  | ToolIOError Text         -- ^ transient IO failure (error class only in audit log — see 'errorClass')
  | ToolRetriesExhausted ToolError  -- ^ wrapper after max retries
  deriving stock (Eq, Show)

-- | Extract the per-call timeout from the tool input JSON. The @timeout@
-- field is in SECONDS (the JSON wire unit; converted to microseconds
-- internally). Validation:
--
--   * absent / null / non-integer (string, float, bool) → default
--   * negative / zero → default
--   * positive > max → clamp to max
--   * positive in [1, max] → as-is (× 1_000_000)
--
-- The output is always in @[1_000_000, max * 1_000_000]@ (1s to max) — never
-- negative, never zero (which would cause an instant-timeout DoS or a
-- @threadDelay@ crash).
extractPerCallTimeout :: Value -> ToolTimeoutConfig -> Microseconds
extractPerCallTimeout input cfg =
  case parseMaybe (A.withObject "input" (A..: "timeout")) input of
    Nothing -> defaultMicros
    Just v -> case A.fromJSON @Int v of
      A.Error _ -> defaultMicros
      A.Success n
        | n <= 0    -> defaultMicros
        | n > maxS  -> maxMicros
        | otherwise -> Microseconds (n * 1_000_000)
  where
    maxS = ttcMaxSeconds cfg
    defaultMicros = Microseconds (ttcDefaultSeconds cfg * 1_000_000)
    maxMicros = Microseconds (maxS * 1_000_000)

-- | Compute the retry delay: @base * factor^attempt@. Pure, overflow-safe
-- (guards against Int overflow at large attempt counts). For @factor >= 1.0@
-- the result is monotonically increasing in the attempt number.
computeRetryDelay :: ToolTimeoutConfig -> Int -> Microseconds
computeRetryDelay cfg attempt =
  let base = fromIntegral (ttcRetryBaseMicros cfg) :: Double
      factor = ttcRetryFactor cfg
      raw = base * factor ^ attempt
      -- Guard against Int overflow: clamp to maxBound if the Double exceeds it.
      clamped = if raw > fromIntegral (maxBound :: Int)
                then maxBound
                else round raw
  in Microseconds clamped

-- | Whether to retry on a given 'ToolError'. Retry only on transient
-- failures (timeout, IO error). Do NOT retry on abort (user cancelled —
-- respect immediately) or on retries-exhausted (already exhausted).
shouldRetry :: ToolError -> Bool
shouldRetry (ToolTimeout _)        = True
shouldRetry (ToolIOError _)         = True
shouldRetry ToolAborted             = False
shouldRetry (ToolRetriesExhausted _) = False

-- | Render the error CLASS for the audit log. Returns ONLY the class
-- string — never the full 'ToolIOError' Text payload (which could contain
-- paths/host info from an IO error). The audit log ('orRecorded') carries
-- this class string; the model-visible error text ('renderToolError') is
-- separate.
errorClass :: ToolError -> Text
errorClass (ToolTimeout _)          = "timeout"
errorClass ToolAborted              = "aborted"
errorClass (ToolIOError _)          = "io"
errorClass (ToolRetriesExhausted _) = "retries_exhausted"

-- | Render a model-visible error message. The timeout value is rendered
-- in seconds (not microseconds) so the model can reason about it. The
-- message is actionable: the timeout case tells the model how to retry
-- with a larger timeout.
renderToolError :: OpName -> ToolError -> Text
renderToolError (OpName name) = \case
  ToolTimeout s ->
    name <> " timed out after " <> T.pack (show s) <> "s. If this command is expected to take longer, retry with a larger timeout value."
  ToolAborted ->
    name <> " was aborted by the user."
  ToolIOError msg ->
    name <> " failed with an IO error: " <> msg
  ToolRetriesExhausted innerErr ->
    name <> " failed after " <> T.pack (show (ttcRetryMax defaultToolTimeoutConfig)) <> " retries (last error: " <> innerRender innerErr <> ")."
  where
    innerRender (ToolTimeout s)    = "timed out after " <> T.pack (show s) <> "s"
    innerRender (ToolIOError m)    = "IO error: " <> m
    innerRender ToolAborted        = "aborted"
    innerRender (ToolRetriesExhausted _) = "retries exhausted"