{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.CursorSpec (spec) where

import Control.Concurrent.Async (replicateConcurrently_)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative qualified as Opt
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Channels.Cursor
import Seal.Channels.Cursor.Persist (loadCursorMap, saveCursorMap)
import Seal.Channels.Loop
  (ChannelDeps (..), createConversationSession, newChannelDeps)
import Seal.Command.Model (modelCommandSpecForSession, noModelTranscriptWriter)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.File (defaultRuntimeConfig)
import Seal.Config.Paths (SealPaths (..), cursorMapPath)
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.TurnEngine (loadSessionMeta)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner (..))
import Seal.Handles.AskReply (newApprovalCache)
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Logging.Logger (testSealLogger)
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tabs (newTabsHandle)
import Seal.Tabs.Types (TabRef (BoundSession))
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.Vault.Commands (VaultRuntime (..))

mkSid :: String -> SessionId
mkSid s = case mkSessionId (T.pack s) of
  Right x -> x
  Left _  -> error ("bad sid: " <> s)

-- | A stub ChannelHandle (the cursor tests don't drive turns, but
-- createConversationSession sends a confirmation via chSend).
stubHandle :: ChannelHandle
stubHandle = ChannelHandle
  { chLabel       = "test"
  , chSend         = \_ -> pure ()
  , chSendError    = \_ -> pure ()
  , chSendChunk    = \_ -> pure ()
  , chPrompt       = \_ -> pure (Left Deferred)
  , chPromptSecret = \_ -> pure (Left Deferred)
  , chStreaming    = False
  , chReadSecret   = pure Nothing
  , chReceive      = pure (Nothing, "")
  , chLastChatId   = pure Nothing
  }

stubTmux :: TmuxRunner
stubTmux = TmuxRunner (\_args -> pure (Right ""))

-- | Build a minimal ChannelDeps against a temp state dir, with a persisting
-- cursor store rooted at @paths@. Mirrors the LoopSpec setup but threads a
-- 'newPersistingCursorStore' (the new parameter on 'newChannelDeps').
mkDeps
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> Backends
  -> IO ChannelDeps
mkDeps paths vaultRt pr backends = do
  harnessReg <- newHarnessRegistry
  mgr <- newManager defaultManagerSettings
  approvals <- newApprovalCache
  tabsH <- newTabsHandle
  logger <- testSealLogger
  cursors <- newPersistingCursorStore (cursorMapPath paths)
  newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends
    Supervised Nothing harnessReg stubTmux (Just mgr) approvals
    (pure defaultRuntimeConfig) False tabsH logger cursors

mkPaths :: FilePath -> SealPaths
mkPaths root = SealPaths
  { spHome = root, spState = root </> "state"
  , spConfig = root, spKeys = root </> "keys"
  , spCache = root </> "cache"
  }

