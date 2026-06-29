{-# LANGUAGE OverloadedStrings #-}
-- | The \/vault CommandSpec: eight subcommands (setup, add, get, list, delete,
-- lock, unlock, status) wired to the Phase 1 VaultHandle. Commands close over
-- a VaultRuntime so they carry no global state. The optparse parser produces
-- CommandActions; test code calls them through execParserPure.
module Seal.Vault.Commands
  ( VaultRuntime (..)
  , vaultCommandSpec
  ) where

import Control.Monad (when)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative
import System.Directory (doesFileExist)

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..)
  , CommandAction (..)
  , CommandGroup (..)
  , CommandName (..)
  , CommandSpec (..)
  )
import Seal.Config.File (FileConfig (..), loadFileConfig, updateFileConfig)
import Seal.Config.Paths (SealPaths, vaultFilePath)
import Seal.Security.Vault
  ( VaultConfig (..)
  , VaultHandle (..)
  , VaultStatus (..)
  , UnlockMode (..)
  , openVault
  )
import Seal.Security.Vault.Age
  ( AgeIdentity (..)
  , AgeRecipient (..)
  , VaultEncryptor
  , VaultError (..)
  , mkAgeEncryptor
  )
import Seal.Vault.Backend
  ( ResolvedKey (..)
  , detectAgePlugins
  , resolveEncryptor
  , setupLocalAgeKey
  , setupUserSupplied
  , setupYubiKey
  )

-- ---------------------------------------------------------------------------
-- Runtime
-- ---------------------------------------------------------------------------

data VaultRuntime = VaultRuntime
  { vrPaths :: SealPaths
  , vrConfigPath :: FilePath
  , vrHandleRef :: IORef (Maybe VaultHandle)
  }

-- ---------------------------------------------------------------------------
-- CommandSpec entry point
-- ---------------------------------------------------------------------------

vaultCommandSpec :: VaultRuntime -> CommandSpec
vaultCommandSpec rt = CommandSpec
  { csName         = CommandName "vault"
  , csAliases      = []
  , csGroup        = GroupVault
  , csSynopsis     = "Manage the encrypted secret vault"
  , csParserInfo   = vaultParserInfo rt
  , csAvailability = InteractiveOnly
  }

vaultParserInfo :: VaultRuntime -> ParserInfo CommandAction
vaultParserInfo rt =
  info (vaultParser rt <**> helper)
    (  progDesc "Encrypted secret vault operations"
    <> header   "vault — manage secrets in the on-disk encrypted vault"
    )

vaultParser :: VaultRuntime -> Parser CommandAction
vaultParser rt = hsubparser
  (  command "setup"
       (info (pure (setupCmd rt))
             (progDesc "Set up the vault backend and create the vault"))
  <> command "add"
       (info (addCmd rt <$> nameArg)
             (progDesc "Add or update a secret (value entered via hidden prompt)"))
  <> command "get"
       (info (getCmd rt <$> nameArg)
             (progDesc "Retrieve and reveal a secret"))
  <> command "list"
       (info (pure (listCmd rt))
             (progDesc "List all secret names (values are never shown)"))
  <> command "delete"
       (info (deleteCmd rt <$> nameArg)
             (progDesc "Delete a secret"))
  <> command "lock"
       (info (pure (lockCmd rt))
             (progDesc "Lock the vault (clear the decrypted cache)"))
  <> command "unlock"
       (info (pure (unlockCmd rt))
             (progDesc "Unlock the vault (decrypt into memory cache)"))
  <> command "status"
       (info (pure (statusCmd rt))
             (progDesc "Show vault status: locked, secret count, key type"))
  <> metavar "COMMAND"
  )

nameArg :: Parser Text
nameArg = T.pack <$> strArgument (metavar "NAME" <> help "Secret name")

-- ---------------------------------------------------------------------------
-- Guard + error helpers
-- ---------------------------------------------------------------------------

-- | Run k with the vault handle, or send "not configured" and return.
withHandle :: VaultRuntime -> ChannelCaps -> (VaultHandle -> IO ()) -> IO ()
withHandle rt caps k = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> ccSend caps "vault not configured — run /vault setup"
    Just h  -> k h

vaultErrMsg :: VaultError -> Text
vaultErrMsg VaultLocked           = "vault is locked — run /vault unlock"
vaultErrMsg VaultNotFound         = "vault not found — run /vault setup"
vaultErrMsg VaultAlreadyExists    = "vault already exists"
vaultErrMsg (VaultKeyNotFound k)  = "no such secret: " <> k
vaultErrMsg (VaultBackendError t) = "backend error: " <> t

handleResult :: ChannelCaps -> Either VaultError a -> (a -> IO ()) -> IO ()
handleResult caps (Left e)  _ = ccSend caps (vaultErrMsg e)
handleResult _    (Right a) k = k a

-- ---------------------------------------------------------------------------
-- Subcommand handlers
-- ---------------------------------------------------------------------------

