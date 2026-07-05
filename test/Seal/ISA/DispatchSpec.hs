{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.DispatchSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.IORef
import Test.Hspec

import Seal.Core.Types
import Seal.Handles.Audited (AuditedHandle (..))
import Seal.Handles.Transcript (TwoFileHandle (..))
import Seal.ISA.Dispatch
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

-- | A two-file transcript + opcode that both append to one ordered log. The
-- handle records @"ack"@ for a 'tfwRecordAndAck' call and @"async"@ for a
-- 'tfwRecordAsync' call, so the test asserts the ACK-before-execute ordering
-- for Untrusted opcodes. The Audited log is a fake (its writes are recorded
-- too, so the Audited-branch test can assert the cross-session write fires).
probe :: IORef [String] -> TrustLevel -> (TwoFileHandle, AuditedHandle, Opcode)
probe ref tl =
  ( TwoFileHandle
      { tfwRecordAndAck = \_ -> modifyIORef' ref (++ ["ack"])
      , tfwRecordAsync  = \_ -> modifyIORef' ref (++ ["async"])
      , tfwReadConversation = pure []
      , tfwReadEntries     = pure []
      , tfwCloseTranscript = pure ()
      }
  , AuditedHandle
      { auditedAck   = \_ -> modifyIORef' ref (++ ["audited"])
      , auditedAsync = \_ -> modifyIORef' ref (++ ["audited-async"])
      , readAudited  = pure []
      , closeAudited = pure ()
      }
  , Opcode (OpName "P") tl "p" (object []) (object [])
           (const (Right ()))
           (\_ _ -> do
               liftIO (modifyIORef' ref (++ ["run"]))
               pure (OpResult [] False Null))
  )

runTestApp :: App a -> IO a
runTestApp act = do
  env <- mkEnv defaultConfig
  runApp env act

spec :: Spec
spec = describe "Seal.ISA.Dispatch" $ do
  it "Untrusted: ack precedes run" $ do
    ref <- newIORef []
    let (h, audited, op) = probe ref Untrusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h audited localBackend (OpName "P") (object []))
    readIORef ref `shouldReturn` ["ack", "run"]

  it "Trusted: async then run (no ACK gate)" $ do
    ref <- newIORef []
    let (h, audited, op) = probe ref Trusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h audited localBackend (OpName "P") (object []))
    readIORef ref `shouldReturn` ["async", "run"]

  it "Audited: session-async + audited then run (writes both logs)" $ do
    ref <- newIORef []
    let (h, audited, op) = probe ref Audited
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h audited localBackend (OpName "P") (object []))
    readIORef ref `shouldReturn` ["async", "audited", "run"]

  it "missing opcode -> OpNotFound" $ do
    ref <- newIORef []
    let (h, audited, _) = probe ref Trusted
    res <- runTestApp (dispatch (mkRegistry []) h audited localBackend (OpName "Z") (object []))
    res `shouldBe` Left (OpNotFound (OpName "Z"))

  it "failed authorization -> Denied, never runs" $ do
    ref <- newIORef []
    let (h, audited, base) = probe ref Trusted
        op = base { opAuthorize = const (Left "nope") }
    res <- runTestApp (dispatch (mkRegistry [op]) h audited localBackend (OpName "P") (object []))
    res `shouldBe` Left (Denied "nope")
    readIORef ref `shouldReturn` []