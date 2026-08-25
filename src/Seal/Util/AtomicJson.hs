{-# LANGUAGE OverloadedStrings #-}
-- | Shared atomic JSON persistence for small state files
-- (@\<state\>\/tabs.json@, @\<state\>\/cursors.json@).
--
-- The pattern — write @path.tmp@, chmod 0600, rename over the target, all
-- serialized by a module-level MVar so concurrent writes to the same file
-- cannot interleave — was duplicated across 'Seal.Tabs.Persist.saveTabList'
-- and is now needed by 'Seal.Channels.Cursor.Persist.saveCursorMap'. This
-- helper centralizes it so the two do not drift.
--
-- Note: 'Seal.Session.Store.saveSessionMeta' uses a different temp-file
-- strategy ('openBinaryTempFile' for a unique name per call) because it
-- guards against concurrent saves of the /same/ session file from multiple
-- threads without a shared lock; it is intentionally NOT consolidated here
-- (see the design doc's §6). This helper is for files where a single
-- module-level MVar is an acceptable serialization point.
module Seal.Util.AtomicJson
  ( saveJsonAtomic
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Data.ByteString.Lazy qualified as BL
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (setFileMode, unionFileModes, ownerReadMode, ownerWriteMode)

-- | Module-level write lock — serializes concurrent 'saveJsonAtomic' calls
-- so two mutations cannot interleave file writes (a bare forkIO TVar
-- listener would race; the explicit MVar guarantees atomicity). One lock
-- per process, shared across all callers. The critical sections are short
-- (a single file write + rename) so this is not a contention concern in
-- practice — these files mutate at human, not machine, rate.
writeLock :: MVar ()
writeLock = unsafePerformIO (newMVar ())
{-# NOINLINE writeLock #-}

-- | Atomically write a lazy 'BL.ByteString' (typically @Aeson.encode@ output)
-- to @path@: create the parent dir, write @path.tmp@, chmod 0600, rename
-- over the target. Serialized via 'writeLock' so concurrent calls from
-- multiple threads (channel loop + gateway API + slash command) don't
-- collide on the shared @.tmp@ path. Never throws (the caller is expected
-- to 'catch' log a warning on failure, matching the
-- 'Seal.Tabs.Persist' / 'Seal.Channels.Cursor.Persist' pattern — the
-- in-memory handle stays authoritative within the session and the next
-- successful mutation retries by writing the full current state, so a
-- missed save self-heals).
saveJsonAtomic :: FilePath -> BL.ByteString -> IO ()
saveJsonAtomic path bs = modifyMVar_ writeLock $ \_ -> do
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path <> ".tmp"
  BL.writeFile tmp bs
  setFileMode tmp (unionFileModes ownerReadMode ownerWriteMode)  -- 0600
  renameFile tmp path