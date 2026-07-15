{-# LANGUAGE OverloadedStrings #-}
-- | The shared inbox-driven channel loop, used by both Signal and Telegram
-- channels (and any future inbox-driven channel). The loop pulls
-- @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route' (Layer-1 terse grammar + /tab commands BEFORE the
-- /-command registry), dispatches slash commands via a 'ChannelCaps'
-- adapter over the 'ChannelHandle', and routes plain messages to the
-- supplied 'plainHandler' (which runs 'runTurn' with 'aeMessageSource' =
-- @Just ms@). Terminates when 'chReceive' returns EOF.
-- Extracted from 'Seal.Channels.Signal.Run.runSignalLoop' so both channels
-- share the same routing logic.
module Seal.Channels.Loop
  ( runChannelLoop
  , handleTabCommand
  , plainTurn
  , buildIsaRegistry
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Data.Either (fromRight)
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.IO (hPutStrLn, stderr)

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (adSystem)
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli
  ( Backends (..), execBackendFromFile, mkSessionAgentEnv
  , resolveSessionProvider, debugRequestsPath )
import Seal.Channels.Class (Channel (..))
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (CommandAction (..), Registry, runCommandAction)
import Seal.Config.File (loadFileConfig)
import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Core.MessageSource (MessageSource)
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Handles.AskReply
  ( ApprovalCache, AskReplyStore, askHuman, deliverNextAnswer )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Handles.Tab (TabKind (..), tabIndexToChar)
import Seal.Handles.Transcript (withTwoFileTranscript, tfwSetSecretOps)
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)
import qualified Seal.ISA.Registry as ISA
import Seal.ISA.Ops.File (fileReadOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillReadOp, skillWriteOp )
import Seal.ISA.Ops.Agent
  ( agentDefDeleteOp, agentDefListOp, agentDefReadOp, agentDefWriteOp
  , agentInstancesOp, agentStatusOp, agentStopOp )
import Seal.Routing.Route qualified as Route
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (AutonomyLevel)
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tabs
  ( TabsHandle, focusTabH, insertTabH, removeTabH, renameTabH, snapshotTabs )
import Seal.Tabs.Types
  ( Tab (..), TabList (..), TabRef (..), TabSlashCommand (..), ForceMode (..)
  , tabCount, tlTabs )
