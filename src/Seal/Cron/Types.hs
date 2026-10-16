{-# LANGUAGE OverloadedStrings #-}
-- | Cron types: smart-constructed newtypes for job IDs, cron expressions,
-- and timezones, plus the 'CronJob' and 'CronRun' data types.
module Seal.Cron.Types
  ( CronJobId (..)
  , mkCronJobId
  , cronJobIdText
  , CronExpr (..)
  , mkCronExpr
  , cronExprText
  , CronTimeZone (..)
  , mkCronTimeZone
  , cronTimeZoneText
  , CronJob (..)
  , CronRun (..)
  , CronRunStatus (..)
  , slugify
  , computeNextFire
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=) )
import Data.Char (isAlphaNum, isAscii, isAsciiLower, isDigit, toLower)
import Data.List.NonEmpty (NonEmpty, toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( UTCTime (..), toGregorian, DayOfWeek (..), dayOfWeek
  , addUTCTime, utc, utcToLocalTime, localTimeToUTC )
import GHC.Generics (Generic)

import System.Cron.Parser (parseCronSchedule)
import System.Cron.Types (CronSchedule)
import System.Cron.Internal.Check (Expanded (..), expand)
import Data.Time.Zones (loadTZFromDB, utcToLocalTimeTZ, localTimeToUTCTZ)

-- ---------------------------------------------------------------------------
-- CronJobId
-- ---------------------------------------------------------------------------

newtype CronJobId = CronJobId { unCronJobId :: Text }
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

mkCronJobId :: Text -> Either Text CronJobId
mkCronJobId t
  | T.null t = Left "cron job id must not be empty"
  | T.length t > 64 = Left "cron job id must be at most 64 characters"
  | T.head t == '-' = Left "cron job id must not start with a dash"
  | not (T.all isValidIdChar t) = Left "cron job id must contain only [a-z0-9-]"
  | otherwise = Right (CronJobId t)

isValidIdChar :: Char -> Bool
isValidIdChar c = isAsciiLower c || isDigit c || c == '-'

cronJobIdText :: CronJobId -> Text
cronJobIdText = unCronJobId

instance FromJSON CronJobId where
  parseJSON = withObject "CronJobId" $ \o -> do
    t <- o .: "id"
    case mkCronJobId t of
      Left e -> fail (T.unpack e)
      Right cid -> pure cid

-- ---------------------------------------------------------------------------
-- CronExpr
-- ---------------------------------------------------------------------------

-- | A validated 5-field cron expression (e.g. @"0 9 * * 1-5"@). The
-- underlying 'CronSchedule' is parsed at construction time.
data CronExpr = CronExpr
  { ceSchedule :: !CronSchedule
  , ceText     :: !Text
  }

mkCronExpr :: Text -> Either Text CronExpr
mkCronExpr t
  | T.null t = Left "cron expression must not be empty"
  | otherwise = case parseCronSchedule t of
      Left err -> Left ("invalid cron expression: " <> t <> " (" <> T.pack err <> ")")
      Right sched -> Right (CronExpr { ceSchedule = sched, ceText = t })

cronExprText :: CronExpr -> Text
cronExprText = ceText

instance ToJSON CronExpr where
  toJSON = toJSON . ceText

instance FromJSON CronExpr where
  parseJSON v = do
    t <- parseJSON v
    case mkCronExpr t of
      Left e -> fail (T.unpack e)
      Right e -> pure e

instance Show CronExpr where
  show = T.unpack . ceText

instance Eq CronExpr where
  a == b = ceText a == ceText b

instance Ord CronExpr where
  compare a b = compare (ceText a) (ceText b)

-- ---------------------------------------------------------------------------
-- CronTimeZone
-- ---------------------------------------------------------------------------

newtype CronTimeZone = CronTimeZone { unCronTimeZone :: Text }
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

mkCronTimeZone :: Text -> Either Text CronTimeZone
mkCronTimeZone t
  | T.null t = Left "timezone must not be empty"
  | not (isValidIanaTz t) = Left "timezone must be a valid IANA identifier (e.g. America/New_York)"
  | otherwise = Right (CronTimeZone t)

isValidIanaTz :: Text -> Bool
isValidIanaTz t =
  let parts = T.splitOn "/" t
  in length parts >= 2 && not (any T.null parts) && all isValidTzComponent parts

isValidTzComponent :: Text -> Bool
isValidTzComponent = T.all (\c -> isAscii c && (isAlphaNum c || c == '_' || c == '-'))

cronTimeZoneText :: CronTimeZone -> Text
cronTimeZoneText = unCronTimeZone

instance FromJSON CronTimeZone where
  parseJSON v = do
    t <- parseJSON v
    case mkCronTimeZone t of
      Left e -> fail (T.unpack e)
      Right tz -> pure tz

-- ---------------------------------------------------------------------------
-- CronJob
-- ---------------------------------------------------------------------------

data CronJob = CronJob
  { cjId          :: !CronJobId
  , cjName        :: !Text
  , cjSchedule    :: !CronExpr
  , cjTimezone    :: !(Maybe CronTimeZone)
  , cjPrompt      :: !Text
  , cjAgentDefId  :: !(Maybe Text)
  , cjEnabled     :: !Bool
  , cjOneShot     :: !Bool
  , cjCreatedAt   :: !UTCTime
  , cjUpdatedAt   :: !UTCTime
  , cjLastFire    :: !(Maybe UTCTime)
  , cjRunCount    :: !Int
  , cjConsecutiveFailures :: !Int
  } deriving stock (Eq, Show, Generic)

instance ToJSON CronJob where
  toJSON j = object
    [ "id" .= cjId j
    , "name" .= cjName j
    , "schedule" .= cjSchedule j
    , "timezone" .= cjTimezone j
    , "prompt" .= cjPrompt j
    , "agent_def_id" .= cjAgentDefId j
    , "enabled" .= cjEnabled j
    , "one_shot" .= cjOneShot j
    , "created_at" .= cjCreatedAt j
    , "updated_at" .= cjUpdatedAt j
    , "last_fire" .= cjLastFire j
    , "run_count" .= cjRunCount j
    , "consecutive_failures" .= cjConsecutiveFailures j
    ]

instance FromJSON CronJob where
  parseJSON = withObject "CronJob" $ \o -> do
    rawId <- o .: "id"
    cid <- either (fail . T.unpack) pure (mkCronJobId rawId)
    name <- o .: "name"
    sched <- o .: "schedule"
    mTz <- o .:? "timezone"
    prompt <- o .: "prompt"
    mAgentDefId <- o .:? "agent_def_id"
    enabled <- o .: "enabled"
    oneShot <- o .: "one_shot"
    createdAt <- o .: "created_at"
    updatedAt <- o .: "updated_at"
    mLastFire <- o .:? "last_fire"
    runCount <- o .: "run_count"
    failCount <- fromMaybe 0 <$> o .:? "consecutive_failures"
    pure CronJob
      { cjId = cid
      , cjName = name
      , cjSchedule = sched
      , cjTimezone = mTz
      , cjPrompt = prompt
      , cjAgentDefId = mAgentDefId
      , cjEnabled = enabled
      , cjOneShot = oneShot
      , cjCreatedAt = createdAt
      , cjUpdatedAt = updatedAt
      , cjLastFire = mLastFire
      , cjRunCount = runCount
      , cjConsecutiveFailures = failCount
      }

-- ---------------------------------------------------------------------------
-- CronRun + CronRunStatus
-- ---------------------------------------------------------------------------

data CronRunStatus = CrPending | CrRunning | CrCompleted | CrFailed
  deriving stock (Eq, Show, Generic)

instance ToJSON CronRunStatus where
  toJSON s = toJSON $ case s of
    CrPending -> ("pending" :: Text)
    CrRunning -> "running"
    CrCompleted -> "completed"
    CrFailed -> "failed"

instance FromJSON CronRunStatus where
  parseJSON v = do
    t <- parseJSON v
    case t :: Text of
      "pending" -> pure CrPending
      "running" -> pure CrRunning
      "completed" -> pure CrCompleted
      "failed" -> pure CrFailed
      other -> fail ("unknown cron run status: " <> T.unpack other)

data CronRun = CronRun
  { crJobId     :: !CronJobId
  , crSessionId :: !Text
  , crStartedAt :: !UTCTime
  , crEndedAt   :: !(Maybe UTCTime)
  , crStatus    :: !CronRunStatus
  , crError     :: !(Maybe Text)
  } deriving stock (Eq, Show, Generic)

instance ToJSON CronRun where
  toJSON r = object
    [ "job_id" .= crJobId r
    , "session_id" .= crSessionId r
    , "started_at" .= crStartedAt r
    , "ended_at" .= crEndedAt r
    , "status" .= crStatus r
    , "error" .= crError r
    ]

instance FromJSON CronRun where
  parseJSON = withObject "CronRun" $ \o -> do
    rawJobId <- o .: "job_id"
    jid <- either (fail . T.unpack) pure (mkCronJobId rawJobId)
    sid <- o .: "session_id"
    started <- o .: "started_at"
    mEnded <- o .:? "ended_at"
    status <- o .: "status"
    mErr <- o .:? "error"
    pure CronRun
      { crJobId = jid
      , crSessionId = sid
      , crStartedAt = started
      , crEndedAt = mEnded
      , crStatus = status
      , crError = mErr
      }

-- ---------------------------------------------------------------------------
-- Slug
-- ---------------------------------------------------------------------------

slugify :: Text -> Text
slugify name =
  let lowered = T.map toLower name
      slugged = T.map (\c -> if isSlugChar c then c else '-') lowered
      collapsed = collapseDashes slugged
      trimmed = T.dropWhile (== '-') (T.dropWhileEnd (== '-') collapsed)
      truncated = T.take 32 trimmed
  in if T.null truncated then "job" else truncated
  where
    isSlugChar :: Char -> Bool
    isSlugChar c = isAsciiLower c || isDigit c || c == '-'

collapseDashes :: Text -> Text
collapseDashes = T.intercalate "-" . filter (not . T.null) . T.splitOn "-"

-- ---------------------------------------------------------------------------
-- Next fire computation
-- ---------------------------------------------------------------------------

-- | Compute the next fire time for a cron job, given the reference time
-- (usually @now@). Uses the @cron@ package's 'expand' for schedule matching
-- and the @tz@ package for timezone-aware computation.
--
-- When the job has a timezone, the reference time is converted to local
-- time, the next fire is computed in local time, and the result is
-- converted back to UTC.
computeNextFire :: CronExpr -> Maybe CronTimeZone -> UTCTime -> IO (Maybe UTCTime)
computeNextFire expr mTz refTime =
  case mTz of
    Nothing -> pure (nextFireUTC (ceSchedule expr) refTime)
    Just tz -> nextFireTZ (ceSchedule expr) tz refTime

-- | Compute next fire in UTC (no timezone). Searches minute by minute
-- from the reference time forward, up to a reasonable limit (366 days).
nextFireUTC :: CronSchedule -> UTCTime -> Maybe UTCTime
nextFireUTC sched refTime =
  case expand sched of
    Nothing -> Nothing
    Just ex -> findNextMatch ex refTime

-- | Compute next fire with timezone awareness.
nextFireTZ :: CronSchedule -> CronTimeZone -> UTCTime -> IO (Maybe UTCTime)
nextFireTZ sched tz refTime = do
  loadedTz <- loadTZFromDB (T.unpack (cronTimeZoneText tz))
  let localRef = utcToLocalTimeTZ loadedTz refTime
      pseudoUtc = localTimeToUTC utc localRef
  case nextFireUTC sched pseudoUtc of
    Nothing -> pure Nothing
    Just nextPseudoUtc -> do
      let nextLocal = utcToLocalTime utc nextPseudoUtc
      pure (Just (localTimeToUTCTZ loadedTz nextLocal))

-- | Find the next time after @refTime@ that matches all cron fields.
-- Searches up to 366 days forward (527040 minutes).
findNextMatch :: Expanded -> UTCTime -> Maybe UTCTime
findNextMatch ex refTime =
  let truncated = truncateToMinute refTime
      startMinute = addOneMinute truncated
  in go 0 startMinute
  where
    go :: Int -> UTCTime -> Maybe UTCTime
    go n t
      | n >= 366 * 24 * 60 = Nothing
      | matchesExpanded ex t = Just t
      | otherwise = go (n + 1) (addOneMinute t)

-- | Check if a 'UTCTime' matches all fields of an 'Expanded' cron schedule.
matchesExpanded :: Expanded -> UTCTime -> Bool
matchesExpanded ex t =
  let (_year, month, day) = toGregorian (utctDay t)
      secs = utctDayTime t
      totalSecs = floor secs :: Int
      hour = totalSecs `div` 3600
      minute = (totalSecs `div` 60) `mod` 60
      dowNum = dowToInt (dayOfWeek (utctDay t))
  in  inSet minute (minF ex)
      && inSet hour (hourF ex)
      && inSet day (domF ex)
      && inSet month (monthF ex)
      && inSet dowNum (dowF ex)

-- | Check if an 'Int' is in the expanded field's 'NonEmpty Int' list.
inSet :: Int -> NonEmpty Int -> Bool
inSet x = elem x . toList

-- | Convert 'DayOfWeek' to cron integer (0=Sunday, 7=Sunday, 1=Monday..6=Saturday).
-- The cron package uses 0-7 where both 0 and 7 mean Sunday.
dowToInt :: DayOfWeek -> Int
dowToInt Sunday = 0
dowToInt Monday = 1
dowToInt Tuesday = 2
dowToInt Wednesday = 3
dowToInt Thursday = 4
dowToInt Friday = 5
dowToInt Saturday = 6

-- | Add one minute to a 'UTCTime'.
addOneMinute :: UTCTime -> UTCTime
addOneMinute = addUTCTime 60

-- | Truncate a 'UTCTime' to the minute boundary (zero out seconds).
-- Ensures cron fire times are always at second 0.
truncateToMinute :: UTCTime -> UTCTime
truncateToMinute t =
  let secs = floor (utctDayTime t) :: Int
  in t { utctDayTime = fromIntegral ((secs `div` 60) * 60) }
