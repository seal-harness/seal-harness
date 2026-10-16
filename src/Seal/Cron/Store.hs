{-# LANGUAGE OverloadedStrings #-}
-- | The cron store backend. Disk is canonical: jobs live as JSON files
-- under @config\/cron\/jobs\/\<id\>.json@ and run history as append-only
-- JSONL at @config\/cron\/runs\/\<id\>.jsonl@ (rotated to last 100).
module Seal.Cron.Store
  ( CronStore (..)
  , fileCronStore
  , memoryCronStore
  ) where

import Data.Aeson (eitherDecode, encode)
import Data.IORef
import Data.List (isSuffixOf, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Either (rights)
import Data.Maybe (catMaybes, fromMaybe)
import Control.Monad (when)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Text.Lazy qualified as TL
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
  , listDirectory, removeFile, renameFile )
import System.FilePath (takeDirectory, (</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Cron.Types
  ( CronJob (..), CronJobId (..), CronRun (..)
  , cronJobIdText )
import Seal.Git.Repo (ConfigRepo, gitCommitAll)

data CronStore = CronStore
  { csCreate    :: CronJob -> IO ()
  , csRead      :: CronJobId -> IO (Maybe CronJob)
  , csList      :: Bool -> IO [CronJob]
  , csSave      :: CronJob -> IO ()
  , csDelete    :: CronJobId -> IO ()
  , csRecordRun :: CronJobId -> CronRun -> IO ()
  , csListRuns  :: CronJobId -> Int -> IO [CronRun]
  }

fileCronStore :: FilePath -> ConfigRepo -> IO CronStore
fileCronStore dir repo = do
  let jobsDir = dir </> "jobs"
      runsDir = dir </> "runs"
  createDirectoryIfMissing True jobsDir
  createDirectoryIfMissing True runsDir
  pure CronStore
    { csCreate    = writeJobFile jobsDir repo
    , csRead      = readJobFile jobsDir
    , csList      = listJobs jobsDir
    , csSave      = writeJobFile jobsDir repo
    , csDelete    = deleteJobFile jobsDir repo
    , csRecordRun = recordRun runsDir repo
    , csListRuns  = listRuns runsDir
    }

writeJobFile :: FilePath -> ConfigRepo -> CronJob -> IO ()
writeJobFile jobsDir repo job = do
  let path = jobFilePath jobsDir (cjId job)
      tmp  = path <.> "tmp"
  createDirectoryIfMissing True (takeDirectory path)
  TIO.writeFile tmp (TL.toStrict (TLE.decodeUtf8 (encode job)))
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "cron/jobs" </> T.unpack (cronJobIdText (cjId job)) <.> "json"
  _ <- gitCommitAll repo rel ("seal: CRON write " <> cronJobIdText (cjId job))
  pure ()

readJobFile :: FilePath -> CronJobId -> IO (Maybe CronJob)
readJobFile jobsDir jid = do
  let path = jobFilePath jobsDir jid
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      case eitherDecode (TLE.encodeUtf8 (TL.fromStrict content)) of
        Left _    -> pure Nothing
        Right job -> pure (Just job)

listJobs :: FilePath -> Bool -> IO [CronJob]
listJobs jobsDir enabledOnly = do
  exists <- doesDirectoryExist jobsDir
  if not exists
    then pure []
    else do
      entries <- listDirectory jobsDir
      let jsonFiles = filter (isSuffixOf ".json") entries
      jobs <- mapM (readJobByName jobsDir) jsonFiles
      let allJobs = catMaybes jobs
          filtered = if enabledOnly
                       then filter cjEnabled allJobs
                       else allJobs
      pure (sortOn (cronJobIdText . cjId) filtered)

deleteJobFile :: FilePath -> ConfigRepo -> CronJobId -> IO ()
deleteJobFile jobsDir repo jid = do
  let path = jobFilePath jobsDir jid
  exists <- doesFileExist path
  when exists $ do
    removeFile path
    let rel = "cron/jobs" </> T.unpack (cronJobIdText jid) <.> "json"
    _ <- gitCommitAll repo rel ("seal: CRON delete " <> cronJobIdText jid)
    pure ()

recordRun :: FilePath -> ConfigRepo -> CronJobId -> CronRun -> IO ()
recordRun runsDir repo jid run = do
  let path = runFilePath runsDir jid
  createDirectoryIfMissing True (takeDirectory path)
  existing <- readRunFile path
  let updated = take 100 (run : existing)
  writeRunFile path updated
  let rel = "cron/runs" </> T.unpack (cronJobIdText jid) <.> "jsonl"
  _ <- gitCommitAll repo rel ("seal: CRON run record " <> cronJobIdText jid)
  pure ()

listRuns :: FilePath -> CronJobId -> Int -> IO [CronRun]
listRuns runsDir jid limit = do
  let path = runFilePath runsDir jid
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      runs <- readRunFile path
      pure (take limit runs)

jobFilePath :: FilePath -> CronJobId -> FilePath
jobFilePath jobsDir jid = jobsDir </> T.unpack (cronJobIdText jid) <.> "json"

runFilePath :: FilePath -> CronJobId -> FilePath
runFilePath runsDir jid = runsDir </> T.unpack (cronJobIdText jid) <.> "jsonl"

readRunFile :: FilePath -> IO [CronRun]
readRunFile path = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      content <- TIO.readFile path
      let lines' = filter (not . T.null) (T.lines content)
          decoded = [ eitherDecode (TLE.encodeUtf8 (TL.fromStrict line))
                    | line <- lines' ]
      pure (rights decoded)

writeRunFile :: FilePath -> [CronRun] -> IO ()
writeRunFile path runs = do
  let tmp = path <.> "tmp"
      content = T.intercalate "\n"
                  [ TL.toStrict (TLE.decodeUtf8 (encode run))
                  | run <- runs ]
  TIO.writeFile tmp content
  setFileMode tmp 0o600
  renameFile tmp path

readJobByName :: FilePath -> FilePath -> IO (Maybe CronJob)
readJobByName jobsDir name = do
  let path = jobsDir </> name
  content <- TIO.readFile path
  case eitherDecode (TLE.encodeUtf8 (TL.fromStrict content)) of
    Left _    -> pure Nothing
    Right job -> pure (Just job)

memoryCronStore :: IO CronStore
memoryCronStore = do
  jobsRef <- newIORef (Map.empty :: Map CronJobId CronJob)
  runsRef <- newIORef (Map.empty :: Map CronJobId [CronRun])
  pure CronStore
    { csCreate = \job -> modifyIORef' jobsRef (Map.insert (cjId job) job)
    , csRead   = \jid -> do
        m <- readIORef jobsRef
        pure (Map.lookup jid m)
    , csList   = \enabledOnly -> do
        m <- readIORef jobsRef
        let allJobs = Map.elems m
            filtered = if enabledOnly
                         then filter cjEnabled allJobs
                         else allJobs
        pure (sortOn (cronJobIdText . cjId) filtered)
    , csSave   = \job -> modifyIORef' jobsRef (Map.insert (cjId job) job)
    , csDelete = modifyIORef' jobsRef . Map.delete
    , csRecordRun = \jid run -> modifyIORef' runsRef
        (Map.insertWith (\_new old -> take 100 (run : old)) jid [run])
    , csListRuns = \jid limit -> do
        m <- readIORef runsRef
        pure (take limit (fromMaybe [] (Map.lookup jid m)))
    }