import Seal.Tools.Exec.Local (mkLocalExecHandle)
import Seal.Tools.Exec.Types (ExecBackend (..))
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Types.App (runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

-- | The inbox-driven loop. Spawns the channel via the supplied bracket,
-- pulls @(MessageSource, body)@ from 'chReceive', classifies via
-- 'Seal.Routing.Route' (Layer-1 terse grammar + /tab commands BEFORE the
-- /-command registry), dispatches slash commands via a 'ChannelCaps'
-- adapter over the 'ChannelHandle', and routes plain messages to the
-- supplied 'plainHandler'. Terminates when 'chReceive' returns EOF.
-- The 'withChannel' bracket owns cleanup.
runChannelLoop
  :: (Channel c)
  => ((c -> IO ()) -> IO ())
  -> (ChannelHandle -> Maybe MessageSource -> Text -> IO ())
  -> Registry
  -> PreprocessChain
  -> AskReplyStore
  -> SessionRuntime
  -> TabsHandle
  -> IO ()
runChannelLoop withChannel plainHandler registry chain askReply sr tabsH =
  withChannel $ \ch -> do
    let h = toHandle ch
        handleCaps = ChannelCaps
          { ccSend         = chSend h
          , ccPrompt       = \q -> do
              meta <- readIORef (srActive sr)
              let sid = smId meta
              outcome <- askHuman askReply sid q (\_qid -> chSend h q)
              pure (fromRight "" outcome)
          , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
          }
    loop h handleCaps
  where
    loop h handleCaps = do
      (mSrc, body) <- chReceive h
      case mSrc of
        Nothing -> pure ()  -- EOF: reader exited + inbox drained
        Just _ms -> do
          meta <- readIORef (srActive sr)
          let sid = smId meta
          delivered <- deliverNextAnswer askReply sid body
          if delivered
            then loop h handleCaps
            else do
              case Route.route body of
                Right (Route.Focus idx) -> do
                  _ <- focusTabH tabsH idx
                  chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
                  loop h handleCaps
                Right (Route.Inject idx payload) -> do
                  _ <- focusTabH tabsH idx
                  void (forkIO (plainHandler h mSrc payload))
                  loop h handleCaps
                Right (Route.TabCommand tsc) -> do
                  _ <- handleTabCommand h tabsH tsc
                  loop h handleCaps
                Right (Route.SlashCommand _) -> do
                  d <- ingest registry chain (RawInbound body)
                  case d of
                    DispatchAction a -> runCommandAction a handleCaps >> loop h handleCaps
                    ShowText t       -> chSend h t >> loop h handleCaps
                    PlainMessage t   -> void (forkIO (plainHandler h mSrc t)) >> loop h handleCaps
                    Rejected msg     -> chSend h msg >> loop h handleCaps
                Right (Route.Plain t) -> do
                  void (forkIO (plainHandler h mSrc t))
                  loop h handleCaps
                Left (Route.ParseError e) -> do
                  chSend h e
                  loop h handleCaps

-- | Handle a parsed 'TabSlashCommand' over a channel (mutates the
-- TabsHandle, replies via chSend). Mirrors Seal.Channel.Cli.handleTabCommand.
handleTabCommand :: ChannelHandle -> TabsHandle -> TabSlashCommand -> IO ()
handleTabCommand h tabsH = \case
  TabListCmd -> do
    tl <- snapshotTabs tabsH
    if tabCount tl == 0
      then chSend h "no tabs"
      else mapM_ (chSend h . renderTab) (tlTabs tl)
  TabNewCmd _mKind -> do
    r <- insertTabH tabsH (BoundSession placeholderSid) KindAi Nothing
    case r of
      Left e  -> chSend h ("tab new failed: " <> e)
      Right i -> chSend h ("tab " <> T.singleton (tabIndexToChar i) <> " created")
  TabCloseCmd idx force -> do
    r <- removeTabH tabsH idx
    case r of
      Left e  -> chSend h (if force == Force then "force close: " <> e else "close failed: " <> e)
      Right _ -> chSend h ("tab " <> T.singleton (tabIndexToChar idx) <> " closed")
  TabFocusCmd idx -> do
    r <- focusTabH tabsH idx
    case r of
      Left e  -> chSend h ("focus failed: " <> e)
      Right _ -> chSend h ("focused tab " <> T.singleton (tabIndexToChar idx))
  TabResumeCmd sid -> do
    r <- insertTabH tabsH (BoundSession sid) KindAi Nothing
    case r of
      Left e  -> chSend h ("resume failed: " <> e)
      Right i -> chSend h ("tab " <> T.singleton (tabIndexToChar i) <> " resumed")
  TabRenameCmd idx name -> do
    r <- renameTabH tabsH idx name
    case r of
      Left e  -> chSend h ("rename failed: " <> e)
      Right _ -> chSend h ("tab " <> T.singleton (tabIndexToChar idx) <> " renamed to " <> name)
  where
    placeholderSid = case mkSessionId "tab-session" of
      Right s -> s
      Left _  -> error "placeholder session id"
    renderTab t =
      T.singleton (tabIndexToChar (tIndex t)) <> "  " <> T.pack (show (tKind t))
        <> maybe "" ("  " <>) (tLabel t)

-- | Run one plain-text turn through the agent loop with the
-- 'MessageSource' threaded into 'aeMessageSource'. Mirrors 'runCliTui's
-- 'plainHandler' but pulls the active session's provider+model and builds
-- the 'AgentEnv' with @aeMessageSource = Just ms@. The 'ChannelHandle'
-- supplies the 'ChannelCaps' (forwarded) so the agent's replies go out via
-- the channel. The ask/reply store backs ASK_HUMAN. Generic — used by any
-- inbox-driven channel.
plainTurn
  :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime -> Backends
  -> ChannelHandle -> AskReplyStore -> AutonomyLevel -> ApprovalCache
  -> Maybe MessageSource -> Text -> IO ()
plainTurn paths rt pr sr backends h askReply autonomy approvals mSrc t = do
  meta <- readIORef (srActive sr)
  eprov <- resolveSessionProvider pr meta
  case eprov of
    Left err -> hPutStrLn stderr (T.unpack err)
    Right (prov, model) -> do
      let sid = smId meta
          sessionDirPath = sessionDir paths sid
      createDirectoryIfMissing True sessionDirPath
      withTwoFileTranscript sessionDirPath $ \tHandle -> do
        wsroot <- WorkspaceRoot <$> getCurrentDirectory
        appEnv <- mkEnv defaultConfig
        eCfg <- loadFileConfig (prConfigPath pr)
        -- Resolve the bound agent's system prompt (re-read per turn; agent
        -- dirs are small). Nothing when no agent is bound or the def has no
        -- system prompt. Mirrors 'runCliTui's plainHandler.
        mSystem <- case smAgent meta of
          Nothing  -> pure Nothing
          Just aid -> maybe Nothing adSystem <$> Def.adbRead (bAgentDefs backends) aid
        let isaReg = buildIsaRegistry rt backends wsroot sid askReply h sid
            handleCaps = ChannelCaps
              { ccSend         = chSend h
              , ccPrompt       = \q -> do
                  outcome <- askHuman askReply sid q (\_qid -> chSend h q)
                  pure (fromRight "" outcome)
              , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
              }
            execBackend = either (const defaultExecBackend) (execBackendFromFile wsroot) eCfg
            defaultExecBackend = EbLocal (mkLocalExecHandle wsroot)
        tfwSetSecretOps tHandle (ISA.secretOpNames isaReg)
        let env = (mkSessionAgentEnv
                     handleCaps prov (smProvider meta) model sid mSystem isaReg tHandle execBackend
                     (debugRequestsPath paths sid eCfg) autonomy approvals (pure ()))
                    { aeMessageSource = mSrc }
        runApp appEnv (runTurn env t)

