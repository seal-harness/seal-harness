{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.BrowserSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (uoAuthorize, uoRun, orIsError)
import Seal.ISA.Ops.Browser
  ( browserManageOp, BrowserAction (..), NetworkFilters (..), HarAction (..)
  , buildBrowserArgs )
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Args (textBinArg)
import Seal.Tools.Exec.UIO (runUIOWithEnv, mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)

testPolicy :: SecurityPolicy
testPolicy = SecurityPolicy (AllowOnly Set.empty) Full

denyPolicy :: SecurityPolicy
denyPolicy = SecurityPolicy (AllowOnly Set.empty) Deny

noFilters :: NetworkFilters
noFilters = NetworkFilters Nothing Nothing Nothing Nothing False

spec :: Spec
spec = describe "BROWSER_MANAGE opcode" $ do

  describe "authorize gate" $ do
    it "accepts open action with url" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("open" :: String), "url" .= ("https://example.com" :: String)])
        `shouldBe` Right ()
    it "rejects open action without url" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("open" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: open requires {url:string}"
    it "rejects open action with empty url" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("open" :: String), "url" .= ("" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: url is empty"
    it "rejects unknown action" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("frobnicate" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: unknown action \"frobnicate\""
    it "rejects missing action" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object [])
        `shouldBe` Left "BROWSER_MANAGE requires {action:string}"
    it "rejects all actions when autonomy is Deny" $ do
      let op = browserManageOp denyPolicy
      uoAuthorize op (object ["action" .= ("open" :: String), "url" .= ("https://example.com" :: String)])
        `shouldBe` Left "BROWSER_MANAGE denied by autonomy policy"
    it "accepts click action with ref" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("click" :: String), "ref" .= ("@e1" :: String)])
        `shouldBe` Right ()
    it "rejects click action without ref or selector" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("click" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: click requires {ref:string} or {selector:string}"
    it "accepts fill action with ref and text" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("fill" :: String), "ref" .= ("@e1" :: String), "text" .= ("hello" :: String)])
        `shouldBe` Right ()
    it "rejects fill action without text" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("fill" :: String), "ref" .= ("@e1" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: fill requires {text:string}"
    it "accepts close action with no extra fields" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("close" :: String)])
        `shouldBe` Right ()
    it "accepts snapshot action with no extra fields" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("snapshot" :: String)])
        `shouldBe` Right ()

  describe "authorize gate — network actions" $ do
    it "accepts network-requests with no filters" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-requests" :: String)])
        `shouldBe` Right ()
    it "accepts network-requests with filter" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-requests" :: String), "filter" .= ("api" :: String)])
        `shouldBe` Right ()
    it "accepts network-requests with type and method" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object
        [ "action" .= ("network-requests" :: String)
        , "type" .= ("xhr,fetch" :: String)
        , "method" .= ("POST" :: String)
        ])
        `shouldBe` Right ()
    it "accepts network-requests with clear" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-requests" :: String), "clear" .= True])
        `shouldBe` Right ()
    it "rejects network-requests when autonomy is Deny" $ do
      let op = browserManageOp denyPolicy
      uoAuthorize op (object ["action" .= ("network-requests" :: String)])
        `shouldBe` Left "BROWSER_MANAGE denied by autonomy policy"
    it "accepts network-request with requestId" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-request" :: String), "requestId" .= ("req-42" :: String)])
        `shouldBe` Right ()
    it "rejects network-request without requestId" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-request" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: network-request requires {requestId:string}"
    it "rejects network-request with empty requestId" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-request" :: String), "requestId" .= ("" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: requestId is empty"
    it "accepts network-har with harAction start" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-har" :: String), "harAction" .= ("start" :: String)])
        `shouldBe` Right ()
    it "accepts network-har with harAction stop and path" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object
        [ "action" .= ("network-har" :: String)
        , "harAction" .= ("stop" :: String)
        , "path" .= ("./trace.har" :: String)
        ])
        `shouldBe` Right ()
    it "accepts network-har start with content" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object
        [ "action" .= ("network-har" :: String)
        , "harAction" .= ("start" :: String)
        , "content" .= ("all" :: String)
        ])
        `shouldBe` Right ()
    it "rejects network-har without harAction" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-har" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: network-har requires {harAction:string}"
    it "rejects network-har with invalid harAction" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("network-har" :: String), "harAction" .= ("frobnicate" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: network-har requires harAction \"start\" or \"stop\", got \"frobnicate\""

  describe "buildBrowserArgs" $ do
    it "builds open args with url" $ do
      let result = buildBrowserArgs (BaOpen "https://example.com") Nothing 15000
      case result of
        Right (_, args) -> do
          map textBinArg args `shouldContain` ["open", "https://example.com"]
          map textBinArg args `shouldContain` ["--json"]
        Left e -> expectationFailure (T.unpack e)
    it "builds snapshot args with -i flag" $ do
      let result = buildBrowserArgs BaSnapshot Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["snapshot", "-i"]
        Left e -> expectationFailure (T.unpack e)
    it "builds click args with ref" $ do
      let result = buildBrowserArgs (BaClick "@e1") Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["click", "@e1"]
        Left e -> expectationFailure (T.unpack e)
    it "builds fill args with ref and text" $ do
      let result = buildBrowserArgs (BaFill "@e1" "hello world") Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["fill", "@e1", "hello world"]
        Left e -> expectationFailure (T.unpack e)
    it "injects --session when session is provided" $ do
      let result = buildBrowserArgs (BaOpen "https://example.com") (Just "my-session") 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--session", "my-session"]
        Left e -> expectationFailure (T.unpack e)
    it "omits --session when no session is provided" $ do
      let result = buildBrowserArgs BaSnapshot Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldNotContain` ["--session"]
        Left e -> expectationFailure (T.unpack e)
    it "includes --max-output with the configured value" $ do
      let result = buildBrowserArgs BaSnapshot Nothing 5000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--max-output", "5000"]
        Left e -> expectationFailure (T.unpack e)

  describe "buildBrowserArgs — network actions" $ do
    it "builds network-requests with no filters" $ do
      let result = buildBrowserArgs (BaNetworkRequests noFilters) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["network", "requests"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-requests with --filter" $ do
      let f = noFilters { nfFilter = Just "api" }
          result = buildBrowserArgs (BaNetworkRequests f) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--filter", "api"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-requests with --type" $ do
      let f = noFilters { nfType = Just "xhr,fetch" }
          result = buildBrowserArgs (BaNetworkRequests f) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--type", "xhr,fetch"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-requests with --method" $ do
      let f = noFilters { nfMethod = Just "POST" }
          result = buildBrowserArgs (BaNetworkRequests f) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--method", "POST"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-requests with --status" $ do
      let f = noFilters { nfStatus = Just "2xx" }
          result = buildBrowserArgs (BaNetworkRequests f) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--status", "2xx"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-requests with --clear" $ do
      let f = noFilters { nfClear = True }
          result = buildBrowserArgs (BaNetworkRequests f) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--clear"]
        Left e -> expectationFailure (T.unpack e)
    it "omits --clear when not set" $ do
      let result = buildBrowserArgs (BaNetworkRequests noFilters) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldNotContain` ["--clear"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-request with requestId" $ do
      let result = buildBrowserArgs (BaNetworkRequest "req-42") Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["network", "request", "req-42"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-har start with no content" $ do
      let result = buildBrowserArgs (BaNetworkHar (HarStart Nothing)) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["network", "har", "start"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-har start with --content all" $ do
      let result = buildBrowserArgs (BaNetworkHar (HarStart (Just "all"))) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--content", "all"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-har stop with path" $ do
      let result = buildBrowserArgs (BaNetworkHar (HarStop (Just "./trace.har"))) Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["network", "har", "stop", "./trace.har"]
        Left e -> expectationFailure (T.unpack e)
    it "builds network-har stop without path" $ do
      let result = buildBrowserArgs (BaNetworkHar (HarStop Nothing)) Nothing 15000
      case result of
        Right (_, args) -> do
          map textBinArg args `shouldContain` ["network", "har", "stop"]
          map textBinArg args `shouldNotContain` ["./trace.har"]
        Left e -> expectationFailure (T.unpack e)

  describe "run (stub UIO — no agent-browser installed)" $ do
    it "returns error for open action when binary not found" $ do
      let op = browserManageOp testPolicy
          input = object ["action" .= ("open" :: String), "url" .= ("https://example.com" :: String)]
      result <- runUIOWithEnv (mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps) (uoRun op input)
      orIsError result `shouldBe` True
    it "returns error for snapshot action when binary not found" $ do
      let op = browserManageOp testPolicy
          input = object ["action" .= ("snapshot" :: String)]
      result <- runUIOWithEnv (mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps) (uoRun op input)
      orIsError result `shouldBe` True
    it "returns error for close action when binary not found" $ do
      let op = browserManageOp testPolicy
          input = object ["action" .= ("close" :: String)]
      result <- runUIOWithEnv (mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps) (uoRun op input)
      orIsError result `shouldBe` True
    it "returns error for network-requests when binary not found" $ do
      let op = browserManageOp testPolicy
          input = object ["action" .= ("network-requests" :: String)]
      result <- runUIOWithEnv (mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps) (uoRun op input)
      orIsError result `shouldBe` True
    it "returns error for network-request when binary not found" $ do
      let op = browserManageOp testPolicy
          input = object ["action" .= ("network-request" :: String), "requestId" .= ("req-1" :: String)]
      result <- runUIOWithEnv (mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps) (uoRun op input)
      orIsError result `shouldBe` True