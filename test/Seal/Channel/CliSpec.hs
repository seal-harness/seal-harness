{-# LANGUAGE OverloadedStrings #-}
module Seal.Channel.CliSpec (spec) where

import Data.Either (fromRight)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Client (defaultManagerSettings, newManager)

import Test.Hspec

import Seal.Agent.Env (AgentEnv (..))
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli (interpretDisposition, mkSessionAgentEnv, resolveSessionProvider)
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..))
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Handles.AskReply (newApprovalCache)
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.Ingest (Disposition (..))
import Seal.Security.Policy (AutonomyLevel (..))
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class (Provider (..), SomeProvider (..))
import Seal.Security.Vault (VaultHandle)
import Seal.Session.Meta (SessionMeta (..))
import Seal.TestHelpers.FakeCaps (makeFakeCaps)
import Seal.Vault.Commands (VaultRuntime (..))

-- | A minimal in-process provider for testing 'mkSessionAgentEnv'.
data StubProvider = StubProvider
instance Provider StubProvider where
  complete _ _   = pure (Left "stub")
  listModels _   = pure (Right [])

-- | Build a 'SessionMeta' with the given provider label and model id.
metaWith :: T.Text -> T.Text -> SessionMeta
metaWith p m =
  let sid = fromRight (error "unreachable: literal session id")
              (mkSessionId "20260701-120000-002")
      t   = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)
  in SessionMeta sid p m "cli" Nothing Nothing Nothing t t

-- | A 'ChannelCaps' that records every 'ccSend' call into @ref@ (prepended;
-- reverse for chronological order).  Prompt functions return the empty string.
recordingCaps :: IORef [Text] -> ChannelCaps
recordingCaps ref = ChannelCaps
  { ccSend         = \t -> modifyIORef' ref (t :)
  , ccPrompt       = \_ -> pure ""
  , ccPromptSecret = \_ -> pure ""
  }

-- | A plain-text handler that never fires; used by the non-'PlainMessage' cases.
ignoredHandler :: Text -> IO ()
ignoredHandler _ = pure ()

spec :: Spec
spec = do
  describe "interpretDisposition" $ do
    it "ShowText routes the text to ccSend" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) ignoredHandler (ShowText "hello world")
      sent <- readIORef ref
      sent `shouldBe` ["hello world"]

    it "PlainMessage routes the text to the injected handler" $ do
      capRef <- newIORef []
      seen   <- newIORef []
      let handler t = modifyIORef' seen (t :)
      interpretDisposition (recordingCaps capRef) handler (PlainMessage "ignored text")
      received <- readIORef seen
      sent     <- readIORef capRef
      received `shouldBe` ["ignored text"]
      sent `shouldBe` []   -- handler owns the message; ccSend is not touched

    it "Rejected emits the rejection message" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) ignoredHandler (Rejected "input blocked")
      sent <- readIORef ref
      sent `shouldBe` ["input blocked"]

    it "DispatchAction runs the action through caps" $ do
      ref <- newIORef []
      let caps   = recordingCaps ref
          action = CommandAction $ \c -> ccSend c "from action"
      interpretDisposition caps ignoredHandler (DispatchAction action)
      sent <- readIORef ref
      sent `shouldBe` ["from action"]

  describe "resolveSessionProvider" $ do
    it "reports when the vault is not configured" $ do
      ref <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      cntRef <- newIORef 0
      let pr = ProviderRuntime
                 { prConfigPath = "/nonexistent/config.toml"
                 , prVault = VaultRuntime
                     { vrPaths = SealPaths "/x" "/x" "/x" "/x" "/x"
                     , vrConfigPath = "/x/config.toml", vrHandleRef = ref }
                 , prManager = mgr
                 , prCallCounter = cntRef }
      r <- resolveSessionProvider pr (metaWith "anthropic" "claude-opus-4-8")
      case r of
        Left e  -> e `shouldSatisfy` ("vault not configured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "reports an unknown provider label in the session" $ do
      ref <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      cntRef <- newIORef 0
      let pr = ProviderRuntime
                 { prConfigPath = "/x/config.toml"
                 , prVault = VaultRuntime
                     { vrPaths = SealPaths "/x" "/x" "/x" "/x" "/x"
                     , vrConfigPath = "/x/config.toml", vrHandleRef = ref }
                 , prManager = mgr
                 , prCallCounter = cntRef }
      r <- resolveSessionProvider pr (metaWith "bogus" "m")
      case r of
        Left e  -> e `shouldSatisfy` ("unknown provider" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "mkSessionAgentEnv" $
    it "carries the session's model and id into the AgentEnv" $ do
      approvals <- newApprovalCache
      (_, caps) <- makeFakeCaps []
      (th, _)   <- fakeTwoFileTranscript
      let sid = fromRight (error "unreachable: literal session id")
                  (mkSessionId "20260701-120000-002")
          env = mkSessionAgentEnv caps (SomeProvider StubProvider) "anthropic"
                  (ModelId "claude-haiku-4-5") sid Nothing (ISA.mkRegistry []) th mkRemoteUntrustedIOStub
                  Nothing Full approvals (pure ()) False
      aeModel env   `shouldBe` ModelId "claude-haiku-4-5"
      aeSession env `shouldBe` sid
      aeDebugRequestsPath env `shouldBe` Nothing
      -- The untrusted-execution capability is threaded into the env.
      aeUntrustedIO env `seq` pure ()  -- type-level check: the field exists

  describe "seal tui smoke (interactive — manual)" $
    it "seal tui launches and shows the > prompt" $
      pendingWith
        "interactive: run `nix develop --command cabal run seal -- tui` \
        \and verify the '> ' prompt appears; Ctrl-D exits cleanly"
