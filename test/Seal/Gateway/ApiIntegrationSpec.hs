{-# LANGUAGE OverloadedStrings #-}
-- | Gateway API integration tests for the BIN_EXEC git deploy-key flow.
-- Exercises the full API → agent loop → ISA dispatch → UntrustedIO → git
-- push path, asserting local/remote parity. Uses the 'runApiTest' harness
-- so the same test body runs in both modes.
module Seal.Gateway.ApiIntegrationSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.Process (readCreateProcessWithExitCode, proc)
import Test.Hspec

import Seal.Providers.Class
  ( ContentBlock (..), CompletionResponse (..), StopReason (..), Usage (..) )
import Seal.SourceControl.Repo (RepoCredential (..))
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
          -- Set the mock LLM script dynamically (the clone URL depends
          -- on the dummy repo's temp path, which is only known at
          -- runtime).
          let cloneUrl = T.pack ("git clone " <> drBareRepoPath dr <> " repo")
          setScript env
            [ -- Step 1: clone the repo via SHELL_EXEC.
              CompletionResponse
                [ CbToolUse (ToolCallId "t1") (OpName "SHELL_EXEC")
                    (object ["command" .= cloneUrl])
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
              -- Step 3: git add + commit via SHELL_EXEC.
            , CompletionResponse
                [ CbToolUse (ToolCallId "t3") (OpName "SHELL_EXEC")
                    (object ["command" .= ("cd repo && git add foo.txt && git commit -m 'add foo'" :: Text)])
                ]
                StopToolUse (Usage 0 0)
              -- Step 4: git push via BIN_EXEC (exercises the deploy-key
              -- credential injection path).
            , CompletionResponse
                [ CbToolUse (ToolCallId "t4") (OpName "BIN_EXEC")
                    (object
                      [ "binary" .= ("git" :: Text)
                      , "args" .= (["-C", "repo", "push", "-u", "origin", "HEAD"] :: [Text])
                      ])
                ]
                StopToolUse (Usage 0 0)
              -- Final reply.
            , CompletionResponse [CbText "Pushed successfully"] StopEnd (Usage 0 0)
            ]

          -- Create a tab and send the message.
          sid <- callApiNewTab env "ollama" "llama3.2"
          sendMsgToSession env sid "Clone the repo, add foo.txt, commit, and push"

          -- Assert the transcript contains the success message.
          assertTranscriptContains env sid "Pushed successfully"

          -- Assert the bare repo received the commit.
          (logEc, logOut, _) <- readCreateProcessWithExitCode
            (proc "git" ["--git-dir", drBareRepoPath dr, "log", "--all", "--oneline"]) ""
          logEc `shouldBe` ExitSuccess
          T.strip (T.pack logOut) `shouldSatisfy` ("add foo" `T.isInfixOf`)