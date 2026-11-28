{-# LANGUAGE OverloadedStrings #-}
-- | WU-3: dispatcher-side machine resolution.
--
-- Covers the behaviour design §6.2 rests on: the target is resolved in
-- @dispatch@ before the ACK, an unknown machine runs nothing anywhere, omission
-- always falls back to the session machine, and selection is not sticky.
module Seal.ISA.DispatchMachineSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, Selectable (..), mkMachineName)
import Seal.Core.Types (OpName (..))
import Seal.Handles.Transcript (IndexedTranscriptHandle, fakeIndexedTranscript)
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.ISA.Dispatch (DispatchError (..), dispatch, dispatchOn)
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
import Seal.Tools.Exec.Types (ExecError (..))
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedErr (..), UntrustedIO (..), mkRemoteUntrustedIOStub )
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

  -- ---------------------------------------------------------------------
  -- WU-12: the ACK record. The property is ACK-BEFORE-EXECUTE, so the
  -- interesting cases are the ones where execution fails: a record that only
  -- appears on success would have been written AFTER the action ran, which is
  -- the ordering this whole module exists to prevent.
  -- ---------------------------------------------------------------------

  describe "WU-12 the ACK entry names the machine" $ do

    it "records the resolved name when the call SUCCEEDS" $ do
      sessionRef <- newIORef 0
      otherRef   <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      r <- dispatchWith h sessionRef otherRef (object ["machine" .= ("other" :: Text)])
      r `shouldSatisfy` isRight
      (_, entries) <- readState
      entryMachine entries `shouldBe` Just "other"

    it "records the resolved name when the call FAILS — before it ran" $ do
      -- P10 from the plan gate: a post-execution assertion passes the success
      -- path and proves nothing about ordering. Drive a machine whose handle
      -- fails, and require the entry to exist anyway.
      ref <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref), (nm "broken", failingIO ref)]
      abort <- newAbortFlag
      _ <- runTestApp (dispatch (mkRegistry [shellOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC")
             (object ["machine" .= ("broken" :: Text)]))
      (_, entries) <- readState
      entryMachine entries `shouldBe` Just "broken"

    it "records the SESSION machine when the model names none" $ do
      ref <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref)]
      abort <- newAbortFlag
      _ <- runTestApp (dispatch (mkRegistry [shellOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") (object []))
      (_, entries) <- readState
      -- Stronger than "records something": an omitting call records the
      -- machine it actually used.
      entryMachine entries `shouldBe` Just "session"

    it "a DENIED call records nothing (opAuthorize runs first)" $ do
      ref <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref)]
      abort <- newAbortFlag
      r <- runTestApp (dispatch (mkRegistry [denyingOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") (object []))
      r `shouldSatisfy` isDenied
      (_, entries) <- readState
      entries `shouldBe` []
      readIORef ref `shouldReturn` 0

    it "records the REQUESTED name plus an error class when resolution fails" $ do
      -- OWASP A09: a model naming a forbidden machine must leave a trace,
      -- otherwise the attempt is invisible in the audit log.
      ref <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref)]
      abort <- newAbortFlag
      _ <- runTestApp (dispatch (mkRegistry [shellOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC")
             (object ["machine" .= ("forbidden" :: Text)]))
      (_, entries) <- readState
      entryMachine entries `shouldBe` Just "forbidden"
      entryErrorClass entries `shouldBe` Just "machine"
      readIORef ref `shouldReturn` 0

    it "the record carries the name and NOTHING else about the machine" $ do
      -- Negative: no host, user, path or key may reach the transcript. The
      -- machine's coordinates are exactly what the model must never see.
      ref <- newIORef 0
      (h, readState) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref)]
      abort <- newAbortFlag
      _ <- runTestApp (dispatch (mkRegistry [shellOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") (object []))
      (_, entries) <- readState
      let rendered = T.intercalate "\n" (map (T.pack . show . erMeta) entries)
      rendered `shouldNotSatisfy` T.isInfixOf "host"
      rendered `shouldNotSatisfy` T.isInfixOf "/srv/"
      rendered `shouldNotSatisfy` T.isInfixOf "identity"

  -- ---------------------------------------------------------------------
  -- WU-13: dispatchOn reports WHICH machine ran, for the post-SETUP_REPO
  -- hooks. They must not re-scan the session machine's workdir after a clone
  -- landed on another one — so they need the name, and re-deriving it outside
  -- dispatch would be a second resolution that could disagree.
  -- ---------------------------------------------------------------------

  describe "WU-13 dispatchOn reports the machine" $ do

    it "reports the named machine for an untrusted call" $ do
      ref <- newIORef 0
      (h, _) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref), (nm "beta", countingIO ref)]
      abort <- newAbortFlag
      (_, mRanOn) <- runTestApp (dispatchOn (mkRegistry [shellOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC")
             (object ["machine" .= ("beta" :: Text)]))
      mRanOn `shouldBe` Just (nm "beta")

    it "reports the session machine when none is named" $ do
      ref <- newIORef 0
      (h, _) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref)]
      abort <- newAbortFlag
      (_, mRanOn) <- runTestApp (dispatchOn (mkRegistry [shellOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") (object []))
      mRanOn `shouldBe` Just (nm "session")

    it "reports Nothing when the call was denied before resolution" $ do
      -- opAuthorize runs first, so a denied call has no machine — and the
      -- caller must not act as though it ran somewhere.
      ref <- newIORef 0
      (h, _) <- fakeIndexedTranscript
      seeded <- routingFor [(nm "session", countingIO ref)]
      abort <- newAbortFlag
      (res, mRanOn) <- runTestApp (dispatchOn (mkRegistry [denyingOp]) h localBackend
             (mkTestUIOEnvWith mkRemoteUntrustedIOStub stubCloneDeps seeded)
             defaultToolTimeoutConfig abort (OpName "SHELL_EXEC") (object []))
      res `shouldSatisfy` isDenied
      mRanOn `shouldBe` Nothing

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

-- | An 'UntrustedIO' whose every operation fails, for the ACK-on-failure case.
-- Built from the remote stub so no real IO is reachable.
failingIO :: IORef Int -> UntrustedIO
failingIO ref = mkRemoteUntrustedIOStub
  { uioShellExec = \_ _ -> do
      modifyIORef' ref (+ 1)
      pure (Left (UeExec (ExecNotImplementedReason "no transport")))
  }

-- | Routing whose session machine is @session@, with the given handle per
-- name, and a bootstrap that always fails — so a name nobody seeded is a typed
-- routing error rather than an accidental success.
routingFor :: [(MachineName, UntrustedIO)] -> IO MachineRouting
routingFor entries = do
  routing <- mkMachineRouting (nm "session")
               (map (SelMachine . fst) entries)
               (\n _ -> pure (Left (MachineUnreachable n UrConnectFailed)))
               stubCloneDeps
  seedRouting routing [ (n, uio, stubCloneDeps) | (n, uio) <- entries ]

-- | The machine name recorded in the ACK entry, if any.
--
-- Reads the structured @erMeta@ field rather than grepping the rendered JSON: a
-- substring match would also pass on a name appearing in the opcode's INPUT,
-- which is a different claim.
entryMachine :: [EntryRecord] -> Maybe Text
entryMachine entries = case mapMaybe machineOf entries of
  (x : _) -> Just x
  []      -> Nothing
  where
    machineOf e = case Map.lookup "machine" (erMeta e) of
      Just (String t) -> Just t
      _               -> Nothing

-- | The error class recorded in the ACK entry, if any.
entryErrorClass :: [EntryRecord] -> Maybe Text
entryErrorClass entries = case mapMaybe clsOf entries of
  (x : _) -> Just x
  []      -> Nothing
  where
    clsOf e = case Map.lookup "error" (erMeta e) of
      Just (String t) -> Just t
      _               -> Nothing

-- | An opcode whose authorize gate always rejects, for the
-- "a denied call records nothing" assertion.
denyingOp :: Opcode
denyingOp = UntrustedOpcode
  { uoName = OpName "SHELL_EXEC"
  , uoDesc = "denied"
  , uoInSchema = object []
  , uoOutSchema = object []
  , uoAuthorize = const (Left "denied by test policy")
  , uoRun = \_ -> pure (OpResult [TrpText "should not run"] True (object []))
  }

isDenied :: Either DispatchError a -> Bool
isDenied (Left (Denied _)) = True
isDenied _                 = False

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False
