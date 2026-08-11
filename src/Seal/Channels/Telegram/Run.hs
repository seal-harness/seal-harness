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
  , mkTelegramHandleCaps
  , onTelegramCallback
  ) where

import Data.Char (isDigit)
import Data.Either (fromRight)
import Data.IORef (newIORef)
import Data.Default (def)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR (decimal)
import Data.Vector qualified as V
import Network.HTTP.Client.TLS (newTlsManager)

import Katip (Severity (..), ls)

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Core.Types (SessionId)
import Seal.Channels.Loop (ChannelDeps (..), newChannelDeps, plainTurnWithCaps, runChannelLoop, mkTabCloseNotifier)
import Seal.Handles.AskReply
  ( AskId, AskReplyStore, newApprovalCache, newAskReplyStore
  , deliverAnswer, AskReply (..), ApprovalScope (..), findByAskIdPrefix
  , askHumanWithOptions, askIdText, pendingForSession, pqiId, pqiOptions
  , QuestionOption (..), formatQuestionWithOptions )
import Seal.Handles.Channel (ChannelHandle (..))
import Seal.Channels.Telegram.Transport
  ( TelegramTransport (..), TelegramButton (..), mkRealTelegramTransport, tgSetCommands )
import Seal.Logging.Logger (SealLogger, logIO)
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Channels.Telegram.Commands (telegramBotCommands)
import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Command.Channel
  ( ChannelRuntime (..), channelCommandSpec, mkRealSignalCli
  , mkRealTelegramBotApi, mkRealVaultStore )
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (Registry, mkRegistry)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Tab (tabCommandSpec, terseGrammarSpec)
import Seal.Config.File (RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig)
import Seal.Config.Migrate (migrateSecurityConfig)
import Seal.Config.Security (SecurityConfig (..), defaultSecurityConfig, loadSecurityConfig, untrustedExecConfigFromSecurity)
import Seal.Config.Paths
  ( SealPaths (..), configFilePath, ensureSealDirs, getSealPaths
  , reposFilePath, securityFilePath, vaultFilePath )
import Seal.Core.AllowList (AllowList)
import Seal.Core.MessageSource (UserId)
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry qualified
import Seal.Harness.Tmux qualified
import Seal.Ingest (PreprocessChain, emptyChain)
import Seal.Security.Policy (AutonomyLevel)
import Seal.SourceControl.Registry (mkRepoRegistryHandle)
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
  let withCh = withTelegramChannel (allow, chunkLimit) transport (cdLogger deps)
      plainHandler h = plainTurnWithCaps deps h askReply (Just (mkTelegramHandleCaps transport))
  tabsH <- newTabsHandle
  runChannelLoop deps withCh plainHandler registry chain askReply tabsH
    (Just (mkTelegramHandleCaps transport)) (Just (onTelegramCallback askReply))

