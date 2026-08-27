{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Haskeline-backed CLI TUI channel. Plain (non-slash) input is routed through
-- the agent loop ('runTurn'); slash commands and rejections flow through the
-- existing command registry.
module Seal.Channel.Cli
  ( runCliTui
  , interpretDisposition
  , handlePlain
  , resolveSessionProvider
  , mkSessionAgentEnv
  , TurnEnv (..)
  , untrustedIOFromSecurity
  , Backends (..)
  , newBackends
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Either (fromRight)
import Data.Foldable (for_)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import System.Console.Haskeline
  ( InputT
  , Settings (..)
  , defaultSettings
  , getInputLine
  , getPassword
  , handleInterrupt
  , noCompletion
  , runInputT
  , withInterrupt
  )
import System.FilePath ((</>))

import Seal.Agent.Env (AgentEnv (..), TurnEnv (..), mkSessionAgentEnv)
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec)
import Seal.Command.Call (callCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), resolveSessionProvider)
import Seal.Command.Spec
  ( CommandAction (..), Registry, mkRegistry, registrySpecs )
import Seal.Config.File (defaultRuntimeConfig, loadRuntimeConfig)
import Seal.Config.Security (SecurityConfig, loadSecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Config.Paths (SealPaths (..), securityFilePath)
import Seal.Core.Backends (Backends (..), newBackends)
import Seal.Core.TurnEngine (TurnDeps (..), TurnAdapter (..), TurnOutcome (..), runSessionTurn)
import qualified Seal.Core.TurnEngine as TurnEngine
import Seal.Core.Types (mkSessionId)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
#if !defined(REMOTE_ONLY_UNTRUSTED)
import Seal.Tools.Exec.UntrustedIO ( mkLocalUntrustedIO, mkRemoteUntrustedIO, mkRemoteUntrustedIOStub, UntrustedIO )
#else
import Seal.Tools.Exec.UntrustedIO ( mkRemoteUntrustedIO, mkRemoteUntrustedIOStub, UntrustedIO )
#endif
import Seal.Tools.Exec.Untrusted (UntrustedExecConfig (..))
import Seal.Tools.Exec.Remote (mkRealRemoteRunner)
import Seal.Tools.Exec.Abort (SessionAbortRegistry, setSessionAbort)
import Seal.Agent.Def.Types (agentDefIdText)
import Seal.Routing.Route qualified
import Seal.Session.ExecCache (newSessionExecCache)
import Seal.Session.Lock (newReplyRegistry, newSessionLocks)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Tabs (TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs)
import Seal.Tabs.Types (TabSlashCommand (..), ForceMode (..), tabCount, tlTabs, Tab(..), TabRef (..), lookupByRef)
import Seal.Handles.AskReply
  ( AskReplyStore, deliverNextAnswerResolvedAny
  , askHumanWithOptions, formatQuestionWithOptions, newApprovalCache )
import Seal.Handles.Tab (tabIndexToChar, TabKind (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( SessionRuntime (..), defaultSessionSelection
  , newSession, resolveDefaultAgent )
import Seal.Types.App (runApp)
import Seal.Logging.Logger (SealLogger)
import Seal.Logging.Exceptions (withExceptionLogging)
import Seal.Types.Env (Env, envLogger)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Harness.Registry (HarnessRegistry)
import Seal.Harness.Tmux (TmuxRunner)

-- | Map a 'Disposition' to its channel effect.
--
-- Extracted for testability: callers supply a 'ChannelCaps' and a handler for
-- plain (agent-bound) text; no Haskeline context is required. Routing plain
-- text through an injected handler keeps this function testable without a live
-- provider.
interpretDisposition :: ChannelCaps -> (Text -> IO ()) -> Disposition -> IO ()
interpretDisposition caps plainHandler = \case
  DispatchAction a -> runCommandAction a caps
  ShowText t       -> ccSend caps t
  PlainMessage t   -> plainHandler t
  Rejected msg     -> ccSend caps msg

-- | Drive one plain-text turn through the agent loop. The seam the wiring test
-- asserts against: a 'PlainMessage' becomes @runApp env (runTurn agentEnv t)@.
-- Catches exceptions (including 'TranscriptError' from a dead writer daemon)
-- so the TUI reports the error instead of crashing.
handlePlain :: AgentEnv -> Env -> Text -> IO ()
handlePlain agentEnv env t = do
  eResult <- withExceptionLogging (envLogger env) (aeLogPath agentEnv) "plain" $
    runApp env (runTurn agentEnv t)
  case eResult of
    Left errMsg -> ccSend (aeCaps agentEnv) ("turn failed: " <> errMsg)
    Right _     -> pure ()

-- | Resolve the active session's provider from the vault, or explain why not.
-- Key bytes never surface: 'resolveProvider' returns an opaque 'SomeProvider'.
--
-- 'resolveSessionProvider' and 'resolveDefProvider' are defined in
-- 'Seal.Command.Provider' and re-exported here for backwards compatibility.

-- | A parameter object bundling the per-turn inputs to 'mkSessionAgentEnv'.
-- The 22 positional arguments are collected into one record so call sites
-- construct it with named-field syntax (no positional-counting mistakes)
-- and future additions are a one-field change. This is the W3 step-1
-- mechanical refactor: no behavior change, just argument bundling.
--
-- 'TurnEnv' and 'mkSessionAgentEnv' are defined in 'Seal.Agent.Env' (next
-- to 'AgentEnv') and re-exported here for backwards compatibility with
-- existing import sites.

-- | Run the Haskeline TUI loop.
--
-- History is persisted at @\<state\>\/history@; the agent transcript is written
-- under the session directory (@\<state\>\/sessions\/\<id\>\/transcript.jsonl@).
-- EOF (Ctrl-D) exits. The provider and model are resolved from the active
-- session on every turn so mid-session @\/model use@ changes take effect
-- immediately.
runCliTui
  :: SealPaths -> VaultRuntime -> RepoRegistryHandle -> ProviderRuntime -> SessionRuntime
  -> Registry -> PreprocessChain -> Backends -> TabsHandle -> AutonomyLevel
  -> AskReplyStore -> SealLogger -> HarnessRegistry -> TmuxRunner
  -> SessionAbortRegistry -> IO ()
runCliTui paths rt repoReg pr sr registry chain backends tabsH autonomy askReply logger harnessReg tmuxRunner abortReg = do
  approvals <- newApprovalCache
  replies <- newReplyRegistry
  locks <- newSessionLocks
  execCache <- newSessionExecCache
  active0 <- readIORef (srActive sr)
  eSecCfg <- loadSecurityConfig (securityFilePath paths)
  let isRemote = either (const False) (isJust . untrustedExecConfigFromSecurity) eSecCfg
      histFile       = spState paths </> "history"
      innerSettings  = (defaultSettings :: Settings IO) { complete = noCompletion }
      hlSettings     = innerSettings { historyFile = Just histFile }
      caps = def
        { ccSend         = putStrLn . T.unpack
       , ccShowHuman    = putStrLn . T.unpack
        , ccPrompt       = \(AskPrompt prompt opts) ->
            runInputT innerSettings $ do
              mLine <- getInputLine (T.unpack (formatQuestionWithOptions prompt opts))
              pure (maybe "" T.pack mLine)
        , ccPromptSecret = \prompt ->
            runInputT innerSettings $ do
              mPass <- getPassword (Just '*') (T.unpack prompt)
              pure (maybe "" T.pack mPass)
        }
  -- Startup diagnostic: show which provider+model the active session will use
  -- for plain-text turns (resolved from config at session creation), and the
  -- bound default agent (if any).
  let agentLine = case smAgent active0 of
        Nothing -> ""
        Just aid -> "  agent: " <> agentDefIdText aid
  ccSend caps ("session: " <> smProvider active0 <> " / " <> smModel active0 <> agentLine)
  let skillBackend     = bSkills backends
      agentDefBackend   = bAgentDefs backends
    -- The /bg runner: mint a fresh persisted session from the config
    -- defaults, build a ChannelCaps whose ccPrompt routes through askHuman
    -- (notify = print the question via ccSend, so the confirmation appears
    -- at the > prompt), and fork a turn against a bg-session-scoped ISA
    -- registry. The fork lets the CLI loop keep reading input; the loop's
    -- deliverNextAnswerAny routes the next line as the confirmation answer.
    -- The assistant reply is delivered via the bg caps' ccSend (println).
    -- No tab/cursor state is touched. The bg session's ISA registry is
    -- built per-invocation (its own sid, its own transcript bracket) —
    -- unchanged by the per-turn refactor.
      bgRunner = BgRunner $ \prompt -> do
        cfg <- fromRight defaultRuntimeConfig <$> loadRuntimeConfig (prConfigPath pr)
        (mAgent, mProv, mModel) <- resolveDefaultAgent agentDefBackend cfg
        let (cfgProv, cfgModel) = defaultSessionSelection cfg
            provider = fromMaybe cfgProv mProv
            model    = fromMaybe cfgModel mModel
        meta <- newSession paths provider model "bg" mAgent
        let bgSid = smId meta
            bgCaps = def
              { ccSend = ccSend caps
              , ccShowHuman = ccShowHuman caps
              , ccPrompt = \(AskPrompt q opts) -> do
                  outcome <- askHumanWithOptions askReply bgSid q opts
                               (\_qid -> ccSend caps (formatQuestionWithOptions q opts))
                  pure (fromRight "" outcome)
              , ccPromptSecret = ccPromptSecret caps
              }
            td = TurnDeps
              { tdPaths        = paths
              , tdVault        = rt
              , tdProvider     = pr
              , tdResolve      = resolveSessionProvider pr
              , tdRepoReg      = repoReg
              , tdAutonomy     = autonomy
              , tdBroker       = Nothing
              , tdHarnessReg   = harnessReg
              , tdTmuxRunner   = tmuxRunner
              , tdHttpManager  = Just (prManager pr)
              , tdApprovals    = approvals
              , tdReplies      = replies
              , tdLocks        = locks
              , tdAbortReg     = abortReg
              , tdTabsHandle   = tabsH
              , tdLogger       = logger
              , tdIsRemote     = isRemote
              , tdBaseBackends = backends
              , tdExecCache    = execCache
              , tdRemoteRunner = Nothing
              , tdMkWorker    = Nothing
              }
            bgAdapter = TurnAdapter
              { taCaps          = bgCaps
              , taPreTurn       = \_ _ _ -> pure ()
              , taChannelLabel  = smChannel
              , taOnStop        = const Nothing
              , taOnUserMessage = const Nothing
              , taPostTurn      = \_ _ -> pure ()
              , taStartWiring   = \sessionBackends sid appEnv' eCfg' opCeiling m ->
                  TurnEngine.buildStartWiring td sessionBackends sid appEnv' eCfg' opCeiling (smChannel m)
              }
        void (forkIO (do
          outcome <- runSessionTurn td bgAdapter meta Nothing prompt
          case toError outcome of
            Just err -> ccSend caps ("bg failed: " <> err)
            Nothing  -> pure ()))
      registryWithBg = mkRegistry (registrySpecs registry <> [backgroundCommandSpec bgRunner, callCommandSpec callDispatcher, skillCommandSpec skillBackend callDispatcher (Just plainHandler)])
      -- The /call dispatcher: dispatch an opcode against the active
      -- session's ISA registry + transcript under Full autonomy (the
      -- operator is the approver by typing /call). Returns the
      -- structured DispatchError/OpResult for the command to render.
      -- Rebuilt per invocation via `withCliTurn` so a `/new` swap of
      -- `srActive` flows the new sid's transcript + isaReg into the
      -- dispatch.
      callDispatcher callOpName val = do
        meta <- readIORef (srActive sr)
        let sid = smId meta
            td = TurnDeps
              { tdPaths        = paths
              , tdVault        = rt
              , tdProvider     = pr
              , tdResolve      = resolveSessionProvider pr
              , tdRepoReg      = repoReg
              , tdAutonomy     = autonomy
              , tdBroker       = Nothing
              , tdHarnessReg   = harnessReg
              , tdTmuxRunner   = tmuxRunner
              , tdHttpManager  = Just (prManager pr)
              , tdApprovals    = approvals
              , tdReplies      = replies
              , tdLocks        = locks
              , tdAbortReg     = abortReg
              , tdTabsHandle   = tabsH
              , tdLogger       = logger
              , tdIsRemote     = isRemote
              , tdBaseBackends = backends
              , tdExecCache    = execCache
              , tdRemoteRunner = Nothing
              , tdMkWorker    = Nothing
              }
        TurnEngine.callDispatcher td caps sid "cli" callOpName val
      plainHandler t = do
        meta <- readIORef (srActive sr)
        let td = TurnDeps
              { tdPaths        = paths
              , tdVault        = rt
              , tdProvider     = pr
              , tdResolve      = resolveSessionProvider pr
              , tdRepoReg      = repoReg
              , tdAutonomy     = autonomy
              , tdBroker       = Nothing  -- CLI has no WS broker
              , tdHarnessReg   = harnessReg
              , tdTmuxRunner   = tmuxRunner
              , tdHttpManager  = Just (prManager pr)
              , tdApprovals    = approvals
              , tdReplies      = replies
              , tdLocks        = locks
              , tdAbortReg     = abortReg
              , tdTabsHandle   = tabsH
              , tdLogger       = logger
              , tdIsRemote     = isRemote
              , tdBaseBackends = backends
              , tdExecCache    = execCache
              , tdRemoteRunner = Nothing
              , tdMkWorker    = Nothing
              }
            adapter = TurnAdapter
              { taCaps          = caps
              , taPreTurn       = \_ _ _ -> pure ()
              , taChannelLabel  = const "cli"
              , taOnStop        = const Nothing
              , taOnUserMessage = const Nothing
              , taPostTurn      = \_ _ -> pure ()
              , taStartWiring   = \sessionBackends sid appEnv' eCfg' opCeiling _meta ->
                  TurnEngine.buildStartWiring td sessionBackends sid appEnv' eCfg' opCeiling "cli"
              }
        outcome <- runSessionTurn td adapter meta Nothing t
        for_ (toError outcome) (ccSend caps)
  runInputT hlSettings (loop caps plainHandler tabsH registryWithBg)
  where
    loop :: ChannelCaps -> (Text -> IO ()) -> TabsHandle -> Registry -> InputT IO ()
    loop caps plainHandler th reg = do
      -- Ctrl-C handler: on interrupt, abort the active session's in-flight
      -- tool call (design Task 7 — CLI abort wiring). The interrupt is
      -- caught here (not propagated), so the loop continues; the next
      -- getInputLine re-prompts. The active session's abort flag is set
      -- via the SessionAbortRegistry.
      mLine <- withInterrupt
        (handleInterrupt
          (liftIO $ do
            active <- readIORef (srActive sr)
            setSessionAbort abortReg (smId active)
            ccSend caps "interrupted (in-flight tool call aborted)"
            pure Nothing
          )
          (getInputLine "> "))
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          -- A forked /bg turn may have registered a pending confirmation
          -- (askHuman) for its background session. Deliver the next input
          -- line as that answer before any normal routing; if no ask is
          -- pending, deliverNextAnswerAny returns False and the line is
          -- routed normally. This mirrors the per-session deliverNextAnswer
          -- the inbox-driven channels run at the top of their loop, but is
          -- session-agnostic because the CLI has one input stream serving
          -- the active session plus any /bg background sessions.
          (_resolved, delivered) <- liftIO $ deliverNextAnswerResolvedAny askReply (T.pack line)
          if delivered
            then loop caps plainHandler th reg
            else do
              case Seal.Routing.Route.route (T.pack line) of
                Right (Seal.Routing.Route.Focus idx) -> liftIO (focusTabH th idx) >>= \r -> liftIO $ ccSend caps (case r of Left e -> "focus: " <> e; Right _ -> "focused tab " <> T.singleton (tabIndexToChar idx))
                Right (Seal.Routing.Route.Inject idx payload) -> liftIO $ do
                  _ <- focusTabH th idx
                  plainHandler payload
                Right (Seal.Routing.Route.TabCommand tsc) -> liftIO (handleTabCommand caps th tsc)
                Right Seal.Routing.Route.CurrentTab -> liftIO $ do
                  active <- readIORef (srActive sr)
                  tl <- snapshotTabs th
                  case lookupByRef tl (BoundSession (smId active)) of
                    Just t  -> ccSend caps (renderTab t)
                    Nothing -> ccSend caps "no current tab"
                Right (Seal.Routing.Route.NewSession _args) -> do
                  -- /new is registered as a CommandSpec in the registry
                  -- (the CLI tracks "current" via srActive, not a cursor),
                  -- so re-route to the registry path below. Falling
                  -- through by re-parsing as SlashCommand.
                  d <- liftIO $ ingest reg chain (RawInbound (T.pack line))
                  liftIO $ interpretDisposition caps plainHandler d
                Right (Seal.Routing.Route.SlashCommand _) -> do
                  d <- liftIO $ ingest reg chain (RawInbound (T.pack line))
                  liftIO $ interpretDisposition caps plainHandler d
                Right (Seal.Routing.Route.Plain t) -> liftIO $ plainHandler t
                Left (Seal.Routing.Route.ParseError e) -> liftIO $ ccSend caps e
              loop caps plainHandler th reg

-- | Handle a parsed 'TabSlashCommand' by mutating the 'TabsHandle' and
-- replying via the channel caps. Pure-ish (the handle mutations are STM).
handleTabCommand :: ChannelCaps -> TabsHandle -> TabSlashCommand -> IO ()
handleTabCommand caps tabsH = \case
  TabListCmd -> do
    tl <- snapshotTabs tabsH
    if tabCount tl == 0
      then ccSend caps "no tabs"
      else mapM_ (ccSend caps . renderTab) (tlTabs tl)
  TabNewCmd _mKind -> do
    r <- insertTabH tabsH (BoundSession placeholderSid) KindAi Nothing
    case r of
      Left e  -> ccSend caps ("tab new failed: " <> e)
      Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " created")
  TabCloseCmd idx force -> do
    r <- removeTabH tabsH idx
    case r of
      Left e  -> ccSend caps (if force == Force then "force close: " <> e else "close failed: " <> e)
      Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar idx) <> " closed")
  TabFocusCmd idx -> do
    r <- focusTabH tabsH idx
    case r of
      Left e  -> ccSend caps ("focus failed: " <> e)
      Right _ -> ccSend caps ("focused tab " <> T.singleton (tabIndexToChar idx))
  TabResumeCmd sid -> do
    r <- insertTabH tabsH (BoundSession sid) KindAi Nothing
    case r of
      Left e  -> ccSend caps ("resume failed: " <> e)
      Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " resumed")
  TabRenameCmd idx name -> do
    r <- renameTabH tabsH idx name
    case r of
      Left e  -> ccSend caps ("rename failed: " <> e)
      Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar idx) <> " renamed to " <> name)
  where
    placeholderSid = case mkSessionId "tab-session" of
      Right s -> s
      Left _  -> error "placeholder session id"

