{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SessionSpec (spec) where

import Data.Either (fromRight)
import Data.IORef (newIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Session (renderSessionInfo, renderSessionLine, sessionCommandSpec)
import Seal.Command.Spec (CommandSpec (..), mkRegistry, runCommandAction)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), newSession)
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.Vault.Commands (VaultRuntime (..))

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

meta :: T.Text -> SessionMeta
meta idText =
  let sid = fromRight (error $ "invalid session id: " <> show idText) (mkSessionId idText)
  in SessionMeta sid "anthropic" "claude-opus-4-8" "cli" Nothing Nothing Nothing aTime aTime

mkSR :: FilePath -> SessionMeta -> IO SessionRuntime
mkSR root active = do
  ref <- newIORef active
  let paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys")
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

-- | A 'ProviderRuntime' good enough to build a 'CommandSpec' for the help
-- index (never invoked here, so no vault is required).
mkPR :: FilePath -> IO ProviderRuntime
mkPR cfgPath = do
  ref <- newIORef Nothing
  mgr <- newManager defaultManagerSettings
  cntRef <- newIORef 0
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr, prCallCounter = cntRef }

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
        _  <- newSession (srPaths sr) "anthropic" "claude-opus-4-8" "cli" Nothing
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

    it "session and model appear under their groups in the help index" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        sr <- mkSR root (meta "20260701-120000-000")
        pr <- mkPR (root </> "config.toml")
        let idx = renderHelpIndex (mkRegistry [sessionCommandSpec sr, modelCommandSpec pr sr])
        idx `shouldSatisfy` ("Sessions" `T.isInfixOf`)
        idx `shouldSatisfy` ("/session" `T.isInfixOf`)
        idx `shouldSatisfy` ("Model" `T.isInfixOf`)
        idx `shouldSatisfy` ("/model" `T.isInfixOf`)
