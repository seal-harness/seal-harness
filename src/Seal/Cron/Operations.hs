{-# LANGUAGE OverloadedStrings #-}
-- | Shared cron job operations used by both the 'CRON_MANAGE' opcode and
-- the gateway REST API. This module is the single implementation of
-- create / update / enable / delete so the two surfaces cannot drift —
-- a validation rule added here applies to both paths.
module Seal.Cron.Operations
  ( createJob
  , updateJob
  , setJobEnabled
  , deleteJob
  , dedupSlug
  , CronUpdate (..)
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Agent.Def.Types (mkAgentDefId)
import Seal.Cron.Types
import Seal.Cron.Store

-- | The partial-update record for 'updateJob'. 'Nothing' means "leave
-- this field unchanged". For 'cuTimezone' and 'cuAgentDefId', 'Nothing'
-- means unchanged (NOT "clear the field").
data CronUpdate = CronUpdate
  { cuName       :: Maybe Text
  , cuSchedule   :: Maybe Text
  , cuTimezone   :: Maybe Text
  , cuPrompt     :: Maybe Text
  , cuAgentDefId :: Maybe Text
  , cuEnabled    :: Maybe Bool
  , cuOneShot    :: Maybe Bool
  }

-- | Create a new cron job. Slugifies the name, dedups against existing
-- ids, validates all fields, and defaults @enabled@ to 'False'.
-- Returns 'Left' with a human-readable error on validation failure.
createJob
  :: CronStore
  -> Text          -- ^ name (1–100 chars)
  -> Text          -- ^ schedule (5-field cron expression)
  -> Maybe Text    -- ^ timezone (IANA identifier, validated against tzdb)
  -> Text          -- ^ prompt (1–4000 chars)
  -> Maybe Text    -- ^ agent_def_id (validated with 'mkAgentDefId')
  -> Bool          -- ^ enabled
  -> Bool          -- ^ one_shot
  -> IO (Either Text CronJob)
createJob store name schedStr mTzStr prompt mAgentDefId enabled oneShot
  | T.null name || T.length name > 100 =
      pure (Left "name must be 1-100 characters")
  | T.null prompt || T.length prompt > 4000 =
      pure (Left "prompt must be 1-4000 characters")
  | otherwise = case mkCronExpr schedStr of
      Left e -> pure (Left e)
      Right expr -> do
        mValidTz <- validateTimezone mTzStr
        case mValidTz of
          Left e -> pure (Left e)
          Right mTz -> case validateAgentDefId mAgentDefId of
            Left e -> pure (Left e)
            Right mValidAid -> do
              allJobs <- csList store False
              if length allJobs >= 100
                then pure (Left "maximum job count (100) reached")
                else do
                  let baseSlug = slugify name
                  existingIds <- map (cronJobIdText . cjId) <$> csList store False
                  let slug = dedupSlug baseSlug existingIds
                  case mkCronJobId slug of
                    Left e -> pure (Left e)
                    Right jid -> do
                      now <- getCurrentTime
                      let job = CronJob
                            { cjId = jid, cjName = name, cjSchedule = expr
                            , cjTimezone = mTz, cjPrompt = prompt
                            , cjAgentDefId = mValidAid, cjEnabled = enabled
                            , cjOneShot = oneShot, cjCreatedAt = now
                            , cjUpdatedAt = now, cjLastFire = Nothing
                            , cjRunCount = 0, cjConsecutiveFailures = 0 }
                      csCreate store job
                      pure (Right job)

-- | Update an existing cron job, patching only the supplied fields.
-- Applies the same validation as 'createJob' to each supplied field.
-- Returns 'Left' if the job doesn't exist or a field is invalid.
updateJob
  :: CronStore
  -> CronJobId
  -> CronUpdate
  -> IO (Either Text CronJob)
updateJob store jid upd = do
  mJob <- csRead store jid
  case mJob of
    Nothing -> pure (Left ("cron job not found: " <> cronJobIdText jid))
    Just job -> updateJobValidated store job upd

-- | Internal: validate all supplied fields and persist the update.
updateJobValidated :: CronStore -> CronJob -> CronUpdate -> IO (Either Text CronJob)
updateJobValidated store job upd
  -- Validate name
  | Just name <- cuName upd
  , T.null name || T.length name > 100 =
      pure (Left "name must be 1-100 characters")
  -- Validate prompt
  | Just prompt <- cuPrompt upd
  , T.null prompt || T.length prompt > 4000 =
      pure (Left "prompt must be 1-4000 characters")
  | otherwise = do
      -- Validate schedule
      case cuSchedule upd of
        Just schedStr -> case mkCronExpr schedStr of
          Left e -> pure (Left e)
          Right _ -> continueAfterSchedule
        Nothing -> continueAfterSchedule
  where
    continueAfterSchedule = do
      mValidTz <- validateTimezone (cuTimezone upd)
      case mValidTz of
        Left e -> pure (Left e)
        Right mTz -> case validateAgentDefId (cuAgentDefId upd) of
          Left e -> pure (Left e)
          Right mValidAid -> do
            let newSched = case cuSchedule upd of
                  Just s -> case mkCronExpr s of Right e -> e; Left _ -> cjSchedule job
                  Nothing -> cjSchedule job
                newTz = case mTz of
                  Just tz -> Just tz
                  Nothing -> cjTimezone job
                newAid = case mValidAid of
                  Just aid -> Just aid
                  Nothing -> cjAgentDefId job
            now <- getCurrentTime
            let updatedJob = job
                  { cjName = fromMaybe (cjName job) (cuName upd)
                  , cjSchedule = newSched
                  , cjTimezone = newTz
                  , cjPrompt = fromMaybe (cjPrompt job) (cuPrompt upd)
                  , cjAgentDefId = newAid
                  , cjEnabled = fromMaybe (cjEnabled job) (cuEnabled upd)
                  , cjOneShot = fromMaybe (cjOneShot job) (cuOneShot upd)
                  , cjUpdatedAt = now }
            csSave store updatedJob
            pure (Right updatedJob)

-- | Enable or disable a job. Idempotent — setting enabled to its current
-- value is a no-op that still returns 'Right'. Returns 'Left' if the job
-- doesn't exist.
setJobEnabled :: CronStore -> CronJobId -> Bool -> IO (Either Text CronJob)
setJobEnabled store jid newEnabled = do
  mJob <- csRead store jid
  case mJob of
    Nothing -> pure (Left ("cron job not found: " <> cronJobIdText jid))
    Just job -> do
      now <- getCurrentTime
      let updatedJob = job { cjEnabled = newEnabled, cjUpdatedAt = now }
      csSave store updatedJob
      pure (Right updatedJob)

-- | Delete a job. Idempotent — deleting a non-existent job returns
-- 'Right ()'. Never fails.
deleteJob :: CronStore -> CronJobId -> IO (Either Text ())
deleteJob store jid = do
  csDelete store jid
  pure (Right ())

-- | Ensure a slug does not collide with existing ids by appending a
-- numeric suffix. Owned here so both the opcode and the web path dedup
-- identically.
dedupSlug :: Text -> [Text] -> Text
dedupSlug base existingIds
  | base `notElem` existingIds = base
  | otherwise = go (2 :: Int)
  where
    go :: Int -> Text
    go n = let c = base <> "-" <> T.pack (show n)
           in if c `notElem` existingIds then c else go (n + 1)

-- | Validate a timezone string: format check via 'mkCronTimeZone',
-- then existence check via 'validateCronTimeZone'. 'Nothing' input
-- means "no timezone supplied" and yields 'Right Nothing'.
validateTimezone :: Maybe Text -> IO (Either Text (Maybe CronTimeZone))
validateTimezone Nothing = pure (Right Nothing)
validateTimezone (Just tzStr) = case mkCronTimeZone tzStr of
  Left e -> pure (Left e)
  Right tz -> do
    eValid <- validateCronTimeZone tz
    pure $ case eValid of
      Left e -> Left e
      Right _ -> Right (Just tz)

-- | Validate an agent_def_id string with 'mkAgentDefId'. 'Nothing' input
-- means "no agent_def_id supplied" and yields 'Right Nothing'.
validateAgentDefId :: Maybe Text -> Either Text (Maybe Text)
validateAgentDefId Nothing = Right Nothing
validateAgentDefId (Just aidStr) = case mkAgentDefId aidStr of
  Left e -> Left e
  Right _ -> Right (Just aidStr)
