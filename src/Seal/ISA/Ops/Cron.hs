{-# LANGUAGE OverloadedStrings #-}
-- | The CRON_MANAGE opcode: action-based interface for managing cron jobs.
-- Audited trust level — cron job definitions are persistent, cross-session
-- state.
module Seal.ISA.Ops.Cron
  ( cronManageOp
  , CronFireDelegate
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( Value, object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)

import Seal.Core.Types (OpName (..), SessionId, TrustLevel (..), sessionIdText)
import Seal.Types.App (App)
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Cron.Types
import Seal.Cron.Store

type CronFireDelegate = CronJob -> IO (Either Text SessionId)

data CronAction
  = CaCreate | CaRead | CaList | CaUpdate | CaDelete | CaTrigger | CaEnable | CaDisable

parseCronAction :: Value -> Either Text CronAction
parseCronAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "create"  -> Right CaCreate
      "read"    -> Right CaRead
      "list"    -> Right CaList
      "update"  -> Right CaUpdate
      "delete"  -> Right CaDelete
      "trigger" -> Right CaTrigger
      "enable"  -> Right CaEnable
      "disable" -> Right CaDisable
      other     -> Left ("unknown cron action: " <> other)
    Nothing -> Left "missing or invalid action field"

idField :: Value -> Maybe Text
idField = parseMaybe (withObject "in" (.: "id"))

nameField :: Value -> Maybe Text
nameField = parseMaybe (withObject "in" (.: "name"))

scheduleField :: Value -> Maybe Text
scheduleField = parseMaybe (withObject "in" (.: "schedule"))

timezoneField :: Value -> Maybe Text
timezoneField v = joinMaybe (parseMaybe (withObject "in" (.:? "timezone")) v)

promptField :: Value -> Maybe Text
promptField = parseMaybe (withObject "in" (.: "prompt"))

agentDefIdField :: Value -> Maybe Text
agentDefIdField v = joinMaybe (parseMaybe (withObject "in" (.:? "agent_def_id")) v)

enabledField :: Value -> Bool
enabledField v = fromMaybe False (joinMaybe (parseMaybe (withObject "in" (.:? "enabled")) v))

oneShotField :: Value -> Bool
oneShotField v = fromMaybe False (joinMaybe (parseMaybe (withObject "in" (.:? "one_shot")) v))

enabledOnlyField :: Value -> Bool
enabledOnlyField v = fromMaybe False (joinMaybe (parseMaybe (withObject "in" (.:? "enabled_only")) v))

enabledField' :: Value -> Maybe Bool
enabledField' v = joinMaybe (parseMaybe (withObject "in" (.:? "enabled")) v)

oneShotField' :: Value -> Maybe Bool
oneShotField' v = joinMaybe (parseMaybe (withObject "in" (.:? "one_shot")) v)

joinMaybe :: Maybe (Maybe a) -> Maybe a
joinMaybe = (>>= id)

handleCreate :: CronStore -> Value -> App OpResult
handleCreate store v = do
  case (nameField v, scheduleField v, promptField v) of
    (Nothing, _, _) -> pure (errResult "create requires {name:string}")
    (_, Nothing, _) -> pure (errResult "create requires {schedule:string}")
    (_, _, Nothing) -> pure (errResult "create requires {prompt:string}")
    (Just name, Just sched, Just prompt) -> do
      case mkCronExpr sched of
        Left e -> pure (errResult e)
        Right expr -> do
          let mTz = timezoneField v >>= either (const Nothing) Just . mkCronTimeZone
              mAgentDefId = agentDefIdField v
              enabled = enabledField v
              oneShot = oneShotField v
          if T.null name || T.length name > 100
            then pure (errResult "name must be 1-100 characters")
            else if T.null prompt || T.length prompt > 4000
              then pure (errResult "prompt must be 1-4000 characters")
              else do
                allJobs <- liftIO (csList store False)
                if length allJobs >= 100
                  then pure (errResult "maximum job count (100) reached")
                  else do
                    let baseSlug = slugify name
                    existingIds <- liftIO (map (cronJobIdText . cjId) <$> csList store False)
                    let slug = dedupSlug baseSlug existingIds
                    case mkCronJobId slug of
                      Left e -> pure (errResult e)
                      Right jid -> do
                        now <- liftIO getCurrentTime
                        mNextFire <- liftIO (computeNextFire expr mTz now)
                        let job = CronJob
                              { cjId = jid, cjName = name, cjSchedule = expr
                              , cjTimezone = mTz, cjPrompt = prompt
                              , cjAgentDefId = mAgentDefId, cjEnabled = enabled
                              , cjOneShot = oneShot, cjCreatedAt = now
                              , cjUpdatedAt = now, cjLastFire = Nothing
                              , cjRunCount = 0, cjConsecutiveFailures = 0 }
                        liftIO (csCreate store job)
                        pure (OpResult
                          [ TrpText ("created job '" <> name <> "' (id: " <> slug
                                     <> "), next fire: " <> tshowUTC mNextFire) ]
                          False
                          (object [ "action" .= ("create" :: Text), "id" .= slug
                                  , "name" .= name, "schedule" .= sched
                                  , "enabled" .= enabled, "one_shot" .= oneShot
                                  , "next_fire" .= mNextFire ]))

handleRead :: CronStore -> Value -> App OpResult
handleRead store v = do
  case idField v >>= either (const Nothing) Just . mkCronJobId of
    Nothing -> pure (errResult "read requires {id:string}")
    Just jid -> do
      mJob <- liftIO (csRead store jid)
      case mJob of
        Nothing -> pure (OpResult
          [ TrpText ("cron job not found: " <> cronJobIdText jid) ] True
          (object [ "action" .= ("read" :: Text), "id" .= cronJobIdText jid, "found" .= False ]))
        Just job -> pure (OpResult
          [ TrpText (renderJob job) ] False
          (object [ "action" .= ("read" :: Text), "id" .= cronJobIdText jid, "found" .= True
                  , "name" .= cjName job, "schedule" .= cronExprText (cjSchedule job)
                  , "enabled" .= cjEnabled job, "one_shot" .= cjOneShot job ]))

handleList :: CronStore -> Value -> App OpResult
handleList store v = do
  let enabledOnly = enabledOnlyField v
  jobs <- liftIO (csList store enabledOnly)
  let rendered = case jobs of
        [] -> "(no cron jobs defined)"
        _ -> T.intercalate "\n"
               [ cronJobIdText (cjId j)
                 <> " [" <> (if cjEnabled j then "enabled" else "disabled" :: Text) <> "]: "
                 <> cjName j <> " — " <> cronExprText (cjSchedule j)
               | j <- jobs ]
  pure (OpResult [TrpText rendered] False
         (object [ "action" .= ("list" :: Text), "count" .= length jobs
                 , "ids" .= map (cronJobIdText . cjId) jobs
                 , "enabled_count" .= length (filter cjEnabled jobs) ]))

handleUpdate :: CronStore -> Value -> App OpResult
handleUpdate store v = do
  case idField v >>= either (const Nothing) Just . mkCronJobId of
    Nothing -> pure (errResult "update requires {id:string}")
    Just jid -> do
      mJob <- liftIO (csRead store jid)
      case mJob of
        Nothing -> pure (OpResult
          [ TrpText ("cron job not found: " <> cronJobIdText jid) ] True
          (object [ "action" .= ("update" :: Text), "id" .= cronJobIdText jid, "found" .= False ]))
        Just job -> do
          let mNewSched = scheduleField v
          case maybe (Right (cjSchedule job)) mkCronExpr mNewSched of
            Left e -> pure (errResult e)
            Right newSched -> do
              let newTz = case timezoneField v of
                    Just tzText -> either (const Nothing) Just (mkCronTimeZone tzText)
                    Nothing -> cjTimezone job
              now <- liftIO getCurrentTime
              mNextFire <- liftIO (computeNextFire newSched newTz now)
              let updatedJob = job
                    { cjName = fromMaybe (cjName job) (nameField v)
                    , cjSchedule = newSched, cjTimezone = newTz
                    , cjPrompt = fromMaybe (cjPrompt job) (promptField v)
                    , cjAgentDefId = case agentDefIdField v of
                        Just aid -> Just aid; Nothing -> cjAgentDefId job
                    , cjEnabled = fromMaybe (cjEnabled job) (enabledField' v)
                    , cjOneShot = fromMaybe (cjOneShot job) (oneShotField' v)
                    , cjUpdatedAt = now }
              liftIO (csSave store updatedJob)
              pure (OpResult
                [ TrpText ("updated job '" <> cronJobIdText jid <> "'") ] False
                (object [ "action" .= ("update" :: Text), "id" .= cronJobIdText jid
                        , "next_fire" .= mNextFire ]))

handleDelete :: CronStore -> Value -> App OpResult
handleDelete store v = do
  case idField v >>= either (const Nothing) Just . mkCronJobId of
    Nothing -> pure (errResult "delete requires {id:string}")
    Just jid -> do
      mJob <- liftIO (csRead store jid)
      liftIO (csDelete store jid)
      let existed = isJust mJob
      pure (OpResult
        [ TrpText (if existed then "deleted" else "deleted (was not present)") ] False
        (object [ "action" .= ("delete" :: Text), "id" .= cronJobIdText jid, "existed" .= existed ]))

handleTrigger :: Maybe CronFireDelegate -> CronStore -> Value -> App OpResult
handleTrigger mFireDelegate store v = do
  case idField v >>= either (const Nothing) Just . mkCronJobId of
    Nothing -> pure (errResult "trigger requires {id:string}")
    Just jid -> do
      mJob <- liftIO (csRead store jid)
      case mJob of
        Nothing -> pure (OpResult
          [ TrpText ("cron job not found: " <> cronJobIdText jid) ] True
          (object [ "action" .= ("trigger" :: Text), "id" .= cronJobIdText jid, "found" .= False ]))
        Just job -> case mFireDelegate of
          Nothing -> pure (errResult "trigger not available (no fire delegate configured)")
          Just fire -> do
            eResult <- liftIO (fire job)
            case eResult of
              Left err -> pure (errResult ("trigger failed: " <> err))
              Right sid -> pure (OpResult
                [ TrpText ("triggered job '" <> cronJobIdText jid
                           <> "', session: " <> sessionIdText sid) ] False
                (object [ "action" .= ("trigger" :: Text), "id" .= cronJobIdText jid
                        , "session_id" .= sessionIdText sid ]))

handleEnable :: CronStore -> Value -> App OpResult
handleEnable store v = do
  case idField v >>= either (const Nothing) Just . mkCronJobId of
    Nothing -> pure (errResult "enable requires {id:string}")
    Just jid -> do
      mJob <- liftIO (csRead store jid)
      case mJob of
        Nothing -> pure (OpResult
          [ TrpText ("cron job not found: " <> cronJobIdText jid) ] True
          (object [ "action" .= ("enable" :: Text), "id" .= cronJobIdText jid, "found" .= False ]))
        Just job -> do
          now <- liftIO getCurrentTime
          mNextFire <- liftIO (computeNextFire (cjSchedule job) (cjTimezone job) now)
          liftIO (csSave store job { cjEnabled = True, cjUpdatedAt = now })
          pure (OpResult
            [ TrpText ("enabled job '" <> cronJobIdText jid <> "', next fire: " <> tshowUTC mNextFire) ] False
            (object [ "action" .= ("enable" :: Text), "id" .= cronJobIdText jid, "next_fire" .= mNextFire ]))

handleDisable :: CronStore -> Value -> App OpResult
handleDisable store v = do
  case idField v >>= either (const Nothing) Just . mkCronJobId of
    Nothing -> pure (errResult "disable requires {id:string}")
    Just jid -> do
      mJob <- liftIO (csRead store jid)
      case mJob of
        Nothing -> pure (OpResult
          [ TrpText ("cron job not found: " <> cronJobIdText jid) ] True
          (object [ "action" .= ("disable" :: Text), "id" .= cronJobIdText jid, "found" .= False ]))
        Just job -> do
          now <- liftIO getCurrentTime
          liftIO (csSave store job { cjEnabled = False, cjUpdatedAt = now })
          pure (OpResult
            [ TrpText ("disabled job '" <> cronJobIdText jid <> "'") ] False
            (object [ "action" .= ("disable" :: Text), "id" .= cronJobIdText jid ]))

authorizeCronManage :: Value -> Either Text ()
authorizeCronManage v =
  case parseCronAction v of
    Left e -> Left e
    Right action -> case action of
      CaCreate -> do
        case (nameField v, scheduleField v, promptField v) of
          (Just name, Just sched, Just _prompt) -> do
            whenB (T.null name || T.length name > 100) (Left "name must be 1-100 characters")
            case mkCronExpr sched of
              Left e -> Left e
              Right _ -> case timezoneField v of
                Just tzText -> const (Right ()) =<< mkCronTimeZone tzText
                Nothing -> Right ()
          _ -> Left "create requires {name, schedule, prompt}"
      CaRead    -> checkId v "read"
      CaList    -> Right ()
      CaUpdate  -> do
        _ <- checkId v "update"
        let hasField = any isJust [nameField v, scheduleField v, timezoneField v, promptField v]
                      || isJust (enabledField' v) || isJust (oneShotField' v)
        if hasField then Right () else Left "update requires at least one field to update"
      CaDelete  -> checkId v "delete"
      CaTrigger -> checkId v "trigger"
      CaEnable  -> checkId v "enable"
      CaDisable -> checkId v "disable"

checkId :: Value -> Text -> Either Text ()
checkId v actionName =
  case idField v of
    Nothing -> Left (actionName <> " requires {id:string}")
    Just t -> const (Right ()) =<< mkCronJobId t

cronManageOp :: Maybe CronFireDelegate -> CronStore -> SessionId -> Opcode
cronManageOp mFireDelegate store _session = TrustedOpcode
  { toName = OpName "CRON_MANAGE"
  , toTrust = Audited
  , toDesc = "Manage cron jobs. Use action to select: create (new job), read (by id), list (all jobs), update (modify by id), delete (by id, idempotent), trigger (fire immediately), enable (enable job), disable (pause job)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["create","read","list","update","delete","trigger","enable","disable"] :: [Text])
              , "description" .= ("Operation to perform." :: Text) ]
          , fromText "id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Cron job id ([a-z0-9-]+) (read, update, delete, trigger, enable, disable)." :: Text) ]
          , fromText "name" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Human-readable job name, max 100 chars (create, update)." :: Text) ]
          , fromText "schedule" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("5-field cron expression, e.g. \"0 9 * * 1-5\" (create, update)." :: Text) ]
          , fromText "timezone" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("IANA timezone, e.g. \"America/New_York\" (create, update)." :: Text) ]
          , fromText "prompt" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Prompt to run on each fire, max 4000 chars (create, update)." :: Text) ]
          , fromText "agent_def_id" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("Agent def id to use (create, update). Default: default agent." :: Text) ]
          , fromText "enabled" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("Initial enabled state (create, update). Default: false on create." :: Text) ]
          , fromText "one_shot" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("If true, auto-disable after first run (create, update). Default: false." :: Text) ]
          , fromText "enabled_only" .= object
              [ "type" .= ("boolean" :: Text)
              , "description" .= ("List only enabled jobs (list). Default: false." :: Text) ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeCronManage
  , toBlocking = False
  , toRun = \_ v ->
      case parseCronAction v of
        Left e -> pure (errResult e)
        Right action -> case action of
          CaCreate  -> handleCreate store v
          CaRead    -> handleRead store v
          CaList    -> handleList store v
          CaUpdate  -> handleUpdate store v
          CaDelete  -> handleDelete store v
          CaTrigger -> handleTrigger mFireDelegate store v
          CaEnable  -> handleEnable store v
          CaDisable -> handleDisable store v
  }

