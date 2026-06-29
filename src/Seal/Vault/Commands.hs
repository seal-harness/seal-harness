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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative

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
      setupYubiKey (vrPaths rt) "default" touch caps
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
          let vaultCfg = VaultConfig
                { vcPath   = vaultFilePath (vrPaths rt)
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
      case (fcVaultRecipient oldCfg, fcVaultIdentity oldCfg) of
        (Nothing, Nothing) ->
          -- Vault file exists but config has no key: a previous setup was
          -- interrupted before the config was written.  Tell the user to
          -- remove the orphaned file rather than trying to re-encrypt it.
          ccSend caps
            (  "vault file exists at "
            <> T.pack (vaultFilePath (vrPaths rt))
            <> " but the config has no key recorded — it was likely left from"
            <> " an interrupted setup. Delete that file and re-run '/vault setup'.")
        _ -> do
          oldEncResult <- resolveEncryptor oldCfg
          case oldEncResult of
            Left e ->
              ccSend caps ("Cannot load existing key for rekey: " <> vaultErrMsg e)
            Right oldEnc -> do
              let oldVaultCfg = VaultConfig
                    { vcPath    = vaultFilePath (vrPaths rt)
                    , vcKeyType = fromMaybe "unknown" (fcVaultKeyType oldCfg)
                    , vcUnlock  = UnlockOnDemand
                    }
              oldH <- openVault oldVaultCfg oldEnc
              -- vhRekey reads from disk directly; no explicit unlock needed.
              let confirmRekey msg = do
                    ccSend caps msg
                    r <- ccPrompt caps "Confirm rekey? [y/N]: "
                    pure (T.toLower (T.strip r) `elem` ["y", "yes"])
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
                      <> " config failed (" <> err <> "). The vault on disk now requires"
                      <> " the NEW key, but the config still points at the OLD key, so the"
                      <> " next session cannot open it. Fix: re-run '/vault setup' to write"
                      <> " the new key into config, or restore config from backup.")
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
