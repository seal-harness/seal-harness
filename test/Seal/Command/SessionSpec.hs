{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SessionSpec (spec) where

import Data.Either (fromRight)
import Data.IORef (newIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Session (renderSessionInfo, renderSessionLine, sessionCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), newSession)
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

meta :: T.Text -> SessionMeta
meta idText =
  let sid = fromRight (error $ "invalid session id: " <> show idText) (mkSessionId idText)
  in SessionMeta sid "anthropic" "claude-opus-4-8" "cli" aTime aTime

mkSR :: FilePath -> SessionMeta -> IO SessionRuntime
mkSR root active = do
  ref <- newIORef active
  let paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys")
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

runSess :: SessionRuntime -> [String] -> ChannelCaps -> IO ()
runSess sr argv caps =
  case execParserPure defaultPrefs (csParserInfo (sessionCommandSpec sr)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Session" $ do
  describe "pure renderers" $ do
    it "marks the active session" $ do
      let active = fromRight (error "invalid session id") (mkSessionId "20260701-120000-002")
      renderSessionLine active (meta "20260701-120000-002")
        `shouldSatisfy` ("(active)" `T.isInfixOf`)
      renderSessionLine active (meta "20260701-120000-001")
        `shouldSatisfy` (not . ("(active)" `T.isInfixOf`))

    it "info includes id, provider and model" $ do
      let ls = T.unlines (renderSessionInfo (meta "20260701-120000-002"))
      ls `shouldSatisfy` ("20260701-120000-002" `T.isInfixOf`)
      ls `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      ls `shouldSatisfy` ("claude-opus-4-8" `T.isInfixOf`)

  describe "/session commands" $ do
    it "list shows saved sessions" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        sr <- mkSR root (meta "20260701-000000-000")
        _  <- newSession (srPaths sr) "anthropic" "claude-opus-4-8" "cli"
        (fc, caps) <- makeFakeCaps []
        runSess sr ["list"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)

    it "info prints the active session" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        sr <- mkSR root (meta "20260701-120000-009")
        (fc, caps) <- makeFakeCaps []
        runSess sr ["info"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("20260701-120000-009" `T.isInfixOf`)
