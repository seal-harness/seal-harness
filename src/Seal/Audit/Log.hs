{-# LANGUAGE OverloadedStrings #-}
-- | Cross-session audit log for trusted mutating opcodes.
--
-- The audit log is a monthly-rotated, append-only text file under
-- @~\/.seal\/audit\/audit-YYYY-MM.log@. Each line records one mutating
-- opcode invocation: timestamp, session id, opcode name, action, target
-- id, and the config repo's git commit hash at the time of the write.
--
-- The log is intentionally concise — full diffs and content live in the
-- config git repo (for skills and agent defs) or the session transcript
-- (for vault and memory). The audit log is the single cross-session
-- timeline an operator can @tail -F@ or @grep@ to see what changed and
-- when.
--
-- /Process-global pattern/: like 'Seal.Logging.Global', the audit logger
-- is set once at startup via 'setAuditLogger' and read via
-- 'globalAuditLog'. This avoids threading an 'AuditLogger' through the
-- dispatcher and every opcode call site. If 'setAuditLogger' has not been
-- called, 'globalAuditLog' is a no-op (best-effort — the audit log must
-- never crash the caller, especially inside the dispatch path).
module Seal.Audit.Log
  ( AuditLogger
  , AuditSink (..)
  , fileAuditSink
  , fileAuditSinkWithGit
  , setAuditLogger
  , unsetAuditLogger
  , globalAuditLog
  , globalAuditWrite
  , withAuditLogger
  , auditWrite
  , auditWriteIf
  , formatAuditLine
  , auditFileName
  ) where

import Control.Exception (catch, SomeException, bracket)
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), getCurrentTime, formatTime, defaultTimeLocale)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)

import Seal.Core.Types (OpName (..), SessionId, sessionIdText)

-- | Where audit lines are written. The production sink writes to a
-- monthly file under @~\/.seal\/audit\/@ and optionally fetches the
-- config repo's git HEAD hash on each write; tests inject a simple
-- temp-directory sink.
data AuditSink = AuditSink
  { asWriteLine :: Text -> IO ()
    -- ^ Write one complete line (without trailing newline) to the sink.
  , asGitHash :: IO (Maybe Text)
    -- ^ Fetch the current git HEAD short hash for the config repo.
    -- Returns 'Nothing' if git is unavailable or the repo has no commits.
    -- Best-effort: failures are swallowed and rendered as @-@.
  }

-- | A file-based audit sink that writes to @\<dir\>\/audit-YYYY-MM.log@.
-- No git hash fetching (the hash field in log lines will be @-@). Used by
-- tests.
fileAuditSink :: FilePath -> AuditSink
fileAuditSink dir = AuditSink
  { asWriteLine = writeLineToFile dir
  , asGitHash = pure Nothing
  }

-- | A file-based audit sink with git hash fetching. The directory is
-- created (recursively) on construction. Each write appends one line to
-- the current month's file. The git hash is fetched via the supplied IO
-- action (typically @git -C \<configRoot\> rev-parse --short HEAD@).
fileAuditSinkWithGit :: FilePath -> IO (Maybe Text) -> AuditSink
fileAuditSinkWithGit dir gitHashAction = AuditSink
  { asWriteLine = writeLineToFile dir
  , asGitHash = gitHashAction
  }

-- | Internal: write one line to the monthly file under @dir@.
writeLineToFile :: FilePath -> Text -> IO ()
writeLineToFile dir line = do
  now <- getCurrentTimeSafe
  let fname = "audit-" <> formatTime defaultTimeLocale "%Y-%m" now <> ".log"
      path = dir </> fname
  appendFile path (T.unpack line <> "\n")
    `catch` \(_ :: SomeException) -> pure ()

-- | A safe 'getCurrentTime' that never throws (best-effort).
getCurrentTimeSafe :: IO UTCTime
getCurrentTimeSafe = getCurrentTime
  `catch` \(_ :: SomeException) -> pure (UTCTime (toEnum 0) 0)

-- | The audit logger handle. Carries the sink and is set once at startup.
newtype AuditLogger = AuditLogger
  { alSink :: AuditSink
  }

-- | The process-global audit logger ref. Initialized to 'Nothing' (no-op).
-- Set once at startup via 'setAuditLogger'.
globalAuditLoggerRef :: IORef (Maybe AuditLogger)
globalAuditLoggerRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE globalAuditLoggerRef #-}

-- | Set the process-global audit logger. Called once at startup.
setAuditLogger :: AuditSink -> IO ()
setAuditLogger sink = writeIORef globalAuditLoggerRef (Just (AuditLogger sink))

