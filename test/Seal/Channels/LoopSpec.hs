{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Loop.channelCallDispatcher' — the inbox-channel
-- analogue of 'Seal.Gateway.Send.webCallDispatcher'. The dispatcher is
-- constructed inside 'runChannelLoop' at Loop.hs:243 and closes over a
-- per-loop 'IORef SessionId' (the existing 'bgConvSid' cell) plus the
-- 'AskReplyStore' param. These tests exercise the dispatcher's contract
-- directly: dispatch an opcode against the session's transcript + ISA
-- registry and return the structured result.
module Seal.Channels.LoopSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.FilePath ((</>))
import Network.HTTP.Client (newManager, defaultManagerSettings)
import Options.Applicative qualified as Opt
import Test.Hspec

import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Channels.Loop
  ( channelCallDispatcher, newChannelDeps, ChannelDeps (..)
  , shouldAutoTab, isBgSlash, createConversationSession, createConversationSessionHeadless
  , mkBgRunner, buildChannelRegistry )
import Seal.Command.Background (BgRunner (..))
import Seal.Command.Call (CallDispatcher)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Spec
  ( CommandAction (..), CommandName (..), CommandSpec (..), Registry
  , Availability (..), CommandGroup (..)
  , lookupSpec, mkRegistry, registrySpecs, runCommandAction )
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.Types (OpName (..), mkSessionId, mkSystemSessionId)
import Seal.Config.File (defaultRuntimeConfig)
import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Gateway.StreamBroker
  ( BrokerEvent (..), newStreamBroker, subscribe )
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner (..))
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Handles.Transcript (withTwoFileTranscript, TwoFileHandle (..))
import Seal.ISA.Opcode (OpResult (..))
import Seal.Logging.Logger (testSealLogger)
import Seal.ISA.Dispatch (DispatchError (..))
import Seal.Providers.Class (ContentBlock (..), Message (..), ToolResultPart (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Skills.Backend (noneBackend, sbCreate)
import Seal.Skills.Types (Skill (..), mkSkillId)
import Seal.Tabs (newTabsHandle, insertTabH, snapshotTabs, ensureTabForSession)
import Seal.Tabs.Types (TabRef (BoundSession), Tab (tRef), tlTabs)
import Seal.Handles.Tab (TabKind (KindAi))
import Seal.TestHelpers.FakeCaps (makeFakeCaps, getSent)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Channels.Cursor (cursorLookup)

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

-- | A minimal no-op CommandSpec with the given name, used to populate a base
-- registry in the buildChannelRegistry tests. Its parser parses no args and
-- its action does nothing — only the name (used by the collision filter)
-- matters.
stubSpec :: Text -> CommandSpec
stubSpec name = CommandSpec
  { csName         = CommandName name
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "stub"
  , csParserInfo   = Opt.info (pure (CommandAction (\_ -> pure ())))
                          (Opt.progDesc "stub")
  , csAvailability = AlwaysAvailable
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
    tabsH <- newTabsHandle
    logger <- testSealLogger
    deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                    harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
    askReply <- newAskReplyStore 0
    let sid = either (error "sid") id (mkSessionId "loop-test")
    sidRef <- newIORef sid
    let dispatcher = channelCallDispatcher deps stubHandle askReply sidRef
    res <- dispatcher (OpName "BOGUS_OP") (object [])
    case res of
      Left (OpNotFound (OpName n)) -> n `shouldBe` "BOGUS_OP"
      _ -> expectationFailure ("expected Left (OpNotFound ...), got: " <> show res)

  it "SKILL_LOAD writes the skill body to conversation.jsonl (the Telegram/Signal path)" $ do
    -- Regression: /skill load displays the "Command output" box but the skill
    -- body never reaches the model's context on inbox channels (Telegram,
    -- Signal). The channelCallDispatcher calls dispatch (which records an
    -- EKHarness entry to entries.jsonl) then recordSkillLoadResult (which
    -- must write the skill body to conversation.jsonl so runTurn's prior-read
    -- picks it up on the next turn). This test exercises the REAL dispatcher
    -- wiring — same as the Telegram path under seal serve / seal telegram.
    let cfgRoot = "/tmp/seal-channelCallDispatcher-skillload-test"
    ensureConfigRepo cfgRoot
    let repo = openConfigRepo cfgRoot
    backends <- newBackends cfgRoot repo
    -- Preload a skill into the backend.
    let skillId = case mkSkillId "greet" of
          Right i  -> i
          Left _   -> error "invalid skill id"
        aTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)
        skill = Skill
          { skId = skillId
          , skDescription = "greeting skill"
          , skBody = "say hi warmly"
          , skGroup = Nothing
          , skCreatedAt = aTime
          , skUpdatedAt = aTime
          , skSession = mkSystemSessionId "s1"
          }
    sbCreate (bSkills backends) skill
    harnessReg <- newHarnessRegistry
    let paths = SealPaths
          { spHome = cfgRoot, spState = cfgRoot </> "state"
          , spConfig = cfgRoot, spKeys = cfgRoot </> "keys"
          , spCache = cfgRoot </> "cache"
          }
        vaultRt = VaultRuntime
          { vrPaths = paths, vrConfigPath = cfgRoot </> "config.toml"
          , vrHandleRef = error "vrHandleRef: stubbed — SKILL_LOAD test does not read the vault"
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
    tabsH <- newTabsHandle
    logger <- testSealLogger
    deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                    harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
    askReply <- newAskReplyStore 0
    let sid = either (error "sid") id (mkSessionId "skillload-test")
    sidRef <- newIORef sid
    let dispatcher = channelCallDispatcher deps stubHandle askReply sidRef
    res <- dispatcher (OpName "SKILL_LOAD") (object ["id" .= ("greet" :: Text)])
    case res of
      Left e -> expectationFailure ("expected Right, got Left: " <> show e)
      Right _r -> do
        -- The dispatcher succeeded. Now verify the skill body landed in
        -- conversation.jsonl by opening the session's transcript and reading
        -- back the conversation.
        let sessionDirPath = sessionDir paths sid
        withTwoFileTranscript sessionDirPath $ \h -> do
          conv <- tfwReadConversation h
          let bodies = [ t | Message _ cs <- conv, CbText t <- cs ]
          T.unlines bodies `shouldSatisfy` ("say hi warmly" `T.isInfixOf`)

  describe "buildChannelRegistry" $ do
    -- Regression guard for the /skill load shadowing bug. Under @seal serve@,
    -- the web gateway's registry is passed to runChannelLoop, and it contains
    -- a skillCommandSpec + callCommandSpec bound to webCallDispatcher (which
    -- reads the process-global srActive ref). Without filtering those out
    -- before appending the channel-dispatcher versions, lookupSpec returns
    -- the FIRST match — the web spec — so a /skill load issued from Telegram
    -- records the SKILL_LOAD entry on whatever srActive points at, NOT the
    -- Telegram conversation's session. buildChannelRegistry must drop the
    -- incoming skill/call/bg specs so the channel-dispatcher versions win.
    --
    -- We can't observe which CallDispatcher a resolved spec closes over
    -- directly, so the test uses recording dispatchers: the "web" dispatcher
    -- records "web", the "channel" dispatcher records "channel". After running
    -- /skill load through the assembled registry's spec, the recorded value
    -- must be "channel".
    it "channel skill spec shadows a same-named web spec in the base registry" $ do
      webCalls <- newIORef ([] :: [Text])
      chanCalls <- newIORef ([] :: [Text])
      let webDispatcher :: CallDispatcher
          webDispatcher _opName _val = do
            modifyIORef' webCalls ("web" :)
            pure (Right (OpResult [TrpText "web"] False (object [])))
          chanDispatcher :: CallDispatcher
          chanDispatcher _opName _val = do
            modifyIORef' chanCalls ("channel" :)
            pure (Right (OpResult [TrpText "channel"] False (object [])))
          bgRunner = BgRunner (\_prompt -> pure ())
      skillBackend <- noneBackend
      let baseRegistry :: Registry
          baseRegistry = mkRegistry
            [ skillCommandSpec skillBackend webDispatcher
            , stubSpec "ping"
            ]
          channelReg = buildChannelRegistry skillBackend bgRunner chanDispatcher baseRegistry
      -- The channel registry must have exactly one "skill" spec (the channel
      -- one), not two.
      let skillSpecs = [ s | s <- registrySpecs channelReg, csName s == CommandName "skill" ]
      length skillSpecs `shouldBe` 1
      -- And it must resolve to the CHANNEL dispatcher. Run /skill load greet
      -- through the resolved spec and check the recording IORef.
      case lookupSpec channelReg (CommandName "skill") of
        Nothing -> expectationFailure "expected a skill spec in the channel registry"
        Just skillSpec -> do
          (fc, caps) <- makeFakeCaps []
          case Opt.execParserPure Opt.defaultPrefs (csParserInfo skillSpec) ["load", "greet"] of
            Opt.Success act -> do
              runCommandAction act caps
              _ <- getSent fc  -- drain (echo line); not asserted
              chan <- readIORef chanCalls
              web <- readIORef webCalls
              chan `shouldBe` ["channel"]
              web `shouldBe` []
            _ -> expectationFailure "parse failed for /skill load greet"

    it "preserves non-colliding specs from the base registry" $ do
      let chanDispatcher :: CallDispatcher
          chanDispatcher _opName _val = pure (Right (OpResult [] False (object [])))
          bgRunner = BgRunner (\_prompt -> pure ())
      skillBackend <- noneBackend
      let baseRegistry = mkRegistry [ stubSpec "ping", stubSpec "vault" ]
          channelReg = buildChannelRegistry skillBackend bgRunner chanDispatcher baseRegistry
          names = [ n | CommandName n <- map csName (registrySpecs channelReg) ]
      -- ping + vault preserved, plus bg + call + skill appended.
      "ping" `elem` names `shouldBe` True
      "vault" `elem` names `shouldBe` True
      "bg" `elem` names `shouldBe` True
      "call" `elem` names `shouldBe` True
      "skill" `elem` names `shouldBe` True

  it "newChannelDeps sets cdTabs to the passed TabsHandle (unified)" $ do
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
          , vrHandleRef = error "vrHandleRef: stubbed — cdTabs test does not read the vault"
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
    tabsH <- newTabsHandle
    logger <- testSealLogger
    deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                    harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
    -- A tab inserted via the passed handle is visible through cdTabs —
    -- proving cdTabs IS the passed handle (unified, not a forked copy).
    -- (TabsHandle has no Eq instance, so we verify unification by behavior.)
    let sid = either (error "sid") id (mkSessionId "cdtabs-test")
    _ <- insertTabH tabsH (BoundSession sid) KindAi Nothing
    snap <- snapshotTabs (cdTabs deps)
    length (tlTabs snap) `shouldBe` 1

  it "ensureTabForSession is reachable via cdTabs (W3 channel auto-tab wiring)" $ do
    -- The channel plainTurn path calls `ensureTabForSession (cdTabs deps)
    -- KindAi sid` after a turn (Loop.hs). This test verifies the function is
    -- reachable from a ChannelDeps context and inserts a KindAi tab via the
    -- unified handle — the same call the production channel path makes.
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
          , vrHandleRef = error "vrHandleRef: stubbed — W3 test does not read the vault"
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
    tabsH <- newTabsHandle
    logger <- testSealLogger
    deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                    harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
    let sid = either (error "sid") id (mkSessionId "w3-autotab")
    -- Simulate the channel auto-tab call (production code: Loop.hs runTurnOnSession)
    ensureTabForSession (cdTabs deps) KindAi sid
    snap <- snapshotTabs (cdTabs deps)
    case tlTabs snap of
      [t] -> tRef t `shouldBe` BoundSession sid
      _   -> expectationFailure ("expected exactly one auto-tab, got " <> show (tlTabs snap))

  describe "shouldAutoTab" $ do
    -- Regression guard for the /bg tab-leak bug. A /bg turn runs on a fresh
    -- headless session (smChannel = "bg", set at Loop.hs:645 and Cli.hs:551)
    -- and must NOT auto-tab into the web sidebar: the tab would be bound to
    -- the bg session's sid while the reply/ask-key is wired to the
    -- originating conversation's sid, producing a dead-looking tab that
    -- strands the session in Recent Sessions when closed.
    let mkMeta channel = SessionMeta
          { smId = either (error "sid") id (mkSessionId "autotab-test")
          , smProvider = "ollama"
          , smModel = "llama3.2"
          , smChannel = channel
          , smAgent = Nothing
          , smSystemOverride = Nothing
          , smAgentName = Nothing
          , smDescription = Nothing
          , smCreatedAt = error "unused"
          , smLastActive = error "unused"
          }

    it "is False for a /bg session (smChannel = \"bg\")" $
      shouldAutoTab (mkMeta "bg") `shouldBe` False

    it "is True for a Telegram channel session" $
      shouldAutoTab (mkMeta "telegram") `shouldBe` True

    it "is True for a Signal channel session" $
      shouldAutoTab (mkMeta "signal") `shouldBe` True

    it "is True for a CLI session" $
      shouldAutoTab (mkMeta "cli") `shouldBe` True

    it "is True for a Web session" $
      shouldAutoTab (mkMeta "web") `shouldBe` True

    -- Defense against a future collision: the Background channel kind maps
    -- to "background", NOT "bg", so a real channel turn never trips the
    -- guard. If someone changes channelKindToText to emit "bg", this test
    -- fails and flags the collision.
    it "does not collide with the Background channel kind (\"background\")" $
      shouldAutoTab (mkMeta "background") `shouldBe` True

  describe "isBgSlash" $ do
    -- The loop uses isBgSlash to pick the headless session-creation path,
    -- so a /bg from a fresh conversation does NOT mint a spurious empty tab
    -- for the conversation (the bg turn runs on a separate fresh bg session;
    -- the conversation session is only an ask-key anchor).
    it "matches /bg with no prompt" $
      isBgSlash "/bg" `shouldBe` True

    it "matches /bg with a prompt" $
      isBgSlash "/bg tell me a joke" `shouldBe` True

    it "matches /bg with a quoted prompt" $
      isBgSlash "/bg \"hello world\"" `shouldBe` True

    it "is case-insensitive (/BG)" $
      isBgSlash "/BG hello" `shouldBe` True

    it "does not match /bgx (longer command name)" $
      isBgSlash "/bgx" `shouldBe` False

    it "does not match plain text" $
      isBgSlash "hello" `shouldBe` False

    it "does not match /new (a different slash command)" $
      isBgSlash "/new" `shouldBe` False

    it "does not match the tab grammar /1" $
      isBgSlash "/1" `shouldBe` False

  describe "createConversationSessionHeadless" $ do
    -- Regression guard for the spurious-empty-tab bug. A /bg from a fresh
    -- conversation must anchor a conversation session (so the bg runner has
    -- a sid to key its confirmation ask to) but must NOT insert a tab or
    -- broadcast to the sidebar — no turn ever runs on this session, so a
    -- tab would surface as an empty conversation in the web frontend.
    it "persists the session and sets the cursor but inserts NO tab" $ do
      let cfgRoot = "/tmp/seal-createConversationSessionHeadless-test"
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
            , vrHandleRef = error "vrHandleRef: stubbed — headless test does not read the vault"
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
      tabsH <- newTabsHandle
      logger <- testSealLogger
      deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                        harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
      let key = ("telegram", "conv-headless-test")
      meta <- createConversationSessionHeadless deps key Telegram
      -- The conversation session is persisted (cursor can resolve it).
      mCursor <- cursorLookup (cdCursors deps) key
      mCursor `shouldBe` Just (BoundSession (smId meta))
      -- NO tab was inserted into the shared TabsHandle — the web sidebar
      -- never sees this session.
      snap <- snapshotTabs (cdTabs deps)
      tlTabs snap `shouldBe` []

  describe "createConversationSession cursor-binding" $ do
    -- Regression guard for the latent full-tab-list bug. Previously
    -- cursorSet lived inside the Right _ branch of insertTabH's case, so a
    -- full tab list (Left _) silently skipped cursor-binding: the session
    -- was minted and persisted but no cursor pointed at it, so the loop's
    -- next-turn lookup (Loop.hs:278) returned Nothing and minted a
    -- brand-new session — orphaning this one and repeating every turn.
    -- Now cursorSet runs unconditionally; this test fills the tab list to
    -- its 36-slot cap, calls createConversationSession, and asserts the
    -- cursor is bound even though the tab insertion fails.
    it "binds the cursor even when the tab list is full (Left _)" $ do
      let cfgRoot = "/tmp/seal-createConversationSession-full-test"
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
            , vrHandleRef = error "vrHandleRef: stubbed — full-list test does not read the vault"
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
      tabsH <- newTabsHandle
      -- Fill the tab list to the 36-slot cap with distinct sids.
      mapM_ (\i -> do
          let sid = either (error "sid") id (mkSessionId ("filler-" <> T.pack (show i)))
          _ <- insertTabH tabsH (BoundSession sid) KindAi Nothing
          pure ())
        [1 :: Int .. 36]
      fullSnap <- snapshotTabs tabsH
      length (tlTabs fullSnap) `shouldBe` 36
      logger <- testSealLogger
      deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                        harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
      let key = ("telegram", "conv-full-tabs-test")
      meta <- createConversationSession deps stubHandle key Telegram tabsH
      -- The tab insertion fails (list full) but the cursor MUST still bind
      -- to the newly-minted session, so the next turn resolves to it.
      mCursor <- cursorLookup (cdCursors deps) key
      mCursor `shouldBe` Just (BoundSession (smId meta))
      -- The tab list is unchanged — no 37th tab was added.
      snap' <- snapshotTabs (cdTabs deps)
      length (tlTabs snap') `shouldBe` 36

  describe "mkBgRunner lists broadcast" $ do
    -- Regression guard for the missing-push bug. A /bg session is persisted
    -- to disk and surfaces in the web frontend's recentSessions — but only
    -- if the frontend receives a `lists` WS frame. Without a broadcast the
    -- frontend doesn't learn about the new session until a hard refresh.
    -- mkBgRunner must broadcast a lists snapshot right after persisting the
    -- bg session so the frontend's useListsStream picks it up immediately.
    it "broadcasts a lists snapshot when a bg session is minted (broker present)" $ do
      let cfgRoot = "/tmp/seal-mkBgRunner-broadcast-test"
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
            , vrHandleRef = error "vrHandleRef: stubbed — bg broadcast test does not read the vault"
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
      tabsH <- newTabsHandle
      broker <- newStreamBroker 10
      eventsRef <- newIORef ([] :: [BrokerEvent])
      _ <- subscribe broker (either (error "sid") id (mkSessionId "any")) (\e -> modifyIORef' eventsRef (e :))
      logger <- testSealLogger
      deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised (Just broker)
                        harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
      bgConvSid <- newIORef (either (error "sid") id (mkSessionId "conv-anchor"))
      askReply <- newAskReplyStore 0
      let runner = mkBgRunner deps stubHandle askReply bgConvSid tabsH
      runBg runner "hello bg"
      events <- readIORef eventsRef
      -- A BeListsSnapshot was delivered — the frontend's useListsStream
      -- would pick up the new bg session in recentSessions from this frame.
      any isListsSnapshot events `shouldBe` True

    it "does not broadcast when the broker is absent (standalone channel)" $ do
      -- A standalone Telegram/Signal run (no `seal serve`) has cdBroker =
      -- Nothing. mkBgRunner must be a no-op for the broadcast (it must not
      -- crash trying to reach a nonexistent broker).
      let cfgRoot = "/tmp/seal-mkBgRunner-nobroker-test"
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
            , vrHandleRef = error "vrHandleRef: stubbed — no-broker test does not read the vault"
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
      tabsH <- newTabsHandle
      logger <- testSealLogger
      deps <- newChannelDeps paths vaultRt fakeRepoRegistryHandle pr backends Supervised Nothing
                        harnessReg stubTmux (Just mgr) approvals (pure defaultRuntimeConfig) False tabsH logger
      bgConvSid <- newIORef (either (error "sid") id (mkSessionId "conv-anchor"))
      askReply <- newAskReplyStore 0
      let runner = mkBgRunner deps stubHandle askReply bgConvSid tabsH
      -- Should not throw.
      runBg runner "hello bg"

-- | Match only 'BeListsSnapshot' broker events (the @lists@ WS frame).
isListsSnapshot :: BrokerEvent -> Bool
isListsSnapshot (BeListsSnapshot _) = True
isListsSnapshot _ = False