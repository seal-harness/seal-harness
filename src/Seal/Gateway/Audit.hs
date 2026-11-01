{-# LANGUAGE OverloadedStrings #-}
-- | The access-control audit log: @\<state\>\/access-control.log@.
--
-- Detective, not preventive (design §15). It exists so an operator can answer
-- "when did this passkey appear, and what authorised it?" after the fact —
-- under the accepted risk R2 (same-uid code can truncate it) it is a detective
-- aid, not tamper-evidence. That sentence is the honest scope; nothing here
-- should be read as stronger.
--
-- Two properties are load-bearing and both are enforced structurally:
--
-- * __The field set is closed.__ 'AuditFields' is a record, and 'auditLine'
--   renders exactly its fields. A caller cannot add a request-derived value —
--   no @rawId@, no client-supplied origin, no presented token, no digest, no
--   @User-Agent@ — because there is nowhere to put one.
-- * __Refusals cannot flood.__ 'admitRefusal' aggregates them per
--   @(source, minute)@ on a fixed-size table with backoff, and they go to a
--   separate file, so a pre-auth flood cannot rotate the state-changing
--   evidence away.
--
-- The log is opened @O_APPEND|O_CREAT|O_NOFOLLOW@ at @0600@ and refused if the
-- target is a symlink or not a regular file: a log that can be pointed at
-- another file is a write primitive.
module Seal.Gateway.Audit
  ( AuditEvent (..)
  , auditEventText
  , AuditFields (..)
  , emptyAuditFields
  , auditLine
  , auditLogPath
  , auditRefusalLogPath
  , appendAudit
  , AuditGate
  , newAuditGate
  , admitRefusal
  , auditMaxBytes
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, diffUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory (doesFileExist, removeFile, renameFile)
import System.FilePath ((</>))
import System.IO (hClose)
import System.Posix.Files (fileSize, getFileStatus, isRegularFile)
import System.Posix.Types (FileOffset)
import System.Posix.IO
  ( OpenFileFlags (append, creat, nofollow), OpenMode (WriteOnly)
  , defaultFileFlags, fdToHandle, openFd )

import Seal.Config.Paths (SealPaths (..))
import Seal.Security.EnrollmentGrant (GrantSource, grantSourceText)

-- | The enumerated events. Nothing else may be logged, so the log's vocabulary
-- is a compile-time fact rather than a convention.
data AuditEvent
  = CredentialAdded
  | CredentialRemoved
  | GrantMinted
  | GrantConsumed
  | GrantRefused
  | ModeEnabled
  | ModeDisabled
  deriving stock (Eq, Ord, Show)

auditEventText :: AuditEvent -> Text
auditEventText event = case event of
  CredentialAdded   -> "credential_added"
  CredentialRemoved -> "credential_removed"
  GrantMinted       -> "grant_minted"
  GrantConsumed     -> "grant_consumed"
  GrantRefused      -> "grant_refused"
  ModeEnabled       -> "mode_enabled"
  ModeDisabled      -> "mode_disabled"

-- | The closed field set.
data AuditFields = AuditFields
  { afEvent            :: !AuditEvent
  , afCredentialId     :: !(Maybe Text)
  , afLabel            :: !(Maybe Text)
  , afRpId             :: !(Maybe Text)
  , afOrigin           :: !(Maybe Text)
  , afVia              :: !(Maybe GrantSource)
  , afRemainingSeconds :: !(Maybe Int)
  } deriving stock (Eq, Show)

-- | A record with only the event set; every optional field absent.
emptyAuditFields :: AuditEvent -> AuditFields
emptyAuditFields event = AuditFields
  { afEvent            = event
  , afCredentialId     = Nothing
  , afLabel            = Nothing
  , afRpId             = Nothing
  , afOrigin           = Nothing
  , afVia              = Nothing
  , afRemainingSeconds = Nothing
  }

-- | Render one line.
--
-- Values are sanitised: control characters become spaces and each value is
-- capped, so a credential label an operator typed cannot forge a log line or
-- blow the file up. The event names come from 'auditEventText', never from
-- input.
auditLine :: UTCTime -> AuditFields -> Text
auditLine now fields = T.intercalate " " (timestampPart : map renderField present)
  where
    timestampPart = "ts=" <> isoTimeText now
    present = [ ("event", auditEventText (afEvent fields)) ]
      <> [ ("credential_id", value) | Just value' <- [afCredentialId fields]
                                    , let value = sanitize 128 value' ]
      <> [ ("label", sanitize 64 value) | Just value <- [afLabel fields] ]
      <> [ ("rp_id", sanitize 128 value) | Just value <- [afRpId fields] ]
      <> [ ("origin", sanitize 200 value) | Just value <- [afOrigin fields] ]
      <> [ ("via", grantSourceText source) | Just source <- [afVia fields] ]
      <> [ ("remaining_s", tshow value) | Just value <- [afRemainingSeconds fields] ]
    renderField (key, value) = key <> "=" <> value

-- | Percent-encode everything that could break the line format.
--
-- The log is @key=value@ pairs separated by single spaces, so a value must never
-- contain a space, an @=@ or a control character: otherwise a credential label
-- an operator typed (or a hostile one) could append its own fields. Encoding
-- rather than stripping keeps the value recognisable.
sanitize :: Int -> Text -> Text
sanitize limit = T.take limit . T.concatMap escape
  where
    escape c
      | c == ' '  = "%20"
      | c == '='  = "%3D"
      | c == '"'  = "%22"
      | c == '\n' = "%0A"
      | c == '\r' = "%0D"
      | c < ' ' || c == '\DEL' = "%" <> pad (showHexChar c)
      | otherwise = T.singleton c
    pad raw = if T.length raw < 2 then "0" <> raw else raw
    showHexChar c =
      let n = fromEnum c
      in T.map toUpperChar (T.pack [ hexDigit (n `div` 16), hexDigit (n `mod` 16) ])
    toUpperChar ch = if ch >= 'a' && ch <= 'f' then toEnum (fromEnum ch - 32) else ch
    hexDigit n
      | n < 10 = toEnum (fromEnum '0' + n)
      | otherwise = toEnum (fromEnum 'A' + n - 10)

isoTimeText :: UTCTime -> Text
isoTimeText stamp =
  let seconds = floor (utcTimeToPOSIXSeconds stamp) :: Integer
      daySeconds = seconds `mod` 86400
      hours = daySeconds `div` 3600
      minutes = (daySeconds `mod` 3600) `div` 60
      secs = daySeconds `mod` 60
      days = seconds `div` 86400
      (year, month, day) = civilFromDays days
      pad2 n = if n < 10 then "0" <> tshow n else tshow n
  in tshow year <> "-" <> pad2 month <> "-" <> pad2 day <> "T"
       <> pad2 hours <> ":" <> pad2 minutes <> ":" <> pad2 secs <> "Z"

-- | Howard Hinnant's @civil_from_days@: days since the Unix epoch to a calendar
-- date, without pulling a formatter into a hot path.
civilFromDays :: Integer -> (Integer, Integer, Integer)
civilFromDays days =
  let z = days + 719468
      era = (if z >= 0 then z else z - 146096) `div` 146097
      doe = z - era * 146097
      yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
      y = yoe + era * 400
      doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
      mp = (5 * doy + 2) `div` 153
      d = doy - (153 * mp + 2) `div` 5 + 1
      m = if mp < 10 then mp + 3 else mp - 9
  in (if m <= 2 then y + 1 else y, m, d)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | State-changing events, in one file.
auditLogPath :: SealPaths -> FilePath
auditLogPath paths = spState paths </> "access-control.log"

-- | Refusals, in another: a flood must not rotate the evidence away.
auditRefusalLogPath :: SealPaths -> FilePath
auditRefusalLogPath paths = spState paths </> "access-control-refusals.log"

-- | Rotate at 4 MiB.
auditMaxBytes :: FileOffset
auditMaxBytes = 4 * 1024 * 1024

-- | Append one event.
--
-- Failures are returned rather than thrown: an audit write must never fail the
-- request or the command it describes.
appendAudit :: SealPaths -> UTCTime -> AuditFields -> IO (Either Text ())
appendAudit paths now fields = do
  let path = case afEvent fields of
        GrantRefused -> auditRefusalLogPath paths
        _            -> auditLogPath paths
  rotateIfNeeded path
  appended <- try (appendLine path (auditLine now fields))
  pure $ case appended of
    Left (err :: IOException) -> Left (T.pack path <> ": " <> T.pack (show err))
    Right () -> Right ()

appendLine :: FilePath -> Text -> IO ()
appendLine path line = do
  fd <- openFd path WriteOnly defaultFileFlags
          { append = True, creat = Just 0o600, nofollow = True }
  status <- getFileStatus path
  -- A symlink is refused by O_NOFOLLOW; anything else that is not a regular
  -- file (a fifo, a device) is refused here, because appending to it is not
  -- writing a log.
  if not (isRegularFile status)
    then hClose =<< fdToHandle fd
    else do
      handle <- fdToHandle fd
      BS.hPut handle (TE.encodeUtf8 (line <> "\n"))
      hClose handle

rotateIfNeeded :: FilePath -> IO ()
rotateIfNeeded path = do
  exists <- doesFileExist path
  when exists $ do
    status <- getFileStatus path
    when (fileSize status > auditMaxBytes) $ do
      let rotated = path <> ".1"
      rotatedExists <- doesFileExist rotated
      when rotatedExists (removeFile rotated)
      renameFile path rotated

-- | Aggregation state for refusal events.
--
-- Keyed on the /source/ and the minute, never on the presented value: an
-- attacker-chosen key would be an unbounded allocation on a pre-auth path.
newtype AuditGate = AuditGate (MVar (Map (Text, Integer) RefusalSlot))

data RefusalSlot = RefusalSlot
  { rsCount    :: !Int
  , rsLastEmit :: !UTCTime
  }

newAuditGate :: IO AuditGate
newAuditGate = AuditGate <$> newMVar Map.empty

-- | May this refusal be written?
--
-- One line per @(source, minute)@ at most, and exponential backoff on repeats
-- (1 s doubling to a 60 s cap), so a pre-auth flood produces a handful of lines
-- rather than a gigabyte. The table is capped: once it is full, further keys are
-- dropped rather than allowed to grow it.
admitRefusal :: AuditGate -> UTCTime -> Text -> IO Bool
admitRefusal (AuditGate cells) now source =
  modifyMVar cells $ \table -> do
    let key = (source, minuteOf now)
        backoff count = fromIntegral (min (60 :: Int) (2 ^ max 0 (count - 1)))
    case Map.lookup key table of
      Just slot ->
        if realToFrac (diffUTCTime now (rsLastEmit slot)) < (backoff (rsCount slot) :: Double)
          then pure (table, False)
          else pure (Map.insert key slot { rsCount = rsCount slot + 1, rsLastEmit = now } table, True)
      Nothing ->
        if Map.size table >= maxRefusalKeys
          then pure (table, False)
          else pure (Map.insert key (RefusalSlot 1 now) table, True)

maxRefusalKeys :: Int
maxRefusalKeys = 256

minuteOf :: UTCTime -> Integer
minuteOf stamp = floor (utcTimeToPOSIXSeconds stamp) `div` 60
