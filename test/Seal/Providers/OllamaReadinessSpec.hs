{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.OllamaReadinessSpec (spec) where

import Control.Exception (SomeException, toException, try)
import Data.CaseInsensitive qualified as CI
import Data.Either (isLeft, isRight)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error (Errno (..), eCONNRESET)
import GHC.IO.Exception
  ( IOErrorType (ResourceVanished), IOException (..) )
import Network.HTTP.Client
  ( HttpException (..), HttpExceptionContent (..), Manager, Request (..)
  , defaultManagerSettings, httpNoBody, newManager, parseRequest
  , responseTimeout, responseTimeoutMicro )
import Test.Hspec

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

tag :: Text -> OllamaTag
tag name = OllamaTag { otName = name }

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
