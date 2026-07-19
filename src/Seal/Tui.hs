{-# LANGUAGE OverloadedStrings #-}
-- | Top-level TUI entry: path resolution -> config -> vault -> registry -> loop.
module Seal.Tui (runTui) where

import Data.IORef (newIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Network.HTTP.Client.TLS (newTlsManager)

import Seal.Channel.Cli (Backends (..), newBackends, runCliTui)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Channel
  ( ChannelRuntime (..), channelCommandSpec, mkRealSignalCli
  , mkRealTelegramBotApi, mkRealVaultStore )
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Command.Tab (tabCommandSpec, tabsCommandSpec, terseGrammarSpec)
import Seal.Command.Spec (mkRegistry)
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
import Seal.Config.Paths
  ( SealPaths (..)
  , configFilePath
  , ensureSealDirs
  , getSealPaths
  , vaultFilePath
  )
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.AskReply (newAskReplyStore)
import Seal.Ingest (emptyChain)
import Seal.Security.Policy (AutonomyLevel)
import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
import Seal.Session.Store (SessionRuntime (..), initSession)
import Seal.Tabs (newTabsHandle)
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

-- | Open the vault if both recipient and identity are configured.
-- Failures print a warning and return 'Nothing' so the TUI still starts;
-- vault commands will direct the user to run @\/vault setup@.
tryOpenVault :: SealPaths -> FileConfig -> IO (Maybe VaultHandle)
tryOpenVault paths cfg =
  case (fcVaultRecipient cfg, fcVaultIdentity cfg) of
    (Just _, Just _) ->
      resolveEncryptor cfg >>= \case
        Left err -> do
          putStrLn ("Warning: vault not available: " <> show err)
          pure Nothing
        Right enc -> do
          -- Honor vault_path from config if set; fall back to the default.
          -- setupCmd and rekeyExisting in Seal.Vault.Commands replicate this
          -- same expression so all three stay in sync.
          let vcfg = VaultConfig
                { vcPath    = maybe (vaultFilePath paths) T.unpack
                                    (fcVaultPath cfg)
                , vcKeyType = fromMaybe "x25519" (fcVaultKeyType cfg)
                , vcUnlock  = parseUnlockMode (fcVaultUnlock cfg)
                }
          Just <$> openVault vcfg enc
    _ -> pure Nothing

-- | Full TUI wiring. The autonomy level threads through to 'mkSessionAgentEnv'
-- so 'Supervised' (the default) prompts before running Untrusted opcodes.
runTui :: AutonomyLevel -> IO ()
runTui autonomy = do
  paths <- getSealPaths
  ensureSealDirs paths
  let cfgPath = configFilePath paths
  cfg <- loadFileConfig cfgPath >>= \case
    Left err -> do
      putStrLn ("Warning: could not load config: " <> T.unpack err)
      pure defaultFileConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths cfg
  ref     <- newIORef mHandle
  let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  -- A dedicated manager for the /provider test round-trip. (M2 consolidates
  -- this with the chat provider's manager when the startup hardcode is removed.)
  mgr <- newTlsManager
  callCounter <- newIORef 0
  let pr = ProviderRuntime
            { prConfigPath  = cfgPath
            , prVault       = rt
            , prManager     = mgr
            , prCallCounter = callCounter
            }
  -- The config directory is a git repo (versioning + audit for the
  -- evolutionary stores: skills, agent-defs, memory live as Markdown files
  -- under config/skills, config/agents, config/memory). ensureConfigRepo
  -- runs `git init` + an initial empty commit if needed; idempotent.
  let cfgRoot = spConfig paths
  ensureConfigRepo cfgRoot
  let repo = openConfigRepo cfgRoot
  -- The evolutionary-store backends are disk-backed (Markdown + git), created
  -- once and shared between the @\/skill@ \/ @\/agent@ command specs
  -- (read-only) and the ISA opcodes (mutate, auto-commit). Disk is canonical.
  -- Built before initSession so the default agent can be resolved from disk.
  backends <- newBackends cfgRoot repo
  tabsH   <- newTabsHandle
  cli <- mkRealSignalCli
  tgApi <- mkRealTelegramBotApi
  vaultStore <- mkRealVaultStore mHandle
  let channelRt = ChannelRuntime { crConfigPath = cfgPath, crSignalCli = cli
                                 , crTelegramBotApi = tgApi
                                 , crVaultStore = vaultStore }
  -- Every launch starts a fresh session (resume is a follow-on milestone).
  -- The default agent (if set in config) is bound here: its id persists in
  -- smAgent and its non-empty provider/model override the config defaults.
  sessionMeta <- initSession paths cfg (bAgentDefs backends)
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
  -- The /bg command is wired inside runCliTui (it needs the ISA registry +
  -- transcript handle that are constructed there). The AskReplyStore is the
  -- async bridge for /bg confirmation prompts: a forked /bg turn's ccPrompt
  -- routes through askHuman, and the CLI loop delivers the next input line
  -- as the answer via deliverNextAnswerAny. 0 = block indefinitely.
  askReply <- newAskReplyStore 0
  let registry = mkRegistry
        [ vaultCommandSpec rt
        , providerCommandSpec pr
        , sessionCommandSpec sr
        , modelCommandSpec pr sr
        , skillCommandSpec (bSkills backends)
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , channelCommandSpec channelRt
        , tabCommandSpec tabsH
        , tabsCommandSpec tabsH
        , terseGrammarSpec
        ]
  runCliTui paths rt pr sr registry emptyChain backends tabsH autonomy askReply
