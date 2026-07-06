{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.DispatchSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.IORef
import Test.Hspec

import Seal.Core.Types
import Seal.Handles.Transcript (TwoFileHandle (..))
import Seal.ISA.Dispatch
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

-- | A two-file transcript handle that records @"ack"@ for a 'tfwRecordAndAck'
-- call and @"async"@ for a 'tfwRecordAsync' call, so the test asserts the
-- ACK-before-execute ordering for Untrusted opcodes.
probe :: IORef [String] -> TrustLevel -> (TwoFileHandle, Opcode)
probe ref tl =
  ( TwoFileHandle
      { tfwRecordAndAck = \_ -> modifyIORef' ref (++ ["ack"])
      , tfwRecordAsync  = \_ -> modifyIORef' ref (++ ["async"])
      , tfwReadConversation = pure []
      , tfwReadEntries     = pure []
      , tfwCloseTranscript = pure ()
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
    let (h, op) = probe ref Untrusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h localBackend (OpName "P") (object []))
    readIORef ref `shouldReturn` ["ack", "run"]

  it "Trusted: async then run (no ACK gate)" $ do
    ref <- newIORef []
    let (h, op) = probe ref Trusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h localBackend (OpName "P") (object []))
    readIORef ref `shouldReturn` ["async", "run"]

  it "missing opcode -> OpNotFound" $ do
    ref <- newIORef []
    let (h, _) = probe ref Trusted
    res <- runTestApp (dispatch (mkRegistry []) h localBackend (OpName "Z") (object []))
    res `shouldBe` Left (OpNotFound (OpName "Z"))

  it "failed authorization -> Denied, never runs" $ do
    ref <- newIORef []
    let (h, base) = probe ref Trusted
        op = base { opAuthorize = const (Left "nope") }
    res <- runTestApp (dispatch (mkRegistry [op]) h localBackend (OpName "P") (object []))
    res `shouldBe` Left (Denied "nope")
    readIORef ref `shouldReturn` []