-- | Unset the process-global audit logger (set the ref to 'Nothing'). Used
-- by tests that install a logger and want to restore the no-op default
-- after the test so subsequent tests are unaffected.
unsetAuditLogger :: IO ()
unsetAuditLogger = writeIORef globalAuditLoggerRef Nothing

-- | Emit an audit line via the process-global logger. If no logger has
-- been set, this is a no-op. Best-effort: if the sink throws, the error is
-- silently swallowed (the audit log must never crash the dispatch path).
globalAuditLog :: Text -> IO ()
globalAuditLog line = do
  mLogger <- readIORef globalAuditLoggerRef
  case mLogger of
    Nothing -> pure ()
    Just logger -> asWriteLine (alSink logger) line
      `catch` \(_ :: SomeException) -> pure ()

-- | Emit a structured audit entry via the process-global logger. Fetches
-- the git hash from the sink, formats the line, and writes it. If no
-- logger has been set, this is a no-op. Best-effort. This is the function
-- the agent loop calls after a successful mutating opcode dispatch.
globalAuditWrite
  :: UTCTime -> Maybe SessionId -> OpName -> Maybe Text
  -> Text -> IO ()
globalAuditWrite ts mSession opName mAction targetId = do
  mLogger <- readIORef globalAuditLoggerRef
  case mLogger of
    Nothing -> pure ()
    Just logger -> do
      mGitHash <- asGitHash (alSink logger) `catch` \(_ :: SomeException) -> pure Nothing
      let line = formatAuditLine ts mSession opName mAction targetId mGitHash
      asWriteLine (alSink logger) line
        `catch` \(_ :: SomeException) -> pure ()

-- | Bracket the audit logger's lifetime. Sets the logger for the duration
-- of the action, unsets it on exit (even on exception). Used by tests; the
-- production code uses 'setAuditLogger' (the logger lives for the process
-- lifetime).
withAuditLogger :: AuditSink -> (AuditLogger -> IO a) -> IO a
withAuditLogger sink = bracket before after
  where
    before = do
      let logger = AuditLogger sink
      writeIORef globalAuditLoggerRef (Just logger)
      pure logger
    after _ = writeIORef globalAuditLoggerRef Nothing

-- | Write an audit entry for a mutating opcode invocation. Called by
-- tests that want explicit control over the logger. The timestamp is
-- supplied by the caller (so tests can use a fixed time); in production
-- the agent loop uses 'globalAuditWrite' which fetches the current time
-- and git hash internally.
auditWrite
  :: AuditLogger -> UTCTime -> Maybe SessionId -> OpName -> Maybe Text
  -> Text -> Maybe Text -> IO ()
auditWrite logger ts mSession opName mAction targetId mGitHash = do
  let line = formatAuditLine ts mSession opName mAction targetId mGitHash
  asWriteLine (alSink logger) line
    `catch` \(_ :: SomeException) -> pure ()

-- | Like 'auditWrite' but only writes if the predicate says this
-- opcode+action should be audited. This is the function tests call to
-- verify the predicate gating.
auditWriteIf
  :: AuditLogger -> (OpName -> Maybe Text -> Bool)
  -> UTCTime -> Maybe SessionId -> OpName -> Maybe Text
  -> Text -> Maybe Text -> IO ()
auditWriteIf logger predicate ts mSession opName mAction targetId mGitHash =
  when (predicate opName mAction) $
    auditWrite logger ts mSession opName mAction targetId mGitHash

-- | Format one audit log line. The format is:
--
-- @
-- YYYY-MM-DDThh:mm:ss.sssZ session=\<id\> op=\<name\> action=\<action\> id=\<target\> git=\<hash\>
-- @
--
-- Missing fields are rendered as @-@ (never omitted, so the line is
-- greppable by field). The timestamp is ISO-8601 UTC with milliseconds.
formatAuditLine
  :: UTCTime -> Maybe SessionId -> OpName -> Maybe Text
  -> Text -> Maybe Text -> Text
formatAuditLine ts mSession (OpName opName) mAction targetId mGitHash =
  T.intercalate " "
    [ T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S.%3qZ" ts)
    , "session=" <> maybe "-" sessionIdText mSession
    , "op=" <> opName
    , "action=" <> fromMaybe "-" mAction
    , "id=" <> targetId
    , "git=" <> fromMaybe "-" mGitHash
    ]

-- | The audit filename for a given timestamp: @audit-YYYY-MM.log@.
auditFileName :: UTCTime -> FilePath
auditFileName ts =
  "audit-" <> formatTime defaultTimeLocale "%Y-%m" ts <> ".log"
