{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.OllamaReadinessSpec (spec) where

import Control.Exception (SomeException, toException, try)
import Data.CaseInsensitive qualified as CI
import Data.Either (isLeft, isRight)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Foreign.C.Error (Errno (..), eCONNRESET)
import GHC.IO.Exception
  ( IOErrorType (ResourceVanished), IOException (..) )
import Network.HTTP.Client
  ( HttpException (..), HttpExceptionContent (..), Manager, Request (..)
  , defaultManagerSettings, httpNoBody, newManager, parseRequest
  , responseTimeout, responseTimeoutMicro )
import Test.Hspec
import Test.QuickCheck
  ( Gen, choose, elements, forAll, listOf, oneof, resize, (==>) )

import Seal.Providers.OllamaReadiness
import Seal.TestHelpers.FreePort (withFreePort)

spec :: Spec
spec = describe "Seal.Providers.OllamaReadiness" $ do

  describe "classifyOllamaReadiness (state machine)" $ do

    it "1. refused + loopback + binary present -> RdNotRunning" $
      classifyOllamaReadiness (probe OhLoopback (Left OpeRefused) True)
        `shouldBe` RdNotRunning

    it "2. refused + loopback + no binary -> RdNotInstalled" $
      classifyOllamaReadiness (probe OhLoopback (Left OpeRefused) False)
        `shouldBe` RdNotInstalled

    it "3. refused + other host -> RdUnknown (never claim not-installed for a LAN host)" $
      classifyOllamaReadiness (probe OhOtherHost (Left OpeRefused) False)
        `shouldBe` RdUnknown

    it "4. cloud host -> RdCloud regardless of the tag result" $ do
      classifyOllamaReadiness (probe OhCloud (Left OpeRefused) False)
        `shouldBe` RdCloud
      classifyOllamaReadiness (probe OhCloud (Right [tag "x"]) True)
        `shouldBe` RdCloud

    it "5. OpeBlocked -> RdUnknown" $
      classifyOllamaReadiness (probe OhLoopback (Left OpeBlocked) True)
        `shouldBe` RdUnknown

    it "6. OpeTimeout -> RdUnknown" $
      classifyOllamaReadiness (probe OhLoopback (Left OpeTimeout) True)
        `shouldBe` RdUnknown

    it "7. OpeBadResponse -> RdUnknown" $
      classifyOllamaReadiness (probe OhLoopback (Left OpeBadResponse) True)
        `shouldBe` RdUnknown

    it "8. OpeHttp 401 -> RdUnknown" $
      classifyOllamaReadiness (probe OhLoopback (Left (OpeHttp 401)) True)
        `shouldBe` RdUnknown

    it "9. OpeHttp 302 -> RdUnknown (a 3xx is never followed)" $
      classifyOllamaReadiness (probe OhLoopback (Left (OpeHttp 302)) True)
        `shouldBe` RdUnknown

    it "9b. a refused default-loopback URL with a binary present is RdNotRunning" $
      classifyOllamaReadiness (probe OhDefaultLoopback (Left OpeRefused) True)
        `shouldBe` RdNotRunning

    it "9c. a refused default-loopback URL with no binary is RdNotInstalled" $
      classifyOllamaReadiness (probe OhDefaultLoopback (Left OpeRefused) False)
        `shouldBe` RdNotInstalled

    it "10. daemon answered with zero models -> RdNoModels" $
      classifyOllamaReadiness (probe OhDefaultLoopback (Right []) True)
        `shouldBe` RdNoModels

    it "11. daemon answered with one model -> RdReady 1" $
      classifyOllamaReadiness (probe OhDefaultLoopback (Right [tag "llama3.2"]) True)
        `shouldBe` RdReady 1

    it "11b. daemon answered with three models -> RdReady 3 (WU-A counts all returned models)" $ do
      let tags = [tag "a", tag "b", tag "c"]
      classifyOllamaReadiness (probe OhOtherHost (Right tags) False)
        `shouldBe` RdReady 3

  describe "hostKindFor (D3.4: loopback aliases are the same host)" $ do

    it "the default Ollama base URL is OhDefaultLoopback" $
      hostKindFor "http://localhost:11434" `shouldBe` OhDefaultLoopback

    it "ollama.com is OhCloud" $ do
      hostKindFor "https://ollama.com" `shouldBe` OhCloud
      hostKindFor "https://ollama.com:443/" `shouldBe` OhCloud

    it "127.0.0.1 is OhLoopback (any port, not just the default spelling)" $ do
      hostKindFor "http://127.0.0.1:11434" `shouldBe` OhLoopback
      hostKindFor "http://127.0.0.1:1234/api/tags" `shouldBe` OhLoopback

    it "[::1] is OhLoopback" $
      hostKindFor "http://[::1]:11434" `shouldBe` OhLoopback

    it "127.9.9.9 is OhLoopback (all of 127/8 is loopback)" $
      hostKindFor "http://127.9.9.9:11434" `shouldBe` OhLoopback

    it "a LAN address is OhOtherHost" $
      hostKindFor "http://192.168.1.9:11434" `shouldBe` OhOtherHost

    it "a remote hostname is OhOtherHost" $
      hostKindFor "https://gpu-box.example.com:11434" `shouldBe` OhOtherHost

    -- A hostname is not a loopback literal; only the exact localhost and
    -- 127/8 spellings refine to RdNotInstalled. This is the guard that stops
    -- "localhost.attacker.tld" from being treated as the default URL.
    it "localhost.attacker.tld is OhOtherHost, not OhLoopback" $
      hostKindFor "http://localhost.attacker.tld:11434" `shouldBe` OhOtherHost

    it "127.0.0.1.nip.io is OhOtherHost (not a 127/8 literal)" $
      hostKindFor "http://127.0.0.1.nip.io:11434" `shouldBe` OhOtherHost

  describe "readinessText (17: total over all eight constructors)" $ do

    it "RdPending renders empty (the segment is omitted)" $
      readinessText RdPending `shouldBe` ""

    it "renders each remaining state" $ do
      readinessText RdUnknown        `shouldBe` "Status Unknown"
      readinessText RdNotInstalled   `shouldBe` "Ollama Not Found"
      readinessText RdNotRunning     `shouldBe` "Not Running"
      readinessText RdNoModels       `shouldBe` "No Models Pulled"
      readinessText RdNoFittingModel `shouldBe` "May Not Fit in RAM"
      readinessText RdCloud          `shouldBe` "Cloud"

    it "pluralises the ready count" $ do
      readinessText (RdReady 1) `shouldBe` "Ready · 1 Model"
      readinessText (RdReady 3) `shouldBe` "Ready · 3 Models"

  -- ── WU-B: the RAM-fit judgement (design D5) ──────────────────────────

  describe "isCloudModel (15: four explicit assertions)" $ do

    it "15a: remote_host set -> cloud" $
      isCloudModel (OllamaTag "gemma4:latest" Nothing (Just "https://ollama.com"))
        `shouldBe` True

    it "15b: a :cloud suffix -> cloud" $
      isCloudModel (OllamaTag "deepseek-v4.1-flash:cloud" Nothing Nothing)
        `shouldBe` True

    it "15c: both -> cloud" $
      isCloudModel (OllamaTag "glm-5.2:cloud" Nothing (Just "https://ollama.com"))
        `shouldBe` True

    it "15d: neither -> not cloud" $
      isCloudModel (OllamaTag "gemma4:latest" (Just 9_600_000_000) Nothing)
        `shouldBe` False

    it "15e: remote_host is authoritative when the suffix disagrees" $ do
      -- A daemon build that omits remote_host but names the model ':cloud'.
      isCloudModel (OllamaTag "x:cloud" Nothing Nothing) `shouldBe` True
      -- And one that reports a remote host without the suffix.
      isCloudModel (OllamaTag "x:latest" Nothing (Just "https://ollama.com"))
        `shouldBe` True

  describe "the fit predicate (13, D5.2: exact integers, 1.25x headroom)" $ do

    -- 1.25x headroom: fits iff size * 5 < ram * 4. 10 GB on 16 GB RAM fits
    -- (50 < 64); 13 GB on 16 GB does not (65 >= 64).
    it "13: a model that does not fit with RAM known -> RdNoFittingModel" $
      classifyOllamaReadiness (probeWithRam (Just 16_000_000_000)
        (Right [OllamaTag "big" (Just 51_000_000_000) Nothing]))
        `shouldBe` RdNoFittingModel

    it "13b: exactly at the boundary does not fit (size * 5 >= ram * 4)" $
      -- size * 5 == ram * 4 exactly: 12.8 GB on 16 GB.
      classifyOllamaReadiness (probeWithRam (Just 16_000_000_000)
        (Right [OllamaTag "edge" (Just 12_800_000_000) Nothing]))
        `shouldBe` RdNoFittingModel

    it "13c: a wrapping Word64 size is not reported as fitting" $
      -- A hostile or buggy daemon reports a size of 2^64/5 + 1. In Word64
      -- arithmetic `size * 5` wraps to exactly 4, which is smaller than
      -- ram * 4, so the model would compare as FITTING — the worst possible
      -- direction for an absurd size. The comparison is therefore done in
      -- Integer. (Verified: this test fails if the Word64 form is restored.)
      classifyOllamaReadiness (probeWithRam (Just 16_000_000_000)
        (Right [OllamaTag "absurd" (Just 3_689_348_814_741_910_324) Nothing]))
        `shouldBe` RdNoFittingModel

    it "12: only :cloud models -> RdReady n (cloud models are usable and unsized)" $
      classifyOllamaReadiness (probeWithRam (Just 8_000_000_000)
        (Right [ OllamaTag "a:cloud" (Just 336) (Just "https://ollama.com")
               , OllamaTag "b:cloud" (Just 336) Nothing ]))
        `shouldBe` RdReady 2

    it "one fitting local model among clouds counts in n (n is USABLE, D4)" $
      classifyOllamaReadiness (probeWithRam (Just 64_000_000_000)
        (Right [ OllamaTag "a:cloud" (Just 336) Nothing
               , OllamaTag "local" (Just 9_600_000_000) Nothing ]))
        `shouldBe` RdReady 2

    it "a mixed list counts only the fitting models" $
      classifyOllamaReadiness (probeWithRam (Just 16_000_000_000)
        (Right [ OllamaTag "small" (Just 4_000_000_000) Nothing
               , OllamaTag "huge" (Just 51_000_000_000) Nothing ]))
        `shouldBe` RdReady 1

  describe "the symmetric size rule (14b, 14c, D5.3)" $ do

    it "14b: every size unknown -> RdReady with count = all models (no size evidence)" $
      classifyOllamaReadiness (probeWithRam (Just 16_000_000_000)
        (Right [ OllamaTag "a" Nothing Nothing
               , OllamaTag "b" Nothing Nothing ]))
        `shouldBe` RdReady 2

    it "14c: mixed known/unknown -> the unknown-size model counts as usable" $
      -- One known size that does NOT fit, one unknown. Because we cannot
      -- substantiate a problem with the second, we do not claim one.
      classifyOllamaReadiness (probeWithRam (Just 16_000_000_000)
        (Right [ OllamaTag "huge" (Just 51_000_000_000) Nothing
               , OllamaTag "unsized" Nothing Nothing ]))
        `shouldBe` RdReady 1

    it "14b(ii): RdNoFittingModel requires at least one KNOWN size" $
      classifyOllamaReadiness (probeWithRam (Just 1_000_000_000)
        (Right [OllamaTag "a" Nothing Nothing]))
        `shouldBe` RdReady 1

  describe "14/18: unknown RAM never produces a claim (D5.3)" $ do

    it "14: models exist, RAM unknown -> RdReady (assume usable)" $
      classifyOllamaReadiness (probeWithRam Nothing
        (Right [OllamaTag "huge" (Just 51_000_000_000) Nothing]))
        `shouldBe` RdReady 1

    it "18: forAll over tag lists, opTotalRam = Nothing => never RdNoFittingModel" $
      forAll (resize 8 arbitraryTags) $ \tags ->
        tags /= []
          ==> classifyOllamaReadiness (probeWithRam Nothing (Right tags))
                `shouldSatisfy` (/= RdNoFittingModel)

  describe "19: monotonicity over the exported classifier" $ do

    it "19: more RAM never yields a smaller usable count" $
      forAll (resize 6 arbitraryTags) $ \tags ->
        forAll (choose (1_000_000_000, 128_000_000_000)) $ \r ->
          forAll (choose (1_000_000_000, 128_000_000_000)) $ \r' ->
            let n  = usableCountAt r tags
                m  = usableCountAt r' tags
            in r' >= r ==> m >= n

  describe "20: otRemoteHost = Just _ => usable regardless of size" $ do

    it "20: forAll over sizes, a remote-host model is always usable" $
      forAll (choose (1, 1_000_000_000_000)) $ \size ->
        classifyOllamaReadiness
          (probeWithRam (Just 1_000_000)
            (Right [OllamaTag "remote" (Just size) (Just "https://ollama.com")]))
          `shouldBe` RdReady 1

  describe "21: parseMemTotal (kW -> bytes, no silent rescale)" $ do

    it "21a: converts kB to bytes" $
      parseMemTotal "MemTotal:       16384000 kB" `shouldBe` Just 16_777_216_000

    it "21b: rejects an empty line" $
      parseMemTotal "" `shouldBe` Nothing

    it "21c: a zero total is Just 0 (a real kernel value, not unknown)" $
      parseMemTotal "MemTotal: 0 kB" `shouldBe` Just 0

    it "21d: rejects garbage" $
      parseMemTotal "garbage" `shouldBe` Nothing

    it "21e: rejects a non-kB unit rather than rescaling" $
      parseMemTotal "MemTotal: 16 MB" `shouldBe` Nothing

    it "21f: rejects a kB value that is not a plain decimal" $
      parseMemTotal "MemTotal: 1.5 kB" `shouldBe` Nothing

  describe "classifyProbeFailure (16: only errno separates a refusal from a DNS failure)" $ do

    -- (a) A REAL refused connect to a definitely-closed loopback port.
    it "(a) a real refused connect is OpeRefused" $
      withFreePort $ \port -> do
        e <- tryGet ("http://127.0.0.1:" <> T.pack (show port) <> "/api/tags")
        classifyProbeFailure e `shouldBe` OpeRefused

    -- (b) A REAL DNS failure. `.invalid` is reserved (RFC 6761) and never
    -- resolves. The exception type and message are byte-identical to (a);
    -- only errno separates them, which is the whole point of D3.1.
    it "(b) a real DNS failure is NOT OpeRefused" $ do
      e <- tryGet "http://seal-readiness-does-not-exist.invalid/api/tags"
      classifyProbeFailure e `shouldSatisfy` (/= OpeRefused)

    -- (c) A synthetic connection reset. Synthetic is allowed here, but the
    -- record must carry every field so -Wmissing-fields stays clean.
    it "(c) a synthetic eCONNRESET is NOT OpeRefused" $ do
      let Errno n = eCONNRESET
          ioe = IOError
            { ioe_handle      = Nothing
            , ioe_type        = ResourceVanished
            , ioe_location    = "connect"
            , ioe_description = "synthetic reset"
            , ioe_errno       = Just n
            , ioe_filename    = Nothing
            }
      classifyProbeFailure (connFailure ioe) `shouldBe` OpeOther

    it "(d) a non-connection HttpException fails safe to OpeOther" $
      classifyProbeFailure (InvalidUrlException "nope" "no such thing")
        `shouldBe` OpeOther

    it "(f) a response timeout is OpeTimeout, which classifies to RdUnknown" $ do
      classifyProbeFailure (HttpExceptionRequest neverInspected ResponseTimeout)
        `shouldBe` OpeTimeout
      classifyOllamaReadiness (probe OhLoopback (Left OpeTimeout) True)
        `shouldBe` RdUnknown

  describe "probeTargetFor (22: the URL-shape and SSRF floor)" $ do

    it "rejects a non-http(s) scheme" $
      probeTargetFor "file:///etc/passwd" `shouldSatisfy` isLeft

    it "rejects a URL carrying userinfo" $
      probeTargetFor "http://x@169.254.169.254/api/tags" `shouldSatisfy` isLeft

    it "rejects the AWS metadata IP" $
      probeTargetFor "http://169.254.169.254/api/tags" `shouldSatisfy` isLeft

    it "rejects the bracketed IPv6 metadata literal" $
      probeTargetFor "http://[fd00:ec2::254]/api/tags" `shouldSatisfy` isLeft

    it "accepts the primary use cases" $ do
      probeTargetFor "http://localhost:11434/api/tags" `shouldSatisfy` isRight
      probeTargetFor "http://127.0.0.1:11434/api/tags" `shouldSatisfy` isRight
      probeTargetFor "http://192.168.1.9:11434/api/tags" `shouldSatisfy` isRight

  describe "probeTargetFor (23: the request is keyless)" $ do

    it "carries no Authorization header in any casing" $
      case probeTargetFor "http://localhost:11434/api/tags" of
        Left e    -> expectationFailure ("expected Right, got " <> show e)
        Right req -> map fst (requestHeaders req)
          `shouldSatisfy` all (\k -> CI.foldCase k /= authorityHeaderName)

  describe "the probe timeout is 2 s, not the provider's 5 minutes (D2.7)" $ do

    it "probeTargetFor sets a 2 s response timeout" $
      case probeTargetFor "http://localhost:11434/api/tags" of
        Left e    -> expectationFailure ("expected Right, got " <> show e)
        Right req -> responseTimeout req
          `shouldBe` responseTimeoutMicro probeTimeoutMicro

    it "probeTimeoutMicro is two seconds" $
      probeTimeoutMicro `shouldBe` 2_000_000

  describe "single-flight key normalisation (D2.10)" $ do

    it "strips a trailing slash" $ do
      singleFlightKey "http://localhost:11434/" `shouldBe` "http://localhost:11434"
      singleFlightKey "http://localhost:11434"  `shouldBe` "http://localhost:11434"

    it "two spellings that differ only by a trailing slash share a key" $
      singleFlightKey "http://localhost:11434"
        `shouldBe` singleFlightKey "http://localhost:11434/"

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

probe :: OllamaHostKind -> Either OllamaProbeError [OllamaTag] -> Bool -> OllamaProbe
probe kind tags binary = OllamaProbe
  { opHostKind      = kind
  , opTags          = tags
  , opBinaryPresent = binary
  , opTotalRam      = Nothing
  }

-- | A probe on the default loopback URL with an explicit RAM figure.
probeWithRam :: Maybe Word64 -> Either OllamaProbeError [OllamaTag] -> OllamaProbe
probeWithRam ram tags = (probe OhDefaultLoopback tags True) { opTotalRam = ram }

-- | The usable count a probe would report at a given RAM figure, or 0 when the
-- state is not 'RdReady' (monotonicity is stated over the count).
usableCountAt :: Word64 -> [OllamaTag] -> Int
usableCountAt ram tags = case classifyOllamaReadiness (probeWithRam (Just ram) (Right tags)) of
  RdReady n -> n
  _         -> 0

-- | Bounded tag lists: a name, an optional size, an optional remote host. Sizes
-- span the interesting boundary (a few GB to a few tens of GB) so the
-- monotonicity property exercises both sides of the predicate.
arbitraryTags :: Gen [OllamaTag]
arbitraryTags = listOf (OllamaTag <$> genName <*> genSize <*> genRemote)
  where
    genName = elements ["a", "b:cloud", "gemma4:latest", "qwen3-coder-next:latest"]
    genSize = oneof [pure Nothing, Just <$> choose (1, 64_000_000_000)]
    genRemote = oneof [pure Nothing, pure (Just "https://ollama.com")]

tag :: Text -> OllamaTag
tag name = OllamaTag { otName = name, otSizeBytes = Nothing, otRemoteHost = Nothing }

authorityHeaderName :: CI.CI B.ByteString
authorityHeaderName = "authorization"

-- | Wrap an 'IOException' payload the way http-client does. A real
-- 'ConnectionFailure' carries a 'SomeException', not an 'IOException'.
connFailure :: IOException -> HttpException
connFailure = HttpExceptionRequest neverInspected . ConnectionFailure . toSome

toSome :: IOException -> SomeException
toSome = toException

-- | A 'Request' that 'classifyProbeFailure' never inspects.
neverInspected :: Request
neverInspected = case parseRequest "http://localhost:11434/api/tags" of
  Right r -> r
  Left e  -> error ("neverInspected: " <> show e)

-- | Run a GET expected to fail, returning the 'HttpException'.
tryGet :: Text -> IO HttpException
tryGet url = do
  mreq <- parseRequest ("GET " <> T.unpack url)
  mgr  <- newManager defaultManagerSettings :: IO Manager
  r    <- try (httpNoBody mreq mgr)
  case r of
    Left e  -> pure e
    Right _ -> fail ("expected the request to " <> T.unpack url <> " to fail")
