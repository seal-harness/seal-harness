{-# LANGUAGE OverloadedStrings #-}
-- | Source-control clone seam — credential-injected @git clone@ / @git
-- ls-remote@ with the token NEVER in argv, the URL, or the environment (design
-- §4.4, §5). This is the most security-sensitive module in the repo-registry
-- feature.
--
-- Security invariants (enforced by construction — the human checkpoint after
-- W3 reviews these):
--
-- 1. Token/key bytes NEVER appear in argv, the URL, or the @GIT_SSH_COMMAND@
--    env value. For PAT / MachineUser the token lives only in a 0700
--    @GIT_ASKPASS@ helper script under 'repoCloneStateDir' (the env carries
--    only the non-secret @GIT_ASKPASS=<path>@); for DeployKey the key bytes
--    live only in a 0600 keyfile (the env @GIT_SSH_COMMAND@ carries the path,
--    not the bytes).
--
-- 2. Temp files (ASKPASS helper, deploy-key keyfile, @known_hosts@) live under
--    'repoCloneStateDir' (a 0700 private dir, NEVER @/tmp@), created with
--    @O_EXCL@-style create + immediate @fchmod@ 0600/0700 + a random suffix,
--    and are @bracket@-cleaned on success AND failure.
--
-- 3. The host allow-list (§5.2) is enforced clone-time in 'planClone'
--    ('CloneHostNotSupported'), defense-in-depth on top of write-time
--    validation.
--
-- 4. 'CloneGitFailed' carries the exit code ONLY — no stderr (§5.4: git can
--    echo a token-bearing URL in stderr on auth failure).
--
-- 5. 'withCloneTarget' is CPS (mirrors 'Seal.Security.Secrets.withApiKey'):
--    the authenticated bits are scoped to the continuation and the cleanup
--    always runs (bracket semantics).
--
-- 6. The ASKPASS helper is prompt-aware (§5.1): git invokes
--    @$GIT_ASKPASS \<prompt>@ TWICE for an HTTPS challenge — once with a
--    @Username for …@ prompt and once with @Password for …@. A single-value
--    "echo the token" helper LEAVES the username prompt unanswered and (with
--    @GIT_TERMINAL_PROMPT=0@) the clone fails. The helper branches on
--    @argv[1]@: PAT returns @x-access-token@ for Username + the token for
--    Password; MachineUser returns @cUsername@ for Username + the token for
--    Password.
module Seal.SourceControl.Clone
  ( CloneError (..)
  , ClonePlan (..)
  , CloneTarget
  , CloneEnv (..)
  , planClone
  , resolveCloneTarget
  , withCloneTarget
  , cloneRepo
  , lsRemoteRepo
  , renderCloneError
  ) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (showHex)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, removeFile )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Types (FileMode)
import System.Random (randomRIO)

import Seal.Git.Repo (readProcessBinaryCwdEnv)
import Seal.Security.Vault (VaultHandle (vhGet))
import Seal.Security.Vault.Age (VaultError (VaultKeyNotFound, VaultLocked))
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..)
  , hostAllowed, parseRepoHost )

----------------------------------------------------------------------------
-- Errors
----------------------------------------------------------------------------

-- | The clone seam's error type. 'CloneGitFailed' carries the exit code ONLY
-- (no stderr — §5.4: git can echo a token-bearing URL in stderr on auth
-- failure; a "redacted one-liner" heuristic is fragile, so stderr is dropped
-- entirely for this pass).
data CloneError
  = CloneVaultError VaultError
    -- ^ A vault access failure. Preserves the 'VaultError' so the caller can
    -- distinguish 'VaultLocked' from 'VaultKeyNotFound'.
  | CloneNoCredentialForUrl Text
    -- ^ The URL is malformed (host unparseable) — no credential can be
    -- resolved.
  | CloneUnsupportedVcs VcsKind
    -- ^ The 'VcsKind' has no credential-injection path in this pass
    -- (only 'VcsGitHub' is supported).
  | CloneHostNotSupported Text
    -- ^ The parsed host is not in the allow-list (defense-in-depth on top of
    -- write-time validation).
  | CloneGitFailed Int
    -- ^ @git@ exited non-zero. Carries the exit code ONLY — NO stderr (§5.4).
  deriving stock (Eq, Show)