-- | Render one tab as a single line: @<index>  <kind>  [label]@.
renderTab :: Tab -> Text
renderTab t =
  T.singleton (tabIndexToChar (tIndex t)) <> "  " <> T.pack (show (tKind t))
    <> maybe "" ("  " <>) (tLabel t)

-- | Resolve the untrusted-execution 'UntrustedIO' capability handle from the
-- 'SecurityConfig'. Absent section / mode=local → the local arm (real local
-- executor wired to the workspace root). mode=remote + remote fully
-- configured → the remote arm (the SSH executor; the opcodes run remotely
-- via 'mkRemoteUntrustedIO'). mode=remote + remote absent/incomplete → the
-- fail-closed stub so untrusted opcodes fail at call time (the
-- 'UeExec ExecNotImplemented' error surfaces).
untrustedIOFromSecurity :: WorkspaceRoot -> SecurityConfig -> UntrustedIO
untrustedIOFromSecurity wsRoot cfg =
  case untrustedExecConfigFromSecurity cfg of
    Nothing -> defaultHandle
    Just uec ->
      case uecRemote uec of
        Nothing -> mkRemoteUntrustedIOStub  -- mode=remote, no remote configured
        Just sshCfg ->
          -- The remote SSH arm. The RemoteRunner is the real
          -- 'mkRealRemoteRunner' (System.Process-backed); the SSH argv +
          -- host-key pinning are inherited from 'Seal.Tools.Exec.Remote'.
          mkRemoteUntrustedIO sshCfg mkRealRemoteRunner
  where
#if !defined(REMOTE_ONLY_UNTRUSTED)
    defaultHandle = mkLocalUntrustedIO wsRoot
#else
    defaultHandle = mkRemoteUntrustedIOStub  -- local executor absent; fail-closed
    _ = wsRoot  -- keep wsRoot referenced under the flag (unused when local absent)
#endif

-- The CLI security policy and bin allow-list are now centralized in
-- 'Seal.Core.TurnEngine.buildSessionRegistry' (the unified ISA registry
-- builder). The CLI no longer defines its own 'cliSecurityPolicy' or
-- 'binAllowList' — it passes 'autonomy' to the unified builder, which
-- constructs 'Policy.SecurityPolicy Policy.AllowAll autonomy' internally.
