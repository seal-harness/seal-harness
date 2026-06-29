{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
-- | Vault key-backend selection and setup. Produces a ResolvedKey (recipient +
-- identity path) from whichever backend the user chooses; converts it into a
-- live VaultEncryptor via the Phase 1 mkAgeEncryptor seam.
module Seal.Vault.Backend
  ( VaultKeyBackend (..)
  , ResolvedKey (..)
  , detectAgePlugins
  , filterPluginNames    -- exported for testing
  , parsePluginRecipient -- exported for testing
  , setupLocalAgeKey
  , setupYubiKey
  , setupUserSupplied
  , parseUnlockMode
  , resolveEncryptor
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Either (fromRight)
import Data.ByteString.Lazy qualified as BL
import Data.List (isPrefixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (findExecutable, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath)
import System.Posix.Files (setFileMode)
import System.Process.Typed (ExitCode (..), proc, readProcess)

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Config.File (FileConfig (..))
import Seal.Config.Paths (SealPaths (..))
import Seal.Security.Path (ensureKeysRoot, getSafeKeyPath, mkSafeKeyPath)
import Seal.Security.Vault (UnlockMode (..))
import Seal.Security.Vault.Age
  ( AgeIdentity (..)
  , AgeRecipient (..)
  , VaultEncryptor
  , VaultError (..)
  , mkAgeEncryptor
  )

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data VaultKeyBackend
  = LocalAgeKey
  | YubiKey { ykTouchRequired :: Bool }
  | UserSupplied
  deriving stock (Eq, Show)

data ResolvedKey = ResolvedKey
  { rkRecipient :: Text   -- age1... / age1yubikey1...
  , rkIdentity :: Text   -- absolute path to identity file
  , rkKeyType :: Text   -- "x25519" | "yubikey" | "user"
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Plugin detection
-- ---------------------------------------------------------------------------

-- | Pure helper: given the filenames in one directory, return the plugin suffixes.
filterPluginNames :: [FilePath] -> [Text]
filterPluginNames names =
  [ T.pack (drop prefixLen n)
  | n <- names
  , pluginPrefix `isPrefixOf` n
  ]
  where
    pluginPrefix = "age-plugin-"
    prefixLen    = length pluginPrefix

detectAgePlugins :: IO [Text]
detectAgePlugins = do
  mPath    <- lookupEnv "PATH"
  let dirs  = maybe [] splitSearchPath mPath
  allNames <- traverse safeList dirs
  pure (sort (nub (concatMap filterPluginNames allNames)))
  where
    safeList d = do
      r <- try @IOException (listDirectory d)
      pure (fromRight [] r)

-- ---------------------------------------------------------------------------
-- Backend setup
-- ---------------------------------------------------------------------------

setupLocalAgeKey :: SealPaths -> Text -> IO (Either Text ResolvedKey)
setupLocalAgeKey paths name = do
  keysRoot <- ensureKeysRoot (spKeys paths)
  pathRes  <- mkSafeKeyPath keysRoot (T.unpack name <> ".identity")
  case pathRes of
    Left err       -> pure (Left (T.pack (show err)))
    Right safePath -> do
      let identPath = getSafeKeyPath safePath
      (exitCode, _stdout, stderrBs) <-
        readProcess (proc "age-keygen" ["-o", identPath])
      case exitCode of
        ExitFailure n ->
          pure (Left ("age-keygen exited with code " <> T.pack (show n)))
        ExitSuccess -> do
          let stderrText = TE.decodeUtf8Lenient (BL.toStrict stderrBs)
          case parseAgePublicKey stderrText of
            Nothing  -> pure (Left "age-keygen: could not parse public key from stderr")
            Just pub -> do
              setFileMode identPath 0o600
              pure (Right ResolvedKey
                { rkRecipient = pub
                , rkIdentity  = T.pack identPath
                , rkKeyType   = "x25519"
                })

setupYubiKey
  :: SealPaths -> Text -> Bool -> ChannelCaps -> IO (Either Text ResolvedKey)
setupYubiKey paths name touchRequired caps = do
  mPlugin <- findExecutable "age-plugin-yubikey"
  case mPlugin of
    Nothing ->
      pure (Left "age-plugin-yubikey not found on PATH")
    Just _ -> do
      keysRoot <- ensureKeysRoot (spKeys paths)
      pathRes  <- mkSafeKeyPath keysRoot (T.unpack name <> ".yubikey.txt")
      case pathRes of
        Left err -> pure (Left (T.pack (show err)))
        Right safePath -> do
          let identPath   = getSafeKeyPath safePath
              touchPolicy = if touchRequired then "always" else "never"
          (exitCode, stdoutBs, _) <-
            readProcess (proc "age-plugin-yubikey"
              ["--generate", "--touch-policy", touchPolicy])
          let stdoutText = TE.decodeUtf8Lenient (BL.toStrict stdoutBs)
          mRecipient <-
            if exitCode == ExitSuccess && not (T.null (T.strip stdoutText))
              then do
                BS.writeFile identPath (TE.encodeUtf8 stdoutText)
                setFileMode identPath 0o600
                pure (Right (parsePluginRecipient stdoutText))
              else do
                -- TTY fallback: instruct user and wait for manual completion.
                ccSend caps
                  ("age-plugin-yubikey requires interactive input. Run:\n"
                   <> "    age-plugin-yubikey --generate --touch-policy "
                   <> T.pack touchPolicy <> " > " <> T.pack identPath)
                _ <- ccPrompt caps "Press Enter once the command has completed"
                rawE <- try @IOException (BS.readFile identPath)
                case rawE of
                  Left e ->
                    pure (Left ("age-plugin-yubikey: identity file not readable: "
                                 <> T.pack (show e)))
                  Right raw -> do
                    setFileMode identPath 0o600
                    pure (Right (parsePluginRecipient (TE.decodeUtf8Lenient raw)))
          case mRecipient of
            Left ioErr       -> pure (Left ioErr)
            Right Nothing    -> pure (Left "age-plugin-yubikey: could not parse recipient line")
            Right (Just pub) ->
              pure (Right ResolvedKey
                { rkRecipient = pub
                , rkIdentity  = T.pack identPath
                , rkKeyType   = "yubikey"
                })

setupUserSupplied :: ChannelCaps -> IO (Either Text ResolvedKey)
setupUserSupplied caps = do
  recipient <- ccPrompt caps "Recipient (age1\x2026): "
  identity  <- ccPrompt caps "Identity file path: "
  pure (Right ResolvedKey
    { rkRecipient = T.strip recipient
    , rkIdentity  = T.strip identity
    , rkKeyType   = "user"
    })

-- ---------------------------------------------------------------------------
-- Unlock mode + encryptor resolution
-- ---------------------------------------------------------------------------

parseUnlockMode :: Maybe Text -> UnlockMode
parseUnlockMode (Just "startup")    = UnlockStartup
parseUnlockMode (Just "per_access") = UnlockPerAccess
parseUnlockMode _                   = UnlockOnDemand

resolveEncryptor :: FileConfig -> IO (Either VaultError VaultEncryptor)
resolveEncryptor fc =
  case (fcVaultRecipient fc, fcVaultIdentity fc) of
    (Just r, Just i) ->
      mkAgeEncryptor (AgeRecipient r) (AgeIdentity i)
    (Nothing, _) ->
      pure (Left (VaultBackendError "vault not configured: missing vault_recipient"))
    (_, Nothing) ->
      pure (Left (VaultBackendError "vault not configured: missing vault_identity"))

-- ---------------------------------------------------------------------------
-- Internal parsers
-- ---------------------------------------------------------------------------

-- | Parse "Public key: age1..." from age-keygen stderr.
-- age-keygen always emits exactly this line (capital P, no '#' prefix).
parseAgePublicKey :: Text -> Maybe Text
parseAgePublicKey txt =
  case filter (T.isPrefixOf "Public key: ") (T.lines txt) of
    []       -> Nothing
    (line:_) -> Just (T.drop (T.length "Public key: ") line)

-- | Parse "# Recipient: age1yubikey1..." from age-plugin-yubikey output.
-- Match is case-insensitive on "recipient" per the age plugin spec.
-- Structure: "# " (2) + word + ": " + recipient. We drop "# ", then split on ": ".
parsePluginRecipient :: Text -> Maybe Text
parsePluginRecipient txt =
  let isRecipientLine l = "# recipient: " `T.isPrefixOf` T.toCaseFold l
  in case filter isRecipientLine (T.lines txt) of
       []      -> Nothing
       (line:_) ->
         case T.breakOn ": " (T.drop 2 line) of   -- drop "# "
           (_, rest) | not (T.null rest) -> Just (T.strip (T.drop 2 rest))
           _                             -> Nothing
