{-# LANGUAGE OverloadedStrings #-}
-- | The I/O half of readiness, exercised entirely against **local loopback
-- listeners**. No external network, no real Ollama daemon, no real PATH lookup,
-- no real clock and no wall-clock sleeps: every seam in 'ProbesConfig' is
-- overridden per test.
module Seal.Providers.OllamaReadinessProbeSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Network.HTTP.Client
  ( Manager, defaultManagerSettings, managerModifyRequest, newManager )
import Network.HTTP.Client qualified as NHC
import Network.HTTP.Types (status200, status302, status500)
import Network.Wai (Application, responseLBS)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Test.Hspec

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), defaultRuntimeConfig )
import Seal.Providers.OllamaReadiness
import Seal.Providers.OllamaReadinessProbe

spec :: Spec
spec = describe "Seal.Providers.OllamaReadinessProbe" $ do

  describe "parseTagsBody (26: decode the whole body, never a prefix)" $ do

    it "decodes a two-segment model list fully" $
      parseTagsBody "{\"models\":[{\"name\":\"llama3.2\"},{\"name\":\"qwen3:8b\"}]}"
        `shouldBe` Right [OllamaTag "llama3.2" Nothing Nothing, OllamaTag "qwen3:8b" Nothing Nothing]

    it "an absent models key is an empty list (a daemon with nothing pulled)" $
      parseTagsBody "{}" `shouldBe` Right []

    it "a model entry without a name makes the body malformed" $
      parseTagsBody "{\"models\":[{\"size\":123}]}" `shouldSatisfy` isLeft'

    it "invalid JSON is malformed" $
      parseTagsBody "not json" `shouldSatisfy` isLeft'

  describe "the wire (24: the listener observes a keyless request)" $ do

    -- This is the test that actually observes manager-level header injection:
    -- a pure header-construction check cannot see what a manager's
    -- managerModifyRequest adds.
    it "sends no Authorization header to the daemon" $
      withListener okTags $ \port seen -> do
        r <- probeAgainst 2_000_000 port
        r `shouldBe` RdReady 1
        reqs <- readIORef seen
        length reqs `shouldBe` 1
        mapM_ assertNoAuth reqs

    -- 25a, the REAL control: construct the factory over a manager that stamps a
    -- sentinel header, and prove the header ARRIVES. This is the half that
    -- would have caught the original bug class (a probe built on the wrong
    -- manager), and it is what makes 25b's source assertion a regression guard
    -- rather than the only evidence.
    it "25a: honours the manager it is given (a sentinel header arrives)" $
      withListener okTags $ \port seen -> do
        mgr <- newManager defaultManagerSettings
          { managerModifyRequest = \req -> pure
              (req { NHC.requestHeaders = ("X-Seal-Sentinel", "abc123") : NHC.requestHeaders req }) }
        let cfg = baseConfig mgr (pure (runtimeFor (urlFor port))) 2_000_000 30_000_000
        _ <- probeOnce cfg { pcManager = mgr } (urlFor port)
        reqs <- readIORef seen
        length reqs `shouldBe` 1
        let hdrs = case reqs of (h : _) -> h; [] -> []
        lookup "x-seal-sentinel" hdrs `shouldBe` Just "abc123"

    it "25a(ii): a manager that stamps Authorization IS observed by the listener" $
      -- The negative control for the pair above: proves the listener would
      -- catch a token-stamping manager, so "no Authorization" is meaningful.
      withListener okTags $ \port seen -> do
        mgr <- newManager defaultManagerSettings
          { managerModifyRequest = \req -> pure
              (req { NHC.requestHeaders = ("Authorization", "Bearer service-token") : NHC.requestHeaders req }) }
        let cfg = baseConfig mgr (pure (runtimeFor (urlFor port))) 2_000_000 30_000_000
        _ <- probeOnce cfg { pcManager = mgr } (urlFor port)
        reqs <- readIORef seen
        (case reqs of (h : _) -> lookup "authorization" h; [] -> Nothing)
          `shouldBe` Just "Bearer service-token"

    it "reaches the daemon at all (the control for the test above)" $
      withListener okTags $ \port seen -> do
        _ <- probeAgainst 2_000_000 port
        n <- length <$> readIORef seen
        n `shouldBe` 1

  describe "the short timeout (6b: a liveness requirement)" $ do

    -- D2.6 caps in-flight probes at one GLOBALLY. A probe that never returns
    -- would hold that slot forever and starve every later refresh permanently —
    -- a worse failure than the bug being fixed.
    it "returns RdUnknown well under 5 s when the daemon never answers" $
      withListener neverAnswers $ \port _ -> do
        start <- getCurrentTime
        r <- probeAgainst 200_000 port
        end <- getCurrentTime
        let elapsed = diffUTCTime start end
        r `shouldBe` RdUnknown
        realToFrac elapsed `shouldSatisfy` (< (5 :: Double))

    it "releases the single-flight slot, so a later refresh still runs" $
      withListener hangsOnce $ \port seen -> do
        -- The first probe times out against the hanging listener; if the slot
        -- leaked, every later refresh would be a silent no-op forever.
        probes <- probesFor port 200_000 0
        _ <- oprRefresh probes
        waitForCount seen 1
        threadDelay 600_000
        _ <- oprRefresh probes
        waitForCount seen 2
        n <- length <$> readIORef seen
        n `shouldBe` 2

  describe "a 3xx is reported, never followed (test 9)" $ do

    it "a 302 lands in RdUnknown and the listener sees exactly one request" $
      withListener redirects $ \port seen -> do
        r <- probeAgainst 2_000_000 port
        r `shouldBe` RdUnknown
        n <- length <$> readIORef seen
        n `shouldBe` 1

    it "a 500 lands in RdUnknown" $
      withListener serverError $ \port _ -> do
        probeAgainst 2_000_000 port `shouldReturn` RdUnknown

  describe "the cache (8: TTL, a non-blocking read, an async refresh)" $ do

    it "a fresh cache returns RdPending before any probe completes" $
      withListener okTags $ \port _ -> do
        probes <- probesFor port 2_000_000 30_000_000
        oprReadiness probes `shouldReturn` RdPending

    it "within the TTL a read returns the cached value and issues no second request" $
      withListener okTags $ \port seen -> do
        probes <- probesFor port 2_000_000 30_000_000
        _ <- oprRefresh probes
        waitForCount seen 1
        oprReadiness probes `shouldReturn` RdReady 1
        threadDelay 150_000
        n <- length <$> readIORef seen
        n `shouldBe` 1

    it "past the TTL a read kicks exactly one further refresh" $
      withListener okTags $ \port seen -> do
        clock <- newIORef (0 :: Double)
        probes <- probesWithClock port clock
        _ <- oprRefresh probes
        waitForCount seen 1
        -- Advance the injected clock 31 s: the entry is now stale.
        modifyIORef' clock (+ 31)
        _ <- oprReadiness probes
        waitForCount seen 2
        n <- length <$> readIORef seen
        n `shouldBe` 2

    it "oprRefresh returns before its probe completes (the HTTP bind is never delayed)" $
      withListener slowTags $ \port _ -> do
        probes <- probesFor port 2_000_000 30_000_000
        start <- getCurrentTime
        oprRefresh probes
        end <- getCurrentTime
        let elapsed = diffUTCTime start end
        -- The probe itself takes 300 ms; returning must be far quicker.
        realToFrac elapsed `shouldSatisfy` (< (0.1 :: Double))

  describe "single-flight (28, 29: atomic, global cap 1, normalised key)" $ do

    it "28. concurrent refreshes issue exactly one request" $
      withListener slowTags $ \port seen -> do
        probes <- probesFor port 5_000_000 30_000_000
        sequence_ [oprRefresh probes, oprRefresh probes, oprRefresh probes]
        waitForCount seen 1
        threadDelay 400_000
        n <- length <$> readIORef seen
        n `shouldBe` 1

    it "29. two spellings differing only by a trailing slash share one cache entry" $
      withListener okTags $ \port seen -> do
        -- Probe with the trailing-slash spelling, then read with the bare
        -- spelling: the normalised key means the cached value is reused, so
        -- the two spellings issue exactly one probe between them.
        urls <- newIORef [urlFor port <> "/"]
        probes <- probesReadingFrom urls 2_000_000 30_000_000
        _ <- oprRefresh probes
        waitForCount seen 1
        writeIORef urls [urlFor port]
        oprReadiness probes `shouldReturn` RdReady 1
        threadDelay 200_000
        n <- length <$> readIORef seen
        n `shouldBe` 1

  describe "8b: every refresh re-reads the config (D2.10)" $ do

    it "a base_url edit takes effect without a restart" $
      withTwoListeners okTags okTags $ \portA portB seenA seenB -> do
        urls <- newIORef [urlFor portA]
        probes <- probesReadingFrom urls 2_000_000 30_000_000
        _ <- oprRefresh probes
        waitForCount seenA 1
        -- Edit the config's base_url, as an operator would.
        writeIORef urls [urlFor portB]
        _ <- oprRefresh probes
        waitForCount seenB 1
        nA <- length <$> readIORef seenA
        nA `shouldBe` 1

  describe "the seam record (14: no test touches the real PATH or the network)" $ do

    it "consults only the injected executable lookup" $ do
      calls <- newIORef ([] :: [Text])
      probes <- probesWithSeams $ \cfg -> cfg { pcIsExecutable = \n ->
        modifyIORef' calls (<> [n]) >> pure (Just "/fake/ollama") }
      _ <- oprReadiness probes
      names <- readIORef calls
      names `shouldSatisfy` all (== "ollama")

  describe "size + remote_host decoding (WU-B)" $ do

    it "decodes size and remote_host, and omits them when absent" $
      parseTagsBody
        "{\"models\":[{\"name\":\"big\",\"size\":51000000000,\"remote_host\":\"https://ollama.com\"},{\"name\":\"plain\"}]}"
        `shouldBe` Right
          [ OllamaTag "big" (Just 51_000_000_000) (Just "https://ollama.com")
          , OllamaTag "plain" Nothing Nothing ]

  describe "the RAM reader (WU-B DoD 9: memoise ONLY Just)" $ do

    it "a transient failure does NOT permanently disable the judgement" $ do
      -- First read misses (a PATH-less launchd environment), later reads
      -- succeed. If the miss were memoised, the fit judgement would be dead
      -- for the process lifetime.
      attempts <- newIORef (0 :: Int)
      probes <- probesWithSeams $ \cfg -> cfg
        { pcTotalRam = do
            n <- readIORef attempts
            modifyIORef' attempts (+ 1)
            pure (if n == 0 then Nothing else Just 32_000_000_000) }
      first <- oprTotalRam probes
      first `shouldBe` Nothing
      second <- oprTotalRam probes
      second `shouldBe` Just 32_000_000_000

    it "a success IS memoised (one read, not one per call)" $ do
      attempts <- newIORef (0 :: Int)
      probes <- probesWithSeams $ \cfg -> cfg
        { pcTotalRam = modifyIORef' attempts (+ 1) >> pure (Just 16_000_000_000) }
      _ <- oprTotalRam probes
      _ <- oprTotalRam probes
      n <- readIORef attempts
      n `shouldBe` 1

  describe "the RAM seam (WU-B's input; memoised only on success)" $ do

    it "returns Nothing when the reader cannot determine RAM" $ do
      probes <- probesWithSeams id
      oprTotalRam probes `shouldReturn` Nothing

    it "returns Just when the reader succeeds" $ do
      probes <- probesWithSeams $ \cfg -> cfg { pcTotalRam = pure (Just 16_000_000_000) }
      oprTotalRam probes `shouldReturn` Just 16_000_000_000

-- ---------------------------------------------------------------------------
-- the listener harness
-- ---------------------------------------------------------------------------

type Headers = [(Text, ByteString)]

okTags :: Application
okTags _ respond =
  respond (responseLBS status200 [] "{\"models\":[{\"name\":\"llama3.2\"}]}")

slowTags :: Application
slowTags _ respond = do
  threadDelay 300_000
  respond (responseLBS status200 [] "{\"models\":[{\"name\":\"llama3.2\"}]}")

redirects :: Application
redirects _ respond =
  respond (responseLBS status302 [("Location", "http://169.254.169.254/latest")] "")

serverError :: Application
serverError _ respond = respond (responseLBS status500 [] "boom")

neverAnswers :: Application
neverAnswers _ respond = do
  threadDelay 30_000_000
  respond (responseLBS status500 [] "never")

-- | Hang on the first request, answer the second. Used to prove the
-- single-flight slot is released after a timeout rather than leaked.
hangsOnce :: Application
hangsOnce _ respond = do
  threadDelay 3_000_000
  respond (responseLBS status200 [] "{\"models\":[{\"name\":\"llama3.2\"}]}")

-- | Run a body with a listener on an ephemeral loopback port, capturing the
-- headers of every request it received.
withListener :: Application -> (Int -> IORef [Headers] -> IO a) -> IO a
withListener app body = do
  seen <- newIORef []
  testWithApplication (pure (recording seen app)) $ \port -> body port seen

withTwoListeners
  :: Application -> Application
  -> (Int -> Int -> IORef [Headers] -> IORef [Headers] -> IO a) -> IO a
withTwoListeners a b body = do
  seenA <- newIORef []
  seenB <- newIORef []
  testWithApplication (pure (recording seenA a)) $ \portA ->
    testWithApplication (pure (recording seenB b)) $ \portB ->
      body portA portB seenA seenB

recording :: IORef [Headers] -> Application -> Application
recording seen app req respond = do
  let hdrs = [(T.toLower (TE.decodeUtf8 (CI.original k)), v) | (k, v) <- Wai.requestHeaders req]
  modifyIORef' seen (<> [hdrs])
  app req respond

assertNoAuth :: Headers -> Expectation
assertNoAuth hdrs =
  [v | (k, v) <- hdrs, "authorization" `T.isInfixOf` k] `shouldBe` []

-- ---------------------------------------------------------------------------
-- probe construction: every seam stubbed
-- ---------------------------------------------------------------------------

urlFor :: Int -> Text
urlFor port = "http://127.0.0.1:" <> T.pack (show port)

-- | One probe, directly, bypassing the cache. Polls the listener's clock only
-- for the timeout bounds.
probeAgainst :: Int -> Int -> IO OllamaReadiness
probeAgainst timeoutMicro port = do
  cfg <- stubConfig (urlFor port) timeoutMicro 30_000_000
  probeOnce cfg { pcTimeoutMicro = timeoutMicro } (urlFor port)

-- | Probes over the cache, default seams.
probesFor :: Int -> Int -> Int -> IO OllamaProbes
probesFor port timeoutMicro ttlMicro = do
  cfg <- stubConfig (urlFor port) timeoutMicro ttlMicro
  mkOllamaProbes cfg

-- | Probes whose clock is driven by a test-controlled offset.
probesWithClock :: Int -> IORef Double -> IO OllamaProbes
probesWithClock port offset = do
  cfg <- stubConfig (urlFor port) 2_000_000 30_000_000
  base <- getCurrentTime
  mkOllamaProbes cfg { pcNow = do
    s <- readIORef offset
    pure (addUTCTime (realToFrac s) base) }

-- | Probes whose config action yields a different base URL each call.
probesReadingFrom :: IORef [Text] -> Int -> Int -> IO OllamaProbes
probesReadingFrom urls timeoutMicro ttlMicro = do
  mgr <- newManager defaultManagerSettings
  let readCfg = do
        us <- readIORef urls
        pure (runtimeFor (case us of (u : _) -> u; [] -> "http://127.0.0.1:1"))
  mkOllamaProbes (baseConfig mgr readCfg timeoutMicro ttlMicro)

-- | Probes with no listener at all: for the pure-seam tests. The function
-- argument overrides only the seam under test.
probesWithSeams :: (ProbesConfig -> ProbesConfig) -> IO OllamaProbes
probesWithSeams tweak = do
  mgr <- newManager defaultManagerSettings
  mkOllamaProbes (tweak (baseConfig mgr (pure defaultRuntimeConfig) 2_000_000 0))

stubConfig :: Text -> Int -> Int -> IO ProbesConfig
stubConfig url timeoutMicro ttlMicro = do
  mgr <- newManager defaultManagerSettings
  pure (baseConfig mgr (pure (runtimeFor url)) timeoutMicro ttlMicro)

baseConfig :: Manager -> IO RuntimeConfig -> Int -> Int -> ProbesConfig
baseConfig mgr readCfg timeoutMicro ttlMicro = ProbesConfig
  { pcManager      = mgr
  , pcReadConfig   = readCfg
  , pcTimeoutMicro = timeoutMicro
  , pcTtlMicro     = ttlMicro
  , pcNow          = getCurrentTime
  , pcIsExecutable = \_ -> pure Nothing
  , pcTotalRam     = pure Nothing
  }

runtimeFor :: Text -> RuntimeConfig
runtimeFor url = defaultRuntimeConfig
  { rcProviders = Map.singleton "ollama" ProviderConfig
      { pcDefaultModel = Nothing
      , pcBaseUrl      = Just url
      , pcModels       = Nothing
      }
  }

-- | Poll until the listener has seen @n@ requests (bounded).
waitForCount :: IORef [a] -> Int -> IO ()
waitForCount seen n = go (300 :: Int)
  where
    go 0 = expectationFailure ("listener never saw " <> show n <> " request(s)")
    go k = do
      cnt <- length <$> readIORef seen
      if cnt >= n then pure () else threadDelay 20_000 >> go (k - 1)

isLeft' :: Either a b -> Bool
isLeft' (Left _) = True
isLeft' _        = False
