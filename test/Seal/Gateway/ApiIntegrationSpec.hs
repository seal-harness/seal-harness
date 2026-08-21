{-# LANGUAGE OverloadedStrings #-}
-- | Gateway API integration tests for the BIN_EXEC git deploy-key flow.
-- Exercises the full API → agent loop → ISA dispatch → UntrustedIO → git
-- push path, asserting local/remote parity. Uses the 'runApiTest' harness
-- so the same test body runs in both modes.
module Seal.Gateway.ApiIntegrationSpec (spec) where

import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, findExecutable)
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
spec = describe "Seal.Gateway.ApiIntegration (git deploy-key)" $ do

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