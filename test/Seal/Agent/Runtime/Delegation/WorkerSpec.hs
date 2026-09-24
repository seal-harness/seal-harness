{-# LANGUAGE OverloadedStrings #-}
-- | Pure-function tests for the W2 delegation mechanics (issue #154):
-- the role-aware child blocklist, the effective-role resolver, and the
-- def-tools intersection. The integration behavior (nested AGENT_START,
-- depth plumb) lives in Gateway.AgentIntegrationSpec.
module Seal.Agent.Runtime.Delegation.WorkerSpec (spec) where

import Control.Exception (SomeException, catch)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck

import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..))
import Seal.Agent.Runtime.Delegation
  ( ChildExitReason (..)
  , ChildRunHooks (..)
  , ChildTask (..)
  , ChildWorkerOutcome (..)
  )
import Seal.Agent.Runtime.Delegation.Worker
import Seal.Channel.Caps (ChannelCaps)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSystemSessionId)
import Seal.Handles.AskReply (newApprovalCache)
import Seal.ISA.Registry (mkRegistry)
import Seal.Logging.Logger (testSealLogger)
import Seal.Providers.Class (SomeProvider (..))
import Seal.Security.Policy (AllowList (..), AutonomyLevel (..))
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.TestHelpers.Arbitrary ()
import Seal.TestHelpers.ScriptProvider (ScriptProvider (..))
import Seal.Tools.Exec.Abort (newAbortFlag)
import Seal.Tools.Exec.UIO.Internal
  (mkRemoteUntrustedIOStub, mkTestUIOEnv)
import Seal.Tools.Timeout (defaultToolTimeoutConfig)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import System.FilePath ((</>))

agentStart :: OpName
agentStart = OpName "AGENT_START"

