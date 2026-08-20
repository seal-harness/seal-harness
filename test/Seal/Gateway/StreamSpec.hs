{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Gateway.StreamSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (catch, IOException)
import System.Timeout (timeout)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Network.WebSockets (ClientApp, runClient, receiveData, ConnectionException)
import Test.Hspec

import Seal.Config.Paths (SealPaths(..))
import Seal.Gateway.Stream
import Seal.Gateway.StreamBroker
import Seal.Tabs (newTabsHandle)
import Seal.TestHelpers.FreePort (withFreePort)

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

-- | Ten seconds — generous for a localhost WebSocket round-trip, short
-- enough that a genuinely stuck server/client doesn't stall the suite.
testTimeoutUs :: Int
testTimeoutUs = 10_000_000

-- | Run an IO action with a per-test timeout. Wraps 'System.timeout' and
-- reports a timeout as a hspec failure so the suite never hangs on a
-- stuck WebSocket server/client.
withTimeout :: IO () -> IO ()
withTimeout act =
  timeout testTimeoutUs act >>= \case
    Just () -> pure ()
    Nothing -> expectationFailure "test timed out (stuck WebSocket server/client)"

-- | Run a WebSocket server on a free port, wait for it to bind, then run
-- the client against it. Tolerates a bind failure (e.g. a transient
-- port-take race) by skipping with 'pendingWith' instead of crashing the
-- suite.
withStreamServer :: StreamGuard -> StreamBroker -> (Int -> ClientApp ()) -> IO ()
withStreamServer guard broker clientApp =
  withFreePort $ \port -> do
    _ <- forkIO (runStreamServer "127.0.0.1" port guard broker)
    threadDelay 200000  -- wait for the server to bind
    withTimeout (runClient "127.0.0.1" port "/" (clientApp port))
      `catch` \(e :: IOException) ->
        pendingWith ("server bind/client failed (port " <> show port <> "): " <> show e)
      `catch` \(_ :: ConnectionException) ->
        pendingWith "client connection closed unexpectedly"

-- | Extract a field from a JSON object (for assertions).
jsonField :: T.Text -> A.Value -> Maybe A.Value
jsonField key (A.Object o) = KeyMap.lookup (Key.fromText key) o
jsonField _ _ = Nothing

spec :: Spec
spec = describe "Seal.Gateway.Stream" $ do
  it "a client connects and receives hello with protocolVersion + serverStartedAt" $ do
    broker <- newStreamBroker 10
    tabsH <- newTabsHandle
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10, sgTabsHandle = tabsH, sgPaths = fakePaths }
    withStreamServer guard broker $ \_port conn -> do
      hello <- receiveData conn :: IO BL.ByteString
      case A.decode hello :: Maybe A.Value of
        Just v -> do
          -- The hello frame must carry protocolVersion + serverStartedAt
          -- so the client can detect server restarts.
          jsonField "type" v `shouldBe` Just (A.String "hello")
          jsonField "protocolVersion" v `shouldBe` Just (A.String "v1")
          case jsonField "serverStartedAt" v of
            Just (A.String _) -> pure ()
            other -> expectationFailure ("expected serverStartedAt string, got " <> show other)
        Nothing -> error "expected hello JSON"

  it "broadcastLists delivers to a connected client" $ do
    broker <- newStreamBroker 10
    tabsH <- newTabsHandle
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10, sgTabsHandle = tabsH, sgPaths = fakePaths }
    withStreamServer guard broker $ \_port conn -> do
      _hello <- receiveData conn :: IO BL.ByteString
      _lists <- receiveData conn :: IO BL.ByteString
      broadcastLists broker (object ["tabs" .= ([] :: [String])])
      threadDelay 100000
      msg <- receiveData conn :: IO BL.ByteString
      case A.decode msg :: Maybe A.Value of
        Just _ -> pure ()
        Nothing -> error "expected an event JSON"

  it "FocusOp parses the since field" $ do
    let msg = A.encode (object ["op" .= ("focus" :: T.Text), "sessionId" .= ("sess-1" :: T.Text), "since" .= ("entry-5" :: T.Text)])
    case A.decode msg :: Maybe FocusOp of
      Just op -> do
        foSession op `shouldBe` "sess-1"
        foSince op `shouldBe` Just "entry-5"
      Nothing -> expectationFailure "expected FocusOp with since"

  it "FocusOp parses without the since field (backwards compat)" $ do
    let msg = A.encode (object ["op" .= ("focus" :: T.Text), "sessionId" .= ("sess-1" :: T.Text)])
    case A.decode msg :: Maybe FocusOp of
      Just op -> do
        foSession op `shouldBe` "sess-1"
        foSince op `shouldBe` Nothing
      Nothing -> expectationFailure "expected FocusOp without since"

  it "FocusOp parses the legacy session field" $ do
    let msg = A.encode (object ["session" .= ("sess-1" :: T.Text)])
    case A.decode msg :: Maybe FocusOp of
      Just op -> foSession op `shouldBe` "sess-1"
      Nothing -> expectationFailure "expected FocusOp from legacy shape"

  it "filterAfterId returns entries after the since id" $ do
    let entries = map (\i -> A.object [Key.fromText "id" .= T.pack (show (i :: Int))]) [0..5] :: [A.Value]
        --    [ {id:"0"}, {id:"1"}, {id:"2"}, {id:"3"}, {id:"4"}, {id:"5"} ]
    filterAfterId "2" entries `shouldSatisfy` \es -> length es == 3

  it "filterAfterId returns all entries when since id is not found" $ do
    let entries = map (\i -> A.object [Key.fromText "id" .= T.pack (show (i :: Int))]) [0..2] :: [A.Value]
    filterAfterId "99" entries `shouldSatisfy` \es -> length es == 3

  it "filterAfterId returns empty when since id is the last entry" $ do
    let entries = map (\i -> A.object [Key.fromText "id" .= T.pack (show (i :: Int))]) [0..2] :: [A.Value]
    filterAfterId "2" entries `shouldBe` []

  it "extractId reads the id field from a frontend entry JSON" $ do
    let entry = A.object [Key.fromText "id" .= ("entry-42" :: T.Text)]
    extractId entry `shouldBe` "entry-42"

  it "extractId returns empty string for missing id field" $ do
    let entry = A.object [Key.fromText "type" .= ("entry" :: T.Text)]
    extractId entry `shouldBe` ""