errResult :: Text -> OpResult
errResult msg = OpResult [TrpText msg] True (object [])

renderJob :: CronJob -> Text
renderJob j = T.intercalate "\n"
  [ "id: " <> cronJobIdText (cjId j)
  , "name: " <> cjName j
  , "schedule: " <> cronExprText (cjSchedule j)
  , "timezone: " <> maybe "(host local)" cronTimeZoneText (cjTimezone j)
  , "prompt: " <> cjPrompt j
  , "enabled: " <> (if cjEnabled j then "true" else "false" :: Text)
  , "one_shot: " <> (if cjOneShot j then "true" else "false" :: Text)
  , "run_count: " <> T.pack (show (cjRunCount j))
  , "consecutive_failures: " <> T.pack (show (cjConsecutiveFailures j))
  ]

dedupSlug :: Text -> [Text] -> Text
dedupSlug base existingIds
  | base `notElem` existingIds = base
  | otherwise = go (2 :: Int)
  where
    go :: Int -> Text
    go n = let c = base <> "-" <> T.pack (show n)
           in if c `notElem` existingIds then c else go (n + 1)

tshowUTC :: Maybe UTCTime -> Text
tshowUTC = maybe "unknown" (T.pack . show)

whenB :: Bool -> Either Text () -> Either Text ()
whenB True e = e
whenB False _ = Right ()