setupCmd :: VaultRuntime -> CommandAction
setupCmd rt = CommandAction $ \caps -> do
  -- Snapshot old config BEFORE any modifications so rekeyExisting can use it.
  oldCfg <- loadFileConfig (vrConfigPath rt)
  let vaultPath = case oldCfg of
        Left _    -> vaultFilePath (vrPaths rt)
        Right cfg -> maybe (vaultFilePath (vrPaths rt)) T.unpack (fcVaultPath cfg)
      hasKey = case oldCfg of
        Right cfg -> isJust (fcVaultRecipient cfg) && isJust (fcVaultIdentity cfg)
        Left _    -> False
  vaultExists <- doesFileExist vaultPath
  -- An existing vault WITH a recorded key means re-running setup rotates that
  -- key; confirm first and reassure that secrets are preserved (the old key is
  -- kept and nothing is decrypted-then-lost). A vault file with no key recorded
  -- in config is an orphan from an interrupted setup — fall through so the
  -- orphan branch in rekeyExisting can tell the user to delete it.
  proceed <-
    if vaultExists && hasKey
      then do
        ccSend caps
          (  "A vault already exists. Continuing will ROTATE its key: every "
          <> "secret is re-encrypted to a new key. Your existing secrets are "
          <> "preserved, and the current key file is kept (never overwritten).")
        ans <- ccPrompt caps "Rotate the vault key? [y/N]: "
        pure (T.toLower (T.strip ans) `elem` ["y", "yes"])
      else pure True
  if not proceed
    then ccSend caps "Setup cancelled; the vault is unchanged."
    else runSetup rt caps oldCfg

-- | Backend selection + key generation + vault init/rekey. Split out of
-- 'setupCmd' so the existing-vault rotation guard stays readable. New keys are
-- always written to a fresh identity file (see 'freshKeyName' in
-- "Seal.Vault.Backend"), so a rotation never overwrites the key the current
-- vault still depends on.
runSetup :: VaultRuntime -> ChannelCaps -> Either Text FileConfig -> IO ()
runSetup rt caps oldCfg = do
  plugins <- detectAgePlugins
  let hasYubi = "yubikey" `elem` plugins
  ccSend caps "Available vault backends:"
  ccSend caps "  1. Local age key (age-keygen) — key stored on disk"
  when hasYubi $
    ccSend caps "  2. YubiKey (age-plugin-yubikey) — key stays on token [recommended]"
  let userNum = if hasYubi then "3" else "2"
  ccSend caps ("  " <> userNum <> ". User-supplied (bring your own key)")
  choice <- T.strip <$> ccPrompt caps "Choose backend [1]: "
  let effective = if T.null choice then "1" else choice
  rkResult <- case (effective, hasYubi) of
    ("1", _)     -> setupLocalAgeKey (vrPaths rt) "default"
    ("2", True)  -> do
      tp <- ccPrompt caps "Require touch? [y/N]: "
      let touch = T.toLower (T.strip tp) `elem` ["y", "yes"]
      pp <- ccPrompt caps
        "Require PIN on each decrypt session? [Y/n] (choose n for no PIN): "
      let pin = T.toLower (T.strip pp) `notElem` ["n", "no"]
      setupYubiKey (vrPaths rt) "default" touch pin caps
    ("2", False) -> setupUserSupplied caps
    ("3", True)  -> setupUserSupplied caps
    (other, _)   -> pure (Left ("Invalid choice: " <> other))
  case rkResult of
    Left err -> ccSend caps ("Setup failed: " <> err)
    Right rk -> do
      encResult <- mkAgeEncryptor
        (AgeRecipient (rkRecipient rk))
        (AgeIdentity  (rkIdentity  rk))
      case encResult of
        Left e -> ccSend caps (vaultErrMsg e)
        Right enc -> do
          -- Honor vault_path from config if set; fall back to the default path.
          -- tryOpenVault in Seal.Tui uses the same expression to stay in sync.
          let vaultPath = case oldCfg of
                Left _    -> vaultFilePath (vrPaths rt)
                Right cfg -> maybe (vaultFilePath (vrPaths rt)) T.unpack (fcVaultPath cfg)
              vaultCfg = VaultConfig
                { vcPath   = vaultPath
                , vcKeyType = rkKeyType rk
                , vcUnlock  = UnlockOnDemand
                }
          h <- openVault vaultCfg enc
          initResult <- vhInit h
          case initResult of
            Right () -> do
              ur <- updateFileConfig (vrConfigPath rt) $ \fc -> fc
                { fcVaultRecipient = Just (rkRecipient rk)
                , fcVaultIdentity  = Just (rkIdentity  rk)
                , fcVaultKeyType   = Just (rkKeyType   rk)
                }
              case ur of
                Left err -> ccSend caps ("Config write failed: " <> err)
                Right () -> do
                  writeIORef (vrHandleRef rt) (Just h)
                  ccSend caps "Vault created successfully."
            Left VaultAlreadyExists ->
              rekeyExisting rt caps enc rk oldCfg
            Left e ->
              ccSend caps (vaultErrMsg e)