spec :: Spec
spec = describe "Seal.Agent.Runtime.Delegation.Worker" $ do
  describe "childBlocklist" $ do
    it "always drops AGENT_START (the gated nested op is the enforcement)" $ do
      Set.member agentStart (childBlocklist (Just "leaf") True) `shouldBe` False
      Set.member agentStart (childBlocklist Nothing True) `shouldBe` False
      Set.member agentStart (childBlocklist (Just "orchestrator") True) `shouldBe` False
      Set.member agentStart (childBlocklist (Just "orchestrator") False) `shouldBe` False

    it "always blocks the rest of the blocklist (membership)" $ do
      let bl = childBlocklist (Just "orchestrator") True
      Set.member (OpName "AGENT_DEF_WRITE") bl `shouldBe` True
      Set.member (OpName "AGENT_DEF_DELETE") bl `shouldBe` True
      Set.member (OpName "AGENT_INSTANCES") bl `shouldBe` True
      Set.member (OpName "AGENT_STATUS") bl `shouldBe` True
      Set.member (OpName "AGENT_STOP") bl `shouldBe` True
      Set.member (OpName "AGENT_INTERRUPT") bl `shouldBe` True

    it "is a subset of the static delegationBlocklist (property)" $
      property $ \r e ->
        Set.isSubsetOf (childBlocklist (roleText <$> r) e) delegationBlocklist

  describe "narrowAllowList (role-aware)" $ do
    it "keeps AGENT_START (present-but-rejecting via the gate)" $
      narrowAllowListWith
        (childBlocklist (Just "leaf") True)
        (AllowOnly (Set.fromList [agentStart, OpName "FILE_READ"]))
        `shouldBe` AllowOnly (Set.fromList [agentStart, OpName "FILE_READ"])

  describe "effectiveRole" $ do
    it "orchestrator def + no ctRole = orchestrator" $
      effectiveRole (Just "orchestrator") Nothing `shouldBe` Just "orchestrator"

    it "orchestrator def + ctRole leaf = leaf (narrowing)" $
      effectiveRole (Just "orchestrator") (Just "leaf") `shouldBe` Just "leaf"

    it "orchestrator def + ctRole orchestrator = orchestrator (no-op)" $
      effectiveRole (Just "orchestrator") (Just "orchestrator") `shouldBe` Just "orchestrator"

    it "orchestrator def + garbage ctRole = orchestrator (ignored, not widened)" $
      effectiveRole (Just "orchestrator") (Just "admin") `shouldBe` Just "orchestrator"

    it "leaf def + ctRole orchestrator = leaf (never widened)" $
      effectiveRole (Just "leaf") (Just "orchestrator") `shouldBe` Just "leaf"

    it "leaf def + garbage ctRole = leaf" $
      effectiveRole (Just "leaf") (Just "admin") `shouldBe` Just "leaf"

    it "no def role + anything = leaf" $ do
      effectiveRole Nothing Nothing `shouldBe` Nothing
      effectiveRole Nothing (Just "orchestrator") `shouldBe` Nothing

    it "a leaf def can never be widened by any task input (property)" $
      property $ \ct -> ioProperty $
        case effectiveRole (Just "leaf") (fmap roleText ct) of
          Nothing     -> pure ()
          Just "leaf" -> pure ()
          Just other  -> expectationFailure ("widened to: " <> T.unpack other)

  describe "intersectAllowList (def tools ∧ base ops)" $ do
    it "AllowOnly keeps only ops that exist in the base set" $ do
      let base = Set.fromList [agentStart, OpName "FILE_READ"]
      intersectAllowList (AllowOnly (Set.fromList [agentStart, OpName "GHOST_OP"]))
                         (`Set.member` base)
        `shouldBe` AllowOnly (Set.fromList [agentStart])

    it "unknown tool names silently drop (no error)" $ do
      let base = Set.fromList [OpName "FILE_READ"]
      intersectAllowList (AllowOnly (Set.fromList [OpName "GHOST_OP"]))
                         (`Set.member` base)
        `shouldBe` AllowOnly Set.empty

    it "AllowAll stays AllowAll" $
      intersectAllowList AllowAll (`Set.member` Set.empty) `shouldBe` AllowAll

    it "intersection is always a subset of base ops (property)" $
      property $ \allowList ->
        case intersectAllowList allowList (`Set.member` baseSet) of
          AllowOnly xs -> Set.isSubsetOf xs baseSet
          AllowAll     -> True

  describe "mkDelegateWorker workdir anchoring (WU-4)" $ do
    it "calls dwdMkUIOEnv with Just parentWorkdir when ctIsolateWorkdir=False" $ do
      withSystemTempDirectory "seal-worker-anchor" $ \tmp -> do
        anchorRef <- newIORef (Nothing :: Maybe (Maybe FilePath))
        deps <- mkAnchorDepsIO tmp anchorRef
        let worker = mkDelegateWorker deps
            task = ChildTask "a1" "do the thing" Nothing Nothing False
            childSid = mkSystemSessionId "child"
        hooks <- mkHooks
        -- The worker may fail (no real provider round-trip is wired),
        -- but dwdMkUIOEnv is called BEFORE runTurn, so the anchor is
        -- captured regardless.
        _ <- worker sampleAgentDef childSid task hooks
          `catch` \(_e :: SomeException) -> pure (ChildWorkerOutcome Nothing CerError 0 0 (Just childSid))
        captured <- readIORef anchorRef
        captured `shouldSatisfy` isJust
        captured `shouldBe` Just (Just "/fake/parent/workdir")

    it "calls dwdMkUIOEnv with Nothing when ctIsolateWorkdir=True" $ do
      withSystemTempDirectory "seal-worker-anchor" $ \tmp -> do
        anchorRef <- newIORef (Nothing :: Maybe (Maybe FilePath))
        deps <- mkAnchorDepsIO tmp anchorRef
        let worker = mkDelegateWorker deps
            task = ChildTask "a1" "do the thing" Nothing Nothing True
            childSid = mkSystemSessionId "child"
        hooks <- mkHooks
        _ <- worker sampleAgentDef childSid task hooks
          `catch` \(_e :: SomeException) -> pure (ChildWorkerOutcome Nothing CerError 0 0 (Just childSid))
        captured <- readIORef anchorRef
        captured `shouldSatisfy` isJust
        captured `shouldBe` Just Nothing

  where
    roleText :: Text -> Text
    roleText t = case T.strip t of
      "" -> "leaf"
      r  -> r

