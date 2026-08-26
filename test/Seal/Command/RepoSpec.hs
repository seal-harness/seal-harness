{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the @/repo@ slash command (W5). Mirrors 'Seal.Command.SkillSpec':
-- parse via 'execParserPure' against 'repoCommandSpec', then run the resulting
-- 'CommandAction' against 'FakeCaps' and assert on 'getSent'.
--
-- The /repo command closes over a 'RepoRegistryHandle' (for list/add/remove/
-- info) and a 'RepoTestSeam' (for /repo test's ls-remote stub + /repo info's
-- vault-key advisory). Tests build a fake handle + a stub seam so no real git
-- or vault is touched.
module Seal.Command.RepoSpec (spec) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import qualified Data.Text.Encoding as TE
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Repo
  ( RepoTestSeam (..), repoCommandSpec, renderRepoInfo, renderRepoLine )
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.SourceControl.Clone (CloneError (..))
import Seal.SourceControl.Repo
  ( RepoCredential (..), RepoId, SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.SourceControl.Registry
  ( RepoRegistry (..), RepoRegistryHandle (..) )
import Seal.TestHelpers.FakeCaps (FakeCaps (..), getSent, makeFakeCaps)

----------------------------------------------------------------------------
-- Test data
----------------------------------------------------------------------------

-- | A PAT-backed GitHub repo.
repoPat :: SourceRepo
repoPat = case mkRepoId "myrepo" of
  Right i -> SourceRepo
    { srId               = i
    , srUrl              = "git@github.com:o/r.git"
    , srVcsKind          = VcsGitHub
    , srCredential       = CredPat "K"
    , srDeployKeyPublic  = Nothing
    , srKeyfilePath      = Nothing
    }
  Left e -> error ("invalid repo id: " <> T.unpack e)

-- | A machine-user-backed GitHub repo.
repoBot :: SourceRepo
repoBot = case mkRepoId "botrepo" of
  Right i -> SourceRepo
    { srId               = i
    , srUrl              = "https://github.com/o/bot.git"
    , srVcsKind          = VcsGitHub
    , srCredential       = CredMachineUser "BK" "bot"
    , srDeployKeyPublic  = Nothing
    , srKeyfilePath      = Nothing
    }
  Left e -> error ("invalid repo id: " <> T.unpack e)

mkRid :: Text -> RepoId
mkRid t = case mkRepoId t of
  Right i -> i
  Left _  -> error ("invalid test id: " <> T.unpack t)

----------------------------------------------------------------------------
-- Fake handle + seam
----------------------------------------------------------------------------

-- | Build a 'RepoRegistryHandle' whose @rrhList@ returns the given repos and
-- whose @rrhMutate@ records each mutation into an 'IORef' (so the test can
-- assert upsert vs. remove). Always returns 'Right ()'.
mkFakeHandle :: [SourceRepo] -> IO (RepoRegistryHandle, IORef RepoRegistry)
mkFakeHandle repos = do
  let initial = RepoRegistry (Map.fromList [(srId r, r) | r <- repos])
  ref <- newIORef initial
  let h = RepoRegistryHandle
        { rrhList   = Right . Map.elems . rrRepos <$> readIORef ref
        , rrhMutate = \f -> do
            rr <- readIORef ref
            writeIORef ref (f rr)
            pure (Right ())
        }
  pure (h, ref)

-- | A seam whose ls-remote always errors, vault-list is empty, and vault-put
-- succeeds. Individual tests override fields as needed.
noOpSeam :: RepoTestSeam
noOpSeam = RepoTestSeam
  { rtsLsRemote  = \_ -> pure (Left (CloneGitFailed 1))
  , rtsVaultList = pure (Right [])
  , rtsVaultPut  = \_ _ -> pure (Right ())
  }

----------------------------------------------------------------------------
-- Runners
----------------------------------------------------------------------------

-- | Build ChannelCaps from a FakeCaps (mirrors SkillSpec's inline caps).
capsFrom :: FakeCaps -> ChannelCaps
capsFrom fc = ChannelCaps
  { ccSend         = \t -> modifyIORef' (fcSent fc) (t :)
  , ccShowHuman    = \_ -> pure ()
  , ccPrompt       = \_ -> pure ""
  , ccPromptSecret = \_ -> pure ""
  , ccStreaming    = False
  }

-- | Parse argv against the /repo command and run the resulting action.
runRepo
  :: RepoRegistryHandle -> RepoTestSeam -> [String] -> FakeCaps -> IO ()
runRepo h seam argv fc =
  case execParserPure defaultPrefs (csParserInfo (repoCommandSpec h seam)) argv of
    Success act -> runCommandAction act (capsFrom fc)
    _           -> expectationFailure ("parse failed: " <> show argv)

-- | Parse argv against the /repo command and run the resulting action with
-- a caller-provided 'ChannelCaps' (for tests that need to override
-- 'ccPromptSecret' or record calls).
runRepoWithCaps
  :: RepoRegistryHandle -> RepoTestSeam -> [String] -> ChannelCaps -> IO ()
runRepoWithCaps h seam argv caps =
  case execParserPure defaultPrefs (csParserInfo (repoCommandSpec h seam)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

----------------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Command.Repo" $ do

  describe "pure renderers" $ do
    it "renderRepoLine shows id, url, and the human credential label (PAT)" $ do
      renderRepoLine repoPat
        `shouldBe` "myrepo  git@github.com:o/r.git  Personal Access Token"

    it "renderRepoLine shows the Bot Account label for a machine user" $ do
      renderRepoLine repoBot
        `shouldBe` "botrepo  https://github.com/o/bot.git  Bot Account"

    it "renderRepoInfo includes id, url, vcs, credential label, and vault key" $ do
      let ls = T.unlines (renderRepoInfo repoPat)
      ls `shouldSatisfy` ("myrepo" `T.isInfixOf`)
      ls `shouldSatisfy` ("git@github.com:o/r.git" `T.isInfixOf`)
      ls `shouldSatisfy` ("github" `T.isInfixOf`)
      ls `shouldSatisfy` ("Personal Access Token" `T.isInfixOf`)
      ls `shouldSatisfy` ("K" `T.isInfixOf`)

    it "renderRepoInfo shows username only for MachineUser" $ do
      let ls = T.unlines (renderRepoInfo repoBot)
      ls `shouldSatisfy` ("username" `T.isInfixOf`)
      ls `shouldSatisfy` ("bot" `T.isInfixOf`)
      -- PAT info must NOT include a username line
      let lsPat = T.unlines (renderRepoInfo repoPat)
      lsPat `shouldNotSatisfy` ("username" `T.isInfixOf`)

  describe "/repo list" $ do
    it "shows defined repos (PAT + MachineUser)" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat, repoBot]
      runRepo h noOpSeam ["list"] fc
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("myrepo" `T.isInfixOf`)
      out `shouldSatisfy` ("botrepo" `T.isInfixOf`)
      out `shouldSatisfy` ("Personal Access Token" `T.isInfixOf`)
      out `shouldSatisfy` ("Bot Account" `T.isInfixOf`)

    it "reports none when empty" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam ["list"] fc
      sent <- getSent fc
      sent `shouldBe` ["no repos registered"]

  describe "/repo add" $ do
    it "adds a PAT repo on the happy path" $ do
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle []
      runRepo h noOpSeam
        ["add", "myrepo", "git@github.com:o/r.git",
         "--cred", "pat", "--vault-key", "K"]
        fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("added" `T.isInfixOf`)
      rr <- readIORef ref
      case Map.lookup (mkRid "myrepo") (rrRepos rr) of
        Nothing -> expectationFailure "repo not added"
        Just r  -> do
          srId r `shouldBe` mkRid "myrepo"
          srCredential r `shouldBe` CredPat "K"

    it "rejects a bad id" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam
        ["add", "bad/id", "git@github.com:o/r.git",
         "--cred", "pat", "--vault-key", "K"]
        fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("invalid" `T.isInfixOf`)

    it "rejects a disallowed host" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam
        ["add", "r", "git@evil.com:o/r.git",
         "--cred", "pat", "--vault-key", "K"]
        fc
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("host" `T.isInfixOf`)
      out `shouldSatisfy` ("not supported" `T.isInfixOf`)

    it "rejects machine_user without username" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam
        ["add", "r", "git@github.com:o/r.git",
         "--cred", "machine_user", "--vault-key", "K"]
        fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("username" `T.isInfixOf`)

    it "adds a machine_user repo with --username" $ do
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle []
      runRepo h noOpSeam
        [ "add", "botrepo", "https://github.com/o/bot.git"
        , "--cred", "machine_user", "--vault-key", "BK", "--username", "bot"
        ]
        fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("added" `T.isInfixOf`)
      rr <- readIORef ref
      case Map.lookup (mkRid "botrepo") (rrRepos rr) of
        Nothing -> expectationFailure "bot repo not added"
        Just r  -> srCredential r `shouldBe` CredMachineUser "BK" "bot"

    it "prompts for a PAT and stores it in the vault (--cred pat)" $ do
      promptCalled <- newIORef ([] :: [Text])
      putCalled    <- newIORef ([] :: [(Text, ByteString)])
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle []
      let seam = noOpSeam
            { rtsVaultPut = \k v -> do
                modifyIORef' putCalled ((k, v) :)
                pure (Right ())
            }
          caps = (capsFrom fc)
            { ccPromptSecret = \prompt -> do
                modifyIORef' promptCalled (prompt :)
                pure "xyz"
            }
      runRepoWithCaps h seam
        ["add", "myrepo", "git@github.com:o/r.git",
         "--cred", "pat", "--vault-key", "K"]
        caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("added" `T.isInfixOf`)
      propts <- readIORef promptCalled
      propts `shouldSatisfy` (not . null)
      puts <- readIORef putCalled
      puts `shouldBe` [("K", TE.encodeUtf8 "xyz")]
      rr <- readIORef ref
      case Map.lookup (mkRid "myrepo") (rrRepos rr) of
        Nothing -> expectationFailure "repo not added"
        Just r  -> srCredential r `shouldBe` CredPat "K"

    it "aborts on vault-locked during PAT prompt (--cred pat)" $ do
      putCalled <- newIORef ([] :: [(Text, ByteString)])
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle []
      let seam = noOpSeam
            { rtsVaultPut = \k v -> do
                modifyIORef' putCalled ((k, v) :)
                pure (Left VaultLocked)
            }
          caps = (capsFrom fc)
            { ccPromptSecret = \_ -> pure "xyz"
            }
      runRepoWithCaps h seam
        ["add", "myrepo", "git@github.com:o/r.git",
         "--cred", "pat", "--vault-key", "K"]
        caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("vault locked" `T.isInfixOf`)
      T.unlines sent `shouldNotSatisfy` ("added" `T.isInfixOf`)
      puts <- readIORef putCalled
      puts `shouldBe` [("K", TE.encodeUtf8 "xyz")]
      rr <- readIORef ref
      Map.lookup (mkRid "myrepo") (rrRepos rr) `shouldBe` Nothing

    it "does not prompt for deploy_key (--cred deploy_key)" $ do
      promptCalled <- newIORef ([] :: [Text])
      putCalled    <- newIORef ([] :: [(Text, ByteString)])
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle []
      let seam = noOpSeam
            { rtsVaultPut = \k v -> do
                modifyIORef' putCalled ((k, v) :)
                pure (Right ())
            }
          caps = (capsFrom fc)
            { ccPromptSecret = \prompt -> do
                modifyIORef' promptCalled (prompt :)
                pure "xyz"
            }
      runRepoWithCaps h seam
        ["add", "dkrepo", "git@github.com:o/dk.git",
         "--cred", "deploy_key", "--vault-key", "DK"]
        caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("added" `T.isInfixOf`)
      propts <- readIORef promptCalled
      propts `shouldBe` []
      puts <- readIORef putCalled
      puts `shouldBe` []
      rr <- readIORef ref
      case Map.lookup (mkRid "dkrepo") (rrRepos rr) of
        Nothing -> expectationFailure "deploy_key repo not added"
        Just r  -> srCredential r `shouldBe` CredDeployKey "DK"

    it "prompts for a MachineUser token and stores it in the vault (--cred machine_user --username)" $ do
      promptCalled <- newIORef ([] :: [Text])
      putCalled    <- newIORef ([] :: [(Text, ByteString)])
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle []
      let seam = noOpSeam
            { rtsVaultPut = \k v -> do
                modifyIORef' putCalled ((k, v) :)
                pure (Right ())
            }
          caps = (capsFrom fc)
            { ccPromptSecret = \prompt -> do
                modifyIORef' promptCalled (prompt :)
                pure "xyz"
            }
      runRepoWithCaps h seam
        [ "add", "botrepo", "https://github.com/o/bot.git"
        , "--cred", "machine_user", "--vault-key", "BK", "--username", "bot"
        ]
        caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("added" `T.isInfixOf`)
      propts <- readIORef promptCalled
      propts `shouldSatisfy` (not . null)
      puts <- readIORef putCalled
      puts `shouldBe` [("BK", TE.encodeUtf8 "xyz")]
      rr <- readIORef ref
      case Map.lookup (mkRid "botrepo") (rrRepos rr) of
        Nothing -> expectationFailure "bot repo not added"
        Just r  -> srCredential r `shouldBe` CredMachineUser "BK" "bot"

  describe "/repo remove" $ do
    it "removes a repo by id" $ do
      (fc, _) <- makeFakeCaps []
      (h, ref) <- mkFakeHandle [repoPat]
      runRepo h noOpSeam ["remove", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("removed" `T.isInfixOf`)
      rr <- readIORef ref
      Map.lookup (mkRid "myrepo") (rrRepos rr) `shouldBe` Nothing

    it "is idempotent on a missing repo" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam ["remove", "nope"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("removed" `T.isInfixOf`)

  describe "/repo info" $ do
    it "shows the descriptor for a known repo" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      runRepo h noOpSeam ["info", "myrepo"] fc
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("myrepo" `T.isInfixOf`)
      out `shouldSatisfy` ("git@github.com:o/r.git" `T.isInfixOf`)
      out `shouldSatisfy` ("github" `T.isInfixOf`)
      out `shouldSatisfy` ("Personal Access Token" `T.isInfixOf`)
      out `shouldSatisfy` ("K" `T.isInfixOf`)

    it "emits a non-blocking vault-key advisory when the key is absent" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]  -- repoPat's vault key is "K"
      let seam = noOpSeam { rtsVaultList = pure (Right ["OTHER"]) }
      runRepo h seam ["info", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("vault key K not found" `T.isInfixOf`)

    it "emits a vault-locked advisory when the vault is locked" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam { rtsVaultList = pure (Left VaultLocked) }
      runRepo h seam ["info", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("vault locked" `T.isInfixOf`)

    it "reports not found for a missing repo" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam ["info", "nope"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("not found" `T.isInfixOf`)

  describe "/repo test" $ do
    it "echoes the head sha on success" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam { rtsLsRemote = \_ -> pure (Right "abc123") }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("credential verified" `T.isInfixOf`)
      T.unlines sent `shouldSatisfy` ("abc123" `T.isInfixOf`)

    it "reports vault-locked as 'run /vault unlock'" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam
            { rtsLsRemote = \_ -> pure (Left (CloneVaultError VaultLocked)) }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("vault locked" `T.isInfixOf`)
      out `shouldSatisfy` ("/vault unlock" `T.isInfixOf`)

    it "reports a missing vault key by name" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam
            { rtsLsRemote = \_ -> pure (Left (CloneVaultError (VaultKeyNotFound "K"))) }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("vault key K not found" `T.isInfixOf`)

    it "reports a git failure as 'git ls-remote failed' (W3 reconciliation)" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam { rtsLsRemote = \_ -> pure (Left (CloneGitFailed 42)) }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      let out = T.unlines sent
      out `shouldSatisfy` ("ls-remote" `T.isInfixOf`)
      out `shouldSatisfy` ("42" `T.isInfixOf`)
      -- The W3 renderCloneError wording "git failed (exit N)" is NOT what
      -- /repo test emits — W5 reconciles it to "git ls-remote failed".
      out `shouldNotSatisfy` ("git failed (exit" `T.isInfixOf`)

    it "reports an unsupported host" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam
            { rtsLsRemote = \_ -> pure (Left (CloneHostNotSupported "evil.com")) }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("host evil.com not supported" `T.isInfixOf`)

    it "reports no-credential-for-url by url" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam
            { rtsLsRemote = \_ -> pure (Left (CloneNoCredentialForUrl "git@github.com:o/r.git")) }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("no credential resolvable for" `T.isInfixOf`)

    it "reports unsupported VCS" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle [repoPat]
      let seam = noOpSeam
            { rtsLsRemote = \_ -> pure (Left (CloneUnsupportedVcs VcsGit)) }
      runRepo h seam ["test", "myrepo"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("unsupported VCS" `T.isInfixOf`)

    it "reports repo not found" $ do
      (fc, _) <- makeFakeCaps []
      (h, _) <- mkFakeHandle []
      runRepo h noOpSeam ["test", "nope"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("not found" `T.isInfixOf`)