-- | Build the ISA registry for a channel turn. Mirrors 'runCliTui's registry
-- assembly but without the AGENT_START worker (sub-agents over channels is a
-- later phase). The human-interaction opcodes are wired to the ask/reply
-- store via the per-turn 'ChannelCaps' so ASK_HUMAN surfaces the question to
-- the peer and blocks until the next inbound message delivers the answer.
buildIsaRegistry
  :: VaultRuntime -> Backends -> WorkspaceRoot -> SessionId
  -> AskReplyStore -> ChannelHandle -> SessionId
  -> ISA.Registry
buildIsaRegistry rt backends wsRoot sid askReply h _activeSid =
  ISA.mkRegistry
    [ showHumanOp caps
    , askHumanOp caps
    , fileReadOp wsRoot 131072
    , secretGetOp rt
    , memoryWriteOp (bMemory backends) sid
    , memoryRecallOp defaultPageParams (bMemory backends)
    , memoryDeleteOp (bMemory backends)
    , skillWriteOp (bSkills backends) sid
    , skillReadOp (bSkills backends)
    , skillListOp (bSkills backends)
    , skillDeleteOp (bSkills backends)
    , agentDefWriteOp (bAgentDefs backends) sid
    , agentDefReadOp (bAgentDefs backends)
    , agentDefListOp (bAgentDefs backends)
    , agentDefDeleteOp (bAgentDefs backends)
    , agentInstancesOp (bRuntime backends)
    , agentStatusOp (bRuntime backends)
    , agentStopOp (bRuntime backends)
    ]
  where
    caps = ChannelCaps
      { ccSend         = chSend h
      , ccPrompt       = \q -> do
          outcome <- askHuman askReply sid q (\_qid -> chSend h q)
          pure (fromRight "" outcome)
      , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
      }