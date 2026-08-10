-- | In-memory RepoRegistryHandle for tests, mirroring the real handle's
-- Either contract without touching disk. Factored from ApiSpec's
-- @fakeRepoRegistryHandle@ so CloneSpec/LoopSpec/SendSpec/ApiSpec share one.
module Seal.TestHelpers.FakeRegistry
  ( fakeRepoRegistryHandle
  , mkFakeRepoRegistryHandle
  ) where

import Seal.SourceControl.Registry (RepoRegistryHandle (..))

-- | A fake 'RepoRegistryHandle' whose @rrhList@ always returns an empty
-- registry (no registered repos) and @rrhMutate@ is a no-op. Used by the
-- W3 test-site stubs (LoopSpec 8 @newChannelDeps@ calls, SendSpec 1
-- @SendDeps@ literal, ApiSpec 4 @SendDeps@ literals) so they don't need a
-- real @repos.toml@. The clone seam's @lookupRepoByUrl@ against an empty
-- registry falls through to the bare-URL clone path (public repos).
fakeRepoRegistryHandle :: RepoRegistryHandle
fakeRepoRegistryHandle = RepoRegistryHandle
  { rrhList   = pure (Right [])
  , rrhMutate = \_ -> pure (Right ())
  }

-- | 'IO'-wrapped 'fakeRepoRegistryHandle' for callers that want an action.
mkFakeRepoRegistryHandle :: IO RepoRegistryHandle
mkFakeRepoRegistryHandle = pure fakeRepoRegistryHandle