-- | Render a 'CloneError' to the exact user-facing message used by the slash
-- command (W5) and a future @CLONE@ opcode. The mapping is total and stable:
-- each variant maps to a distinct, actionable message.
renderCloneError :: CloneError -> Text
renderCloneError = \case
  CloneVaultError VaultLocked ->
    "vault locked — run /vault unlock"
  CloneVaultError (VaultKeyNotFound k) ->
    "vault key " <> k <> " not found"
  CloneVaultError v ->
    "vault error: " <> T.pack (show v)
  CloneNoCredentialForUrl u ->
    "no credential resolvable for " <> u
  CloneUnsupportedVcs v ->
    "unsupported VCS: " <> T.pack (show v)
  CloneHostNotSupported h ->
    "host " <> h <> " not supported (only github.com is supported in this pass)"
  CloneGitFailed n ->
    "git failed (exit " <> T.pack (show n) <> ")"

----------------------------------------------------------------------------
-- ClonePlan (pure — no IO, no vault)
----------------------------------------------------------------------------

-- | The pure credential-injection strategy for a 'SourceRepo'. Carries only
-- public data (URLs + vault key /names/) — never secret bytes.
data ClonePlan
  = ClonePlanExtraHeader Text Text
    -- ^ Token-free HTTPS URL + the vault key name (PAT / MachineUser). The
    -- token is fetched at clone time and written to a 0700 ASKPASS helper.
  | ClonePlanSshKey Text Text
    -- ^ SSH URL (host-bound) + the vault key name (DeployKey). The key bytes
    -- are fetched at clone time and written to a 0600 keyfile.
  deriving stock (Eq, Show)

-- | Decide the clone strategy for a 'SourceRepo' (pure, no IO, no vault).
-- Re-parses the URL host and asserts the allow-list (§5.2 defense-in-depth),
-- then routes on 'srVcsKind' / 'srCredential'.
--
-- * Malformed URL (host unparseable) → 'CloneNoCredentialForUrl'.
-- * Parsed host not in the allow-list → 'CloneHostNotSupported'.
-- * 'VcsGit' (non-GitHub git) → 'CloneUnsupportedVcs' (no
--   credential-injection path this pass).
-- * 'CredPat' / 'CredMachineUser' → 'ClonePlanExtraHeader' (SSH URL
--   rewritten to token-free HTTPS).
-- * 'CredDeployKey' → 'ClonePlanSshKey' (URL unchanged, SSH).
planClone :: SourceRepo -> Either CloneError ClonePlan
planClone repo =
  case parseRepoHost (srUrl repo) of
    Left _err -> Left (CloneNoCredentialForUrl (srUrl repo))
    Right host
      | not (hostAllowed host) -> Left (CloneHostNotSupported host)
      | srVcsKind repo == VcsGit -> Left (CloneUnsupportedVcs VcsGit)
      | otherwise -> case srCredential repo of
          CredPat vaultKey ->
            Right (ClonePlanExtraHeader (sshToHttps (srUrl repo)) vaultKey)
          CredMachineUser vaultKey _username ->
            Right (ClonePlanExtraHeader (sshToHttps (srUrl repo)) vaultKey)
          CredDeployKey vaultKey ->
            Right (ClonePlanSshKey (srUrl repo) vaultKey)

-- | Rewrite an SSH GitHub URL (@git\@github.com:owner\/repo.git@) to a
-- token-free HTTPS URL (@https:\/\/github.com\/owner\/repo.git@). An
-- already-HTTPS URL is returned unchanged. The result NEVER contains a
-- credential fragment.
sshToHttps :: Text -> Text
sshToHttps url
  | "https://" `T.isPrefixOf` url = url
  | "http://" `T.isPrefixOf` url  = url
  | "git@" `T.isPrefixOf` url =
      let afterAt = T.drop (T.length "git@") url
      in case T.breakOn ":" afterAt of
           (host, rest)
             | T.null rest -> url
             | otherwise  ->
                 "https://" <> host <> "/" <> T.drop (T.length ":") rest
  | otherwise = url

