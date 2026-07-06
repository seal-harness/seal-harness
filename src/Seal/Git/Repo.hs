{-# LANGUAGE OverloadedStrings #-}
-- | Git-backed versioning for @~\/.seal\/config@. The config directory is a
-- git repo (initialized on first run if absent). Skills, agent defs, and
-- memory entries live as Markdown files under @config\/skills@,
-- @config\/agents@, @config\/memory@; disk is canonical and git is the
-- versioning + audit layer. Model-authored writes auto-commit; human
-- file-drops are committed by the human via @git -C ~/.seal/config@ as usual.
--
-- The vault file (@config\/vault\/vault.age@) is ciphertext — it lives in the
-- repo safely; the age identity stays under @keys\/@ (off-repo). A default
-- @\@gitignore@ is NOT installed (the whole config dir is versioned, including
-- the vault ciphertext).
module Seal.Git.Repo
  ( ConfigRepo (..)
  , openConfigRepo
  , ensureConfigRepo
  , gitAdd
  , gitCommit
  , gitCommitAll
  , gitHasCommits
  ) where

import Control.Exception (try, SomeException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hFlush)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess )

-- | A handle to the config git repo. The repo root is the @config@ directory.
newtype ConfigRepo = ConfigRepo
  { crRoot :: FilePath
  -- ^ Absolute path to the git repo (= the @config@ / directory).
  }

-- | Open the config repo handle (no IO validation). The caller is responsible
-- for ensuring the repo exists via 'ensureConfigRepo' at startup.
openConfigRepo :: FilePath -> ConfigRepo
openConfigRepo = ConfigRepo

-- | Ensure @config\/@ is a git repo: @git init@ if @.git@ is absent, make
-- an initial empty commit if the repo has no commits yet (so commit-on-write
-- has a base to build on), and create the three store subdirectories
-- (@skills@, @agents@, @memory@) so the Markdown backends can write files
-- into them. Idempotent.
ensureConfigRepo :: FilePath -> IO ()
ensureConfigRepo root = do
  -- The root may not exist yet (first run); create it so `git init` has a
  -- working directory. createDirectoryIfMissing True creates all parents.
  createDirectoryIfMissing True root
  let gitDir = root </> ".git"
  exists <- doesDirectoryExist gitDir
  if exists
    then ensureInitialCommit root
    else do
      _ <- runGit root ["init"]
      -- Set a local identity so commits succeed in environments without a
      -- global git config (e.g. CI runners). Local config is scoped to this
      -- repo and never touches the user's global settings.
      _ <- runGit root ["config", "user.name", "seal"]
      _ <- runGit root ["config", "user.email", "seal@localhost"]
      ensureInitialCommit root
  -- The three evolutionary-store subdirectories. Created here (not in the
  -- backends) so a hand-edit user who drops a file finds the dirs ready, and
  -- so the backends' TIO.writeFile never hits a missing-parent-dir error.
  mapM_ (createDirectoryIfMissing True . (root </>)) ["skills", "agents", "memory"]

-- | Make an initial empty commit if the repo has no commits yet. Without one,
-- @git commit@ on the first real write fails (nothing to commit against, and
-- @HEAD@ is unborn). Idempotent.
ensureInitialCommit :: FilePath -> IO ()
ensureInitialCommit root = do
  has <- gitHasCommits' root
  if has
    then pure ()
    else do
      -- Commit an empty tree so HEAD is born. -m with --allow-empty.
      _ <- runGit root ["commit", "--allow-empty", "-m", "seal: initialize config repo"]
      pure ()

-- | True if the repo has at least one commit on HEAD.
gitHasCommits :: ConfigRepo -> IO Bool
gitHasCommits = gitHasCommits' . crRoot

gitHasCommits' :: FilePath -> IO Bool
gitHasCommits' root = do
  (ec, _out, _err) <- runGit root ["rev-parse", "--verify", "HEAD"]
  pure (ec == ExitSuccess)

-- | Stage one path (relative to the repo root). @git add <path>@.
gitAdd :: ConfigRepo -> FilePath -> IO ()
gitAdd repo path = do
  (ec, _out, err) <- runGit (crRoot repo) ["add", "--", path]
  case ec of
    ExitSuccess -> pure ()
    ExitFailure n -> ioError (userError ("git add failed (" <> show n <> "): " <> T.unpack err))

-- | Commit staged changes with a message. Fails if nothing is staged (the
-- caller is responsible for staging via 'gitAdd' first). Returns @True@ if a
-- commit was created, @False@ if there was nothing to commit.
gitCommit :: ConfigRepo -> Text -> IO Bool
gitCommit repo msg = do
  (ec, _out, err) <- runGit (crRoot repo) ["commit", "-m", T.unpack msg]
  case ec of
    ExitSuccess   -> pure True
    -- git exits 1 when there is nothing staged; treat as "nothing to commit".
    ExitFailure 1 -> pure False
    ExitFailure n -> ioError (userError ("git commit failed (" <> show n <> "): " <> T.unpack err))

-- | Stage one path and commit it with a message. Returns @True@ if a commit
-- was created. The convenience wrapper for the model-authored write path
-- (each opcode mutation is one file → one commit).
gitCommitAll :: ConfigRepo -> FilePath -> Text -> IO Bool
gitCommitAll repo path msg = do
  gitAdd repo path
  gitCommit repo msg

-- | Run @git@ in @root@ with the given args. Returns the exit code, stdout,
-- and stderr (as decoded Text). Catches process-launch failures (git not on
-- PATH) as an ExitFailure-like result rather than throwing.
runGit :: FilePath -> [String] -> IO (ExitCode, Text, Text)
runGit root args = do
  res <- try @SomeException (readProcessBinaryCwd (Just root) "git" args BS.empty)
  case res of
    Right (ec, out, err) ->
      pure (ec, TE.decodeUtf8Lenient out, TE.decodeUtf8Lenient err)
    Left e ->
      pure (ExitFailure 127, "", T.pack (show e))

-- | Run a process with an optional working directory and a strict
-- 'ByteString' stdin, capturing stdout and stderr as strict 'ByteString's.
-- Used by the git seam (commit messages may carry non-ASCII bytes).
readProcessBinaryCwd :: Maybe FilePath -> FilePath -> [String] -> ByteString
                    -> IO (ExitCode, ByteString, ByteString)
readProcessBinaryCwd mCwd cmdPath args input =
  withCreateProcess
    ( (proc cmdPath args)
        { cwd = mCwd
        , std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe
        }
    ) $ \mIn mOut mErr ph -> do
      (hIn, hOut, hErr) <- case (mIn, mOut, mErr) of
        (Just a, Just b, Just c) -> pure (a, b, c)
        _ -> error "readProcessBinaryCwd: pipe creation failed (unreachable)"
      BS.hPutStr hIn input
      hFlush hIn
      hClose hIn
      out <- BS.hGetContents hOut
      err <- BS.hGetContents hErr
      ec  <- waitForProcess ph
      let !_ = BS.length out
          !_ = BS.length err
      pure (ec, out, err)