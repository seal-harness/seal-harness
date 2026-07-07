{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ServerSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.IORef (newIORef)
import Data.Time (UTCTime(..), fromGregorian)
import Network.HTTP.Types (statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, responseStatus )
import Network.Wai.Internal (ResponseReceived (..))
import System.IO.Temp (withSystemTempDirectory)
import Data.ByteString.Char8 qualified as BC
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.Server
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import System.FilePath ((</>))
import Seal.Tabs (newTabsHandle)
import Seal.Gateway.API (ApiDeps (..))

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "test" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

runAppStatus :: Application -> Request -> IO Int
runAppStatus app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv (statusCode (responseStatus resp)) >> pure ResponseReceived)
  takeMVar mv

mkDeps :: IO ApiDeps
mkDeps = do
  tabsH <- newTabsHandle
  reg   <- newHarnessRegistry
  activeRef <- newIORef fakeMeta
  let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
  pure (ApiDeps { adSessionRuntime = sr, adTabsHandle = tabsH, adHarnessRegistry = reg, adAdoptConsent = Just CcWeb })

spec :: Spec
spec = describe "Seal.Gateway.Server" $ do
  it "gatewayApp routes /api/health to the API" $ do
    deps <- mkDeps
    let app = gatewayApp deps Nothing
    status <- runAppStatus app (defaultRequest { pathInfo = ["api", "health"] })
    status `shouldBe` 200

  it "gatewayApp returns 404 for a non-api path with no static dir" $ do
    deps <- mkDeps
    let app = gatewayApp deps Nothing
    status <- runAppStatus app (defaultRequest { pathInfo = ["foo", "bar"] })
    status `shouldBe` 404

  it "gatewayApp serves index.html for the root with a static dir" $
    withSystemTempDirectory "seal-static-test" $ \dir -> do
      BC.writeFile (dir </> "index.html") "<html>ok</html>"
      deps <- mkDeps
      let app = gatewayApp deps (Just dir)
      status <- runAppStatus app (defaultRequest { pathInfo = [] })
      status `shouldBe` 200