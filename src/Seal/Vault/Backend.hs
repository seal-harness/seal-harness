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
  , readProcessNoInput   -- exported for test reuse
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Either (fromRight)
import Data.List (isPrefixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesPathExist, findExecutable, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (splitSearchPath, (</>))
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess )

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Config.Security (SecurityConfig (..))
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

-- | Run a process with no stdin, capturing stdout and stderr as strict
-- 'ByteString's. Used by the age-keygen / age-plugin-yubikey setup seams
-- (their output may carry non-ASCII recipient strings).
readProcessNoInput :: FilePath -> [String] -> IO (ExitCode, BS.ByteString, BS.ByteString)
readProcessNoInput cmdPath args =
  withCreateProcess
    ( (proc cmdPath args)
        { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }
    ) $ \_ mOut mErr ph -> do
      (hOut, hErr) <- case (mOut, mErr) of
        (Just a, Just b) -> pure (a, b)
        _ -> error "readProcessNoInput: pipe creation failed (unreachable)"
      out <- BS.hGetContents hOut
      err <- BS.hGetContents hErr
      ec  <- waitForProcess ph
      let !_ = BS.length out
          !_ = BS.length err
      pure (ec, out, err)

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

-- | First available relative key-file name under the keys directory, of the
-- form @<base><ext>@, @<base>-1<ext>@, @<base>-2<ext>@, … A newly generated key
-- is always written to a name that does not yet exist, so setup NEVER
-- overwrites an identity file that an existing vault still depends on: key
-- rotation must keep the old key intact in order to decrypt the current vault.
freshKeyName :: FilePath -> String -> String -> IO FilePath
freshKeyName keysDir base ext = go (0 :: Int)
  where
    go n = do
      let rel = base <> (if n == 0 then "" else "-" <> show n) <> ext
      taken <- doesPathExist (keysDir </> rel)
      if taken then go (n + 1) else pure rel

setupLocalAgeKey :: SealPaths -> Text -> IO (Either Text ResolvedKey)
setupLocalAgeKey paths name = do
  keysRoot <- ensureKeysRoot (spKeys paths)
  rel      <- freshKeyName (spKeys paths) (T.unpack name) ".identity"
  pathRes  <- mkSafeKeyPath keysRoot rel
  case pathRes of
    Left err       -> pure (Left (T.pack (show err)))
    Right safePath -> do
      let identPath = getSafeKeyPath safePath
      (exitCode, _stdout, stderrBs) <-
        readProcessNoInput "age-keygen" ["-o", identPath]
      case exitCode of
        ExitFailure n ->
          pure (Left ("age-keygen exited with code " <> T.pack (show n)))
        ExitSuccess -> do
          let stderrText = TE.decodeUtf8Lenient stderrBs
          case parseAgePublicKey stderrText of
            Nothing  -> pure (Left "age-keygen: could not parse public key from stderr")
            Just pub -> do
              setFileMode identPath 0o600
              pure (Right ResolvedKey
                { rkRecipient = pub
                , rkIdentity  = T.pack identPath
                , rkKeyType   = "x25519"
                })

-- | Generate (or reuse) a YubiKey-backed age identity.
--
-- @touchRequired@ -> @--touch-policy always|never@.
-- @pinRequired@   -> @--pin-policy   once|never@. Choosing @never@ means
-- decryption needs no PIN (only the token present, plus a touch if required);
-- choosing @once@ (the age-plugin-yubikey default) prompts for the PIN once per
-- decrypt session.
setupYubiKey
  :: SealPaths -> Text -> Bool -> Bool -> ChannelCaps
  -> IO (Either Text ResolvedKey)
setupYubiKey paths name touchRequired pinRequired caps = do
  mPlugin <- findExecutable "age-plugin-yubikey"
  case mPlugin of
    Nothing ->
      pure (Left "age-plugin-yubikey not found on PATH")
    Just _ -> do
      keysRoot <- ensureKeysRoot (spKeys paths)
      rel      <- freshKeyName (spKeys paths) (T.unpack name) ".yubikey.txt"
      pathRes  <- mkSafeKeyPath keysRoot rel
      case pathRes of
        Left err -> pure (Left (T.pack (show err)))
        Right safePath -> do
          let identPath   = getSafeKeyPath safePath
              touchPolicy = if touchRequired then "always" else "never"
              pinPolicy   = if pinRequired then "once" else "never"
          (exitCode, stdoutBs, _) <-
            readProcessNoInput "age-plugin-yubikey"
              [ "--generate"
              , "--touch-policy", touchPolicy
              , "--pin-policy", pinPolicy
              ]
          let stdoutText = TE.decodeUtf8Lenient stdoutBs
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
                   <> T.pack touchPolicy <> " --pin-policy " <> T.pack pinPolicy
                   <> " > " <> T.pack identPath)
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

resolveEncryptor :: SecurityConfig -> IO (Either VaultError VaultEncryptor)
resolveEncryptor fc =
  case (scVaultRecipient fc, scVaultIdentity fc) of
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

-- | Parse the recipient (public key) from age-plugin-yubikey @--generate@
-- output. The recipient appears on a comment line such as
-- @#    Recipient: age1yubikey1...@. age-plugin-yubikey RIGHT-ALIGNS its
-- comment labels, so the number of spaces between @#@ and the label varies
-- between lines; we therefore strip the leading @#@ and surrounding whitespace
-- before matching the label (case-insensitively per the age plugin spec) and
-- take everything after the first @:@.
parsePluginRecipient :: Text -> Maybe Text
parsePluginRecipient txt =
  case filter isRecipientLine (T.lines txt) of
    []       -> Nothing
    (line:_) ->
      let value = T.strip (T.drop 1 (T.dropWhile (/= ':') (labelOf line)))
      in if T.null value then Nothing else Just value
  where
    -- Drop a leading @#@ comment marker and the surrounding alignment spaces,
    -- leaving the label, e.g. @"Recipient: age1yubikey1..."@.
    labelOf l = T.stripStart (T.dropWhile (== '#') (T.stripStart l))
    isRecipientLine l = "recipient:" `T.isPrefixOf` T.toCaseFold (labelOf l)
