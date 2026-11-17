{-# LANGUAGE OverloadedStrings #-}
-- | Two narrow, call-site-scoped source assertions about @Serve.hs@.
--
-- Why source assertions rather than behavioural tests: @Seal.Command.Serve@
-- exports only @runServeMain@, and the wiring sites live inline inside
-- @runServeMainInner@. No test can reach them.
--
-- These are therefore structural checks, and this module says so plainly rather
-- than dressing them up. Each is scoped to a /single call site/ — a whole-file
-- "does not mention X" check would be false here, because @Serve.hs@
-- legitimately calls @gatewayManager@ for chat channels and legitimately
-- mentions both managers.
--
-- What these are /not/: they are not the primary control.
--
-- * The primary control for the provider-manager rule is the behavioural test
--   in @OllamaReadinessProbeSpec@ — a factory built over a manager that stamps
--   a sentinel header must have that header arrive, and a loopback listener
--   must observe no @Authorization@.
-- * The primary control for the startup-warm ordering is @oprRefresh@'s
--   non-blocking test.
--
-- These two guard the one line each that behaviour cannot observe.
--
-- Precedent: @test/Seal/Agent/Def/BackendNoDirectFsFailSpec.hs@ reads a module's
-- source and asserts on its shape.
module Seal.Command.ServeWiringSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

spec :: Spec
spec = describe "Seal.Command.Serve wiring (source assertions, call-site scoped)" $ do
  src <- runIO (TIO.readFile "src/Seal/Command/Serve.hs")

  -- Design test 25b. The probe must be built on the PROVIDER manager
  -- (Serve.hs's `mgr`), never on `gatewayManager`, which stamps
  -- `Authorization: Bearer <gateway service token>` onto every request.
  -- Scoped to the single `mkOllamaProbes` call, not the whole file.
  describe "25b: mkOllamaProbes is built on the provider manager" $ do

    it "has exactly one mkOllamaProbes call site" $
      T.count "mkOllamaProbes " src `shouldBe` 1

    it "passes `mgr` as the manager argument" $
      case lineOf "mkOllamaProbes " src of
        Nothing -> expectationFailure "no mkOllamaProbes call found in Serve.hs"
        Just _ ->
          case firstLineContaining "mkOllamaProbes " src of
            Nothing -> expectationFailure "no mkOllamaProbes call found"
            Just line -> do
              line `shouldSatisfy` T.isInfixOf "defaultProbesConfig mgr"
              line `shouldNotSatisfy` T.isInfixOf "gatewayManager"

  -- DoD 23. The cache is created before `let deps = ApiDeps` and before
  -- `runGateway`, so the very first /api/providers read has a cache to read and
  -- a warm already in flight. Ordering, not mere presence.
  describe "DoD 23: the startup warm precedes the deps literal and runGateway" $ do

    it "creates the probes before the ApiDeps literal" $
      case (lineOf "mkOllamaProbes " src, lineOf "let deps = ApiDeps" src) of
        (Just probeAt, Just depsAt) -> probeAt `shouldSatisfy` (< depsAt)
        _ -> expectationFailure "mkOllamaProbes or `let deps = ApiDeps` not found"

    it "kicks the startup warm before the ApiDeps literal" $
      case (lineOf "oprRefresh probes" src, lineOf "let deps = ApiDeps" src) of
        (Just warmAt, Just depsAt) -> warmAt `shouldSatisfy` (< depsAt)
        _ -> expectationFailure "oprRefresh or `let deps = ApiDeps` not found"

    it "runs the gateway after the ApiDeps literal" $
      case (lineOf "let deps = ApiDeps" src, lineOf "runGateway logger" src) of
        (Just depsAt, Just gwAt) -> depsAt `shouldSatisfy` (< gwAt)
        _ -> expectationFailure "ApiDeps literal or runGateway not found"

    it "kicks the warm non-blocking (via oprRefresh, never a blocking probe)" $
      src `shouldSatisfy` T.isInfixOf "oprRefresh probes"

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- | Lines of Haskell source with comment lines removed. Both matchers must
-- ignore comments: @Serve.hs@'s own explanatory comment names
-- @let deps = ApiDeps@ and @runGateway@, and a naive scan would "find" the
-- comment above the code it describes, making the ordering assertions vacuous.
codeLines :: Text -> [(Int, Text)]
codeLines hay =
  [ (i, l)
  | (i, l) <- zip [1 :: Int ..] (T.lines hay)
  , not ("--" `T.isPrefixOf` T.stripStart l)
  ]

firstLineContaining :: Text -> Text -> Maybe Text
firstLineContaining needle hay =
  case [l | (_, l) <- codeLines hay, needle `T.isInfixOf` l] of
    (l : _) -> Just l
    []      -> Nothing

-- | The 1-based line number of the first code (non-comment) occurrence.
lineOf :: Text -> Text -> Maybe Int
lineOf needle hay =
  case [i | (i, l) <- codeLines hay, needle `T.isInfixOf` l] of
    (i : _) -> Just i
    []      -> Nothing
