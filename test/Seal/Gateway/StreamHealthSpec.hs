{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the WebSocket stream server's failure reporting.
--
-- Background: the WS server used to be forked with no exception handling,
-- so a bind failure (the port already in use by another process) killed
-- the WS thread SILENTLY while the HTTP gateway stayed up and
-- @\/api\/health@ went on advertising the dead port. The web frontend then
-- connected to a non-WebSocket port and its transcript froze permanently.
--
-- These tests pin the fixed contract: a bind failure is REPORTED (the
-- health state says "failed" instead of the process quietly losing the WS).
module Seal.Gateway.StreamHealthSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Data.IORef (IORef, newIORef, readIORef)
import Control.Monad (join)
import Data.Text qualified as T
import Network.Socket
  ( AddrInfo (..), SocketOption (..), SocketType (..), bind, close
  , defaultHints, getAddrInfo, listen, setSocketOption, socket )
import System.Timeout (timeout)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Gateway.Stream
  ( StreamGuard (..), StreamHealth (..), runStreamServerWithHealth
  , streamHealthMessage, streamHealthStatus )
import Seal.Gateway.StreamBroker (newStreamBroker)
import Seal.Tabs (newTabsHandle)

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

-- | Bind a listening socket on the given port and return a release action
-- that closes it. Used to occupy a port so the WS server's bind fails.
holdPort :: Int -> IO (IO ())
holdPort port = do
  let hints = defaultHints { addrSocketType = Stream }
  addrs <- getAddrInfo (Just hints) (Just "127.0.0.1") (Just (show port))
  case addrs of
    []      -> error "no address info"
    (addr : _) -> do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      bind sock (addrAddress addr)
      listen sock 1
      pure (close sock)

-- | Wait until the health state is no longer "starting", or the timeout
-- elapses. Returns 'Nothing' on timeout.
waitForSettled :: Int -> IORef StreamHealth -> IO (Maybe StreamHealth)
waitForSettled budgetUs ref = do
  m <- timeout budgetUs (go (50 :: Int))
  pure (join m)
  where
    go 0 = pure Nothing
    go n = do
      h <- readIORef ref
      if streamHealthStatus h /= "starting"
        then pure (Just h)
        else threadDelay 100000 >> go (n - 1)

mkGuard :: IO StreamGuard
mkGuard = do
  tabsH <- newTabsHandle
  pure StreamGuard
    { sgAllowedOrigins = ["http://localhost:8080"]
    , sgGlobalCap = 10
    , sgTabsHandle = tabsH
    , sgPaths = fakePaths
    }

spec :: Spec
spec = describe "Seal.Gateway.Stream health" $ do
  it "reports a bind failure instead of dying silently" $ do
    broker <- newStreamBroker 10
    guard <- mkGuard
    -- Occupy the port so the WS server cannot bind it.
    release <- holdPort 45997
    healthRef <- newIORef (StreamHealth "starting" 45997)
    _ <- forkIO (runStreamServerWithHealth "127.0.0.1" 45997 guard broker healthRef)
    settled <- waitForSettled 5_000_000 healthRef
    release
    case settled of
      Nothing -> expectationFailure "health state never settled (no bind-failure report)"
      Just h  -> h `shouldBe` StreamHealth "failed" 45997

  it "reports a healthy server once it is listening" $ do
    broker <- newStreamBroker 10
    guard <- mkGuard
    healthRef <- newIORef (StreamHealth "starting" 45998)
    _ <- forkIO (runStreamServerWithHealth "127.0.0.1" 45998 guard broker healthRef)
    settled <- waitForSettled 5_000_000 healthRef
    case settled of
      Nothing -> expectationFailure "health state never settled"
      Just h  -> h `shouldBe` StreamHealth "up" 45998

  it "does not throw when the port is already taken" $ do
    -- The historical implementation let the bind exception unwind the
    -- forked thread, where it was silently discarded. The server must
    -- not propagate the failure to its caller.
    broker <- newStreamBroker 10
    guard <- mkGuard
    release <- holdPort 45996
    healthRef <- newIORef (StreamHealth "starting" 45996)
    outcome <- try (runStreamServerWithHealth "127.0.0.1" 45996 guard broker healthRef)
    release
    case outcome of
      Left (e :: SomeException) -> expectationFailure ("expected no exception, got: " <> show e)
      Right () -> pure ()

  it "renders the health status verbatim" $ do
    streamHealthStatus (StreamHealth "up" 8080) `shouldBe` "up"
    streamHealthStatus (StreamHealth "down" 8080) `shouldBe` "down"
    streamHealthStatus (StreamHealth "failed" 8080) `shouldBe` "failed"
    streamHealthStatus (StreamHealth "starting" 8080) `shouldBe` "starting"

  it "renders a failed health state with an actionable message" $ do
    let msg = streamHealthMessage (StreamHealth "failed" 9092)
    msg `shouldSatisfy` T.isInfixOf "9092"
    msg `shouldSatisfy` T.isInfixOf "FAILED"

  it "renders a healthy health state naming the port" $ do
    let msg = streamHealthMessage (StreamHealth "up" 9092)
    msg `shouldSatisfy` T.isInfixOf "9092"
    msg `shouldSatisfy` T.isInfixOf "listening"