-- | Rekey an existing vault with a new encryptor.
-- Uses the OLD config snapshot (captured before any modifications) to build
-- the old encryptor; updates the config after a successful rekey.
rekeyExisting
  :: VaultRuntime
  -> ChannelCaps
  -> VaultEncryptor
  -> ResolvedKey
  -> Either Text FileConfig
  -> IO ()
rekeyExisting rt caps newEnc rk eCfg = do
  case eCfg of
    Left err ->
      ccSend caps ("Cannot read existing config for rekey: " <> err)
    Right oldCfg ->
      -- Honor vault_path from config if set; fall back to the default path.
      -- tryOpenVault in Seal.Tui uses the same expression to stay in sync.
      let vaultPath = maybe (vaultFilePath (vrPaths rt)) T.unpack (fcVaultPath oldCfg)
      in case (fcVaultRecipient oldCfg, fcVaultIdentity oldCfg) of
        (Nothing, Nothing) ->
          -- Vault file exists but config has no key: a previous setup was
          -- interrupted before the config was written.  Tell the user to
          -- remove the orphaned file rather than trying to re-encrypt it.
          ccSend caps
            (  "vault file exists at "
            <> T.pack vaultPath
            <> " but the config has no key recorded — it was likely left from"
            <> " an interrupted setup. Delete that file and re-run '/vault setup'.")
        _ -> do
          oldEncResult <- resolveEncryptor oldCfg
          case oldEncResult of
            Left e ->
              ccSend caps ("Cannot load existing key for rekey: " <> vaultErrMsg e)
            Right oldEnc -> do
              let oldVaultCfg = VaultConfig
                    { vcPath    = vaultPath
                    , vcKeyType = fromMaybe "unknown" (fcVaultKeyType oldCfg)
                    , vcUnlock  = UnlockOnDemand
                    }
              oldH <- openVault oldVaultCfg oldEnc
              -- vhRekey reads from disk directly; no explicit unlock needed.
              -- Rotation was already confirmed up front in setupCmd, so show the
              -- old/new key summary and proceed without a second prompt.
              let confirmRekey msg = ccSend caps msg >> pure True
              rekeyResult <- vhRekey oldH newEnc (rkKeyType rk) confirmRekey
              case rekeyResult of
                Right () -> do
                  ur <- updateFileConfig (vrConfigPath rt) $ \fc -> fc
                    { fcVaultRecipient = Just (rkRecipient rk)
                    , fcVaultIdentity  = Just (rkIdentity  rk)
                    , fcVaultKeyType   = Just (rkKeyType   rk)
                    }
                  case ur of
                    Left err -> ccSend caps
                      (  "ERROR: vault was re-encrypted with the new key, but saving the"
                      <> " config failed (" <> err <> "). The vault on disk now uses the"
                      <> " NEW key, but config.toml still names the OLD key. Do NOT re-run"
                      <> " '/vault setup' — that would attempt to decrypt with the old key"
                      <> " and fail. Instead, manually edit config.toml to set"
                      <> " vault_recipient, vault_identity, and vault_key_type to the"
                      <> " values just configured, or restore config.toml from a backup.")
                    Right () -> do
                      writeIORef (vrHandleRef rt) (Just oldH)
                      ccSend caps "Vault rekeyed successfully."
                Left e ->
                  ccSend caps (vaultErrMsg e)

addCmd :: VaultRuntime -> Text -> CommandAction
addCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    val <- ccPromptSecret caps ("Value for " <> name <> ": ")
    result <- vhPut h name (TE.encodeUtf8 val)
    handleResult caps result $ \() ->
      ccSend caps ("Secret '" <> name <> "' stored.")

getCmd :: VaultRuntime -> Text -> CommandAction
getCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhGet h name
    handleResult caps result (ccSend caps . TE.decodeUtf8Lenient)

listCmd :: VaultRuntime -> CommandAction
listCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhList h
    handleResult caps result (mapM_ (ccSend caps))

deleteCmd :: VaultRuntime -> Text -> CommandAction
deleteCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhDelete h name
    handleResult caps result $ \() ->
      ccSend caps ("Secret '" <> name <> "' deleted.")

lockCmd :: VaultRuntime -> CommandAction
lockCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    vhLock h
    ccSend caps "Vault locked."

unlockCmd :: VaultRuntime -> CommandAction
unlockCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhUnlock h
    handleResult caps result $ \() ->
      ccSend caps "Vault unlocked."

statusCmd :: VaultRuntime -> CommandAction
statusCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    st <- vhStatus h
    ccSend caps $ T.unlines
      [ "locked:  " <> (if vsLocked st then "yes" else "no")
      , "secrets: " <> T.pack (show (vsSecretCount st))
      , "key:     " <> vsKeyType st
      ]