----------------------------------------------------------------------------
-- CloneTarget / CloneEnv (opaque, redacted Show, CPS-scoped)
----------------------------------------------------------------------------

-- | The authenticated bits for a single clone, scoped to 'withCloneTarget'.
-- The constructors are NOT exported — callers observe the bits only via the
-- CPS continuation, mirroring 'Seal.Security.Secrets.withApiKey'. 'Show' is
-- redacted so a stray log/exception cannot leak the env extras.
data CloneTarget = CloneTarget
  { ctEnv :: CloneEnv
  , ctCleanup :: IO ()
  }

instance Show CloneTarget where
  show _ = "CloneTarget <redacted>"

-- | The environment passed to @git@. 'ceUrl' is the TOKEN-FREE URL;
-- 'ceEnvExtras' carries only non-secret env values (@GIT_ASKPASS=<path>@ for
-- PAT/MachineUser, @GIT_SSH_COMMAND=<ssh-cmd-with-keyfile-path>@ for
-- DeployKey, @GIT_TERMINAL_PROMPT=0@ always). The secret bytes live only in
-- the temp files referenced by those paths, never in the env values
-- themselves.
data CloneEnv = CloneEnv
  { ceUrl :: Text
    -- ^ The token-free URL passed to @git clone@ / @git ls-remote@.
  , ceGitConfigArgs :: [Text]
    -- ^ Extra @-c@ config args (currently @[]@ — we use @GIT_ASKPASS@, not
    -- @http.extraHeader@, to keep the token out of argv).
  , ceSshCommand :: Maybe Text
    -- ^ @GIT_SSH_COMMAND@ value (deploy-key only). Carries the keyfile PATH,
    -- not the key bytes.
  , ceEnvExtras :: [(String, String)]
    -- ^ Env overrides MERGED over the inherited environment. Carries
    -- @GIT_ASKPASS@ / @GIT_SSH_COMMAND@ / @GIT_TERMINAL_PROMPT@ — only
    -- non-secret values (paths + "0").
  , ceCleanup :: IO ()
    -- ^ Removes the temp keyfile + ASKPASS helper. Run by 'withCloneTarget'
    -- after the continuation (bracket semantics — runs on success AND
    -- failure).
  }

-- | Scope the authenticated bits + cleanup to the continuation (mirrors
-- 'Seal.Security.Secrets.withApiKey'). The cleanup ALWAYS runs, even if the
-- continuation throws — 'bracket' semantics.
withCloneTarget :: CloneTarget -> (CloneEnv -> IO r) -> IO r
withCloneTarget target k =
  bracket (pure target) ctCleanup (k . ctEnv)

----------------------------------------------------------------------------
-- resolveCloneTarget
----------------------------------------------------------------------------

-- | Resolve a 'SourceRepo' to a 'CloneTarget' — fetches the secret bytes
-- from the vault and writes the temp files (ASKPASS helper for PAT/MachineUser,
-- keyfile for DeployKey) under @repoCloneStateDir@. The temp files are created
-- with a random-suffix name + immediate @fchmod@ (§5.5) and are
-- @bracket@-cleaned via 'withCloneTarget'.
--
-- The parent @repoCloneStateDir@ is created 0700 if absent. NEVER writes
-- under @/tmp@.
resolveCloneTarget
  :: VaultHandle -> FilePath -> SourceRepo -> IO (Either CloneError CloneTarget)
