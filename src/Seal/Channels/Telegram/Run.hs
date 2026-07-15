{-# LANGUAGE OverloadedStrings #-}
-- | The @seal telegram@ startup wiring: spawn the Telegram channel + run
-- the agent loop against it, parallel to @seal signal@. Reuses the shared
-- 'Seal.Channels.Loop.runChannelLoop' + 'plainTurn' so the agent loop is
-- identical; the difference is the channel is Telegram (Bot API long-poll)
-- instead of Signal (signal-cli subprocess). 'aeMessageSource' is
-- @Just ms@ so the transcript records the channel + conversation id.
module Seal.Channels.Telegram.Run
  ( runTelegram
  , runTelegramMain
  ) where

import Data.IORef (newIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client.TLS (newTlsManager)
import System.IO (hPutStrLn, stderr)

import Seal.Channels.Loop (ChannelDeps (..), plainTurn, runChannelLoop)
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Channels.Telegram.Commands (telegramBotCommands)
import Seal.Channels.Telegram.Transport (mkRealTelegramTransport, tgSetCommands)
import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Command.Channel
  ( ChannelRuntime (..), channelCommandSpec, mkRealSignalCli
  , mkRealTelegramBotApi, mkRealVaultStore )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (Registry, mkRegistry)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Tab (tabCommandSpec, tabsCommandSpec, terseGrammarSpec)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths
  ( SealPaths (..), configFilePath, ensureSealDirs, getSealPaths, vaultFilePath )
import Seal.Core.AllowList (AllowList)
import Seal.Core.MessageSource (UserId)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry qualified
import Seal.Harness.Tmux qualified
import Seal.Handles.AskReply (AskReplyStore, newApprovalCache, newAskReplyStore)
import Seal.Ingest (PreprocessChain, emptyChain)
import Seal.Security.Policy (AutonomyLevel)
import Seal.Security.Vault qualified as Vault
import Seal.Session.Store (SessionRuntime (..), initSession)
import Seal.Tabs (newTabsHandle)
import Seal.Telegram.Config
  ( TelegramToken (..), resolveTelegramConfig, telegramTokenText
  , telegramVaultKey )
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..))

-- | Spawn the real Telegram transport, resolve the token + chunk limit +
-- allow-list, and run the agent loop against the Telegram channel. Fails
-- fast with a stderr diagnostic if the token is unresolved or the Bot API
-- is unreachable.
runTelegram
  :: ChannelDeps -> Registry -> PreprocessChain
  -> (TelegramToken, Int, AllowList UserId)
  -> AskReplyStore
  -> IO ()
runTelegram deps registry chain (token, chunkLimit, allow) askReply = do
  let mgr = prManager (cdProvider deps)
  transport <- mkRealTelegramTransport (telegramTokenText token) mgr
  -- Register the bot's slash-command menu with BotFather for auto-completion.
  tgSetCommands transport (telegramBotCommands registry)
  let withCh = withTelegramChannel (allow, chunkLimit) transport
      plainHandler h = plainTurn deps h askReply
  tabsH <- newTabsHandle
  runChannelLoop withCh plainHandler registry chain askReply (cdSession deps) tabsH

-- | Full @seal telegram@ startup wiring: paths -> config -> vault -> session
-- -> backends -> registry -> spawn the Telegram channel -> run the loop.
-- Mirrors 'Seal.Channels.Signal.Run.runSignalMain' but drives the Telegram
-- channel instead. Resolves the @[telegram]@ config section + an optional
-- vault-supplied token; fails fast with a stderr diagnostic if the token is
-- unresolved.
runTelegramMain :: AutonomyLevel -> IO ()
runTelegramMain autonomy = do
  paths <- getSealPaths
  ensureSealDirs paths
  let cfgPath = configFilePath paths
  cfg <- loadFileConfig cfgPath >>= \case
    Left err -> do
      hPutStrLn stderr ("Warning: could not load config: " <> T.unpack err)
      pure defaultFileConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths cfg
  ref     <- newIORef mHandle
  let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  mgr <- newTlsManager
  let pr = ProviderRuntime
            { prConfigPath = cfgPath
            , prVault      = rt
            , prManager    = mgr
            }
  let cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  backends <- newBackends cfgRoot repo
  sessionMeta <- initSession paths cfg (bAgentDefs backends)
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
  tabsH <- newTabsHandle
  cli <- mkRealSignalCli
  tgApi <- mkRealTelegramBotApi
  vaultStore <- mkRealVaultStore mHandle
  let channelRt = ChannelRuntime { crConfigPath = cfgPath, crSignalCli = cli
                                 , crTelegramBotApi = tgApi
                                 , crVaultStore = vaultStore }
  let registry = mkRegistry
        [ sessionCommandSpec sr
        , modelCommandSpec pr sr
        , skillCommandSpec (bSkills backends)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , channelCommandSpec channelRt
        , tabCommandSpec tabsH
        , tabsCommandSpec tabsH
        , terseGrammarSpec
        ]
  askReply <- newAskReplyStore 0
  approvals <- newApprovalCache
  harnessReg <- Seal.Harness.Registry.newHarnessRegistry
  tmuxR <- Seal.Harness.Tmux.mkRealTmuxRunner
  let chanDeps = ChannelDeps
        { cdPaths      = paths
        , cdVault      = rt
        , cdProvider   = pr
        , cdSession    = sr
        , cdBackends   = backends
        , cdAutonomy   = autonomy
        , cdBroker     = Nothing  -- standalone mode: no web frontend
        , cdHarnessRegistry = harnessReg
        , cdTmuxRunner  = tmuxR
        , cdHttpManager = Just mgr
        , cdApprovals   = approvals
        }
  -- Read the bot token from the vault (the wizard stores it there, not in
  -- config.toml). Falls back to the config token if present (for backward
  -- compat), but the vault token takes precedence.
  mVaultToken <- case mHandle of
    Nothing -> pure Nothing
    Just vh -> do
      r <- Vault.vhGet vh telegramVaultKey
      pure $ case r of
        Right bs -> Just (TE.decodeUtf8 bs)
        Left _   -> Nothing
  case resolveTelegramConfig (fcTelegram cfg) mVaultToken of
    Left err -> hPutStrLn stderr ("seal telegram: " <> T.unpack err)
    Right resolved -> runTelegram chanDeps registry emptyChain resolved askReply

-- | Open the vault if both recipient and identity are configured. Mirrors
-- 'Seal.Tui.tryOpenVault'; duplicated here to keep this module standalone.
tryOpenVault :: SealPaths -> FileConfig -> IO (Maybe Vault.VaultHandle)
tryOpenVault paths cfg =
  case (fcVaultRecipient cfg, fcVaultIdentity cfg) of
    (Just _, Just _) ->
      resolveEncryptor cfg >>= \case
        Left err -> do
          hPutStrLn stderr ("Warning: vault not available: " <> show err)
          pure Nothing
        Right enc -> do
          let vcfg = Vault.VaultConfig
                { Vault.vcPath    = maybe (vaultFilePath paths) T.unpack (fcVaultPath cfg)
                , Vault.vcKeyType = fromMaybe "x25519" (fcVaultKeyType cfg)
                , Vault.vcUnlock  = parseUnlockMode (fcVaultUnlock cfg)
                }
          Just <$> Vault.openVault vcfg enc
    _ -> pure Nothing