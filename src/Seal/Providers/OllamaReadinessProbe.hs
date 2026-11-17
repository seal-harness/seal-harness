{-# LANGUAGE OverloadedStrings #-}
-- | The I/O half of Ollama readiness: the HTTP probe, the TTL cache, the
-- single-flight gate, the binary lookup and the RAM reader.
--
-- == The rules this module exists to enforce
--
-- 1. /Keyless./ Every request comes from
--    'Seal.Providers.OllamaReadiness.probeTargetFor', never through
--    @withHeaders@. The vault key cannot reach an operator-set @base_url@
--    because no code path here can read the vault at all — there is no
--    'Seal.Security.Vault.VaultHandle' anywhere in this module's interface.
--
-- 2. /The provider manager, never the gateway manager./ The manager is a
--    parameter ('pcManager'). @gatewayManager@ installs a
--    @managerModifyRequest@ that stamps @Authorization: Bearer \<service
--    token\>@ onto every request; building the probe on it would ship that
--    token to an operator-set URL. The wiring site passes the provider
--    manager, and a test constructs the factory over a manager that stamps a
--    sentinel header to prove the factory honours whatever it is given.
--
-- 3. /Bounded, twice./ A short per-request timeout (default 2 s) and a 256 KiB
--    accumulating body cap. The timeout is a liveness requirement, not a
--    nicety: the cache holds at most one in-flight probe /globally/, so a probe
--    that never returns would hold that slot forever and silently starve every
--    later refresh.
--
-- 4. /Never inline./ A request handler reads the cached 'IORef' and returns; it
--    never performs the outbound call. Refreshes happen out of band.
--
-- All seams are fields of 'ProbesConfig' rather than positional arguments:
-- production calls 'defaultProbesConfig' and tests override only the field
-- under test. That is what makes the timeout, TTL, clock, PATH lookup and RAM
-- reader hermetically testable — no real network, no real PATH, no 30 s sleeps.
module Seal.Providers.OllamaReadinessProbe
  ( OllamaProbes (..)
  , ProbesConfig (..)
  , defaultProbesConfig
  , defaultTtlMicro
  , mkOllamaProbes
  , bodyCapBytes
  , parseTagsBody
  , probeOnce
  , findOllamaExecutable
  , readTotalRam
  , parseMemTotal
  , memTotalPath
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Data.Aeson (Value, eitherDecodeStrict', withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
  ( IORef, atomicModifyIORef', newIORef, readIORef, writeIORef )
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import Network.HTTP.Client
  ( BodyReader, HttpException, Manager, Request (..), brReadSome
  , responseBody, responseStatus, responseTimeoutMicro, withResponse )
import Network.HTTP.Types.Status (statusCode)
import System.Directory (findExecutable)
import System.Info (os)
import System.Process (readProcess)

import Seal.Config.File (RuntimeConfig, providerBaseUrl)
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.OllamaReadiness
  ( OllamaHostKind (..), OllamaProbe (..), OllamaProbeError (..)
  , OllamaReadiness (..), OllamaTag (..), classifyOllamaReadiness
  , classifyProbeFailure, hostKindFor, probeTargetFor, probeTimeoutMicro
  , singleFlightKey )

-- | The seam record. Every field is a seam so each rule above is testable in
-- isolation; 'defaultProbesConfig' fills in production values.
data ProbesConfig = ProbesConfig
  { pcManager      :: Manager
    -- ^ The PROVIDER manager (the @mgr@ from @Serve.hs@), never @gatewayManager@.
  , pcReadConfig   :: IO RuntimeConfig
    -- ^ Re-read on every refresh (D2.10), so an edited @base_url@ takes effect
    --   without a restart.
  , pcTimeoutMicro :: Int
    -- ^ Per-request timeout (D2.7), default two seconds.
  , pcTtlMicro     :: Int
    -- ^ Cache TTL (D2.5), default 30 s. Injectable so a test never sleeps.
  , pcNow          :: IO UTCTime
    -- ^ Injectable clock, so TTL expiry is a unit under test, not a wait.
  , pcIsExecutable :: Text -> IO (Maybe FilePath)
    -- ^ @findExecutable@ seam: tests must not consult the real PATH.
  , pcTotalRam     :: IO (Maybe Word64)
    -- ^ RAM reader seam (WU-B's fit predicate consumes it; WU-A stores it).
  }

-- | Production seams: the only place a real manager, a real clock and a real
-- PATH lookup are wired in.
defaultProbesConfig :: Manager -> IO RuntimeConfig -> ProbesConfig
defaultProbesConfig mgr loadCfg = ProbesConfig
  { pcManager      = mgr
  , pcReadConfig   = loadCfg
  , pcTimeoutMicro = probeTimeoutMicro
  , pcTtlMicro     = defaultTtlMicro
  , pcNow          = getCurrentTime
  , pcIsExecutable = findExecutable . T.unpack
  , pcTotalRam     = readTotalRam
  }

-- | The cache TTL: 30 s (design D2.5).
defaultTtlMicro :: Int
defaultTtlMicro = 30_000_000

-- | The read side of the seam, plus the actions behind it.
data OllamaProbes = OllamaProbes
  { oprReadiness :: IO OllamaReadiness
    -- ^ Returns the cached value /immediately/, kicking an async refresh when
    --   the entry is older than the TTL. Never blocks on the network.
  , oprRefresh   :: IO ()
    -- ^ Forks a probe and returns immediately. The startup warm only.
  , oprTotalRam  :: IO (Maybe Word64)
    -- ^ Memoised on success (WU-B).
  }

-- | The cache's mutable state. Every transition goes through
-- 'atomicModifyIORef'' — never read-then-write, the race this repo has already
-- been bitten by once (@claimToolCallIds@).
data CacheState = CacheState
  { csReadiness :: !OllamaReadiness
  , csFetchedAt :: !(Maybe UTCTime)
  , csInFlight  :: !(Maybe Text)  -- ^ the single-flight key currently probing
  }

-- | Build the seam. The returned actions close over one cache, so two sessions
-- observing one base URL cannot disagree, and the startup warm and the handlers
-- share it.
mkOllamaProbes :: ProbesConfig -> IO OllamaProbes
mkOllamaProbes cfg = do
  cache    <- newIORef CacheState
    { csReadiness = RdPending, csFetchedAt = Nothing, csInFlight = Nothing }
  ramCache <- newIORef Nothing
  pure OllamaProbes
    { oprReadiness = readWithRefresh cfg cache
    , oprRefresh   = void (forkIO (refresh cfg cache))
    , oprTotalRam  = memoisedRam cfg ramCache
    }

-- | Read the cache; kick a refresh when stale or never probed. The value
-- returned is whatever the cache holds /now/, so the caller never waits.
readWithRefresh :: ProbesConfig -> IORef CacheState -> IO OllamaReadiness
readWithRefresh cfg cache = do
  st  <- readIORef cache
  now <- pcNow cfg
  let ageMicro = fmap (micros . diffUTCTime now) (csFetchedAt st)
      stale = case ageMicro of
        Nothing   -> True
        Just age  -> age >= fromIntegral (pcTtlMicro cfg)
  if stale
    then do
      void (forkIO (refresh cfg cache))
      pure (csReadiness st)
    else pure (csReadiness st)

-- | Microseconds in a 'Data.Time.Clock.NominalDiffTime' (which is a
-- 'Data.Fixed.Pico'). Exact, no floating point.
micros :: RealFrac a => a -> Integer
micros d = round (d * 1_000_000)

-- | One probe pass: re-read config, take the single-flight slot atomically,
-- probe, store, release. The slot is released in both the success and the
-- failure path — a leaked slot would starve every later refresh permanently.
refresh :: ProbesConfig -> IORef CacheState -> IO ()
refresh cfg cache = do
  runtimeCfg <- pcReadConfig cfg
  let baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl runtimeCfg "ollama")
      key     = singleFlightKey baseUrl
  claimed <- claimSlot cache key
  when claimed $ do
    result <- try (probeOnce cfg baseUrl) :: IO (Either SomeException OllamaReadiness)
    now <- pcNow cfg
    atomicModifyIORef' cache $ const ( CacheState
      { csReadiness = fromRight RdUnknown result
      , csFetchedAt = Just now
      , csInFlight  = Nothing
      }, () )

-- | Atomically take the single-flight slot, but only when nothing else holds
-- it. A global cap of one (D2.6) means a second URL waits rather than running
-- concurrently; a re-entry while a probe is in flight is a no-op.
claimSlot :: IORef CacheState -> Text -> IO Bool
claimSlot cache key = atomicModifyIORef' cache $ \st -> case csInFlight st of
  Just _  -> (st, False)
  Nothing -> (st { csInFlight = Just key }, True)

-- | One probe: URL-shape/floor validation, then the HTTP round-trip.
probeOnce :: ProbesConfig -> Text -> IO OllamaReadiness
probeOnce cfg baseUrl = case hostKindFor baseUrl of
  -- ollama.com is never probed (D3.2): there is nothing local to observe.
  OhCloud -> pure RdCloud
  kind -> do
    binary <- binaryPresent cfg kind
    ram    <- pcTotalRam cfg
    tags   <- case probeTargetFor baseUrl of
      Left _    -> pure (Left OpeBlocked)
      Right req -> probeTagsWith cfg req
    pure (classifyOllamaReadiness OllamaProbe
      { opHostKind      = kind
      , opTags          = tags
      , opBinaryPresent = binary
      , opTotalRam      = ram
      })

-- | D3.3: PATH is only meaningful for a loopback URL. Consulting it for a LAN
-- or remote host would label a Docker-hosted daemon on another machine "not
-- installed" on the strength of /our/ PATH.
binaryPresent :: ProbesConfig -> OllamaHostKind -> IO Bool
binaryPresent cfg kind = case kind of
  OhDefaultLoopback -> isJustPath <$> pcIsExecutable cfg "ollama"
  OhLoopback        -> isJustPath <$> pcIsExecutable cfg "ollama"
  _                 -> pure False
  where
    isJustPath (Just _) = True
    isJustPath Nothing  = False

-- | Run the validated request and decode the tag list. The timeout is applied
-- here from 'pcTimeoutMicro' so a test can shorten it without rebuilding the
-- request.
probeTagsWith :: ProbesConfig -> Request -> IO (Either OllamaProbeError [OllamaTag])
probeTagsWith cfg req0 = do
  let req = req0 { responseTimeout = responseTimeoutMicro (pcTimeoutMicro cfg) }
  result <- try (readCapped (pcManager cfg) req) :: IO (Either HttpException (Int, ByteString))
  pure $ case result of
    Left e                    -> Left (classifyProbeFailure e)
    Right (code, body)        -> decodeStatus code body

-- | One GET, with the body read as an /accumulating/ loop until 'BS.empty' or
-- 'bodyCapBytes'. A single 'brReadSome' may return short and would truncate a
-- healthy remote daemon into a permanent @unknown@; reading past the cap is
-- 'HttpException'→'OpeBadResponse' territory, so the cap is signalled by
-- returning the over-long body and letting 'decodeStatus' reject it.
--
-- http-client's 'withResponse' plus a manual loop is what makes the cap
-- enforceable; 'httpLbs' would read the whole body first.
readCapped :: Manager -> Request -> IO (Int, ByteString)
readCapped mgr req = withResponse req mgr $ \resp -> do
  let code = statusCode (responseStatus resp)
  if code < 200 || code > 299
    then do
      -- A non-2xx body is still bounded, but only its presence matters: the
      -- status is the payload.
      _ <- drainCapped (responseBody resp)
      pure (code, BS.empty)
    else do
      body <- drainCapped (responseBody resp)
      pure (code, BL.toStrict body)

-- | Accumulate until end-of-body or the cap, whichever comes first. Stops one
-- chunk past the cap so 'decodeStatus' can tell "exactly at the cap" (fine)
-- from "over it" (reject).
drainCapped :: BodyReader -> IO BL.ByteString
drainCapped br = go BL.empty
  where
    go acc
      | BL.length acc > fromIntegral bodyCapBytes = pure acc
      | otherwise = do
          chunk <- brReadSome br 32768
          if BL.null chunk
            then pure acc
            else go (acc <> chunk)

-- | Decide from the status and the (already bounded) body.
decodeStatus :: Int -> ByteString -> Either OllamaProbeError [OllamaTag]
decodeStatus code body
  | code < 200 || code > 299  = Left (OpeHttp code)
  | BS.length body > bodyCapBytes = Left OpeBadResponse
  | otherwise = case parseTagsBody body of
      Left _  -> Left OpeBadResponse
      Right t -> Right t

-- | The 256 KiB body cap (D2.3). A hostile or broken daemon cannot make the
-- gateway allocate without bound.
bodyCapBytes :: Int
bodyCapBytes = 256 * 1024

-- | Decode @{"models":[{"name":"..."}]}@. Pure, so the wire shape is testable
-- without a listener. An absent @models@ key is an empty list (a daemon with
-- nothing pulled is a real, reportable state); an entry without a @name@ makes
-- the whole body malformed, because a tag list we cannot fully trust is worse
-- than "unknown".
parseTagsBody :: ByteString -> Either Text [OllamaTag]
parseTagsBody raw = do
  value <- either (Left . T.pack) Right (eitherDecodeStrict' raw)
  either (Left . T.pack) Right (parseEither parseTags value)

parseTags :: Value -> Parser [OllamaTag]
parseTags = withObject "tags" $ \o -> do
  models <- o .:? "models" .!= []
  traverse (withObject "model" (\m -> OllamaTag <$> m .: "name")) models

-- | @findExecutable "ollama"@, tolerant of a missing PATH.
findOllamaExecutable :: IO (Maybe FilePath)
findOllamaExecutable = findExecutable "ollama"

-- | Memoise the RAM reader, but /only/ on success: a transient PATH miss must
-- not permanently disable the judgement (WU-B DoD 9).
memoisedRam :: ProbesConfig -> IORef (Maybe Word64) -> IO (Maybe Word64)
memoisedRam cfg ref = do
  cached <- readIORef ref
  case cached of
    Just r  -> pure (Just r)
    Nothing -> do
      r <- pcTotalRam cfg
      case r of
        Just v  -> writeIORef ref (Just v)
        Nothing -> pure ()
      pure r

-- | Total RAM in bytes. macOS reads @sysctl -n hw.memsize@ (absolute path
-- first, because @\/usr\/sbin@ is often absent from a launchd or GUI gateway's
-- PATH; then a plain-PATH retry); Linux reads @MemTotal@ from @\/proc\/meminfo@.
-- Any failure is 'Nothing', which degrades safely to "assume usable".
readTotalRam :: IO (Maybe Word64)
readTotalRam
  | os == "darwin" = readSysctlMem
  | otherwise = readProcMemTotal

-- | @\/usr\/sbin\/sysctl -n hw.memsize@, falling back to a plain-PATH
-- @sysctl@. 'readProcess' is a fixed-argv invocation of a specific trusted
-- binary (no shell, no operator-supplied argument), matching the precedent of
-- 'Seal.Tls.Cert' and friends.
readSysctlMem :: IO (Maybe Word64)
readSysctlMem = do
  r <- try (readProcess "/usr/sbin/sysctl" ["-n", "hw.memsize"] "")
  case r of
    Right out -> pure (parseWord64 out)
    Left (_ :: SomeException) -> do
      r2 <- try (readProcess "sysctl" ["-n", "hw.memsize"] "")
      case r2 of
        Right out -> pure (parseWord64 out)
        Left (_ :: SomeException) -> pure Nothing

parseWord64 :: String -> Maybe Word64
parseWord64 s = case reads (filter (`notElem` ("\r\n " :: String)) s) of
  [(n, "")] -> Just n
  _         -> Nothing

-- | Linux: @MemTotal@ from @\/proc\/meminfo@.
readProcMemTotal :: IO (Maybe Word64)
readProcMemTotal = do
  r <- try (readFile memTotalPath)
  pure $ case r of
    Left (_ :: SomeException) -> Nothing
    Right contents -> firstMatch (map (parseMemTotal . T.pack) (lines contents))

firstMatch :: [Maybe Word64] -> Maybe Word64
firstMatch [] = Nothing
firstMatch (Just v : _) = Just v
firstMatch (Nothing : rest) = firstMatch rest

memTotalPath :: FilePath
memTotalPath = "/proc/meminfo"

-- | Parse @MemTotal:@ from one @\/proc\/meminfo@ line. @kB@ is the only unit
-- accepted: a non-kB suffix yields 'Nothing' rather than a silent 1000x
-- rescale, because "RAM unknown" degrades safely while a wrong scale does not.
parseMemTotal :: Text -> Maybe Word64
parseMemTotal line = do
  rest0 <- T.stripPrefix "MemTotal:" line
  let fields = T.words rest0
  case fields of
    [valueT, unitT] -> do
      value <- readDecimal valueT
      if unitT == "kB" then Just (value * 1024) else Nothing
    _ -> Nothing
  where
    readDecimal t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _         -> Nothing