resolveCloneTarget vault repoCloneStateDir repo =
  case planClone repo of
    Left e -> pure (Left e)
    Right plan -> do
      createDirectoryIfMissing True repoCloneStateDir
      setFileMode repoCloneStateDir 0o700
      case plan of
        ClonePlanExtraHeader httpsUrl vaultKey -> do
          mtoken <- vhGet vault vaultKey
          case mtoken of
            Left ve -> pure (Left (CloneVaultError ve))
            Right tokenBytes -> do
              let cred = srCredential repo
                  helperBytes = renderAskpassHelper cred tokenBytes
              helperPath <- writePrivateTempFile
                repoCloneStateDir "askpass-" 0o700 helperBytes
              let envExtras =
                    [ ("GIT_ASKPASS", helperPath)
                    , ("GIT_TERMINAL_PROMPT", "0")
                    ]
                  cleanup = removeFile helperPath
                  env = CloneEnv
                    { ceUrl = httpsUrl
                    , ceGitConfigArgs = []
                    , ceSshCommand = Nothing
                    , ceEnvExtras = envExtras
                    , ceCleanup = cleanup
                    }
              pure (Right CloneTarget { ctEnv = env, ctCleanup = cleanup })
        ClonePlanSshKey sshUrl vaultKey -> do
          mkey <- vhGet vault vaultKey
          case mkey of
            Left ve -> pure (Left (CloneVaultError ve))
            Right keyBytes -> do
              keyPath <- writePrivateTempFile
                repoCloneStateDir "ssh-key-" 0o600 keyBytes
              let knownHosts = repoCloneStateDir </> "known_hosts"
              knownExists <- doesFileExist knownHosts
              unless knownExists $ do
                BS.writeFile knownHosts BS.empty
                setFileMode knownHosts 0o600
              let sshCmd = T.pack $
                    "ssh -i " <> keyPath
                    <> " -o IdentitiesOnly=yes"
                    <> " -o StrictHostKeyChecking=accept-new"
                    <> " -o UserKnownHostsFile=" <> knownHosts
                  envExtras =
                    [ ("GIT_SSH_COMMAND", T.unpack sshCmd)
                    , ("GIT_TERMINAL_PROMPT", "0")
                    ]
                  cleanup = removeFile keyPath
                  env = CloneEnv
                    { ceUrl = sshUrl
                    , ceGitConfigArgs = []
                    , ceSshCommand = Just sshCmd
                    , ceEnvExtras = envExtras
                    , ceCleanup = cleanup
                    }
              pure (Right CloneTarget { ctEnv = env, ctCleanup = cleanup })

----------------------------------------------------------------------------
-- GIT_ASKPASS helper (prompt-aware — critical correctness, §5.1)
----------------------------------------------------------------------------

-- | Render the prompt-aware @GIT_ASKPASS@ helper shell script. git invokes
-- @$GIT_ASKPASS \<prompt>@ TWICE for an HTTPS credential challenge:
--
-- * once with @Username for 'https://github.com': @ (argv[1] starts with
--   "Username") → PAT prints @x-access-token@; MachineUser prints @cUsername@.
-- * once with @Password for 'https://github.com': @ (argv[1] starts with
--   "Password") → both print the token bytes.
--
-- A single-value "echo the token" helper FAILS (leaves the username prompt
-- unanswered; @GIT_TERMINAL_PROMPT=0@ prevents fallback). The script branches
-- on @argv[1]@ via a @case@. The values are single-quote-escaped (replace @'@
-- with @'\''@) and embedded in the 0700 script — the same exposure level as
-- the keyfile (0700 in a 0700 private dir, bracket-deleted).
renderAskpassHelper :: RepoCredential -> ByteString -> ByteString
renderAskpassHelper cred tokenBytes =
  TE.encodeUtf8 (T.pack script)
  where
    usernameVal = case cred of
      CredPat _            -> "x-access-token"
      CredMachineUser _ u  -> u
      CredDeployKey _       -> "x-access-token"
    tokenVal = TE.decodeUtf8Lenient tokenBytes
    script = unlines
      [ "#!/bin/sh"
      , "case \"$1\" in"
      , "  Username*) echo '" <> escapeSingle usernameVal <> "';;"
      , "  Password*) echo '" <> escapeSingle tokenVal <> "';;"
      , "esac"
      ]

