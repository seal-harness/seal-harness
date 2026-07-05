{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.AuditedSpec (spec) where

import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
import Data.Time (getCurrentTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Audited.Types
  ( AuditedEntry (..), AuditedKind (..) )
import Seal.Core.Types (OpName (..), SessionId (..))
import Seal.Handles.Audited

mkEntry :: IO AuditedEntry
mkEntry = do
  now <- getCurrentTime
  pure AuditedEntry
    { aeId = "e1"
    , aeTimestamp = now
    , aeSession = SessionId "s1"
    , aeOpcode = OpName "MEMORY_STORE"
    , aeKind = AKMemory
    , aePayload = object ["id" .= ("m1" :: String)]
    }

spec :: Spec
spec = describe "Seal.Handles.Audited" $ do
  it "auditedAck durably appends one JSONL line per entry" $
    withSystemTempDirectory "seal-aud" $ \dir -> do
      let path = dir </> "audited.log"
      e <- mkEntry
      withAuditedLog path $ \h -> do
        auditedAck h e
        auditedAck h e
      contents <- BS8.readFile path
      length (BS8.lines contents) `shouldBe` 2

  it "drains an auditedAsync entry queued just before scope exit" $
    withSystemTempDirectory "seal-aud" $ \dir -> do
      let path = dir </> "audited.log"
      e <- mkEntry
      withAuditedLog path $ \h ->
        auditedAsync h e
      contents <- BS8.readFile path
      length (BS8.lines contents) `shouldBe` 1

  it "readAudited round-trips the written entries" $
    withSystemTempDirectory "seal-aud" $ \dir -> do
      let path = dir </> "audited.log"
      e <- mkEntry
      withAuditedLog path $ \h -> do
        auditedAck h e
        es <- readAudited h
        case es of
          (r : _) -> aeId r `shouldBe` "e1"
          []      -> expectationFailure "no entries read back"

  it "the mirror hook fires after each local fsync (fail-closed ordering)" $
    withSystemTempDirectory "seal-aud" $ \dir -> do
      let path = dir </> "audited.log"
      mirrorCalls <- newIORef (0 :: Int)
      e <- mkEntry
      withAuditedLogMirror
        (\_ -> modifyIORef' mirrorCalls (+ 1))
        path $ \h -> do
          auditedAck h e
          auditedAck h e
      readIORef mirrorCalls `shouldReturn` 2

  it "fakeAuditedLog records entries in invocation order" $ do
    (h, readLog) <- fakeAuditedLog
    e <- mkEntry
    auditedAck h e
    logged <- readLog
    map aeId logged `shouldBe` ["e1"]