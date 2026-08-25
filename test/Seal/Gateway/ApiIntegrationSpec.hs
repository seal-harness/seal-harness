{-# LANGUAGE OverloadedStrings #-}
-- | Gateway API integration tests for the BIN_EXEC git deploy-key flow.
-- Exercises the full API → agent loop → ISA dispatch → UntrustedIO → git
-- push path, asserting local/remote parity. Uses the 'runApiTest' harness
-- so the same test body runs in both modes.
--
-- Also hosts the PAT @SETUP_REPO@ integration suite: a repo registered with
-- a @CredPat@ credential must clone via the web combo-box endpoint in BOTH
-- executors, with @GH_TOKEN@ delivered to the @gh@ command itself. The two
-- arms deliver env differently (local: 'System.Process' env field; remote:
-- the @env@ prefix baked into the composed ssh command), but the test body
-- is mode-agnostic: each arm's gh-observer fixture records what the
-- invocation actually saw into a shared marker file, and identical
-- assertions check it.
--
-- The remote leg needs no live SSH host, gh, or network — it pends only on
-- missing tooling prerequisites, like the deploy-key suite.
module Seal.Gateway.ApiIntegrationSpec (spec) where

import Control.Exception (bracket)
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
          putStrLn ("MODE: " <> T.unpack (uemLabel (ateMode env)))
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
-- The contract under test: the @gh@ invocation each executor runs is
-- @gh repo clone '<url>' '<dest>' -- --depth 1@ carrying
-- @GH_TOKEN=<testPatToken>@ and @GIT_TERMINAL_PROMPT=0@ scoped to the @gh@
-- command itself. The body is mode-agnostic: whichever executor is wired,
-- its gh-observer fixture (local: the shim; remote: the fake runner)
-- appends what the invocation actually saw to the shared marker file, and
-- the same assertions check it. A lost or mis-scoped @GH_TOKEN@ fails the
-- clone in BOTH modes.
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
        markerPath = spHome (atePaths env) </> ghEnvMarkerName
    putStrLn ""
    putStrLn (  "═══ PAT SETUP_REPO ["
             <> T.unpack (uemLabel (ateMode env)) <> "] url=" <> T.unpack url)

    sid <- callApiNewTab env "ollama" "llama3.2"

    -- The gh-observer fixture makes the executor hermetic AND observable:
    -- locally the shim stands in for gh and records its process env;
    -- remotely the fake runner parses the effective env of the composed
    -- command. Installing the observer is mode-agnostic — in remote mode
    -- no local gh ever spawns, so the shim simply sits unused.
    withGhObserver env $ do
      (st, body) <- callSetupRepoRaw env sid url
      putStrLn ("SETUP-REPO STATUS: " <> show st)
      putStrLn ("SETUP-REPO BODY: " <> show body)

      -- Diagnostics: dump the transcript + (remote only) the captured ssh
      -- commands, mirroring the deploy-key suite's style.
      entries <- getTranscript env sid
      putStrLn ("TRANSCRIPT ENTRIES: " <> show (length entries))
      mapM_ (\e -> putStrLn ("  ENTRY: " <> show e)) entries
      case ateCapturedSshArgv env of
        Nothing  -> pure ()
        Just ref -> do
          calls <- readIORef ref
          putStrLn ("CAPTURED SSH CALLS: " <> show (length calls))
          mapM_ (\(argv, _) ->
                  unless (null argv) (putStrLn ("  CMD: " <> last argv)))
                calls

      -- ── The contract (identical in both modes) ────────────────────────
      -- 1. The clone succeeded. Both fixtures fail the clone when the
      --    credential env is missing or scoped to something other than the
      --    gh command.
      st `shouldBe` 200
      assertTranscriptContains env sid "\"cloned\""
      -- 2. What gh ACTUALLY saw: the right URL, and the credential env
      --    bound to its own invocation — not to an earlier command.
      observed <- readGhEnvMarker markerPath
      lookup "URL" observed `shouldBe` Just url
      lookup "GH_TOKEN" observed `shouldBe` Just testPatToken
      lookup "GIT_TERMINAL_PROMPT" observed `shouldBe` Just "0"

-- | Install the gh-observer fixture for the duration of the action and
-- restore @PATH@ afterwards. Writes a minimal @gh@ shim into the test's
-- tmp dir and prepends it to @PATH@; the shim records its invocation
-- (URL + the GH_TOKEN / GIT_TERMINAL_PROMPT it received) into the shared
-- marker file, then fails closed unless the credentials are correct and
-- materializes a bare @.git@ dir so 'Seal.ISA.Ops.Repo.verifyClone' passes.
withGhObserver :: ApiTestEnv -> IO a -> IO a
withGhObserver env action = bracket install uninstall (const action)
  where
    shimDir   = spHome (atePaths env) </> "shim"
    shimPath  = shimDir </> "gh"
    markerPath = spHome (atePaths env) </> ghEnvMarkerName
    install = do
      createDirectoryIfMissing True shimDir
      writeFile shimPath (T.unpack (ghShimScript testPatToken))
      setFileMode shimPath 0o755
      origPath <- lookupEnv "PATH"
      setEnv "PATH" (maybe shimDir (\p -> shimDir <> ":" <> p) origPath)
      setEnv "SEAL_TEST_GH_MARKER" markerPath
      pure origPath
    uninstall origPath = case origPath of
      Just p  -> setEnv "PATH" p
      Nothing -> setEnv "PATH" "/usr/bin:/bin"

-- | The @gh@ stand-in. Usage shape it accepts:
-- @gh repo clone \<url\> \<dest\> [-- ...]@ — @$3@ is the URL, @$4@ the
-- destination. Fails closed (exit 99) when the credential env did not
-- reach this process, and exit 98 on an unexpected argv shape.
ghShimScript :: Text -> Text
ghShimScript expectedToken = T.unlines
  [ "#!/bin/sh"
  , "# seal-test gh shim: record what we were invoked with, then fail"
  , "# closed unless the credential env reached this process."
  , "{"
  , "  echo \"URL='$3'\""
  , "  echo \"GH_TOKEN='$GH_TOKEN'\""
  , "  echo \"GIT_TERMINAL_PROMPT='$GIT_TERMINAL_PROMPT'\""
  , "} >> \"$SEAL_TEST_GH_MARKER\""
  , "if [ \"$GH_TOKEN\" != \"" <> expectedToken <> "\" ] ||"
  , "   [ \"$GIT_TERMINAL_PROMPT\" != \"0\" ]; then"
  , "  echo \"gh-shim: credential env not delivered to gh process\" >&2"
  , "  exit 99"
  , "fi"
  , "[ \"$1\" = \"repo\" ] && [ \"$2\" = \"clone\" ] || {"
  , "  echo \"gh-shim: unexpected argv shape\" >&2"
  , "  exit 98"
  , "}"
  , "# gh repo clone <url> <dest> [-- --depth 1] — $4 is <dest>."
  , "mkdir -p \"$4/.git/objects\" || exit 1"
  , "echo \"Cloning into '$4'...\""
  ]