spec :: Spec
spec = describe "Seal.Channels.Cursor (persistence)" $ do

  describe "saveCursorMap/loadCursorMap round-trip" $ do
    it "save then load returns the map" $
      withSystemTempDirectory "seal-cursor" $ \dir -> do
        let path = dir </> "cursors.json"
            m = Map.fromList
              [ (("telegram","123"), BoundSession (mkSid "20260825-100000-001"))
              , (("signal","+15551234567"), BoundSession (mkSid "20260825-100000-002"))
              ]
        saveCursorMap path m
        loaded <- loadCursorMap path
        loaded `shouldBe` Just m

    it "missing file -> Nothing" $
      withSystemTempDirectory "seal-cursor" $ \dir -> do
        loaded <- loadCursorMap (dir </> "nope.json")
        loaded `shouldBe` Nothing

    it "corrupt JSON -> Nothing (does not throw)" $
      withSystemTempDirectory "seal-cursor" $ \dir -> do
        let path = dir </> "cursors.json"
        writeFile path "not valid json {{{"
        loaded <- loadCursorMap path
        loaded `shouldBe` Nothing

  describe "persisting cursor store (auto-save on mutation)" $ do
    it "cursorSet triggers a save (loadCursorMap returns the entry)" $
      withSystemTempDirectory "seal-cursor" $ \dir -> do
        let paths = mkPaths dir
        store <- newPersistingCursorStore (cursorMapPath paths)
        cursorSet store ("telegram","123") (BoundSession (mkSid "20260825-100000-003"))
        loaded <- loadCursorMap (cursorMapPath paths)
        loaded `shouldBe` Just (Map.singleton ("telegram","123") (BoundSession (mkSid "20260825-100000-003")))

    it "a second cursorSet is persisted alongside the first" $
      withSystemTempDirectory "seal-cursor" $ \dir -> do
        let paths = mkPaths dir
        store <- newPersistingCursorStore (cursorMapPath paths)
        cursorSet store ("telegram","111") (BoundSession (mkSid "20260825-100000-004"))
        cursorSet store ("telegram","222") (BoundSession (mkSid "20260825-100000-005"))
        loaded <- loadCursorMap (cursorMapPath paths)
        loaded `shouldSatisfy` \case
          Just m -> Map.size m == 2
          Nothing -> False

    it "non-persisting store (newCursorStore) writes NO file" $
      withSystemTempDirectory "seal-cursor" $ \dir -> do
        let paths = mkPaths dir
        store <- newCursorStore
        cursorSet store ("telegram","123") (BoundSession (mkSid "20260825-100000-006"))
        exists <- doesFileExist (cursorMapPath paths)
        exists `shouldBe` False

  describe "restart recovery (the core bug fix)" $ do
    it "a fresh persisting store loads the prior process's cursors" $
      withSystemTempDirectory "seal-cursor-restart" $ \dir -> do
        let paths = mkPaths dir
        -- Process 1: bind a cursor.
        store1 <- newPersistingCursorStore (cursorMapPath paths)
        cursorSet store1 ("telegram","999") (BoundSession (mkSid "20260825-100000-007"))
        -- Simulate restart: drop store1, build a fresh store at the same path,
        -- load + seed.
        store2 <- newPersistingCursorStore (cursorMapPath paths)
        mLoaded <- loadCursorMap (cursorMapPath paths)
        case mLoaded of
          Nothing -> expectationFailure "cursors.json not loaded — restart lost the binding"
          Just m -> do
            seedCursorStore store2 m
            cursorLookup store2 ("telegram","999")
              `shouldReturn` Just (BoundSession (mkSid "20260825-100000-007"))

    it "cursorMigrateAll persists the migration (survives restart)" $
      withSystemTempDirectory "seal-cursor-migrate" $ \dir -> do
        let paths = mkPaths dir
        store <- newPersistingCursorStore (cursorMapPath paths)
        let oldRef = BoundSession (mkSid "20260825-100000-008")
            newRef = BoundSession (mkSid "20260825-100000-009")
        cursorSet store ("telegram","abc") oldRef
        _count <- cursorMigrateAll store oldRef newRef
        -- Fresh store loads the migrated state.
        mLoaded <- loadCursorMap (cursorMapPath paths)
        mLoaded `shouldBe` Just (Map.singleton ("telegram","abc") newRef)

    it "cursorClearAll persists (cleared entries are gone after restart)" $
      withSystemTempDirectory "seal-cursor-clearall" $ \dir -> do
        let paths = mkPaths dir
        store <- newPersistingCursorStore (cursorMapPath paths)
        let ref = BoundSession (mkSid "20260825-100000-010")
        cursorSet store ("telegram","aaa") ref
        cursorSet store ("telegram","bbb") ref
        cursorClearAll store ref
        mLoaded <- loadCursorMap (cursorMapPath paths)
        mLoaded `shouldBe` Just Map.empty

  describe "id-validation on load" $ do
    it "skips an entry with an unparseable SessionId (does not error)" $
      withSystemTempDirectory "seal-cursor-valid" $ \dir -> do
        let path = dir </> "cursors.json"
        -- Hand-write a cursors.json with one valid + one invalid sid.
            goodK = ("telegram","ok") :: (Text, Text)
            goodSid = "20260825-100000-011" :: Text
            badK = ("telegram","bad") :: (Text, Text)
            badSid = ".invalid.sid" :: Text  -- rejected by isValidSessionId
        writeFile path (T.unpack (T.unlines
          [ "[ {\"key\":[\"" <> fst goodK <> "\",\"" <> snd goodK <> "\"],\"ref\":{\"tag\":\"BoundSession\",\"contents\":\"" <> goodSid <> "\"}}"
          , ", {\"key\":[\"" <> fst badK <> "\",\"" <> snd badK <> "\"],\"ref\":{\"tag\":\"BoundSession\",\"contents\":\"" <> badSid <> "\"}}"
          , "]"
          ]))
        m <- loadCursorMap path
        m `shouldSatisfy` \case
          Just mp -> Map.size mp == 1
                   && Map.member goodK mp
                   && not (Map.member badK mp)
          Nothing -> False

  describe "concurrent writes do not corrupt" $ do
    it "two threads cursorSet different keys 1000x each; final map has both" $
      withSystemTempDirectory "seal-cursor-concurrent" $ \dir -> do
        let paths = mkPaths dir
        store <- newPersistingCursorStore (cursorMapPath paths)
        let refA = BoundSession (mkSid "20260825-100000-012")
            refB = BoundSession (mkSid "20260825-100000-013")
        replicateConcurrently_ 1000 (cursorSet store ("telegram","aaa") refA)
        replicateConcurrently_ 1000 (cursorSet store ("telegram","bbb") refB)
        mLoaded <- loadCursorMap (cursorMapPath paths)
        mLoaded `shouldSatisfy` \case
          Just m -> Map.lookup ("telegram","aaa") m == Just refA
                 && Map.lookup ("telegram","bbb") m == Just refB
          Nothing -> False

  describe "end-to-end: /model use change survives a gateway restart" $ do
    -- The user's reported bug: /model use ollama qwen3.8 on a Telegram
    -- conversation, restart seal serve, /model list shows the default model
    -- (the conversation rebinds to a fresh session because the cursor was
    -- lost). This test mints a conversation session, runs /model use, then
    -- simulates a restart by building a fresh cursor store against the same
    -- state dir (re-loaded from disk) and asserts the conversation still
    -- resolves to the SAME sid whose session.json carries qwen3.8.
    it "conversation re-resolves to the same session (model preserved) after restart" $
      withSystemTempDirectory "seal-cursor-e2e" $ \dir -> do
        ensureConfigRepo dir
        let repo = openConfigRepo dir
        backends <- newBackends dir repo
        let paths = mkPaths dir
            vaultRt = VaultRuntime
              { vrPaths = paths
              , vrConfigPath = dir </> "config.toml"
              , vrHandleRef = error "vrHandleRef: stubbed — e2e does not read the vault"
              }
        mgr <- newManager defaultManagerSettings
        cntRef <- newIORef (0 :: Int)
        let pr = ProviderRuntime
              { prConfigPath = dir </> "config.toml"
              , prVault = vaultRt
              , prManager = mgr
              , prCallCounter = cntRef
              }
        -- Process 1: build deps with a persisting cursor store, create the
        -- conversation session, run /model use to set qwen3.8 on it.
        deps1 <- mkDeps paths vaultRt pr backends
        tabsH <- newTabsHandle
        let key = ("telegram","e2e-conv")
        meta1 <- createConversationSession deps1 stubHandle key Telegram tabsH
        let sid1 = smId meta1
        -- Run /model use ollama qwen3.8 against this session.
        let cmdSpec = modelCommandSpecForSession pr paths (pure sid1) noModelTranscriptWriter
        (fc, caps) <- makeFakeCaps []
        case Opt.execParserPure Opt.defaultPrefs (csParserInfo cmdSpec)
               ["use","ollama","qwen3.8"] of
          Opt.Success act -> runCommandAction act caps
          _ -> expectationFailure "/model use parse failed"
        _ <- getSent fc
        -- Confirm session.json carries qwen3.8.
        mMeta1 <- loadSessionMeta paths sid1
        smModel (fromMaybe (error "meta1 missing") mMeta1) `shouldBe` "qwen3.8"
        -- Simulate restart: build a fresh cursor store against the SAME
        -- paths, re-loaded from disk.
        cursors2 <- newPersistingCursorStore (cursorMapPath paths)
        mLoaded <- loadCursorMap (cursorMapPath paths)
        case mLoaded of
          Nothing -> expectationFailure "cursors.json not loaded after restart — the bug"
          Just m -> seedCursorStore cursors2 m
        -- The conversation's cursor must still resolve to sid1.
        cursorLookup cursors2 key `shouldReturn` Just (BoundSession sid1)
        -- And session.json for sid1 still carries qwen3.8.
        mMeta2 <- loadSessionMeta paths sid1
        smModel (fromMaybe (error "meta2 missing") mMeta2) `shouldBe` "qwen3.8"