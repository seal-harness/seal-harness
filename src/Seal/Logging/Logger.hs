{-# LANGUAGE OverloadedStrings #-}
-- | The shared logger handle for Seal Harness. Wraps a katip 'LogEnv' and
-- provides 'IO'-level logging functions ('logIO') so that channel, transport,
-- and gateway code (which runs in 'IO', not 'App') can emit structured katip
-- logs without a monad transformer stack.
--
-- The logger is built once at startup via 'withSealLogger' (a bracket that
-- closes the scribe on exit) and threaded through the shared dependency
-- records ('ChannelDeps', 'SendDeps') and 'Env' ('envLogger'). Turn code
-- refines the logger via 'withChannelContext' to attach 'ChannelContext'
-- (channel kind, conversation id hash, session id) so every 'logIO' call
-- within a turn automatically carries the metadata — context-free logging
-- is never the easy path within a turn.
--
-- 'logIO' is best-effort: if the scribe write throws (e.g. closed handle,
-- I/O error), the error is silently swallowed. The logger must never crash
-- the caller, especially inside 'withExceptionLogging' where a logger crash
-- would defeat the exception handler. Newlines in the 'LogStr' are escaped
-- to @\\n@ / @\\r@ before emission (log-injection defense).
module Seal.Logging.Logger
  ( SealLogger (..)
  , withSealLogger
  , newSealLogger
  , newSealLoggerWithScribe
  , closeSealLogger
  , testSealLogger
  , logIO
  , withChannelContext
  , escapeNewlines
  ) where

import Control.Exception (catch, SomeException, bracket)
import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (stderr)

import Katip
  ( Severity (..), LogEnv, LogContexts, Namespace, Scribe (..)
  , LogStr, unLogStr, permitItem, mkHandleScribeWithFormatter, bracketFormat
  , registerScribe, defaultScribeSettings, initLogEnv
  , closeScribes, textToSeverity, runKatipContextT
  , liftPayload
  )
import qualified Katip as K
import Katip.Monadic (logFM)

-- | The shared logger handle. Built once at startup, threaded through
-- 'ChannelDeps', 'SendDeps', and 'Env'. Carries its own 'LogEnv' + context
-- + namespace so 'logIO' can emit from 'IO' without a monad stack.
data SealLogger = SealLogger
  { slLogEnv    :: LogEnv
  , slContext   :: LogContexts
  , slNamespace :: Namespace
  }

-- | Bracket the logger's lifetime. Creates the stderr scribe at the given
-- severity level, runs the action, closes the scribe on exit. Used at all
-- 4 startup sites ('runServeMain', 'runSignalMain', 'runTelegramMain',
-- 'runTui').
withSealLogger :: Text -> (SealLogger -> IO a) -> IO a
withSealLogger logLevel = bracket makeLogEnv' closeLogEnv'
  where
    makeLogEnv' = do
      let sev = fromMaybe InfoS (textToSeverity logLevel)
      scribe <- mkHandleScribeWithFormatter bracketFormat
        K.ColorIfTerminal stderr (permitItem sev) K.V2
      le <- registerScribe "stderr" scribe defaultScribeSettings
        =<< initLogEnv "seal-harness" "production"
      pure SealLogger
        { slLogEnv = le
        , slContext = mempty
        , slNamespace = "seal-harness"
        }
    closeLogEnv' logger = void (closeScribes (slLogEnv logger))

-- | Build a logger without a bracket (for tests). The caller is responsible
-- for closing the scribe via 'closeSealLogger' (or process exit).
newSealLogger :: Text -> IO SealLogger
newSealLogger logLevel = do
  let sev = fromMaybe InfoS (textToSeverity logLevel)
  scribe <- mkHandleScribeWithFormatter bracketFormat
    K.ColorIfTerminal stderr (permitItem sev) K.V2
  le <- registerScribe "stderr" scribe defaultScribeSettings
    =<< initLogEnv "seal-harness" "production"
  pure SealLogger
    { slLogEnv = le
    , slContext = mempty
    , slNamespace = "seal-harness"
    }

-- | Build a logger with a custom scribe (for tests that capture log output).
-- The scribe is registered with the given permit severity.
newSealLoggerWithScribe :: Scribe -> Severity -> IO SealLogger
newSealLoggerWithScribe scribe _sev = do
  le <- registerScribe "capture" scribe defaultScribeSettings
    =<< initLogEnv "seal-harness" "test"
  pure SealLogger
    { slLogEnv = le
    , slContext = mempty
    , slNamespace = "seal-harness"
    }

-- | Close the logger's scribes (for non-bracket construction).
closeSealLogger :: SealLogger -> IO ()
closeSealLogger logger = void (closeScribes (slLogEnv logger))

-- | A logger with a no-op scribe (for tests that don't assert log output).
-- Uses a scribe that accepts all items but does nothing with them.
testSealLogger :: IO SealLogger
testSealLogger = do
  let noopScribe = Scribe
        { liPush = \_ -> pure ()
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  newSealLoggerWithScribe noopScribe DebugS

-- | Emit a log line from 'IO'. Uses the logger's 'LogEnv' + context +
-- namespace. Newlines in the 'LogStr' are escaped to @\\n@ / @\\r@ before
-- emission (log-injection defense). If the scribe write throws, the error
-- is silently swallowed (best-effort logging — the logger must never crash
-- the caller).
logIO :: SealLogger -> Severity -> LogStr -> IO ()
logIO logger sev msg =
  runKatipContextT (slLogEnv logger) (slContext logger)
    (slNamespace logger) (logFM sev (escapeNewlines msg))
  `catch` \(_ :: SomeException) -> pure ()

-- | Refine the logger with additional structured context. Returns a new
-- 'SealLogger' whose 'slContext' is the merge
-- @slContext <> liftPayload item@. This is how 'ChannelContext' is
-- attached: the turn code calls @withChannelContext logger ctx@ once, then
-- threads the refined logger through all subsequent 'logIO' calls.
withChannelContext :: K.LogItem a => SealLogger -> a -> SealLogger
withChannelContext logger item =
  logger { slContext = slContext logger <> liftPayload item }

-- | Escape newlines in a 'LogStr' to prevent log injection. Replaces @\n@
-- with @\\n@ and @\r@ with @\\r@ in the textual representation.
escapeNewlines :: LogStr -> LogStr
escapeNewlines = K.ls . escapeText . T.pack . show . unLogStr
  where
    escapeText :: Text -> Text
    escapeText = T.replace "\n" "\\n" . T.replace "\r" "\\r"