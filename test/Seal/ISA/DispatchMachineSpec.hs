{-# LANGUAGE OverloadedStrings #-}
-- | WU-3: dispatcher-side machine resolution.
--
-- Covers the behaviour design §6.2 rests on: the target is resolved in
-- @dispatch@ before the ACK, an unknown machine runs nothing anywhere, omission
-- always falls back to the session machine, and selection is not sticky.
module Seal.ISA.DispatchMachineSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, Selectable (..), mkMachineName)
import Seal.Core.Types (OpName (..))
import Seal.Handles.Transcript (IndexedTranscriptHandle, fakeIndexedTranscript)
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.ISA.Dispatch (DispatchError (..), dispatch)
import Seal.ISA.Opcode
import Seal.ISA.Registry (mkRegistry)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Exec.Abort (newAbortFlag)
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Logging.Logger (testSealLogger)
import Seal.Tools.Exec.Machine
import Seal.Tools.Timeout (defaultToolTimeoutConfig)
import Seal.Tools.Exec.UIO qualified as UIO
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnvWith)
import Seal.Tools.Exec.UntrustedIO (UntrustedIO (..), mkRemoteUntrustedIOStub)
import Seal.Tools.Args (mkShellCommand)

-- | An 'UntrustedIO' whose shell method bumps a counter. Everything else is the
-- remote stub, so a call that accidentally runs here is still observable.
countingIO :: IORef Int -> UntrustedIO
countingIO ref = mkRemoteUntrustedIOStub
  { uioShellExec = \_ _ -> do
      modifyIORef' ref (+ 1)
      pure (Right "ran")
  }

spec :: Spec
spec = describe "dispatch — per-call machine resolution" $ do

  describe "omission uses the session machine" $
    it "runs on the session machine when the model names none" $ do
      sessionRef <- newIORef 0
      otherRef   <- newIORef 0
      r <- runNamed sessionRef otherRef (object [])
      readIORef sessionRef `shouldReturn` 1
      readIORef otherRef   `shouldReturn` 0
      r `shouldSatisfy` isRight

  describe "selection is not sticky" $
    it "a call naming another machine then one omitting it returns to session" $ do
      sessionRef <- newIORef 0
      otherRef   <- newIORef 0
      _ <- runNamed sessionRef otherRef (object ["machine" .= ("other" :: Text)])
      _ <- runNamed sessionRef otherRef (object [])
      readIORef otherRef   `shouldReturn` 1
      readIORef sessionRef `shouldReturn` 1

  describe "a named machine" $
    it "runs there, not on the session machine" $ do
      sessionRef <- newIORef 0
      otherRef   <- newIORef 0
      r <- runNamed sessionRef otherRef (object ["machine" .= ("other" :: Text)])
      readIORef otherRef   `shouldReturn` 1
      readIORef sessionRef `shouldReturn` 0
      r `shouldSatisfy` isRight

  describe "two machines in one session" $
    it "each call runs on the machine it names, counted separately" $ do
      aRef <- newIORef 0
      bRef <- newIORef 0
      _ <- runTwo aRef bRef (object ["machine" .= ("a" :: Text)])
      _ <- runTwo aRef bRef (object ["machine" .= ("b" :: Text)])
      readIORef aRef `shouldReturn` 1
      readIORef bRef `shouldReturn` 1

  describe "an unknown machine" $
    it "runs nothing anywhere and fails naming the choices" $ do
      sessionRef <- newIORef 0
      otherRef   <- newIORef 0
      r <- runNamed sessionRef otherRef (object ["machine" .= ("nope" :: Text)])
      -- Zero calls anywhere: resolution fails before any UIO action.
      readIORef sessionRef `shouldReturn` 0
      readIORef otherRef   `shouldReturn` 0
      case r of
        Left (ExecFailed msg) -> do
          msg `shouldSatisfy` T.isInfixOf "unknown execution machine"
          msg `shouldSatisfy` T.isInfixOf "nope"
          -- the valid choices are listed
          msg `shouldSatisfy` T.isInfixOf "session"
        other -> expectationFailure ("expected ExecFailed, got " <> show other)

  describe "the ACK entry" $
    it "records the resolved machine name before the call runs" $ do
      sessionRef <- newIORef 0
      otherRef   <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      _ <- dispatchWith h sessionRef otherRef (object ["machine" .= ("other" :: Text)])
      (_, entries) <- readState
      -- The invocation entry names "other", the machine that actually ran.
      let metas = map (T.pack . show . erMeta) entries
      metas `shouldSatisfy` any (T.isInfixOf "machine")
      metas `shouldSatisfy` any (T.isInfixOf "other")

-- Helpers -----------------------------------------------------------------

-- | Run an App action with a test logger (mirrors the local helper in
-- DispatchSpec, which is not exported).
runTestApp :: App a -> IO a
runTestApp act = do
  logger <- testSealLogger
  env <- mkEnv logger defaultConfig
  runApp env act

shellOp :: Opcode
shellOp = UntrustedOpcode
  { uoName = OpName "SHELL_EXEC"
  , uoDesc = "test"
  , uoInSchema = object []
  , uoOutSchema = object []
  , uoAuthorize = const (Right ())
  , uoRun = \_ ->
      case mkShellCommand "true" of
        Left e   -> pure (OpResult [TrpText e] True (object []))
        Right c  -> do
          res <- UIO.uioShellExec c Nothing
          pure $ case res of
            Left e    -> OpResult [TrpText (T.pack (show e))] True (object [])
            Right out -> OpResult [TrpText out] False (object [])
  }

runNamed :: IORef Int -> IORef Int -> Value -> IO (Either DispatchError OpResult)
runNamed sessionRef otherRef input = do
  (h, _) <- fakeIndexedTranscript
  dispatchWith h sessionRef otherRef input

dispatchWith
  :: IndexedTranscriptHandle -> IORef Int -> IORef Int -> Value
  -> IO (Either DispatchError OpResult)
dispatchWith h sessionRef otherRef input = do
  routing <- mkMachineRouting (nm "session")
               [SelMachine (nm "session"), SelMachine (nm "other")]
               (\n _ -> pure (Left (MachineUnreachable n UrConnectFailed)))
               stubCloneDeps
  seeded <- seedRouting routing
    [ (nm "session", countingIO sessionRef, stubCloneDeps)
    , (nm "other",   countingIO otherRef,   stubCloneDeps) ]
  abort <- newAbortFlag
  runTestApp (dispatch (mkRegistry [shellOp]) h localBackend
                (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
                defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") input)

runTwo :: IORef Int -> IORef Int -> Value -> IO (Either DispatchError OpResult)
runTwo aRef bRef input = do
  routing <- mkMachineRouting (nm "a")
               [SelMachine (nm "a"), SelMachine (nm "b")]
               (\n _ -> pure (Left (MachineUnreachable n UrConnectFailed)))
               stubCloneDeps
  seeded <- seedRouting routing
    [ (nm "a", countingIO aRef, stubCloneDeps)
    , (nm "b", countingIO bRef, stubCloneDeps) ]
  abort <- newAbortFlag
  (h, _) <- fakeIndexedTranscript
  runTestApp (dispatch (mkRegistry [shellOp]) h localBackend
                (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
                defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") input)

nm :: String -> MachineName
nm s = case mkMachineName (T.pack s) of
  Right n -> n
  Left e  -> error ("DispatchMachineSpec: " <> show e)

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False
