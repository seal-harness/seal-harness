{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Loop.channelCallDispatcher' — the inbox-channel
-- analogue of 'Seal.Gateway.Send.webCallDispatcher'. The dispatcher is
-- constructed inside 'runChannelLoop' at Loop.hs:243 and closes over a
-- per-loop 'IORef SessionId' (the existing 'bgConvSid' cell) plus the
-- 'AskReplyStore' param. These tests exercise the dispatcher's contract
-- directly: dispatch an opcode against the session's transcript + ISA
-- registry and return the structured result.
module Seal.Channels.LoopSpec (spec) where

import Data.Aeson (object)
import Data.IORef (newIORef)
import System.FilePath ((</>))
import Network.HTTP.Client (newManager, defaultManagerSettings)
import Test.Hspec

import Seal.Channel.Cli (newBackends)
import Seal.Channels.Loop (channelCallDispatcher, newChannelDeps)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Core.Types (OpName (..), mkSessionId)
import Seal.Config.File (defaultRuntimeConfig)
import Seal.Config.Paths (SealPaths (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner (..))
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.ISA.Dispatch (DispatchError (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Vault.Commands (VaultRuntime (..))

-- | A stub TmuxRunner that always succeeds with empty output.
stubTmux :: TmuxRunner
stubTmux = TmuxRunner (\_args -> pure (Right ""))

-- | A stub ChannelHandle for the dispatcher test. 'channelCallDispatcher'
-- uses the handle only via 'mkHandleCaps' to build ChannelCaps (ccSend,
-- ccPrompt, ccPromptSecret) for opcodes that need them (ASK_HUMAN,
-- SHOW_HUMAN). The dispatch path under test (an unknown opcode) doesn't
-- invoke those, so a handle with stub sends is safe.
stubHandle :: ChannelHandle
stubHandle = ChannelHandle
  { chSend         = \_ -> pure ()
  , chSendError    = \_ -> pure ()
  , chSendChunk    = \_ -> pure ()
  , chPrompt       = \_ -> pure (Left Deferred)
  , chPromptSecret = \_ -> pure (Left Deferred)
  , chStreaming    = False
  , chReadSecret   = pure Nothing
  , chReceive      = pure (Nothing, "")
  }

spec :: Spec
spec = describe "Seal.Channels.Loop.channelCallDispatcher" $ do
  it "returns Left (OpNotFound ...) for an unknown opcode" $ do
    -- This test verifies channelCallDispatcher is exported with the right
    -- type signature and dispatches against the ISA registry built by
    -- buildIsaRegistry. The full /skill load happy path (SKILL_LOAD with
    -- a real skill body) is exercised by Seal.Command.SkillSpec against a
    -- mock CallDispatcher; this test covers the real dispatcher wiring
    -- (sid IORef read, transcript open, registry build, dispatch call).
    let cfgRoot = "/tmp/seal-channelCallDispatcher-test"
    ensureConfigRepo cfgRoot
    let repo = openConfigRepo cfgRoot
    backends <- newBackends cfgRoot repo
    harnessReg <- newHarnessRegistry
    let paths = SealPaths
          { spHome = cfgRoot, spState = cfgRoot </> "state"
          , spConfig = cfgRoot, spKeys = cfgRoot </> "keys"
          , spCache = cfgRoot </> "cache"
          }
        vaultRt = VaultRuntime
          { vrPaths = paths, vrConfigPath = cfgRoot </> "config.toml"
          , vrHandleRef = error "vrHandleRef: stubbed — channelCallDispatcher test does not read the vault"
          }
    mgr <- newManager defaultManagerSettings
    cntRef <- newIORef (0 :: Int)
    let pr = ProviderRuntime
          { prConfigPath = cfgRoot </> "config.toml"
          , prVault = vaultRt
          , prManager = mgr
          , prCallCounter = cntRef
          }
    approvals <- newApprovalCache
    deps <- newChannelDeps paths vaultRt pr backends Supervised Nothing
                    harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig)
    askReply <- newAskReplyStore 0
    let sid = either (error "sid") id (mkSessionId "loop-test")
    sidRef <- newIORef sid
    let dispatcher = channelCallDispatcher deps stubHandle askReply sidRef
    res <- dispatcher (OpName "BOGUS_OP") (object [])
    case res of
      Left (OpNotFound (OpName n)) -> n `shouldBe` "BOGUS_OP"
      _ -> expectationFailure ("expected Left (OpNotFound ...), got: " <> show res)