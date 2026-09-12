-- | A small stderr-capture helper for tests that assert load warnings are
-- emitted to stderr. Uses the standard @hDuplicate@\/@hDuplicateTo@
-- redirect technique over a POSIX pipe — no external dependency on
-- @silently@.
module Seal.TestHelpers.CaptureStderr
  ( captureStderr
  ) where

import Control.Exception (finally)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO
  ( BufferMode (..)
  , hClose
  , hFlush
  , hGetContents
  , hSetBuffering
  , stderr
  )
import System.Posix.IO (createPipe, fdToHandle)

-- | Run an 'IO' action, capturing everything written to 'stderr' as 'Text'.
-- The original 'stderr' is restored afterward (even on exception). The
-- returned pair is @(capturedText, actionResult)@.
--
-- The write end of the pipe replaces 'stderr' for the duration of the
-- action. After the action completes (or throws), the write end is closed,
-- which signals EOF on the read end so 'hGetContents' returns.
captureStderr :: IO a -> IO (Text, a)
captureStderr action = do
  hFlush stderr
  (rdFd, wrFd) <- createPipe
  readEnd <- fdToHandle rdFd
  writeEnd <- fdToHandle wrFd
  oldStderr <- hDuplicate stderr
  hDuplicateTo writeEnd stderr
  hSetBuffering stderr NoBuffering
  result <- action `finally` do
    hFlush stderr
    hDuplicateTo oldStderr stderr
    hClose writeEnd
  captured <- T.pack <$> hGetContents readEnd
  -- Force the lazy IO so the handle is fully read before closing.
  let !_ = T.length captured
  hClose readEnd
  pure (captured, result)
