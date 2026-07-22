{-# LANGUAGE OverloadedStrings #-}
-- | Top-level TUI entry: path resolution -> config -> vault -> registry -> loop.
module Seal.Tui (runTui) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Network.HTTP.Client.TLS (newTlsManager)

import Seal.Channel.Cli (Backends (..), newBackends, runCliTui)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Channel
  ( ChannelRuntime (..), channelCommandSpec, mkRealSignalCli
  , mkRealTelegramBotApi, mkRealVaultStore )
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.New (NewDeps (..), newCommandSpec)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Tab (tabCommandSpec, tabsCommandSpec, terseGrammarSpec)
import Seal.Command.Spec (mkRegistry)
import Seal.Config.File (defaultRuntimeConfig, loadRuntimeConfig)
import Seal.Config.Security (SecurityConfig (..), defaultSecurityConfig, loadSecurityConfig)
import Seal.Config.Paths
  ( SealPaths (..)
  , configFilePath
  , ensureSealDirs
  , getSealPaths
  , securityFilePath
  , vaultFilePath
  )
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.AskReply (newAskReplyStore)
import Seal.Ingest (emptyChain)
import Seal.Security.Policy (AutonomyLevel)
import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), initSession)
import Seal.Tabs (newTabsHandle, rebindTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))
import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

-- | Open the vault if both recipient and identity are configured.
-- Failures print a warning and return 'Nothing' so the TUI still starts;
-- vault commands will direct the user to run @\/vault setup@.
tryOpenVault :: SealPaths -> SecurityConfig -> IO (Maybe VaultHandle)
tryOpenVault paths cfg =
  case (scVaultRecipient cfg, scVaultIdentity cfg) of
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
                                    (scVaultPath cfg)
                , vcKeyType = fromMaybe "x25519" (scVaultKeyType cfg)
                , vcUnlock  = parseUnlockMode (scVaultUnlock cfg)
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
  cfg <- loadRuntimeConfig cfgPath >>= \case
    Left err -> do
      putStrLn ("Warning: could not load config: " <> T.unpack err)
      pure defaultRuntimeConfig
    Right c  -> pure c
  secCfg <- loadSecurityConfig (securityFilePath paths) >>= \case
    Left err -> do
      putStrLn ("Warning: could not load security config: " <> T.unpack err)
      pure defaultSecurityConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths secCfg
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
  -- The /new command: mints a fresh session, swaps srActive, and rebinds the
  -- tab (if any) bound to the old sid to the new sid. The ndRebind closure
  -- reads the old sid from srActive BEFORE swapping, rebinds the matching
  -- tab in TabsHandle, then writes the new meta to srActive, and returns
  -- the old sid so the confirmation line can name it.
  let newDeps = NewDeps
        { ndPaths = paths
        , ndCfg = pure cfg
        , ndAgentDefs = backends
        , ndChannelLabel = "cli"
        , ndOldMeta = readIORef activeRef
        , ndRebind = \_caps newMeta -> do
            oldMeta <- readIORef activeRef
            let oldSid = smId oldMeta
            -- Rebind the tab (if any) bound to the old sid to the new sid.
            -- At most one tab can match by I2.
            snap <- snapshotTabs tabsH
            case [ t | t <- tlTabs snap, tRef t == BoundSession oldSid ] of
              []       -> pure ()  -- no tab bound to old sid; just swap srActive
              (tab : _) -> rebindTabH tabsH (tIndex tab) (BoundSession (smId newMeta)) >>= \case
                Left e  -> putStrLn ("warning: /new tab rebind failed: " <> T.unpack e)
                Right _ -> pure ()
            writeIORef activeRef newMeta
            pure oldSid
        }
  let registry = mkRegistry
        [ vaultCommandSpec rt
        , providerCommandSpec pr
        , sessionCommandSpec sr
        , modelCommandSpec pr sr
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , channelCommandSpec channelRt
        , tabCommandSpec tabsH
        , tabsCommandSpec tabsH
        , terseGrammarSpec
        , newCommandSpec newDeps
        ]
  runCliTui paths rt pr sr registry emptyChain backends tabsH autonomy askReply
