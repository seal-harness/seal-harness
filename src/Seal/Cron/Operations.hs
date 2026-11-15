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

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)

import Seal.Agent.Def.Types (mkAgentDefId)
import Seal.Providers.Registry (isProviderName)
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
  , cuProvider   :: Maybe Text
    -- ^ 'Nothing' = leave unchanged; 'Just ""' = clear (fall back to the
    -- configured default); 'Just name' = set. Validated with 'isProviderName'
    -- exactly as on create, so an update cannot smuggle in a value that
    -- 'createJob' would reject.
  , cuModel      :: Maybe Text
    -- ^ Same three-way convention as 'cuProvider'.
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
  -> Maybe Text    -- ^ provider (validated with 'isProviderName'; @""@ = absent)
  -> Maybe Text    -- ^ model (@""@ = absent)
  -> Bool          -- ^ enabled
  -> Bool          -- ^ one_shot
  -> IO (Either Text CronJob)
createJob store name schedStr mTzStr prompt mAgentDefId mProvider mModel enabled oneShot
  | T.null name || T.length name > 100 =
      pure (Left "name must be 1-100 characters")
  | T.null prompt || T.length prompt > 4000 =
      pure (Left "prompt must be 1-4000 characters")
  | otherwise =
      case mkCronExpr schedStr of
        Left e -> pure (Left e)
        Right expr -> do
          mValidTz <- validateTimezone mTzStr
          case mValidTz of
            Left e -> pure (Left e)
            Right mTz ->
              case validateAgentDefId mAgentDefId of
                Left e -> pure (Left e)
                Right mValidAid ->
                  case validateProvider mProvider of
                    Left e -> pure (Left e)
                    Right mValidProv -> do
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
                                    { cjId = jid, cjName = name
                                    , cjSchedule = expr, cjTimezone = mTz
                                    , cjPrompt = prompt
                                    , cjAgentDefId = mValidAid
                                    , cjProvider = mValidProv
                                    , cjModel = validateModel mModel
                                    , cjEnabled = enabled
                                    , cjOneShot = oneShot
                                    , cjCreatedAt = now, cjUpdatedAt = now
                                    , cjLastFire = Nothing
                                    , cjRunCount = 0
                                    , cjConsecutiveFailures = 0 }
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
        Just schedStr ->
          case mkCronExpr schedStr of
            Left e -> pure (Left e)
            Right _ -> continueAfterSchedule
        Nothing -> continueAfterSchedule
  where
    continueAfterSchedule = do
      mValidTz <- validateTimezone (cuTimezone upd)
      case mValidTz of
        Left e -> pure (Left e)
        Right mTz ->
          case validateAgentDefId (cuAgentDefId upd) of
            Left e -> pure (Left e)
            Right mValidAid ->
              case validateProvider (cuProvider upd) of
                Left e -> pure (Left e)
                Right mValidProv -> do
                  now <- getCurrentTime
                  let updatedJob =
                        applyUpdate job upd mTz mValidAid mValidProv now
                  csSave store updatedJob
                  pure (Right updatedJob)

-- | Merge a validated 'CronUpdate' into an existing job. Pure, so the
-- three-way "leave alone / clear / set" rule is readable in one place.
--
-- Provider and model follow the same convention: 'Nothing' means the client
-- did not supply the field (an absent key and an explicit JSON @null@ both
-- decode to 'Nothing'), @Just ""@ means the operator emptied the form field
-- and wants the job back on Seal's configured default, and @Just x@ sets it.
applyUpdate
  :: CronJob
  -> CronUpdate
  -> Maybe CronTimeZone   -- ^ validated timezone ('Nothing' = unchanged)
  -> Maybe Text           -- ^ validated agent def id ('Nothing' = unchanged)
  -> Maybe Text           -- ^ validated provider ('Nothing' = absent/empty)
  -> UTCTime
  -> CronJob
applyUpdate job upd mTz mValidAid mValidProv now = job
  { cjName     = fromMaybe (cjName job) (cuName upd)
  , cjSchedule = case cuSchedule upd of
      Nothing -> cjSchedule job
      Just sc ->
        case mkCronExpr sc of
          Right e -> e
          Left _  -> cjSchedule job
  , cjTimezone = mTz <|> cjTimezone job
  , cjPrompt   = fromMaybe (cjPrompt job) (cuPrompt upd)
  , cjAgentDefId = mValidAid <|> cjAgentDefId job
  , cjProvider = applyTriState (cjProvider job) (cuProvider upd) mValidProv
  , cjModel    = applyTriState (cjModel job) (cuModel upd)
                   (validateModel (cuModel upd))
  , cjEnabled  = fromMaybe (cjEnabled job) (cuEnabled upd)
  , cjOneShot  = fromMaybe (cjOneShot job) (cuOneShot upd)
  , cjUpdatedAt = now
  }

-- | Resolve one tri-state field. @supplied@ is the raw client value, needed to
-- tell "key absent" from "@Just \"\"@" (both would otherwise collapse to
-- 'Nothing'); @validated@ is the smart-constructed value produced by the
-- validator that already ran on this same field — it is 'Nothing' when nothing
-- usable was supplied.
applyTriState :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text
applyTriState current supplied validated =
  case supplied of
    Nothing -> current
    Just raw
      | T.null raw -> Nothing
      | otherwise  -> validated

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

-- | Validate an optional provider name. @Nothing@ and @Just ""@ both mean
-- "no provider supplied" and yield 'Right Nothing' — an emptied form field is
-- an absent choice, not a provider named the empty string.
--
-- The check is '<Seal.Providers.Registry.isProviderName>': a built-in provider
-- label, or a syntactically valid custom instance name. A syntactically valid
-- but *unconfigured* name cannot be rejected here — this module is shared by
-- the opcode and the web gateway and holds no config handle. Such a name
-- surfaces as @\"unknown provider in session: …\"@ inside the spawned session's
-- transcript at fire time; see the design note in
-- @docs/plans/2026-11-15-cron-provider-model-plan.md@ (D2).
validateProvider :: Maybe Text -> Either Text (Maybe Text)
validateProvider Nothing = Right Nothing
validateProvider (Just provStr)
  | T.null provStr = Right Nothing
  | isProviderName provStr = Right (Just provStr)
  | otherwise = Left ("invalid provider name: " <> provStr)

-- | Validate an optional model id. @Nothing@ and @Just ""@ both mean "no model
-- supplied". Model ids are opaque to the harness (every provider names its own),
-- so the only rule is that an emptied field is an absent choice.
validateModel :: Maybe Text -> Maybe Text
validateModel Nothing = Nothing
validateModel (Just m) = if T.null m then Nothing else Just m
