{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ModelSpec (spec) where

import Data.Either (fromRight)
import Data.IORef (newIORef, readIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

mkSR :: FilePath -> IO SessionRuntime
mkSR root = do
  let sid = fromRight (error "invalid session id") (mkSessionId "20260701-120000-002")
      m0 = SessionMeta sid "anthropic" "claude-opus-4-8" "cli" aTime aTime
      paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys")
  ref <- newIORef m0
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

runModel :: SessionRuntime -> [String] -> ChannelCaps -> IO ()
runModel sr argv caps =
  case execParserPure defaultPrefs (csParserInfo (modelCommandSpec sr)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Model" $ do
  it "list shows known providers and the active selection" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      (fc, caps) <- makeFakeCaps []
      runModel sr ["list"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      T.unlines sent `shouldSatisfy` ("active" `T.isInfixOf`)

  it "use updates the active selection and persists it" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      (fc, caps) <- makeFakeCaps []
      runModel sr ["use", "anthropic", "claude-haiku-4-5"] caps
      active <- readIORef (srActive sr)
      smProvider active `shouldBe` "anthropic"
      smModel active    `shouldBe` "claude-haiku-4-5"
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("claude-haiku-4-5" `T.isInfixOf`)

  it "rejects an unknown provider without mutating the session" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      (fc, caps) <- makeFakeCaps []
      runModel sr ["use", "bogus", "x"] caps
      active <- readIORef (srActive sr)
      smModel active `shouldBe` "claude-opus-4-8"   -- unchanged
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("unknown provider" `T.isInfixOf`)
