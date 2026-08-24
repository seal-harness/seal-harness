-- | The per-process session execution + discovery cache.
--
-- Two memoization layers over the per-session workdir machinery, shared by
-- every surface that touches a session's workspace (turn engine, /call
-- dispatcher, gateway API):
--
--   1. __Session exec__ ('cachedSessionExec') — 'mkSessionExec' runs a
--      remote @mkdir -p@ bootstrap on every construction; in remote mode
--      that is one SSH round trip per turn / per API call. The cache keys
--      the built 'SessionExec' by 'SessionId' and rebuilds only when the
--      security config's untrusted-exec fingerprint changes (a local↔remote
--      or workspace switch) or after an explicit 'invalidateExec'.
--      Fail-closed builds are NEVER cached (a later retry must be able to
--      succeed).
--
--   2. __Workdir discovery__ ('cachedWorkdirScan') — the agent-def +
--      skill scans ('listWorkdirAgentDefs', 'listWorkdirSkills') run once
--      per session within a TTL window and are invalidated explicitly when
--      the workdir's structure changes (@SETUP_REPO@ clone). Each cached
--      entry records its workspace root, so a config switch re-scans even
--      inside the TTL.
--
-- Staleness contract: within the TTL, out-of-band workdir mutations (the
-- model writing files via untrusted opcodes, manual edits on the remote
-- machine) are NOT observed. The TTL bounds that window; SETUP_REPO — the
-- only structural mutation the harness itself drives — invalidates eagerly.
module Seal.Session.ExecCache
  ( SessionExecCache
  , newSessionExecCache
  , newSessionExecCacheWith
  , cachedSessionExec
  , invalidateExec
  , cachedWorkdirScan
  , invalidateWorkdirScan
  ) where

import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)

import Seal.Agent.Def.Types (AgentDef)
import Seal.Agent.Def.Workdir (listWorkdirAgentDefsSnap)
import Seal.Config.Paths (SealPaths)
import Seal.Config.Security (SecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Core.Types (SessionId)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.Workdir
  ( SessionExec (..), isFailClosedSessionExec, mkSessionExec
  )
import Seal.Skills.Backend (listWorkdirSkillsSnap)
import Seal.Skills.Types (Skill)
import Seal.SourceControl.Clone (CloneDeps)
import Seal.Tools.Exec.Remote (RemoteRunner)
import Seal.Tools.Exec.WorkdirFs (WorkdirFs, wfsSnapshot)

-- | The shared cache handle. Create ONE per process (per gateway /
-- channel loop / CLI invocation) via 'newSessionExecCache'.
data SessionExecCache = SessionExecCache
  { sceExecs :: IORef (Map SessionId CachedExec)
  , sceScans :: IORef (Map SessionId CachedScan)
  , sceNow   :: IO UTCTime
    -- ^ The clock seam (tests inject a fake).
  }

data CachedExec = CachedExec
  { ceFingerprint :: !Text       -- ^ Untrusted-exec config fingerprint at build time
  , ceExec        :: !SessionExec
  }

data CachedScan = CachedScan
  { csAt    :: !UTCTime          -- ^ When the scan ran (for the TTL)
  , csRoot  :: !Text             -- ^ Workspace root text (config-switch guard)
  , csDefs  :: ![AgentDef]
  , csSkills:: ![Skill]
  }

-- | How long a discovery scan stays fresh before the next consumer re-scans.
defaultDiscoveryTTL :: NominalDiffTime
defaultDiscoveryTTL = 60

-- | Create a cache with the real clock.
newSessionExecCache :: IO SessionExecCache
newSessionExecCache = newSessionExecCacheWith getCurrentTime

-- | Create a cache with an injected clock (tests).
newSessionExecCacheWith :: IO UTCTime -> IO SessionExecCache
newSessionExecCacheWith now =
  SessionExecCache <$> newIORef Map.empty <*> newIORef Map.empty <*> pure now

-- | A stable fingerprint of the part of the security config that determines
-- session-exec behavior (mode local/remote + SSH coordinates). 'Show'-based:
-- the config types are small, pure records with 'Eq'/'Show' pinned for tests.
execFingerprint :: SecurityConfig -> Text
execFingerprint = T.pack . show . untrustedExecConfigFromSecurity

-- | Fetch-or-build the session's 'SessionExec'. Successes are memoized by
-- 'SessionId'; rebuilt on a fingerprint mismatch or explicit
-- 'invalidateExec'. Fail-closed builds are never stored.
cachedSessionExec
  :: SessionExecCache -> SealPaths -> SecurityConfig -> SessionId
  -> CloneDeps -> RemoteRunner -> IO SessionExec
cachedSessionExec cache paths secCfg sid cloneDeps runner = do
  execs <- readIORef (sceExecs cache)
  let fp = execFingerprint secCfg
  case Map.lookup sid execs of
    Just ce | ceFingerprint ce == fp -> pure (ceExec ce)
    _ -> do
      exec <- mkSessionExec paths secCfg sid cloneDeps runner
      if isFailClosedSessionExec exec
        then pure exec   -- never cache failures: a later retry must succeed
        else do
          modifyIORef' (sceExecs cache) (Map.insert sid (CachedExec fp exec))
          pure exec

-- | Drop one session's memoized exec (the next 'cachedSessionExec' call
-- rebuilds it). Used when the workdir is known to have been recreated.
invalidateExec :: SessionExecCache -> SessionId -> IO ()
invalidateExec cache sid =
  modifyIORef' (sceExecs cache) (Map.delete sid)

-- | Fetch-or-scan the session's workdir discovery results: the agent defs
-- + skills, computed together from ONE 'wfsSnapshot' so a cache miss costs
-- exactly one snapshot round trip. Memoized by 'SessionId' within
-- 'defaultDiscoveryTTL'; a stored entry whose workspace root differs from
-- the caller's re-scans immediately (config-switch guard). A FAILED
-- snapshot is returned fail-soft-to-empty and never cached (the next
-- consumer retries).
cachedWorkdirScan
  :: SessionExecCache -> SessionId -> WorkdirFs -> WorkspaceRoot
  -> IO ([AgentDef], [Skill])
cachedWorkdirScan cache sid fs wsRoot = do
  now <- sceNow cache
  scans <- readIORef (sceScans cache)
  let rootText = rootTextOf wsRoot
  case Map.lookup sid scans of
    Just cs | csRoot cs == rootText && diffUTCTime now (csAt cs) < defaultDiscoveryTTL ->
      pure (csDefs cs, csSkills cs)
    _ -> do
      eSnap <- wfsSnapshot fs
      case eSnap of
        -- Fail-soft, uncached: don't freeze empty results for the TTL.
        Left _ -> pure ([], [])
        Right snap -> do
          defs <- listWorkdirAgentDefsSnap snap fs
          skills <- listWorkdirSkillsSnap snap fs
          modifyIORef' (sceScans cache)
            (Map.insert sid (CachedScan now rootText defs skills))
          pure (defs, skills)

-- | Drop one session's memoized discovery scan. Called after SETUP_REPO
-- succeeds (the clone changed the workdir's structure) so the next consumer
-- sees the cloned repo's defs/skills.
invalidateWorkdirScan :: SessionExecCache -> SessionId -> IO ()
invalidateWorkdirScan cache sid =
  modifyIORef' (sceScans cache) (Map.delete sid)

rootTextOf :: WorkspaceRoot -> Text
rootTextOf (WorkspaceRoot p) = T.pack p
