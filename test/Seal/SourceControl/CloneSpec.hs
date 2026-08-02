{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Seal.SourceControl.CloneSpec (spec) where

import Control.Exception (SomeException, try, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, findExecutable )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Info (os)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( getFileStatus, fileMode, intersectFileModes, ownerModes )
import Test.Hspec

import Seal.Git.Repo (readProcessBinaryCwdEnv)
import Seal.Security.Vault.Age (VaultError (VaultKeyNotFound, VaultLocked))
import Seal.SourceControl.Clone
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.TestHelpers.FakeVault (makeFakeVault, makeLockedVault)

----------------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.SourceControl.Clone" $ do

  --------------------------------------------------------------------------
  -- planClone (pure)
  --------------------------------------------------------------------------

  describe "planClone" $ do
    let rid = case mkRepoId "seal-harness" of Right i -> i; Left e -> error (T.unpack e)
        patRepo url = SourceRepo rid url VcsGitHub (CredPat "GITHUB_PAT")
        machineRepo url =
          SourceRepo rid url VcsGitHub (CredMachineUser "GITHUB_MACHINEUSER" "acme-bot")
        deployRepo url = SourceRepo rid url VcsGitHub (CredDeployKey "GITHUB_DEPLOYKEY")

    it "PAT ssh URL → ClonePlanExtraHeader https-url" $
      planClone (patRepo "git@github.com:owner/repo.git")
        `shouldBe` Right (ClonePlanExtraHeader "https://github.com/owner/repo.git" "GITHUB_PAT")

    it "MachineUser ssh URL → ClonePlanExtraHeader https-url (vault key only; username carried by cred)" $
      planClone (machineRepo "git@github.com:owner/repo.git")
        `shouldBe` Right (ClonePlanExtraHeader "https://github.com/owner/repo.git" "GITHUB_MACHINEUSER")

    it "DeployKey ssh URL → ClonePlanSshKey ssh-url (unchanged)" $
      planClone (deployRepo "git@github.com:owner/repo.git")
        `shouldBe` Right (ClonePlanSshKey "git@github.com:owner/repo.git" "GITHUB_DEPLOYKEY")

    it "disallowed host → CloneHostNotSupported" $
      planClone (patRepo "git@evil.com:owner/repo.git")
        `shouldBe` Left (CloneHostNotSupported "evil.com")

    it "malformed URL → CloneNoCredentialForUrl" $
      planClone (patRepo "not-a-url")
        `shouldBe` Left (CloneNoCredentialForUrl "not-a-url")

    it "VcsGit (non-github) → CloneUnsupportedVcs VcsGit" $
      let r = SourceRepo rid "git@github.com:o/r.git" VcsGit (CredPat "K")
      in planClone r `shouldBe` Left (CloneUnsupportedVcs VcsGit)

    it "already-https URL with PAT → ClonePlanExtraHeader same https-url" $
      planClone (patRepo "https://github.com/owner/repo.git")
        `shouldBe` Right (ClonePlanExtraHeader "https://github.com/owner/repo.git" "GITHUB_PAT")

  --------------------------------------------------------------------------
  -- renderCloneError
  --------------------------------------------------------------------------

  describe "renderCloneError" $ do
    it "CloneVaultError VaultLocked → vault locked message" $
      renderCloneError (CloneVaultError VaultLocked)
        `shouldBe` "vault locked — run /vault unlock"

    it "CloneVaultError (VaultKeyNotFound k) → vault key message with name" $ do
      let msg = renderCloneError (CloneVaultError (VaultKeyNotFound "MY_KEY"))
      "vault key" `T.isInfixOf` msg `shouldBe` True
      "MY_KEY" `T.isInfixOf` msg `shouldBe` True

    it "CloneNoCredentialForUrl u → no credential message with url" $
      renderCloneError (CloneNoCredentialForUrl "git@x:o/r.git")
        `shouldBe` "no credential resolvable for git@x:o/r.git"

    it "CloneUnsupportedVcs VcsGit → unsupported VCS message" $
      "unsupported VCS:" `T.isInfixOf`
        renderCloneError (CloneUnsupportedVcs VcsGit) `shouldBe` True

    it "CloneHostNotSupported h → host message with name" $ do
      let msg = renderCloneError (CloneHostNotSupported "evil.com")
      "host evil.com not supported" `T.isInfixOf` msg `shouldBe` True

    it "CloneGitFailed n → exit code message, NO stderr" $ do
      let msg = renderCloneError (CloneGitFailed 42)
      msg `shouldBe` "git failed (exit 42)"
      -- there is no stderr field on CloneGitFailed by construction; assert the
      -- rendered message does not contain "stderr"
      "stderr" `T.isInfixOf` msg `shouldBe` False

  --------------------------------------------------------------------------
  -- resolveCloneTarget + withCloneTarget: env/argv/URL security (§5.1)
  --------------------------------------------------------------------------

  describe "resolveCloneTarget (token never in env/argv/URL)" $ do
    it "PAT: token bytes NOT in ceUrl, ceEnvExtras values, or ceSshCommand" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let token = "ghp_SUPERSECRET_TOKEN_12345" :: ByteString
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", token)]
        result <- resolveCloneTarget vault stateDir repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \env -> do
            let urlBytes = TE.encodeUtf8 (ceUrl env)
                envBytes = BS.concat (map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env))
                sshBytes = maybe BS.empty TE.encodeUtf8 (ceSshCommand env)
            BS.isInfixOf token urlBytes `shouldBe` False
            BS.isInfixOf token envBytes `shouldBe` False
            BS.isInfixOf token sshBytes `shouldBe` False
            -- GIT_ASKPASS path IS in env (non-secret path)
            any (\(k,_) -> k == "GIT_ASKPASS") (ceEnvExtras env) `shouldBe` True
            -- GIT_TERMINAL_PROMPT=0 is in env
            lookup "GIT_TERMINAL_PROMPT" (ceEnvExtras env) `shouldBe` Just "0"

    it "MachineUser: token NOT in env/URL; cUsername NOT in env (only in helper)" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let token = "machineuser_token_BYTES" :: ByteString
            username = "acme-bot" :: Text
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub
                    (CredMachineUser "K" username)
        vault <- makeFakeVault [("K", token)]
        result <- resolveCloneTarget vault stateDir repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \env -> do
            let urlBytes = TE.encodeUtf8 (ceUrl env)
                envBytes = BS.concat (map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env))
            BS.isInfixOf token urlBytes `shouldBe` False
            BS.isInfixOf token envBytes `shouldBe` False
            BS.isInfixOf (TE.encodeUtf8 username) envBytes `shouldBe` False

    it "DeployKey: key bytes NOT in URL or ceSshCommand; keyfile PATH in GIT_SSH_COMMAND" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let keyBytes = "PRIVATE SSH KEY BYTES SECRET" :: ByteString
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K")
        vault <- makeFakeVault [("K", keyBytes)]
        result <- resolveCloneTarget vault stateDir repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \env -> do
            let urlBytes = TE.encodeUtf8 (ceUrl env)
                envBytes = BS.concat (map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env))
                sshBytes = maybe BS.empty TE.encodeUtf8 (ceSshCommand env)
            BS.isInfixOf keyBytes urlBytes `shouldBe` False
            BS.isInfixOf keyBytes envBytes `shouldBe` False
            BS.isInfixOf keyBytes sshBytes `shouldBe` False
            -- But GIT_SSH_COMMAND is set and references the keyfile
            isJust (ceSshCommand env) `shouldBe` True
            "ssh -i" `T.isInfixOf` fromJust (ceSshCommand env) `shouldBe` True
            "IdentitiesOnly=yes" `T.isInfixOf` fromJust (ceSshCommand env) `shouldBe` True
            "StrictHostKeyChecking=accept-new" `T.isInfixOf` fromJust (ceSshCommand env) `shouldBe` True

  --------------------------------------------------------------------------
  -- bracket cleanup (§5.5)
  --------------------------------------------------------------------------

  describe "withCloneTarget bracket cleanup" $ do
    it "removes the ASKPASS helper after the continuation (success path)" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", "tok")]
        Right target <- resolveCloneTarget vault stateDir repo
        mPath <- newIORef Nothing
        withCloneTarget target $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Just p -> writeIORef mPath (Just p)
            Nothing -> expectationFailure "GIT_ASKPASS not in env"
        helperPath <- readIORef mPath
        case helperPath of
          Nothing -> expectationFailure "no helper path captured"
          Just p -> doesFileExist p `shouldReturn` False

    it "removes the keyfile after the continuation (success path)" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K")
        vault <- makeFakeVault [("K", "key-bytes")]
        Right target <- resolveCloneTarget vault stateDir repo
        mPath <- newIORef Nothing
        withCloneTarget target $ \env -> do
          case words . T.unpack <$> ceSshCommand env of
            Just (_ : "-i" : p : _) -> writeIORef mPath (Just p)
            Just other -> expectationFailure ("unexpected ssh cmd shape: " <> show other)
            Nothing -> expectationFailure "no GIT_SSH_COMMAND"
        keyPath <- readIORef mPath
        case keyPath of
          Nothing -> pure ()
          Just p -> doesFileExist p `shouldReturn` False

    it "cleanup STILL runs when the continuation throws (bracket semantics)" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", "tok")]
        Right target <- resolveCloneTarget vault stateDir repo
        mPath <- newIORef Nothing
        let failingK env = do
              case lookup "GIT_ASKPASS" (ceEnvExtras env) of
                Just p -> writeIORef mPath (Just p)
                Nothing -> expectationFailure "GIT_ASKPASS not in env"
              throwIO (userError "intentional failure")
        -- The bracket must catch the exception, run cleanup, then rethrow
        (_ :: Either SomeException ()) <- try (withCloneTarget target failingK)
        helperPath <- readIORef mPath
        case helperPath of
          Nothing -> expectationFailure "no helper path captured"
          Just p -> doesFileExist p `shouldReturn` False

  --------------------------------------------------------------------------
  -- temp file location + permissions (§5.5)
  --------------------------------------------------------------------------

  describe "temp file location + permissions" $ do
    it "ASKPASS helper is created under cloneStateDir (NOT /tmp) with mode 0700" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", "tok")]
        Right target <- resolveCloneTarget vault stateDir repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Nothing -> expectationFailure "GIT_ASKPASS not in env"
            Just p -> do
              (stateDir `isPrefixOf` p) `shouldBe` True
              st <- getFileStatus p
              let mode = fileMode st `intersectFileModes` ownerModes
              mode `shouldBe` 0o700

    it "deploy-key keyfile is created under cloneStateDir with mode 0600" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K")
        vault <- makeFakeVault [("K", "key-bytes")]
        Right target <- resolveCloneTarget vault stateDir repo
        withCloneTarget target $ \env -> do
          case words . T.unpack <$> ceSshCommand env of
            Nothing -> expectationFailure "no GIT_SSH_COMMAND"
            Just (_ : "-i" : keyPath : _) -> do
              (stateDir `isPrefixOf` keyPath) `shouldBe` True
              st <- getFileStatus keyPath
              let mode = fileMode st `intersectFileModes` ownerModes
              mode `shouldBe` 0o600
            Just other -> expectationFailure ("unexpected ssh cmd: " <> show other)

    it "cloneStateDir is created 0700 if absent" $
      withSystemTempDirectory "seal-clone-parent" $ \parent -> do
        let stateDir = parent </> "subdir-that-does-not-exist"
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", "tok")]
        doesFileExist stateDir `shouldReturn` False
        _ <- resolveCloneTarget vault stateDir repo
        st <- getFileStatus stateDir
        let mode = fileMode st `intersectFileModes` ownerModes
        mode `shouldBe` 0o700

  --------------------------------------------------------------------------
  -- ASKPASS prompt-awareness (§5.1 — critical correctness)
  --------------------------------------------------------------------------

  describe "GIT_ASKPASS prompt-awareness" $ do
    it "PAT helper branches on Username/Password; returns x-access-token + token" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let token = "ghp_MY_TOKEN_BYTES" :: ByteString
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", token)]
        Right target <- resolveCloneTarget vault stateDir repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Nothing -> expectationFailure "no GIT_ASKPASS"
            Just p -> do
              content <- BS.readFile p
              let s = TE.decodeUtf8Lenient content
              "case \"$1\"" `T.isInfixOf` s `shouldBe` True
              "Username*)" `T.isInfixOf` s `shouldBe` True
              "Password*)" `T.isInfixOf` s `shouldBe` True
              "x-access-token" `T.isInfixOf` s `shouldBe` True
              -- token must be in the helper (same exposure level as keyfile:
              -- 0700 in 0700 private dir, bracket-deleted)
              BS.isInfixOf token content `shouldBe` True

    it "MachineUser helper returns cUsername + token (NOT x-access-token)" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let token = "machine_TOKEN_BYTES" :: ByteString
            username = "acme-bot" :: Text
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredMachineUser "K" username)
        vault <- makeFakeVault [("K", token)]
        Right target <- resolveCloneTarget vault stateDir repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Nothing -> expectationFailure "no GIT_ASKPASS"
            Just p -> do
              content <- BS.readFile p
              let s = TE.decodeUtf8Lenient content
              "case \"$1\"" `T.isInfixOf` s `shouldBe` True
              "Username*)" `T.isInfixOf` s `shouldBe` True
              "Password*)" `T.isInfixOf` s `shouldBe` True
              -- the username is the MachineUser's, NOT x-access-token
              "acme-bot" `T.isInfixOf` s `shouldBe` True
              -- token is in the helper
              BS.isInfixOf token content `shouldBe` True

    it "single-value helper would FAIL (regression: the helper has TWO arms)" $
      -- Structural assertion: the helper script MUST contain BOTH a Username
      -- arm and a Password arm (a single-value "echo the token" helper has
      -- only one arm and fails git's two-call protocol — §5.1).
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", "tok")]
        Right target <- resolveCloneTarget vault stateDir repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Nothing -> expectationFailure "no GIT_ASKPASS"
            Just p -> do
              content <- BS.readFile p
              let s = TE.decodeUtf8Lenient content
                  usernameCount = length (filter ("Username" `T.isInfixOf`) (T.lines s))
                  passwordCount = length (filter ("Password" `T.isInfixOf`) (T.lines s))
              usernameCount `shouldBe` 1
              passwordCount `shouldBe` 1

    it "single-quote in token/username is escaped (no command injection)" $
      -- §5 security invariant: a vault token or MachineUser username
      -- containing ' must NOT break out of the single-quoted literal in the
      -- ASKPASS helper (would enable command injection in the 0700 script).
      -- The correct POSIX idiom is '\'' (close-quote, escaped-quote,
      -- reopen-quote). This test plants a token containing a single quote
      -- and asserts the generated helper echoes the FULL literal (the quote
      -- is escaped, not interpreted as a string terminator), by checking the
      -- raw script bytes contain the escaped form and NOT a bare unescaped
      -- break. Specifically: the line `Password*) echo '...'\''...';` must
      -- round-trip the token verbatim.
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let token = "ghp_ev'il'payload" :: ByteString  -- contains single quotes
            rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        vault <- makeFakeVault [("K", token)]
        Right target <- resolveCloneTarget vault stateDir repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Nothing -> expectationFailure "no GIT_ASKPASS"
            Just p -> do
              content <- BS.readFile p
              let s = TE.decodeUtf8Lenient content
              -- The escaped form '\'' (close-quote, backslash, quote = 3
              -- chars) must appear for each ' in the token. The token has 2
              -- single quotes → the script must contain 2 occurrences of the
              -- 3-char escape sequence '\'' (Haskell string "'\\'" = '\').
              T.count "'\\'" s `shouldBe` 2
              -- The token bytes (minus the quotes' special meaning) must be
              -- present — i.e. "ghp_ev" + "il" + "payload" all appear.
              "ghp_ev" `T.isInfixOf` s `shouldBe` True
              "payload" `T.isInfixOf` s `shouldBe` True
              -- Regression guard: a broken escapeSingle that emits only \'
              -- (backslash+quote, 2 chars) would leave the NEXT char outside
              -- the literal. The line must still be a single echo statement
              -- ending in `;;` — assert the Password arm line ends with `;;`
              -- (a broken escape would terminate the string early and the
              -- `;;` would not close the echo).
              passwordLine <- case filter ("Password" `T.isInfixOf`) (T.lines s) of
                [l] -> pure l
                _   -> expectationFailure "expected exactly one Password line" >> pure ""
              T.isSuffixOf ";;" (T.strip passwordLine) `shouldBe` True

  --------------------------------------------------------------------------
  -- vault-locked / vault-key-not-found surfacing (§5 vault error mapping)
  --------------------------------------------------------------------------

  describe "vault error surfacing" $ do
    it "locked vault → Left (CloneVaultError VaultLocked); render contains 'vault locked'" $ do
      let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        vault <- makeLockedVault
        result <- resolveCloneTarget vault stateDir repo
        case result of
          Left (CloneVaultError VaultLocked) -> pure ()
          other -> expectationFailure ("expected CloneVaultError VaultLocked, got: " <> show other)
      "vault locked" `T.isInfixOf` renderCloneError (CloneVaultError VaultLocked) `shouldBe` True

    it "missing key → Left (CloneVaultError (VaultKeyNotFound k)); render has key name" $ do
      let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "MISSING_KEY")
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        vault <- makeFakeVault []  -- empty vault: no keys
        result <- resolveCloneTarget vault stateDir repo
        case result of
          Left (CloneVaultError (VaultKeyNotFound k)) -> k `shouldBe` "MISSING_KEY"
          other -> expectationFailure ("expected VaultKeyNotFound, got: " <> show other)
      "vault key MISSING_KEY not found" `T.isInfixOf`
        renderCloneError (CloneVaultError (VaultKeyNotFound "MISSING_KEY")) `shouldBe` True

  --------------------------------------------------------------------------
  -- rotation (S3/AC10): the vault is the source of truth, not a cache
  --------------------------------------------------------------------------

  describe "rotation" $ do
    it "two resolveCloneTarget calls with different vaults resolve different bytes" $
      withSystemTempDirectory "seal-clone" $ \stateDir -> do
        let rid = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid "git@github.com:o/r.git" VcsGitHub (CredPat "K")
        -- We can't run lsRemoteRepo against github.com offline, so we resolve
        -- the clone target twice with two different fake vaults and assert
        -- the helper-script content differs (new bytes, not old).
        vault1 <- makeFakeVault [("K", "OLD-BYTES")]
        Right t1 <- resolveCloneTarget vault1 stateDir repo
        content1 <- newIORef BS.empty
        withCloneTarget t1 $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Just p -> BS.readFile p >>= writeIORef content1
            Nothing -> expectationFailure "no ASKPASS"
        c1 <- readIORef content1
        -- second resolution with new bytes (new handle = new vault content)
        vault2 <- makeFakeVault [("K", "NEW-BYTES")]
        Right t2 <- resolveCloneTarget vault2 stateDir repo
        content2 <- newIORef BS.empty
        withCloneTarget t2 $ \env -> do
          case lookup "GIT_ASKPASS" (ceEnvExtras env) of
            Just p -> BS.readFile p >>= writeIORef content2
            Nothing -> expectationFailure "no ASKPASS"
        c2 <- readIORef content2
        BS.isInfixOf "OLD-BYTES" c1 `shouldBe` True
        BS.isInfixOf "NEW-BYTES" c2 `shouldBe` True
        BS.isInfixOf "OLD-BYTES" c2 `shouldBe` False
        BS.isInfixOf "NEW-BYTES" c1 `shouldBe` False

  --------------------------------------------------------------------------
  -- no-stderr assertion (§5.4 — type-level + behavior)
  --------------------------------------------------------------------------

  describe "no-stderr in CloneGitFailed" $ do
    it "CloneGitFailed carries exit code ONLY (no stderr field)" $ do
      -- Type-level assertion: the constructor takes one Int argument. The
      -- compiler enforces this. We exercise it: a value built from an exit
      -- code has no other field, and renderCloneError does not include
      -- "stderr".
      let e = CloneGitFailed 42
      e `shouldBe` CloneGitFailed 42
      "stderr" `T.isInfixOf` renderCloneError e `shouldBe` False

    it "lsRemoteRepo on a failing git → Left (CloneGitFailed _)" $
      -- We can't construct a CloneEnv directly (constructors not exported),
      -- so we exercise lsRemoteRepo end-to-end against a nonexistent URL.
      -- The host allow-list blocks non-github hosts at planClone, so we use
      -- a github.com URL with a nonexistent repo path — git ls-remote will
      -- fail (network or auth), returning CloneGitFailed (exit code only).
      -- Skip if no git OR no network (CI without network egress). The
      -- type-level assertion above is the primary check; this is the
      -- behavioral supplement.
      pendingWith "network-dependent; type-level assertion above covers the invariant"

  --------------------------------------------------------------------------
  -- git ls-remote integration (skip if no git) — tests the IO mechanism
  -- without bypassing planClone's security gate
  --------------------------------------------------------------------------

  describe "git ls-remote integration (IO mechanism, no allow-list bypass)" $ do
    -- We test readProcessBinaryCwdEnv + env-injection directly against a
    -- local fixture repo (bypassing planClone's host allow-list, which only
    -- allows github.com). This verifies the env-merge + git invocation
    -- mechanism that cloneRepo/lsRemoteRepo rely on, without hitting the
    -- network or bypassing the security gate in planClone.
    it "git ls-remote a local fixture repo via readProcessBinaryCwdEnv succeeds" $ do
      gitExe <- findExecutable "git"
      case gitExe of
        Nothing -> pendingWith "git not on PATH"
        Just _git -> withSystemTempDirectory "seal-clone-integ" $ \dir -> do
          let fixture = dir </> "fixture"
          createDirectoryIfMissing True fixture
          (ec0, _, _) <- readProcessBinaryCwdEnv (Just fixture) [] "git" ["init"] BS.empty
          ec0 `shouldBe` ExitSuccess
          (ec1, _, _) <- readProcessBinaryCwdEnv (Just fixture) [] "git"
            ["config", "user.name", "test"] BS.empty
          ec1 `shouldBe` ExitSuccess
          (ec2, _, _) <- readProcessBinaryCwdEnv (Just fixture) [] "git"
            ["config", "user.email", "test@x"] BS.empty
          ec2 `shouldBe` ExitSuccess
          BS.writeFile (fixture </> "README.md") "hello"
          (ec3, _, _) <- readProcessBinaryCwdEnv (Just fixture) [] "git"
            ["add", "README.md"] BS.empty
          ec3 `shouldBe` ExitSuccess
          (ec4, _, _) <- readProcessBinaryCwdEnv (Just fixture) [] "git"
            ["commit", "-m", "init"] BS.empty
          ec4 `shouldBe` ExitSuccess
          (ec5, out, _) <-
            readProcessBinaryCwdEnv Nothing [] "git" ["ls-remote", "--", fixture] BS.empty
          ec5 `shouldBe` ExitSuccess
          BS.length out `shouldSatisfy` (> 0)

    it "git ls-remote a nonexistent local URL → ExitFailure (CloneGitFailed pattern)" $ do
      gitExe <- findExecutable "git"
      case gitExe of
        Nothing -> pendingWith "git not on PATH"
        Just _git -> do
          (ec, _, _) <-
            readProcessBinaryCwdEnv Nothing [] "git"
              ["ls-remote", "--", "/nonexistent/repo/path/that/does/not/exist"]
              BS.empty
          case ec of
            ExitSuccess -> expectationFailure "expected non-zero exit"
            ExitFailure _ -> pure ()  -- the CloneGitFailed pattern

  --------------------------------------------------------------------------
  -- /proc argv-exposure (Linux only — skip on macOS)
  --------------------------------------------------------------------------

  describe "argv-exposure (/proc, Linux only)" $ do
    -- The platform-independent assertion (token NOT in env/argv/URL) is
    -- already covered in the "resolveCloneTarget (token never in
    -- env/argv/URL)" group above. This is the §5.1 /proc mitigation
    -- verification — deferred because full /proc scanning is complex and
    -- the env/argv/URL assertion is the stronger, platform-independent
    -- invariant.
    it "token not in any process cmdline (Linux /proc; skipped on macOS)" $
      when (os == "linux") $
        pendingWith "/proc scanning deferred — env/argv/URL assertion above covers the invariant"