-- Placeholder base set for the intersection property (the real base ops
-- list lives in buildChildRegistry; the property only needs SOME universe).
baseSet :: Set.Set OpName
baseSet = Set.fromList
  [ agentStart, OpName "FILE_READ", OpName "FILE_WRITE", OpName "MEMORY_READ" ]

-- ---------------------------------------------------------------------------
-- WU-4 workdir anchoring test helpers
-- ---------------------------------------------------------------------------

sampleSession :: SessionId
sampleSession = mkSystemSessionId "parent"

sampleAgentDef :: AgentDef
sampleAgentDef = AgentDef
  { adId = AgentDefId "a1"
  , adName = "test-agent"
  , adProvider = "ollama"
  , adModel = ModelId "llama3"
  , adSystem = Nothing
  , adTools = AllowAll
  , adGroup = Nothing
  , adRole = Nothing
  , adDescription = Nothing
  , adCreatedAt = read "1970-01-01 00:00:00 UTC"
  , adUpdatedAt = read "1970-01-01 00:00:00 UTC"
  , adSession = sampleSession
  }

-- | Build the 'DelegationWorkerDeps' for the anchoring test. The
-- 'dwdMkUIOEnv' records the anchor arg to the IORef and returns a stub
-- 'UIOEnv'. The provider resolver returns a 'ScriptProvider' that
-- immediately yields @\"done\"@ so runTurn completes (or at least reaches
-- the dwdMkUIOEnv call before any failure).
mkAnchorDepsIO :: FilePath -> IORef (Maybe (Maybe FilePath)) -> IO DelegationWorkerDeps
mkAnchorDepsIO tmp anchorRef = do
  logger <- testSealLogger
  appEnv <- mkEnv logger defaultConfig
  approvals <- newApprovalCache
  pure DelegationWorkerDeps
    { dwdPaths = samplePaths tmp
    , dwdParentSid = sampleSession
    , dwdAppEnv = appEnv
    , dwdMkUIOEnv = \anchor _childSid -> do
        writeIORef anchorRef (Just anchor)
        pure (mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps)
    , dwdParentWorkdir = Just "/fake/parent/workdir"
    , dwdAutonomy = Full
    , dwdApprovals = approvals
    , dwdOnDemand = False
    , dwdParentDepth = 0
    , dwdResolveProvider = \_def -> do
        ref <- newIORef []
        pure (Right (SomeProvider (ScriptProvider ref), ModelId "llama3"))
    , dwdResolveProviderOverride = Nothing
    , dwdUnionDefBackend = error "dwdUnionDefBackend: unused (no nested AGENT_START in this test)"
    , dwdChildRegistry = \_def _depth _role _sid (_caps :: ChannelCaps) -> pure (mkRegistry [])
    , dwdChildSystemPrompt = \_ _ -> pure Nothing
    , dwdOnEntry = pure ()
    , dwdChannel = "test"
    , dwdAbortFlag = const newAbortFlag
    , dwdToolTimeout = defaultToolTimeoutConfig
    }

-- | A minimal 'SealPaths' fixture rooted at @tmp@.
samplePaths :: FilePath -> SealPaths
samplePaths tmp = SealPaths
  { spHome = tmp
  , spConfig = tmp </> "config"
  , spState = tmp </> "state"
  , spKeys = tmp </> "keys"
  , spCache = tmp </> "cache"
  }

-- | Construct the 'ChildRunHooks' accumulators (all empty/fresh).
mkHooks :: IO ChildRunHooks
mkHooks = do
  traceRef <- newIORef []
  readRef <- newIORef []
  writtenRef <- newIORef []
  interruptedRef <- newIORef False
  pure (ChildRunHooks traceRef readRef writtenRef interruptedRef)
