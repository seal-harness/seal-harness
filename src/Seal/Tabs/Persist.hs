{-# LANGUAGE OverloadedStrings #-}
-- | Tab list persistence — the 'TabList' survives a @seal serve@ restart.
-- Written atomically (0600) to @\<state\>\/tabs.json@ on every tab mutation;
-- loaded at boot and re-resolved to the tab refs (ids validated; unparseable
-- refs skipped — defense-in-depth against a tampered file). Writes are
-- serialized via a module-level MVar so concurrent mutations cannot
-- interleave file writes.
module Seal.Tabs.Persist
  ( saveTabList
  , loadTabList
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import System.Directory (doesFileExist)
import System.IO.Unsafe (unsafePerformIO)

import Katip (Severity (..))
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Harness.Id (parseHarnessId, harnessIdToText)
import Seal.Logging.Global (globalLogIO)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))
import Seal.Util.AtomicJson (saveJsonAtomic)

-- | Module-level write lock — serializes concurrent 'saveTabList' calls so
-- two tab mutations cannot interleave file writes (a bare forkIO TVar
-- listener would race; the explicit MVar guarantees atomicity). One lock
-- per process, shared across all paths (a single @tabs.json@ per state dir).
--
-- NOTE: 'Seal.Util.AtomicJson.saveJsonAtomic' has its own module-level
-- lock, so the MVar here is redundant for the write itself. It is retained
-- because 'loadTabList' / 'filterValidTabs' are pure and do not take the
-- lock; keeping the local lock documents the serialization invariant. A
-- future cleanup can drop it once all callers route through
-- 'saveJsonAtomic' (which they now do).
writeLock :: MVar ()
writeLock = unsafePerformIO (newMVar ())
{-# NOINLINE writeLock #-}

-- | Save a 'TabList' to @path@ atomically via 'saveJsonAtomic' (0600,
-- MVar-serialized). A thrown IO error propagates to the caller
-- ('Seal.Tabs.persistIf') which catches, logs a warning, and swallows —
-- the in-memory handle stays authoritative within the session. Takes the
-- 'TabList' directly (not a 'TabsHandle') so this module does NOT import
-- 'Seal.Tabs' (avoids a cycle).
saveTabList :: FilePath -> TabList -> IO ()
saveTabList path tl = modifyMVar_ writeLock $ \_ ->
  saveJsonAtomic path (A.encode tl)

-- | Load the tab list from @path@. Missing file -> 'Nothing' (fresh empty
-- list). Corrupt JSON -> 'Nothing' + a stderr warning (ids + error type
-- only — no session content). Every 'TabRef' id is re-validated via
-- 'mkSessionId' / 'parseHarnessId'; tabs carrying an unparseable id are
-- skipped (defense-in-depth against a tampered @tabs.json@).
loadTabList :: FilePath -> IO (Maybe TabList)
loadTabList path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bs <- BL.readFile path
      case A.decode bs :: Maybe TabList of
        Nothing -> do
          globalLogIO WarningS "could not parse tabs.json; using empty tab list"
          pure Nothing
        Just tl -> pure (Just (filterValidTabs tl))

-- | Drop tabs whose 'TabRef' id fails to re-parse. The on-disk ids were
-- validated when written, so a parse failure here means the file was
-- tampered or written by a future/incompatible version — skip rather than
-- error so a corrupt file self-heals on the next save.
filterValidTabs :: TabList -> TabList
filterValidTabs tl = tl { tlTabs = filter (validRef . tRef) (tlTabs tl) }
  where
    validRef (BoundSession sid) = case mkSessionId (sessionIdText sid) of Right _ -> True; Left _ -> False
    validRef (BoundHarness hid) = case parseHarnessId (harnessIdToText hid) of Right _ -> True; Left _ -> False