-- | Full @seal telegram@ startup wiring: paths -> config -> vault -> session
-- -> backends -> registry -> spawn the Telegram channel -> run the loop.
-- Mirrors 'Seal.Channels.Signal.Run.runSignalMain' but drives the Telegram
-- channel instead. Resolves the @[telegram]@ config section + an optional
-- vault-supplied token; fails fast with a stderr diagnostic if the token is
-- unresolved.
runTelegramMain :: AutonomyLevel -> SealLogger -> IO ()
runTelegramMain autonomy logger = do
  paths <- getSealPaths
  ensureSealDirs paths
  migrateSecurityConfig paths
  let cfgPath = configFilePath paths
  cfg <- loadRuntimeConfig cfgPath >>= \case
    Left err -> do
      logIO logger WarningS ("could not load config: " <> ls err)
      pure defaultRuntimeConfig
    Right c  -> pure c
  secCfg <- loadSecurityConfig (securityFilePath paths) >>= \case
    Left err -> do
      logIO logger WarningS ("could not load security config: " <> ls err)
      pure defaultSecurityConfig
    Right c  -> pure c
  mHandle <- tryOpenVault paths secCfg logger
  ref     <- newIORef mHandle
  let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  mgr <- newTlsManager
  callCounter <- newIORef 0
  let pr = ProviderRuntime
            { prConfigPath  = cfgPath
            , prVault       = rt
            , prManager     = mgr
            , prCallCounter = callCounter
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
  askReply <- newAskReplyStore 0
  approvals <- newApprovalCache
  harnessReg <- Seal.Harness.Registry.newHarnessRegistry
  tmuxR <- Seal.Harness.Tmux.mkRealTmuxRunner
  let loadCfg = do
        lc <- loadRuntimeConfig cfgPath
        pure (fromRight defaultRuntimeConfig lc)
  repoRegH <- mkRepoRegistryHandle (reposFilePath paths)
  chanDeps <- newChannelDeps
        paths rt repoRegH pr backends autonomy Nothing
        harnessReg tmuxR (Just mgr) approvals loadCfg (isJust (untrustedExecConfigFromSecurity secCfg)) tabsH logger
  let registry = mkRegistry
        [ sessionCommandSpec sr
        , modelCommandSpec pr sr
        , agentCommandSpec (bAgentDefs backends) cfgPath
        , channelCommandSpec channelRt
        , tabCommandSpec paths tabsH (mkTabCloseNotifier (cdCursors chanDeps) (cdReplies chanDeps))
        , terseGrammarSpec
        ]
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
  case resolveTelegramConfig (rcTelegram cfg) mVaultToken of
    Left err -> logIO logger ErrorS ("seal telegram: " <> ls err)
    Right resolved -> runTelegram chanDeps registry emptyChain resolved askReply

-- | Open the vault if both recipient and identity are configured. Mirrors
-- 'Seal.Tui.tryOpenVault'; duplicated here to keep this module standalone.
tryOpenVault :: SealPaths -> SecurityConfig -> SealLogger -> IO (Maybe Vault.VaultHandle)
tryOpenVault paths cfg logger =
  case (scVaultRecipient cfg, scVaultIdentity cfg) of
    (Just _, Just _) ->
      resolveEncryptor cfg >>= \case
        Left err -> do
          logIO logger WarningS ("vault not available: " <> ls (T.pack (show err)))
          pure Nothing
        Right enc -> do
          let vcfg = Vault.VaultConfig
                { Vault.vcPath    = maybe (vaultFilePath paths) T.unpack (scVaultPath cfg)
                , Vault.vcKeyType = fromMaybe "x25519" (scVaultKeyType cfg)
                , Vault.vcUnlock  = parseUnlockMode (scVaultUnlock cfg)
                }
          Just <$> Vault.openVault vcfg enc
    _ -> pure Nothing

-- | Build a 'ChannelCaps' for the Telegram channel. When the 'AskPrompt'
-- has non-empty options AND the handle has a last chat id, 'ccPrompt' sends
-- the question with an inline keyboard (one button per option + an "Other"
-- free-text button) via 'tgSendWithKeyboard', then blocks on
-- 'askHumanWithOptions'. The @callback_data@ is @\"<8hex>:<idx>\"@ for
-- option buttons and @\"<8hex>:other\"@ for the Other button; the
-- 'onTelegramCallback' hook resolves the index to the option label and
-- delivers it by-id. When the options are empty OR no chat id is known
-- (the graceful-degradation path — should not happen in practice since the
-- first inbound message sets the chat id), it falls back to the generic
-- numbered-list rendering via 'chSend' + 'formatQuestionWithOptions'.
mkTelegramHandleCaps :: TelegramTransport -> ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps
mkTelegramHandleCaps transport h askReply sid = def
  { ccSend         = chSend h
  , ccPrompt       = \ap -> do
      let AskPrompt q opts = ap
      mChat <- chLastChatId h
      case (mChat, opts) of
        (Just chatId, _ : _) -> do
          outcome <- askHumanWithOptions askReply sid q opts (sendKeyboard chatId q opts)
          pure (fromRight "" outcome)
        _ -> do
          -- Empty options OR no chat id: fall back to the numbered list.
          chSend h (formatQuestionWithOptions q opts)
          outcome <- askHumanWithOptions askReply sid q opts (const (pure ()))
          pure (fromRight "" outcome)
  , ccPromptSecret = fmap (fromRight "") . chPromptSecret h
  , ccStreaming    = chStreaming h
  }
  where
    -- | The notify callback: sends the question + inline keyboard before
    -- 'askHumanWithOptions' blocks. The 8-hex prefix of the 'AskId' ties
    -- the buttons to this specific pending ask.
    sendKeyboard :: Text -> Text -> [QuestionOption] -> AskId -> IO ()
    sendKeyboard chatId q opts qid =
      let prefix = T.take 8 (askIdText qid)
      in tgSendWithKeyboard transport chatId q (buildKeyboard prefix opts)

-- | Build the inline keyboard: one row per option (button label = the
-- option's 'qoLabel', callback_data = @\"<prefix>:<idx>\"@), plus a final
-- row with one "Other" button (callback_data = @\"<prefix>:other\"@).
-- Pure. The callback_data is always ≤ 64 bytes (8 hex + 1 colon + ≤ 5
-- chars for the index or "other" = ≤ 14 bytes).
buildKeyboard :: Text -> [QuestionOption] -> [[TelegramButton]]
buildKeyboard prefix opts =
  [ [TelegramButton (qoLabel o) (prefix <> ":" <> T.pack (show i))]
  | (i, o) <- zip [0 :: Int ..] opts
  ]
  <> [[TelegramButton "Other" (prefix <> ":other")]]

-- | The callback handler for Telegram: parses the @callback_data@
-- (@\"<8hex>:<token>\"@), where @token@ is either a decimal index (the
-- tapped option button) or @other@ (the Other free-text button). For an
-- index, finds the pending ask by the 8-hex prefix, resolves the index to
-- the option's label via the pending ask's 'pqiOptions', and delivers it
-- by-id via 'deliverAnswer'. For @other@, returns 'False' so the loop
-- falls through to 'deliverNextAnswerResolved' (the next typed message is
-- captured as the free-text answer). Returns 'True' if a callback was
-- delivered; 'False' if not (fall through).
onTelegramCallback :: AskReplyStore -> SessionId -> Text -> IO Bool
onTelegramCallback store sid body =
  case T.splitOn ":" body of
    [prefix, token]
      | T.length prefix == 8 && T.all isHexChar prefix ->
          if token == "other"
            then pure False  -- Other: fall through to deliverNextAnswerResolved
            else case parseIndex token of
              Just idx -> resolveIndex store sid prefix idx
              Nothing  -> pure False  -- non-numeric token: fall through
    _ -> pure False
  where
    isHexChar c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

-- | Parse a non-negative decimal index from the callback token. 'Nothing'
-- if the token is not a clean decimal (e.g. empty, negative, or has
-- trailing chars).
parseIndex :: Text -> Maybe Int
parseIndex t =
  case TR.decimal (T.strip t) of
    Right (n, rest) | T.null rest && n >= 0 -> Just n
    _ -> Nothing

-- | Resolve a callback index to the option's label + deliver it by-id.
-- Looks up the pending ask by the 8-hex prefix, reads its 'pqiOptions',
-- safely indexes with 'V.!?'. Returns 'True' if delivered; 'False' if the
-- prefix is stale, the ask has no options, or the index is out of bounds
-- (all fall through to 'deliverNextAnswerResolved').
resolveIndex :: AskReplyStore -> SessionId -> Text -> Int -> IO Bool
resolveIndex store sid prefix idx = do
  mQid <- findByAskIdPrefix store sid prefix
  case mQid of
    Nothing -> pure False
    Just qid -> do
      ps <- pendingForSession store sid
      case filter (\p -> pqiId p == qid) ps of
        (p : _) ->
          case V.fromList (pqiOptions p) V.!? idx of
            Just o  -> do
              _accepted <- deliverAnswer store qid (AskReply ScopeOnce (qoLabel o))
              pure True
            Nothing -> pure False  -- out of bounds
        [] -> pure False  -- stale (ask vanished between the two lookups)