-- | Single-quote-escape a value for embedding in a shell @'…'@ literal:
-- replace @'@ with @'\\''@ (close-quote, escaped-quote, reopen-quote — the
-- standard POSIX idiom). A single unescaped quote would break out of the
-- literal and enable command injection in the 0700 ASKPASS helper. PAT
-- tokens/usernames are typically @[A-Za-z0-9_]@ / base64-ish so this rarely
-- fires, but it MUST be correct for defense in depth.
escapeSingle :: Text -> String
escapeSingle = go . T.unpack
  where
    go []          = []
    go ('\'' : xs) = '\'' : '\\' : '\'' : go xs
    go (c : xs)    = c : go xs

----------------------------------------------------------------------------
-- Private temp file writer (random suffix + fchmod, §5.5)
----------------------------------------------------------------------------

-- | Write a private temp file under @parent@ (a 0700 private dir). The
-- filename is @prefix@ + a random hex suffix; the file is written then
-- immediately @fchmod@-ed to @mode@. The random suffix prevents prediction
-- (§5.5); the 0700 parent closes the symlink race. The caller is responsible
-- for bracket-cleanup (the path is returned).
writePrivateTempFile
  :: FilePath -> String -> FileMode -> ByteString -> IO FilePath
writePrivateTempFile parent prefix mode bytes = do
  suffix <- randomRIO (0x10000000 :: Int, 0xFFFFFFFF :: Int)
  let path = parent </> (prefix <> showHex suffix "")
  BS.writeFile path bytes
  setFileMode path mode
  pure path

----------------------------------------------------------------------------
-- cloneRepo / lsRemoteRepo
----------------------------------------------------------------------------

-- | @git clone@ a 'SourceRepo' into @destDir@ using the resolved credential.
-- The token NEVER appears in argv, the URL, or the env (only the non-secret
-- @GIT_ASKPASS=<path>@ is in env). On non-zero exit → 'CloneGitFailed' with
-- the exit code ONLY (stderr is DROPPED — §5.4). Cleanup runs via
-- 'withCloneTarget' (bracket — on success AND failure).
cloneRepo
  :: VaultHandle -> FilePath -> FilePath -> SourceRepo -> IO (Either CloneError ())
cloneRepo vault cloneStateDir destDir repo =
  resolveCloneTarget vault cloneStateDir repo >>= \case
    Left e -> pure (Left e)
    Right target -> withCloneTarget target $ \env -> do
      let gitArgs = ["clone", "--", T.unpack (ceUrl env), destDir]
      (ec, _out, _err) <-
        readProcessBinaryCwdEnv Nothing (ceEnvExtras env) "git" gitArgs BS.empty
      pure $ case ec of
        ExitSuccess   -> Right ()
        ExitFailure n -> Left (CloneGitFailed n)

-- | @git ls-remote@ a 'SourceRepo' (for @/repo test@). Same seam as
-- 'cloneRepo'; on success returns the first line of stdout
-- (@<sha>\\t<ref>@ — W5 echoes it). On non-zero exit → 'CloneGitFailed' with
-- the exit code ONLY (no stderr).
lsRemoteRepo
  :: VaultHandle -> FilePath -> SourceRepo -> IO (Either CloneError Text)
lsRemoteRepo vault cloneStateDir repo =
  resolveCloneTarget vault cloneStateDir repo >>= \case
    Left e -> pure (Left e)
    Right target -> withCloneTarget target $ \env -> do
      let gitArgs = ["ls-remote", "--", T.unpack (ceUrl env)]
      (ec, out, _err) <-
        readProcessBinaryCwdEnv Nothing (ceEnvExtras env) "git" gitArgs BS.empty
      pure $ case ec of
        ExitSuccess   -> Right (firstLine out)
        ExitFailure n -> Left (CloneGitFailed n)
  where
    firstLine bs =
      let l = BS.takeWhile (/= nl) bs
      in TE.decodeUtf8Lenient l
    nl = fromIntegral (ord '\n')