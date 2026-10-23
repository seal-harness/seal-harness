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
import Data.Time (getCurrentTime)
import System.Directory (doesFileExist)
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
import Seal.Config.Paths (SealPaths (..), agentSessionDir)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSystemSessionId)
import Seal.Handles.AskReply (newApprovalCache)
import Seal.ISA.Registry (mkRegistry)
import Seal.ISA.RepeatDetect (newSessionRepeatRegistry, lookupOrCreateRepeatTrack)
import Seal.Logging.Logger (testSealLogger)
import Seal.Providers.Class (SomeProvider (..))
import Seal.Security.Policy (AllowList (..), AutonomyLevel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta)
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.TestHelpers.Arbitrary ()
import Seal.TestHelpers.ScriptProvider (ScriptProvider (..))
import Seal.Tools.Exec.Abort (newAbortFlag)
import Seal.Tools.Exec.UIO.Internal
  (mkRemoteUntrustedIOStub, mkTestUIOEnv)
import Seal.Tools.Timeout (defaultToolTimeoutConfig)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Util.StrictIO (decodeFileStrict)
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
        deps <- mkWorkerDepsIO tmp anchorRef =<< newIORef Nothing
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
        deps <- mkWorkerDepsIO tmp anchorRef =<< newIORef Nothing
        let worker = mkDelegateWorker deps
            task = ChildTask "a1" "do the thing" Nothing Nothing True
            childSid = mkSystemSessionId "child"
        hooks <- mkHooks
        _ <- worker sampleAgentDef childSid task hooks
          `catch` \(_e :: SomeException) -> pure (ChildWorkerOutcome Nothing CerError 0 0 (Just childSid))
        captured <- readIORef anchorRef
        captured `shouldSatisfy` isJust
        captured `shouldBe` Just Nothing

  describe "mkDelegateWorker child meta persistence (WU3)" $ do
    it "writes session.json with smParent = parent into the child dir" $ do
      withSystemTempDirectory "seal-worker-meta" $ \tmp -> do
        let paths = samplePaths tmp
        -- Seed a parent session.json so the child meta inherits its
        -- provider/model.
        now <- getCurrentTime
        let parentMeta = SessionMeta
              { smId = sampleSession, smProvider = "anthropic"
              , smModel = "claude-opus-4", smChannel = "web"
              , smParent = Nothing
              , smAgent = Nothing, smSystemOverride = Nothing, smAgentName = Nothing
              , smDescription = Nothing
              , smSealFrontMatter = True
              , smRepoUrl = Nothing
              , smCreatedAt = now, smLastActive = now }
        saveSessionMeta paths parentMeta
        anchorRef <- newIORef (Nothing :: Maybe (Maybe FilePath))
        deps <- mkWorkerDepsIO tmp anchorRef =<< newIORef Nothing
        let worker = mkDelegateWorker deps
            task = ChildTask "a1" "do the thing" Nothing Nothing False
            childSid = mkSystemSessionId "child"
        hooks <- mkHooks
        _ <- worker sampleAgentDef childSid task hooks
          `catch` \(_e :: SomeException) -> pure (ChildWorkerOutcome Nothing CerError 0 0 (Just childSid))
        let childMetaPath = agentSessionDir paths sampleSession childSid </> "session.json"
        exists <- doesFileExist childMetaPath
        exists `shouldBe` True
        mMeta <- decodeFileStrict childMetaPath
        fmap smParent mMeta `shouldBe` Just (Just sampleSession)
        fmap smId mMeta `shouldBe` Just childSid
        fmap smChannel mMeta `shouldBe` Just "agent"
        fmap smProvider mMeta `shouldBe` Just "anthropic"
        fmap smModel mMeta `shouldBe` Just "claude-opus-4"

  describe "mkDelegateWorker lineage threading (WU3)" $ do
    it "passes childSid : dwdParentLineage to the child-registry seam" $ do
      withSystemTempDirectory "seal-worker-lineage" $ \tmp -> do
        lineageRef <- newIORef (Nothing :: Maybe [SessionId])
        anchorRef <- newIORef (Nothing :: Maybe (Maybe FilePath))
        deps <- mkWorkerDepsIO tmp anchorRef lineageRef
        let worker = mkDelegateWorker deps
            task = ChildTask "a1" "do the thing" Nothing Nothing False
            childSid = mkSystemSessionId "child"
        hooks <- mkHooks
        _ <- worker sampleAgentDef childSid task hooks
          `catch` \(_e :: SomeException) -> pure (ChildWorkerOutcome Nothing CerError 0 0 (Just childSid))
        captured <- readIORef lineageRef
        -- The seam must receive the CHILD's full lineage: the child's own
        -- id prepended to the parent's baked chain (self first).
        captured `shouldBe` Just [childSid, sampleSession, grandparentSid]

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
-- WU-4 workdir anchoring + WU3 lineage test helpers
-- ---------------------------------------------------------------------------

sampleSession :: SessionId
sampleSession = mkSystemSessionId "parent"

-- | A fixed ancestor of 'sampleSession' so the lineage chain in the
-- worker-deps tests is more than one entry long.
grandparentSid :: SessionId
grandparentSid = mkSystemSessionId "grandparent"

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
, adAllowSpawn = Nothing
  , adCreatedAt = read "1970-01-01 00:00:00 UTC"
  , adUpdatedAt = read "1970-01-01 00:00:00 UTC"
  , adSession = sampleSession
  }

-- | Build the 'DelegationWorkerDeps' for the anchoring + lineage tests.
-- The 'dwdMkUIOEnv' records the anchor arg and the 'dwdChildRegistry'
-- records its lineage argument (both to their IORefs) and return stubs.
-- The provider resolver returns a 'ScriptProvider' that immediately
-- yields @\"done\"@ so runTurn completes (or at least reaches the
-- dwdMkUIOEnv call before any failure).
mkWorkerDepsIO
  :: FilePath -> IORef (Maybe (Maybe FilePath)) -> IORef (Maybe [SessionId])
  -> IO DelegationWorkerDeps
mkWorkerDepsIO tmp anchorRef lineageRef = do
  logger <- testSealLogger
  appEnv <- mkEnv logger defaultConfig
  approvals <- newApprovalCache
  repeatReg <- newSessionRepeatRegistry
  pure DelegationWorkerDeps
    { dwdPaths = samplePaths tmp
    , dwdParentSid = sampleSession
    , dwdParentLineage = [sampleSession, grandparentSid]
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
    , dwdChildRegistry = \lineage _def _depth _role _sid (_caps :: ChannelCaps) -> do
        writeIORef lineageRef (Just lineage)
        pure (mkRegistry [])
    , dwdChildSystemPrompt = \_ _ -> pure Nothing
    , dwdOnEntry = pure ()
    , dwdChannel = "test"
    , dwdAbortFlag = const newAbortFlag
    , dwdRepeatTrack = lookupOrCreateRepeatTrack repeatReg
      -- ^ Mirrors the production wiring (TurnEngine.buildWorker): the
      -- registry is created once per test deps-build, the worker resolves
      -- the CHILD's own track from the minted child sid at spawn time
      -- (session-read hardening WU4).
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
