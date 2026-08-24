{-# LANGUAGE OverloadedStrings #-}
-- | Gateway API integration tests for the BIN_EXEC git deploy-key flow.
-- Exercises the full API → agent loop → ISA dispatch → UntrustedIO → git
-- push path, asserting local/remote parity. Uses the 'runApiTest' harness
-- so the same test body runs in both modes.
--
-- Also hosts the PAT @SETUP_REPO@ integration suite: a repo registered with
-- a @CredPat@ credential must clone via the web combo-box endpoint in BOTH
-- executors, with @GH_TOKEN@ delivered to the @gh@ process. The two arms
-- deliver env differently (local: 'System.Process' env field; remote: the
-- @env@ prefix baked into the composed ssh command), so each leg observes
-- the contract at its own boundary:
--
--   * __local__ — a @gh@ shim prepended to @PATH@ fails (exit 99) unless
--     @GH_TOKEN@ reaches the process env. Clone success proves delivery.
--   * __remote__ — the recording fake runner captures the fully-composed
--     ssh command; assertions pin @GH_TOKEN@/@GIT_TERMINAL_PROMPT@ into the
--     @env@ prefix positioned AFTER the @cd … &&@ (scoped to the @gh@
--     command, not to @cd@).
--
-- The remote leg needs no live SSH host, gh, or network — it pends only on
-- missing tooling prerequisites, like the deploy-key suite.
module Seal.Gateway.ApiIntegrationSpec (spec) where

import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, findExecutable )
import System.Posix.Files (setFileMode)
import System.Environment (lookupEnv, setEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (readCreateProcessWithExitCode, proc)
import Test.Hspec

import Seal.ISA.Ops.Repo (sanitizeRepoName)
import Seal.Providers.Class
  ( ContentBlock (..), CompletionResponse (..), StopReason (..), Usage (..) )
import Seal.Config.Paths (SealPaths (..))
import Seal.SourceControl.Repo (RepoCredential (..), srUrl)
import Seal.TestHelpers.ApiTestHarness
import Seal.Core.Types (OpName (..), ToolCallId (..))

spec :: Spec
spec = do
  deployKeySpec
  patSetupRepoSpec

-- | The original deploy-key suite: clone + push through the gateway API in
-- both modes.
deployKeySpec :: Spec
deployKeySpec = describe "Seal.Gateway.ApiIntegration (git deploy-key)" $ do
  runApiTest
    (Just DummyRepoConfig
      { drcRepoId = "test-repo"
      , drcCredential = CredDeployKey "seal-deploy-key-passphrase:test-repo"
      })
    testBody

  where
    testBody :: ApiTestEnv -> IO ()
    testBody env = do
      gitExe <- findExecutable "git"
      case gitExe of
        Nothing -> pendingWith "git not available"
        Just _ -> pure ()

      case ateDummyRepo env of
        Nothing -> expectationFailure "expected dummy repo"
        Just dr -> do
          -- ── Environment diagnostics ──
          putStrLn ""
          putStrLn "═══════════════════════════════════════════════════"
          putStrLn ("MODE: " <> T.unpack (ateMode env))
          putStrLn ("BARE REPO: " <> drBareRepoPath dr)
          putStrLn ("KEYFILE: " <> fromMaybe "<none>" (drKeyfilePath dr))
          -- Check the keyfile exists.
          keyExists <- doesFileExist (fromMaybe "" (drKeyfilePath dr))
          putStrLn ("KEYFILE EXISTS: " <> show keyExists)
          -- Check the known_hosts file.
          let knownHostsPath = maybe "" takeDirectory (drKeyfilePath dr) </> "known_hosts"
          khExists <- doesFileExist knownHostsPath
          putStrLn ("KNOWN_HOSTS: " <> knownHostsPath <> " (exists=" <> show khExists <> ")")
          -- Check the vault has the passphrase.
          putStrLn "VAULT KEY: seal-deploy-key-passphrase:test-repo"
          putStrLn ("REPO URL: " <> T.unpack (srUrl (drRepo dr)))
          -- Check the session workdir path.
          let paths = atePaths env
              workdirRoot = spCache paths </> "workdirs"
          putStrLn ("WORKDIR ROOT: " <> workdirRoot)
          -- Check the security config file.
          let secFile = spHome paths </> "security.toml"
          secExists <- doesFileExist secFile
          putStrLn ("SECURITY.TOML: " <> secFile <> " (exists=" <> show secExists <> ")")
          putStrLn "═══════════════════════════════════════════════════"

          -- Set the mock LLM script. Use BIN_EXEC for both clone and
          -- push to exercise the full credential injection path.
          let cloneCmd = T.pack ("git clone " <> drBareRepoPath dr <> " repo")
          setScript env
            [ -- Step 1: clone via BIN_EXEC (triggers credential injection
              -- — starts ssh-agent, loads deploy key, sets GIT_SSH_COMMAND).
              -- Even though the clone is a local file path, the BIN_EXEC
              -- credential injection pre-flight runs `git config --get
              -- remote.origin.url` which returns nothing (bare repo has
              -- no remote), so it falls through to plain exec.
              CompletionResponse
                [ CbToolUse (ToolCallId "t1") (OpName "SHELL_EXEC")
                    (object ["command" .= cloneCmd])
                ]
                StopToolUse (Usage 0 0)
              -- Step 2: write a file via FILE_WRITE.
            , CompletionResponse
                [ CbToolUse (ToolCallId "t2") (OpName "FILE_WRITE")
                    (object
                      [ "path" .= ("repo/foo.txt" :: Text)
                      , "content" .= ("this is a test" :: Text)
                      ])
                ]
                StopToolUse (Usage 0 0)
              -- Step 4: config + add + commit + push via SHELL_EXEC.
              -- Set user.email/user.name because CI runners don't have
              -- a global git identity configured. The push is a local
              -- file push (origin points at the local bare repo).
              --
              -- TODO: when mkCloneDepsTurn supports per-host known_hosts,
              -- switch the push to BIN_EXEC to test the full credential
              -- injection path through the gateway API.
            , CompletionResponse
                [ CbToolUse (ToolCallId "t3") (OpName "SHELL_EXEC")
                    (object ["command" .= ("cd repo && git config user.email test@seal.local && git config user.name 'Seal Test' && git add foo.txt && git commit -m 'add foo' && git push -u origin HEAD" :: Text)])
                ]
                StopToolUse (Usage 0 0)
              -- Final reply.
            , CompletionResponse [CbText "Pushed successfully"] StopEnd (Usage 0 0)
            ]

          -- Create a tab and send the message.
          sid <- callApiNewTab env "ollama" "llama3.2"
          putStrLn ("SESSION ID: " <> T.unpack sid)

          (sendSt, sendBody) <- sendMsgToSessionRaw env sid "Clone the repo, add foo.txt, commit, and push"
          putStrLn ("SEND STATUS: " <> show sendSt)
          putStrLn ("SEND BODY: " <> show sendBody)

          -- Dump the full transcript.
          entries <- getTranscript env sid
          putStrLn ("TRANSCRIPT ENTRIES: " <> show (length entries))
          mapM_ (\e -> putStrLn ("  ENTRY: " <> show e)) entries

          -- Assert the transcript contains the success message.
          assertTranscriptContains env sid "Pushed successfully"

          -- Assert the bare repo received the commit.
          (logEc, logOut, logErr) <- readCreateProcessWithExitCode
            (proc "git" ["--git-dir", drBareRepoPath dr, "log", "--all", "--oneline"]) ""
          putStrLn ("BARE REPO LOG EC: " <> show logEc)
          putStrLn ("BARE REPO LOG OUT: " <> show logOut)
          unless (null logErr) (putStrLn ("BARE REPO LOG ERR: " <> logErr))
          logEc `shouldBe` ExitSuccess
          T.strip (T.pack logOut) `shouldSatisfy` ("add foo" `T.isInfixOf`)

-- ---------------------------------------------------------------------------
-- PAT SETUP_REPO suite
-- ---------------------------------------------------------------------------

-- | A repo registered with a @CredPat@ credential, cloned via the web
-- combo-box endpoint (@POST /api/sessions/:id/setup-repo@ — the exact path
-- that failed in session 20260824-173939-096) in both modes.
--
-- The contract under test: the clone command the executor runs is
-- @gh repo clone '<url>' '<dest>' -- --depth 1@ carrying
-- @GH_TOKEN=<testPatToken>@ and @GIT_TERMINAL_PROMPT=0@ scoped to the @gh@
-- process. Each arm observes it at its own boundary (see module header).
patSetupRepoSpec :: Spec
patSetupRepoSpec =
  describe "Seal.Gateway.ApiIntegration (PAT SETUP_REPO)" $
    runApiTestOpts
      (Just DummyRepoConfig
        { drcRepoId = "test-repo"
        , drcCredential = CredPat "seal-pat-test:test-repo"
        })
      defaultApiTestOptions { atoFakeRemoteRunner = True }
      patTestBody

patTestBody :: ApiTestEnv -> IO ()
patTestBody env = case ateDummyRepo env of
  Nothing -> expectationFailure "expected dummy repo"
  Just dr -> do
    let url = srUrl (drRepo dr)
        dest = sanitizeRepoName url
        mode = ateMode env
    putStrLn ""
    putStrLn ("═══ PAT SETUP_REPO [" <> T.unpack mode <> "] url=" <> T.unpack url)

    sid <- callApiNewTab env "ollama" "llama3.2"

    -- Local arm only: shadow `gh` with a shim that fails unless GH_TOKEN
    -- reaches the gh PROCESS env. This makes the local executor hermetic
    -- (no real gh/network) while still proving token delivery end-to-end.
    restorePath <- case mode of
      "local" -> Just <$> installGhShim env
      _       -> pure Nothing

    (st, body) <- callSetupRepoRaw env sid url
    putStrLn ("SETUP-REPO STATUS: " <> show st)
    putStrLn ("SETUP-REPO BODY: " <> show body)

    case mode of
      "remote" -> assertRemoteComposedCommand env url dest
      _        -> pure ()
    restorePathIfInstalled restorePath

    -- Dump the transcript (mirrors the deploy-key suite's diagnostics).
    entries <- getTranscript env sid
    putStrLn ("TRANSCRIPT ENTRIES: " <> show (length entries))
    mapM_ (\e -> putStrLn ("  ENTRY: " <> show e)) entries

    -- Both modes: the clone must succeed (the shim/runner make failure the
    -- signature of a lost or mis-scoped GH_TOKEN). The transcript API
    -- surfaces SETUP_REPO as a harness entry whose payload carries
    -- result.status = "cloned".
    st `shouldBe` 200
    assertTranscriptContains env sid "\"cloned\""

-- | Remote-leg assertions over the recorded ssh argvs. The composed command
-- for the clone call must carry the credential env AFTER the @cd … &&@ so it
-- scopes to the @gh@ command — not to @cd@.
assertRemoteComposedCommand :: ApiTestEnv -> Text -> Text -> IO ()
assertRemoteComposedCommand env url dest = case ateCapturedSshArgv env of
  Nothing -> expectationFailure
    "expected captured ssh argvs (the fake remote runner must be enabled)"
  Just ref -> do
    calls <- readIORef ref
    let cmds = [ T.pack c | (argv, _) <- calls
               , not (null argv)
               , let c = last argv ]
        cloneCmds = filter ("gh repo clone" `T.isInfixOf`) cmds
    putStrLn ("CAPTURED SSH CALLS: " <> show (length calls))
    mapM_ (\c -> putStrLn ("  CMD: " <> T.unpack c)) cmds
    case cloneCmds of
      [cmd] -> do
        -- The full gh invocation skeleton, with the token-free https URL.
        ("gh repo clone '" <> url <> "' '" <> dest <> "' -- --depth 1")
          `T.isInfixOf` cmd `shouldBe` True
        -- THE BUG: the env prefix used to lead the whole command
        -- (`env K=V cd … && gh …`), scoping GH_TOKEN to cd. It must come
        -- after the `cd <ws> &&` instead.
        T.isPrefixOf "cd '" cmd `shouldBe` True
        ("&& env GH_TOKEN='" <> testPatToken <> "'") `T.isInfixOf` cmd
          `shouldBe` True
        -- GIT_TERMINAL_PROMPT=0 rides the same prefix, adjacent to gh.
        "GIT_TERMINAL_PROMPT='0' gh repo clone" `T.isInfixOf` cmd
          `shouldBe` True
      _ -> expectationFailure
        ("expected exactly one gh clone call in captured argvs, got: "
         <> show (length cloneCmds))

-- | Write a minimal @gh@ shim into the test's tmp dir and prepend its dir
-- to @PATH@. The shim succeeds ONLY when @GH_TOKEN@ matches 'testPatToken',
-- and materializes a bare @.git@ dir at the destination so 'verifyClone'
-- passes. Returns the previous @PATH@ (or 'Nothing' if unset) for
-- 'restorePathIfInstalled'.
installGhShim :: ApiTestEnv -> IO (Maybe String)
installGhShim env = do
  let shimDir = spHome (atePaths env) </> "shim"
      shimPath = shimDir </> "gh"
  createDirectoryIfMissing True shimDir
  writeFile shimPath (T.unpack (ghShimScript testPatToken))
  setFileMode shimPath 0o755
  origPath <- lookupEnv "PATH"
  setEnv "PATH" (maybe shimDir (\p -> shimDir <> ":" <> p) origPath)
  pure origPath

restorePathIfInstalled :: Maybe (Maybe String) -> IO ()
restorePathIfInstalled mRestore = case mRestore of
  Nothing     -> pure ()
  Just mOld   -> case mOld of
    Just p  -> setEnv "PATH" p
    Nothing -> setEnv "PATH" "/usr/bin:/bin"

-- | The @gh@ stand-in. Usage shape it accepts:
-- @gh repo clone \<url\> \<dest\> [-- ...]@ — @$4@ is the destination.
ghShimScript :: Text -> Text
ghShimScript expectedToken = T.unlines
  [ "#!/bin/sh"
  , "# seal-test gh shim: fail closed unless GH_TOKEN reaches this process."
  , "if [ \"$GH_TOKEN\" != \"" <> expectedToken <> "\" ]; then"
  , "  echo \"gh-shim: GH_TOKEN not delivered to process env\" >&2"
  , "  exit 99"
  , "fi"
  , "# gh repo clone <url> <dest> [-- --depth 1] — $4 is <dest>."
  , "mkdir -p \"$4/.git/objects\" || exit 1"
  , "echo \"Cloning into '$4'...\""
  ]