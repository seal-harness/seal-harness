-- | Process-global logger ref for library modules that don't have a
-- 'SealLogger' threaded through their dependencies (e.g. 'Seal.Tabs',
-- 'Seal.Handles.Transcript', 'Seal.Web.UiState'). Set once at startup via
-- 'setGlobalLogger'; read via 'globalLogIO'. This avoids threading the
-- logger through dozens of function signatures in deep library code.
--
-- The primary logging path is the threaded 'SealLogger' (via 'ChannelDeps',
-- 'SendDeps', 'Env'). This global ref is a fallback for modules that are
-- called from many call sites and can't easily receive the logger as a
-- parameter. If 'setGlobalLogger' has not been called, 'globalLogIO' is a
-- no-op (best-effort — the logger must never crash the caller).
module Seal.Logging.Global
  ( setGlobalLogger
  , globalLogIO
  ) where

import Control.Exception (catch, SomeException)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)

import Seal.Logging.Logger (SealLogger, logIO)

import Katip (Severity (..), LogStr)

-- | The process-global logger ref. Initialized to 'Nothing' (no-op).
-- Set once at startup via 'setGlobalLogger'.
globalLoggerRef :: IORef (Maybe SealLogger)
globalLoggerRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE globalLoggerRef #-}

-- | Set the process-global logger. Called once at startup (in
-- 'Seal.AppMain.dispatch', inside the 'withSealLogger' bracket).
setGlobalLogger :: SealLogger -> IO ()
setGlobalLogger = writeIORef globalLoggerRef . Just

-- | Emit a log line via the process-global logger. If no logger has been
-- set (e.g. in tests that don't call 'setGlobalLogger'), this is a no-op.
-- Best-effort: if the logger throws, the error is silently swallowed.
globalLogIO :: Severity -> LogStr -> IO ()
globalLogIO sev msg = do
  mLogger <- readIORef globalLoggerRef
  case mLogger of
    Nothing    -> pure ()
    Just logger -> logIO logger sev msg
      `catch` \(_ :: SomeException) -> pure ()