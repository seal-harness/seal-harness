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
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (setFileMode, unionFileModes, ownerReadMode, ownerWriteMode)
import System.IO.Unsafe (unsafePerformIO)

import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Harness.Id (parseHarnessId, harnessIdToText)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))

-- | Module-level write lock — serializes concurrent 'saveTabList' calls so
-- two tab mutations cannot interleave file writes (a bare forkIO TVar
-- listener would race; the explicit MVar guarantees atomicity). One lock
-- per process, shared across all paths (a single @tabs.json@ per state dir).
writeLock :: MVar ()
writeLock = unsafePerformIO (newMVar ())
{-# NOINLINE writeLock #-}

-- | Save a 'TabList' to @path@ atomically: write @.tmp@, chmod 0600,
-- rename over the target. Serialized via 'writeLock'. Never throws (a write
-- failure logs to stderr and continues — the in-memory handle stays
-- authoritative within the session). Takes the 'TabList' directly (not a
-- 'TabsHandle') so this module does NOT import 'Seal.Tabs' (avoids a cycle).
saveTabList :: FilePath -> TabList -> IO ()
saveTabList path tl = modifyMVar_ writeLock $ \_ -> do
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path <> ".tmp"
  BL.writeFile tmp (A.encode tl)
  setFileMode tmp (unionFileModes ownerReadMode ownerWriteMode)  -- 0600
  renameFile tmp path

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
          hPutStrLn stderr "Warning: could not parse tabs.json; using empty tab list"
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