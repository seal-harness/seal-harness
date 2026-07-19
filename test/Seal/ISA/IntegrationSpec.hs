{-# LANGUAGE OverloadedStrings #-}
-- | High-level integration tests for every ISA opcode.
--
-- Each test is a small "prompt" (the test description) that would trigger the
-- use of a tool call, the simulated LLM response emitting the matching
-- 'CbToolUse' (we cannot call a real LLM in CI), and the actual 'dispatch'
-- integration seam running the opcode end-to-end (authorize gate →
-- ACK-before-execute → run → 'OpResult'). Assertions cover both the returned
-- 'OpResult' and the real side effects materialized in the backends (files on
-- disk, memories in the store, agents in the runtime, etc.).
--
-- One test drives a full 'runTurn' round-trip through a scripted provider to
-- prove the prompt → tool-call → dispatch → final-answer loop works
-- end-to-end; the rest exercise 'dispatch' directly (the same integration
-- boundary 'runTurn' itself calls), which keeps them deterministic and focused
-- on each opcode's contract.
module Seal.ISA.IntegrationSpec (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend qualified as AgentDefBackend
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Delegation
  ( ChildWorkerOutcome (..), ChildExitReason (..)
  , defaultDelegationConfig, newSpawnPauseFlag )
import Seal.Agent.Runtime.Registry
  (newAgentRuntime)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..), ToolCallId (..),
                        mkSessionId)
import Seal.Handles.AskReply (newApprovalCache)
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.Handles.Harness (HarnessError (..))
import Seal.Harness.Id (harnessIdToText, newHarnessId)
import Seal.Harness.Registry
  (HarnessEntry (..), HarnessOrigin (..), Liveness (..), insert, newHarnessRegistry,
   snapshot)
import Seal.Harness.Tmux (TmuxRunner (..), mkTmuxIdent)
import Seal.ISA.Dispatch (DispatchError (..), dispatch)
import Seal.ISA.Opcode (OpResult (..), localBackend)
import Seal.ISA.Ops.Agent
import Seal.ISA.Ops.Bin
import Seal.ISA.Ops.File
import Seal.ISA.Ops.Harness
import Seal.ISA.Ops.Human
import Seal.ISA.Ops.Memory
import Seal.ISA.Ops.Process
import Seal.ISA.Ops.Search
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Ops.Shell
import Seal.ISA.Ops.Skills
import Seal.ISA.Registry qualified as Registry
import Seal.Media.Image (imageDescribeOp, imageGenerateOp, noImageProvider)
import Seal.Media.Tts (noTtsProvider, textToSpeechOp)
import Seal.Memory.Backend qualified as MemoryBackend
import Seal.Memory.Types (meContent)
import Seal.Providers.Class
  (CompletionResponse (..), ContentBlock (..), Provider (..), SomeProvider (..),
   StopReason (..), ToolResultPart (..), Usage (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (AutonomyLevel (..), SecurityPolicy (..))
import Seal.Security.Vault (UnlockMode (..), VaultConfig (..), openVault, vhInit,
                            vhPut, vhUnlock)
import Seal.Security.Vault.Age (mkMockEncryptor)
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Skills.Backend qualified as SkillBackend
import Seal.Skills.Types (skBody)
import Seal.Text.LineFile (maxScanBytes)
import Seal.Tools.Args (textShellCommand)
import Seal.Tools.Exec.Local (mkLocalExecHandleFromFns)
import Seal.Tools.Exec.Types (ExecBackend (..), ExecError (..),
                              mkLocalExecHandlePlaceholder)
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Web.Browser (browserClickOp, browserOpenOp, browserReadOp,
                         noBrowserDriver)
import Seal.Web.Fetch (WebFetchConfig (..), webFetchOp)
import Seal.Web.Search (WebSearchConfig (..), webSearchOp)

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A scripted provider that pops 'CompletionResponse's from an IORef.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x : xs) -> writeIORef ref xs >> pure (Right x)
      []       -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

-- | A 'ChannelCaps' that records sends into an IORef and returns "yes" on prompt.
recordCaps :: IORef [Text] -> ChannelCaps
recordCaps sent = ChannelCaps
  { ccSend        = \t -> modifyIORef' sent (++ [t])
  , ccPrompt      = \_ -> pure "yes"
  , ccPromptSecret = \_ -> pure ""
  }

-- | Dispatch a single opcode through the full integration seam (authorize →
-- ACK/async transcript record → run). Each call gets a fresh in-memory
-- transcript, so tests are isolated. Uses the placeholder 'ExecBackend'
-- (fail-closed); tests that need a fake executor use 'dispatchOneWith'.
dispatchOne :: Registry.Registry -> OpName -> Value
            -> App (Either DispatchError OpResult)
dispatchOne reg = dispatchOneWith reg (EbLocal mkLocalExecHandlePlaceholder)

-- | Like 'dispatchOne' but with an explicit 'ExecBackend' (for Untrusted
-- opcodes that need a fake executor returning canned output).
dispatchOneWith :: Registry.Registry -> ExecBackend -> OpName -> Value
               -> App (Either DispatchError OpResult)
dispatchOneWith reg execBackend name input = do
  (h, _) <- liftIO fakeTwoFileTranscript
  dispatch reg h localBackend execBackend name input

right :: Show e => Either e a -> a
right (Right x) = x
right (Left e)  = error ("expected Right, got Left: " <> show e)

sid :: SessionId
sid = either (error "sid") id (mkSessionId "s1")

-- | A fake 'ExecBackend' that returns canned stdout and writes the recorded
-- command into the given IORef. For tests that don't inspect the recorded
-- command, pass a throwaway IORef (created with @newIORef []@).
fakeBackend :: IORef [Text] -> Text -> ExecBackend
fakeBackend seen canned =
  EbLocal (mkLocalExecHandleFromFns shellFn progFn)
  where
    shellFn cmd _cwd = do
      modifyIORef' seen (++ [textShellCommand cmd])
      pure (Right canned)
    progFn _ _ = pure (Right canned)

-- | A fail-closed 'ExecBackend' (every call returns 'ExecNotImplemented').
failBackend :: ExecBackend
failBackend = EbLocal (mkLocalExecHandleFromFns
                       (\_ _ -> pure (Left ExecNotImplemented))
                       (\_ _ -> pure (Left ExecNotImplemented)))

-- | A fake 'TmuxRunner' that records argv and returns scripted stdout (LIFO).
mkFakeRunner :: [Text] -> IO (TmuxRunner, IO [[String]])
mkFakeRunner scripted = do
  queueRef <- newIORef scripted
  argsRef  <- newIORef []
  let runner = TmuxRunner $ \argv -> do
        modifyIORef' argsRef (argv :)
        qs <- readIORef queueRef
        case qs of
          []     -> pure (Right "")
          (q:rest) -> do
            writeIORef queueRef rest
            if q == "__EXIT__127__"
              then pure (Left HeTmuxMissing)
              else pure (Right q)
      getArgs = reverse <$> readIORef argsRef
  pure (runner, getArgs)

-- ---------------------------------------------------------------------------
-- The spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.ISA.Integration" $ do

  -- ----------------------------------------------------------------------
  -- FILE_READ
  -- ----------------------------------------------------------------------
  describe "FILE_READ" $ do
    it "\"Read the file notes.txt and show me what's in it.\" -> FILE_READ -> file contents returned" $
      withSystemTempDirectory "seal-int" $ \root -> do
        BS.writeFile (root </> "notes.txt") "hello world"
        let op = fileReadOp (WorkspaceRoot root) maxScanBytes
            reg = Registry.mkRegistry [op]
        r <- runTestApp (dispatchOne reg (OpName "FILE_READ")
                          (object ["path" .= ("notes.txt" :: Text)]))
        case r of
          Right res -> do
            orIsError res `shouldBe` False
            case orParts res of
              [TrpText t] -> "hello world" `T.isInfixOf` t `shouldBe` True
              _          -> expectationFailure "expected a single text part"
          Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"end-to-end: read notes.txt\" -> runTurn -> final text contains the file contents" $
      withSystemTempDirectory "seal-int-e2e" $ \root -> do
        approvals <- newApprovalCache
        BS.writeFile (root </> "notes.txt") "hello world"
        sent <- newIORef []
        let caps = recordCaps sent
            op = fileReadOp (WorkspaceRoot root) maxScanBytes
            reg = Registry.mkRegistry [op]
            script =
              [ CompletionResponse
                  [ CbToolUse (ToolCallId "t1") (OpName "FILE_READ")
                      (object ["path" .= ("notes.txt" :: Text)]) ]
                  StopToolUse (Usage 0 0)
              , CompletionResponse [CbText "the file says: hello world"] StopEnd (Usage 0 0)
              ]
        ref <- newIORef script
        (h, _) <- fakeTwoFileTranscript
        let env = AgentEnv
                    (SomeProvider (ScriptProvider ref))
                    "ollama" (ModelId "m") Nothing reg h localBackend
                    (EbLocal mkLocalExecHandlePlaceholder) caps sid 8 Nothing Full approvals Nothing (pure ()) False
        runTestApp (runTurn env "Read the file notes.txt and show me what's in it.")
        sent' <- readIORef sent
        sent' `shouldSatisfy` any ("hello world" `T.isInfixOf`)

  -- ----------------------------------------------------------------------
  -- FILE_WRITE
  -- ----------------------------------------------------------------------
  describe "FILE_WRITE" $ do
    it "\"Create a todo file with the line 'buy milk'.\" -> FILE_WRITE -> file on disk has the content" $
      withSystemTempDirectory "seal-int" $ \root -> do
        let op = fileWriteOp (WorkspaceRoot root) 65536
            reg = Registry.mkRegistry [op]
        r <- runTestApp (dispatchOne reg (OpName "FILE_WRITE")
                          (object [ "path" .= ("todo.txt" :: Text)
                                  , "content" .= ("buy milk" :: Text) ]))
        case r of
          Right res -> do
            orIsError res `shouldBe` False
            bs <- BS.readFile (root </> "todo.txt")
            bs `shouldBe` "buy milk"
          Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- FILE_PATCH
  -- ----------------------------------------------------------------------
  describe "FILE_PATCH" $ do
    it "\"Replace 'foo' with 'bar' in code.txt.\" -> FILE_PATCH -> file patched in place" $
      withSystemTempDirectory "seal-int" $ \root -> do
        BS.writeFile (root </> "code.txt") "foo\nbaz\n"
        let op = filePatchOp (WorkspaceRoot root)
            reg = Registry.mkRegistry [op]
            patch = "--- a/code.txt\n+++ b/code.txt\n@@ -1,1 +1,1 @@\n-foo\n+bar\n"
        r <- runTestApp (dispatchOne reg (OpName "FILE_PATCH")
                          (object [ "path" .= ("code.txt" :: Text)
                                  , "patch" .= (patch :: Text) ]))
        case r of
          Right res -> do
            orIsError res `shouldBe` False
            bs <- BS.readFile (root </> "code.txt")
            bs `shouldBe` "bar\nbaz\n"
          Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Model sent 'diff' key instead of 'patch'.\" -> FILE_PATCH -> accepted via 'diff' alias, file patched" $
      withSystemTempDirectory "seal-int" $ \root -> do
        BS.writeFile (root </> "code.txt") "foo\nbaz\n"
        let op = filePatchOp (WorkspaceRoot root)
            reg = Registry.mkRegistry [op]
            wrongDiff = "--- a/code.txt\n+++ b/code.txt\n@@ -1,1 +1,1 @@\n-foo\n+bar\n"
        r <- runTestApp (dispatchOne reg (OpName "FILE_PATCH")
                          (object [ "path" .= ("code.txt" :: Text)
                                  , "diff" .= (wrongDiff :: Text) ]))
        case r of
          Right res -> do
            orIsError res `shouldBe` False
            bs <- BS.readFile (root </> "code.txt")
            bs `shouldBe` "bar\nbaz\n"
          Left e -> expectationFailure ("expected dispatch to succeed via 'diff' alias, got " <> show e)

  -- ----------------------------------------------------------------------
  -- SHELL_EXEC
  -- ----------------------------------------------------------------------
  describe "SHELL_EXEC" $ do
    it "\"Run 'echo hello' in the shell.\" -> SHELL_EXEC -> stdout returned" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "hello\n"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg backend (OpName "SHELL_EXEC")
                        (object ["command" .= ("echo hello" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "hello\n"]
          readIORef seen `shouldReturn` ["echo hello"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Run a command.\" -> SHELL_EXEC under a Deny policy -> Denied at the gate" $ do
      let op = shellExecOp (WorkspaceRoot "/ws")
                          (SecurityPolicy (AllowOnly mempty) Deny) failBackend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg failBackend (OpName "SHELL_EXEC")
                        (object ["command" .= ("rm -rf /" :: Text)]))
      r `shouldBe` Left (Denied "SHELL_EXEC denied by autonomy policy")

  -- ----------------------------------------------------------------------
  -- BIN_EXEC
  -- ----------------------------------------------------------------------
  describe "BIN_EXEC" $ do
    it "\"Run this Python script: print('hi').\" -> BIN_EXEC -> binary output" $ do
      seen <- newIORef ([] :: [Text])
      let backend = fakeBackend seen "hi\n"
          allowList = Just (Set.fromList ["python3" :: Text])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg backend (OpName "BIN_EXEC")
                        (object [ "binary" .= ("python3" :: Text)
                                , "args" .= (["-c", "print('hi')"] :: [Text]) ]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "hi\n"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Run rm.\" -> BIN_EXEC with non-allow-listed binary -> Denied" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just mempty) failBackend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg failBackend (OpName "BIN_EXEC")
                        (object [ "binary" .= ("rm" :: Text)
                                , "args" .= (["-rf", "/"] :: [Text]) ]))
      r `shouldBe` Left (Denied "BIN_EXEC: binary \"rm\" not in the allow-list")

  -- ----------------------------------------------------------------------
  -- PROCESS_MANAGE
  -- ----------------------------------------------------------------------
  describe "PROCESS_MANAGE" $ do
    it "\"List the running processes.\" -> PROCESS_MANAGE action=list -> ps output returned" $ do
      seen <- newIORef ([] :: [Text])
      let backend = fakeBackend seen "  1 /sbin/init\n 42 /bin/bash\n"
          op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg backend (OpName "PROCESS_MANAGE")
                        (object ["action" .= ("list" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "init" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Kill process -1.\" -> PROCESS_MANAGE pid=-1 -> Denied (validated PID)" $ do
      let op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) failBackend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg failBackend (OpName "PROCESS_MANAGE")
                        (object [ "action" .= ("kill" :: Text)
                                , "pid" .= (-1 :: Int) ]))
      r `shouldBe` Left (Denied "PROCESS_MANAGE: pid must be a positive integer")

  -- ----------------------------------------------------------------------
  -- SEARCH_FILES
  -- ----------------------------------------------------------------------
  describe "SEARCH_FILES" $ do
    it "\"Find every occurrence of 'TODO' under src/.\" -> SEARCH_FILES -> matches returned" $ do
      seen <- newIORef ([] :: [Text])
      let backend = fakeBackend seen "src/Foo.hs:1:TODO fix\nsrc/Bar.hs:3:TODO later\n"
          op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 100 backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg backend (OpName "SEARCH_FILES")
                        (object [ "pattern" .= ("TODO" :: Text)
                                , "path" .= ("src" :: Text) ]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "TODO" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Search for '-x'.\" -> SEARCH_FILES pattern starting with - -> Denied (option injection)" $ do
      let op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 100 failBackend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOneWith reg failBackend (OpName "SEARCH_FILES")
                        (object ["pattern" .= ("-x" :: Text)]))
      r `shouldBe` Left (Denied "SEARCH_FILES: pattern must not start with '-' (option injection)")

  -- ----------------------------------------------------------------------
  -- MEMORY_WRITE / RECALL / DELETE
  -- ----------------------------------------------------------------------
  describe "MEMORY_WRITE" $ do
    it "\"Remember that the user prefers concise answers.\" -> MEMORY_WRITE (create) -> memory in the store" $ do
      backend <- MemoryBackend.noneBackend
      let op = memoryWriteOp backend sid
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "MEMORY_WRITE")
                        (object [ "id" .= ("user-pref" :: Text)
                                , "content" .= ("prefer concise answers" :: Text) ]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "stored"]
          entries <- MemoryBackend.mbList backend
          case entries of
            (e : _) -> meContent e `shouldBe` "prefer concise answers"
            []     -> expectationFailure "expected at least one memory"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Update the 'pref' memory to say 'very concise'.\" -> MEMORY_WRITE (update) -> content changed, provenance preserved" $ do
      backend <- MemoryBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [memoryWriteOp backend sid])
                          (OpName "MEMORY_WRITE")
                          (object [ "id" .= ("pref" :: Text)
                                  , "content" .= ("concise" :: Text) ]))
      let op = memoryWriteOp backend sid
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "MEMORY_WRITE")
                        (object [ "id" .= ("pref" :: Text)
                                , "content" .= ("very concise" :: Text) ]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "updated"]
          entries <- MemoryBackend.mbList backend
          case entries of
            (e : _) -> meContent e `shouldBe` "very concise"
            []     -> expectationFailure "expected at least one memory"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "MEMORY_RECALL" $ do
    it "\"What do you remember about the user?\" -> MEMORY_RECALL -> returns stored memories" $ do
      backend <- MemoryBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [memoryWriteOp backend sid])
                          (OpName "MEMORY_WRITE")
                          (object [ "id" .= ("pref" :: Text)
                                  , "content" .= ("concise" :: Text) ]))
      let op = memoryRecallOp defaultPageParams backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "MEMORY_RECALL") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "concise" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "MEMORY_DELETE" $ do
    it "\"Forget the 'pref' memory.\" -> MEMORY_DELETE -> memory removed" $ do
      backend <- MemoryBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [memoryWriteOp backend sid])
                          (OpName "MEMORY_WRITE")
                          (object [ "id" .= ("pref" :: Text)
                                  , "content" .= ("concise" :: Text) ]))
      let op = memoryDeleteOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "MEMORY_DELETE")
                        (object ["id" .= ("pref" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          entries <- MemoryBackend.mbList backend
          entries `shouldBe` []
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- SKILL_WRITE / READ / LIST / DELETE
  -- ----------------------------------------------------------------------
  describe "SKILL_WRITE" $ do
    it "\"Define a 'greeting' skill that says hello.\" -> SKILL_WRITE (create) -> skill in the store" $ do
      backend <- SkillBackend.noneBackend
      let op = skillWriteOp backend sid
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SKILL_WRITE")
                        (object [ "id" .= ("greeting" :: Text)
                                , "description" .= ("say hello" :: Text)
                                , "body" .= ("say hello warmly" :: Text) ]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "created"]
          skills <- SkillBackend.sbList backend
          case skills of
            (s : _) -> skBody s `shouldBe` "say hello warmly"
            []     -> expectationFailure "expected at least one skill"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Change the 'greeting' skill body to be more formal.\" -> SKILL_WRITE (update) -> body changed" $ do
      backend <- SkillBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [skillWriteOp backend sid])
                          (OpName "SKILL_WRITE")
                          (object [ "id" .= ("greeting" :: Text)
                                  , "description" .= ("say hello" :: Text)
                                  , "body" .= ("hi" :: Text) ]))
      let op = skillWriteOp backend sid
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SKILL_WRITE")
                        (object [ "id" .= ("greeting" :: Text)
                                , "description" .= ("say hello" :: Text)
                                , "body" .= ("greetings, formally" :: Text) ]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "updated"]
          skills <- SkillBackend.sbList backend
          case skills of
            (s : _) -> skBody s `shouldBe` "greetings, formally"
            []     -> expectationFailure "expected at least one skill"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "SKILL_READ" $ do
    it "\"Show me the 'greeting' skill.\" -> SKILL_READ -> skill body returned" $ do
      backend <- SkillBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [skillWriteOp backend sid])
                          (OpName "SKILL_WRITE")
                          (object [ "id" .= ("greeting" :: Text)
                                  , "description" .= ("say hello" :: Text)
                                  , "body" .= ("say hello warmly" :: Text) ]))
      let op = skillReadOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SKILL_READ")
                        (object ["id" .= ("greeting" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "say hello warmly" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "SKILL_LIST" $ do
    it "\"List all my skills.\" -> SKILL_LIST -> ids + descriptions returned" $ do
      backend <- SkillBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [skillWriteOp backend sid])
                          (OpName "SKILL_WRITE")
                          (object [ "id" .= ("a" :: Text)
                                  , "description" .= ("alpha" :: Text)
                                  , "body" .= ("x" :: Text) ]))
      let op = skillListOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SKILL_LIST") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "a: alpha" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "SKILL_DELETE" $ do
    it "\"Delete the 'greeting' skill.\" -> SKILL_DELETE -> skill removed" $ do
      backend <- SkillBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [skillWriteOp backend sid])
                          (OpName "SKILL_WRITE")
                          (object [ "id" .= ("greeting" :: Text)
                                  , "description" .= ("say hello" :: Text)
                                  , "body" .= ("hi" :: Text) ]))
      let op = skillDeleteOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SKILL_DELETE")
                        (object ["id" .= ("greeting" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          skills <- SkillBackend.sbList backend
          skills `shouldBe` []
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Delete a skill that doesn't exist.\" -> SKILL_DELETE -> idempotent" $ do
      backend <- SkillBackend.noneBackend
      let op = skillDeleteOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SKILL_DELETE")
                        (object ["id" .= ("nope" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "not present" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- AGENT_DEF_WRITE / READ / LIST / DELETE
  -- ----------------------------------------------------------------------
  describe "AGENT_DEF_WRITE" $ do
    it "\"Define a 'greeter' agent on ollama/llama3.\" -> AGENT_DEF_WRITE (create) -> def stored" $ do
      backend <- AgentDefBackend.noneBackend
      let op = agentDefWriteOp backend sid
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_WRITE")
                        (object [ "id" .= ("greeter" :: Text)
                                , "name" .= ("Greeter" :: Text)
                                , "provider" .= ("ollama" :: Text)
                                , "model" .= ("llama3" :: Text) ]))
      case r of
        Right res -> orIsError res `shouldBe` False
        Left e    -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Rename the 'greeter' agent to 'Polite Greeter'.\" -> AGENT_DEF_WRITE (update) -> name changed" $ do
      backend <- AgentDefBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [agentDefWriteOp backend sid])
                          (OpName "AGENT_DEF_WRITE")
                          (object [ "id" .= ("greeter" :: Text)
                                  , "name" .= ("old" :: Text)
                                  , "provider" .= ("ollama" :: Text)
                                  , "model" .= ("llama3" :: Text) ]))
      let op = agentDefWriteOp backend sid
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_WRITE")
                        (object [ "id" .= ("greeter" :: Text)
                                , "name" .= ("Polite Greeter" :: Text)
                                , "provider" .= ("ollama" :: Text)
                                , "model" .= ("llama3" :: Text) ]))
      case r of
        Right res -> orIsError res `shouldBe` False
        Left e    -> expectationFailure ("dispatch failed: " <> show e)

  describe "AGENT_DEF_READ" $ do
    it "\"Show me the 'greeter' agent definition.\" -> AGENT_DEF_READ -> def returned" $ do
      backend <- AgentDefBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [agentDefWriteOp backend sid])
                          (OpName "AGENT_DEF_WRITE")
                          (object [ "id" .= ("greeter" :: Text)
                                  , "name" .= ("Greeter" :: Text)
                                  , "provider" .= ("ollama" :: Text)
                                  , "model" .= ("llama3" :: Text) ]))
      let op = agentDefReadOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_READ")
                        (object ["id" .= ("greeter" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "Greeter" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "AGENT_DEF_LIST" $ do
    it "\"List all agent definitions.\" -> AGENT_DEF_LIST -> empty when none defined" $ do
      backend <- AgentDefBackend.noneBackend
      let op = agentDefListOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_LIST") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "(no agent definitions)"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"List all agent definitions.\" -> AGENT_DEF_LIST -> defs with id, name, provider/model" $ do
      backend <- AgentDefBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [agentDefWriteOp backend sid])
                          (OpName "AGENT_DEF_WRITE")
                          (object [ "id" .= ("greeter" :: Text)
                                  , "name" .= ("Greeter" :: Text)
                                  , "provider" .= ("ollama" :: Text)
                                  , "model" .= ("llama3" :: Text) ]))
      let op = agentDefListOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_LIST") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> do
              "greeter: Greeter" `T.isInfixOf` t `shouldBe` True
              "ollama/llama3" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "AGENT_DEF_DELETE" $ do
    it "\"Delete the 'greeter' agent definition.\" -> AGENT_DEF_DELETE -> def removed" $ do
      backend <- AgentDefBackend.noneBackend
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [agentDefWriteOp backend sid])
                          (OpName "AGENT_DEF_WRITE")
                          (object [ "id" .= ("greeter" :: Text)
                                  , "name" .= ("Greeter" :: Text)
                                  , "provider" .= ("ollama" :: Text)
                                  , "model" .= ("llama3" :: Text) ]))
      let op = agentDefDeleteOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_DELETE")
                        (object ["id" .= ("greeter" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          defs <- AgentDefBackend.adbList backend
          defs `shouldBe` []
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Delete a def that doesn't exist.\" -> AGENT_DEF_DELETE -> idempotent" $ do
      backend <- AgentDefBackend.noneBackend
      let op = agentDefDeleteOp backend
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_DEF_DELETE")
                        (object ["id" .= ("nope" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText t] -> "not present" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- AGENT_START / STATUS / INSTANCES / STOP
  -- ----------------------------------------------------------------------
  describe "AGENT_START" $ do
    it "\"Start the 'greeter' agent.\" -> AGENT_START -> runs synchronously and returns a summary" $ do
      backend <- AgentDefBackend.noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (dispatchOne (Registry.mkRegistry [agentDefWriteOp backend sid])
                          (OpName "AGENT_DEF_WRITE")
                          (object [ "id" .= ("greeter" :: Text)
                                  , "name" .= ("g" :: Text)
                                  , "provider" .= ("ollama" :: Text)
                                  , "model" .= ("llama3" :: Text) ]))
      let worker _ _ _ _ = do modifyIORef' ran (+ 1); pure (ChildWorkerOutcome (Just "hi") CerCompleted 0 0 (Just (SessionId "child")))
          wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (SessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = worker
            }
          op = agentStartOp wiring
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_START")
                        (object ["id" .= ("greeter" :: Text), "goal" .= ("say hi" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          -- Synchronous: the worker has already run by the time dispatch returns.
          readIORef ran `shouldReturn` 1
          case orParts res of
            [TrpText t] -> T.isInfixOf "hi" t `shouldBe` True
            _           -> expectationFailure "expected a single text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "AGENT_STATUS" $ do
    it "\"Is the 'greeter' agent running?\" -> AGENT_STATUS -> reports not running when absent" $ do
      rt <- newAgentRuntime
      let op = agentStatusOp rt
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_STATUS")
                        (object ["subagent_id" .= ("sa-greeter-00000001" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "not running"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "AGENT_INSTANCES" $ do
    it "\"List the running agents.\" -> AGENT_INSTANCES -> empty when none running" $ do
      rt <- newAgentRuntime
      let op = agentInstancesOp rt
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_INSTANCES") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "(no agents running)"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "AGENT_STOP" $ do
    it "\"Stop the 'greeter' agent.\" -> AGENT_STOP -> idempotent when not running" $ do
      rt <- newAgentRuntime
      let op = agentStopOp rt
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "AGENT_STOP")
                        (object ["subagent_id" .= ("sa-greeter-00000001" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "stopped"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- SECRET_GET
  -- ----------------------------------------------------------------------
  describe "SECRET_GET" $ do
    it "\"Fetch the 'TOKEN' secret from the vault.\" -> SECRET_GET -> value returned, not in orRecorded" $
      withSystemTempDirectory "seal-int-vault" $ \tmpDir -> do
        let vaultDir = tmpDir </> "config" </> "vault"
            vaultPath = vaultDir </> "vault.age"
            paths = SealPaths
              { spHome = tmpDir
              , spConfig = tmpDir </> "config"
              , spState = tmpDir </> "state"
              , spKeys = tmpDir </> "keys"
              }
        createDirectoryIfMissing True vaultDir
        let vaultCfg = VaultConfig
              { vcPath = vaultPath
              , vcKeyType = "mock"
              , vcUnlock = UnlockOnDemand
              }
        h <- openVault vaultCfg mkMockEncryptor
        _ <- vhInit h
        _ <- vhUnlock h
        _ <- vhPut h "TOKEN" "s3cr3t"
        ref <- newIORef (Just h)
        let rt = VaultRuntime
              { vrPaths = paths
              , vrConfigPath = tmpDir </> "config" </> "config.toml"
              , vrHandleRef = ref
              }
            op = secretGetOp rt
            reg = Registry.mkRegistry [op]
        r <- runTestApp (dispatchOne reg (OpName "SECRET_GET")
                          (object ["name" .= ("TOKEN" :: Text)]))
        case r of
          Right res -> do
            orIsError res `shouldBe` False
            orParts res `shouldBe` [TrpText "s3cr3t"]
            let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded res)))
            "s3cr3t" `T.isInfixOf` recorded `shouldBe` False
          Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- SHOW_HUMAN / ASK_HUMAN
  -- ----------------------------------------------------------------------
  describe "SHOW_HUMAN" $ do
    it "\"Tell the human that the build is done.\" -> SHOW_HUMAN -> message sent via channel" $ do
      sent <- newIORef []
      let caps = recordCaps sent
          op = showHumanOp caps
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "SHOW_HUMAN")
                        (object ["message" .= ("the build is done" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          readIORef sent `shouldReturn` ["the build is done"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "ASK_HUMAN" $ do
    it "\"Ask the human which branch to use.\" -> ASK_HUMAN -> human's reply returned" $ do
      let caps = ChannelCaps
            { ccSend = \_ -> pure ()
            , ccPrompt = \_ -> pure "main"
            , ccPromptSecret = \_ -> pure ""
            }
          op = askHumanOp caps
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "ASK_HUMAN")
                        (object ["question" .= ("which branch?" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "main"]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- HARNESS_LIST / START / STOP
  -- ----------------------------------------------------------------------
  describe "HARNESS_LIST" $ do
    it "\"List the live harnesses.\" -> HARNESS_LIST -> text returned when none registered" $ do
      reg <- newHarnessRegistry
      let op = harnessListOp reg
          isaReg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne isaReg (OpName "HARNESS_LIST") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          case orParts res of
            [TrpText _] -> pure ()
            _          -> expectationFailure "expected text part"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "HARNESS_START" $ do
    it "\"Start a claude-code harness.\" -> HARNESS_START -> registry has one entry" $ do
      reg <- newHarnessRegistry
      (runner, _getArgs) <- mkFakeRunner
        [ "ok"   -- new-session
        , "ok"   -- new-window
        , "ok"   -- set-option @seal_id
        ]
      let session = right (mkTmuxIdent "seal")
          window  = right (mkTmuxIdent "claude-1")
          mintId  = newHarnessId
          op = harnessStartOp reg runner session window HfClaudeCode mintId
          isaReg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne isaReg (OpName "HARNESS_START")
                        (object ["flavour" .= ("claude-code" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          snap <- snapshot reg
          case snap of
            (e : _) -> heOrigin e `shouldBe` HoSpawned
            []     -> expectationFailure "expected at least one harness"
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  describe "HARNESS_STOP" $ do
    it "\"Stop harness <id>.\" -> HARNESS_STOP -> entry marked LvExited" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically $ insert reg HarnessEntry
        { heId = hid
        , heLabel = "test"
        , heOrigin = HoSpawned
        , heLiveness = LvIdle
        , heTmuxCoord = Just "seal:win"
        , heFlavour = Just "claude-code"
        , heOrphanTicks = 0
        }
      (runner, _) <- mkFakeRunner ["ok"]   -- kill-window succeeds
      let op = harnessStopOp reg runner
          isaReg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne isaReg (OpName "HARNESS_STOP")
                        (object ["id" .= harnessIdToText hid]))
      case r of
        Right res -> do
          orIsError res `shouldBe` False
          orParts res `shouldBe` [TrpText "stopped"]
          snap <- snapshot reg
          fmap heLiveness snap `shouldBe` [LvExited]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- WEB_SEARCH
  -- ----------------------------------------------------------------------
  describe "WEB_SEARCH" $ do
    it "\"Search the web for 'Haskell runtime'.\" -> WEB_SEARCH -> query accepted, fail-closed result (no HTTP manager)" $ do
      let cfg = WebSearchConfig
            { wscManager = Nothing
            , wscEndpoint = "https://search.example.com/api"
            , wscAllowList = ["example.com"]
            , wscAuthKey = Nothing
            }
          op = webSearchOp cfg
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "WEB_SEARCH")
                        (object ["query" .= ("Haskell runtime" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no HTTP manager" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          orRecorded res `shouldBe` object
            [ "query" .= ("Haskell runtime" :: Text)
            , "result_count" .= (0 :: Int)
            ]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Search for ''.\" -> WEB_SEARCH with empty query -> Denied at the gate" $ do
      let cfg = WebSearchConfig Nothing "https://x" [] Nothing
          op = webSearchOp cfg
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "WEB_SEARCH")
                        (object ["query" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "WEB_SEARCH: query is empty")

  -- ----------------------------------------------------------------------
  -- WEB_FETCH
  -- ----------------------------------------------------------------------
  describe "WEB_FETCH" $ do
    it "\"Fetch the page at https://example.com.\" -> WEB_FETCH -> URL accepted, fail-closed result (no HTTP manager)" $ do
      let cfg = WebFetchConfig
            { wfcManager = Nothing
            , wfcAllowList = ["example.com"]
            , wfcMaxBytes = 65536
            , wfcAuthKey = Nothing
            }
          op = webFetchOp cfg
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "WEB_FETCH")
                        (object ["url" .= ("https://example.com" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no HTTP manager" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          -- orRecorded captures the URL + placeholder status/bytes (secret-free).
          orRecorded res `shouldBe` object
            [ "url" .= ("https://example.com" :: Text)
            , "status" .= (0 :: Int)
            , "bytes" .= (0 :: Int)
            ]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Fetch ''.\" -> WEB_FETCH with empty url -> Denied at the gate" $ do
      let cfg = WebFetchConfig Nothing [] 65536 Nothing
          op = webFetchOp cfg
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "WEB_FETCH")
                        (object ["url" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "WEB_FETCH: url is empty")

  -- ----------------------------------------------------------------------
  -- BROWSER_OPEN / CLICK / READ
  -- ----------------------------------------------------------------------
  describe "BROWSER_OPEN" $ do
    it "\"Open https://example.com in a browser.\" -> BROWSER_OPEN -> fail-closed (no driver)" $ do
      let op = browserOpenOp noBrowserDriver
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "BROWSER_OPEN")
                        (object ["url" .= ("https://example.com" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no browser driver" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          orRecorded res `shouldBe` object ["url" .= ("https://example.com" :: Text)]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Open a blank page.\" -> BROWSER_OPEN with empty url -> Denied" $ do
      let op = browserOpenOp noBrowserDriver
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "BROWSER_OPEN")
                        (object ["url" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "BROWSER_OPEN: url is empty")

  describe "BROWSER_CLICK" $ do
    it "\"Click the 'submit' button.\" -> BROWSER_CLICK -> fail-closed (no driver)" $ do
      let op = browserClickOp noBrowserDriver
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "BROWSER_CLICK")
                        (object ["selector" .= ("#submit" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          orRecorded res `shouldBe` object ["selector" .= ("#submit" :: Text)]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Click ''.\" -> BROWSER_CLICK with empty selector -> Denied" $ do
      let op = browserClickOp noBrowserDriver
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "BROWSER_CLICK")
                        (object ["selector" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "BROWSER_CLICK: selector is empty")

  describe "BROWSER_READ" $ do
    it "\"Read the page text.\" -> BROWSER_READ -> fail-closed (no driver); selector optional" $ do
      let op = browserReadOp noBrowserDriver
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "BROWSER_READ") (object []))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no browser driver" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          orRecorded res `shouldBe` object ["selector" .= ("" :: Text)]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Read the text of the '#main' element.\" -> BROWSER_READ with selector -> recorded" $ do
      let op = browserReadOp noBrowserDriver
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "BROWSER_READ")
                        (object ["selector" .= ("#main" :: Text)]))
      case r of
        Right res -> orRecorded res `shouldBe` object ["selector" .= ("#main" :: Text)]
        Left e   -> expectationFailure ("dispatch failed: " <> show e)

  -- ----------------------------------------------------------------------
  -- IMAGE_GENERATE / DESCRIBE
  -- ----------------------------------------------------------------------
  describe "IMAGE_GENERATE" $ do
    it "\"Generate an image of a cat.\" -> IMAGE_GENERATE -> fail-closed (no provider)" $ do
      let op = imageGenerateOp noImageProvider
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "IMAGE_GENERATE")
                        (object ["prompt" .= ("a cat" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no image provider" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          orRecorded res `shouldBe` object ["prompt" .= ("a cat" :: Text)]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Generate an image with no prompt.\" -> IMAGE_GENERATE empty prompt -> Denied" $ do
      let op = imageGenerateOp noImageProvider
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "IMAGE_GENERATE")
                        (object ["prompt" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "IMAGE_GENERATE: prompt is empty")

  describe "IMAGE_DESCRIBE" $ do
    it "\"Describe this image.\" -> IMAGE_DESCRIBE -> fail-closed (no provider)" $ do
      let op = imageDescribeOp noImageProvider
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "IMAGE_DESCRIBE")
                        (object ["image" .= ("https://x/cat.png" :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no image provider" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          orRecorded res `shouldBe` object ["image" .= ("https://x/cat.png" :: Text)]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Describe an empty image ref.\" -> IMAGE_DESCRIBE empty image -> Denied" $ do
      let op = imageDescribeOp noImageProvider
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "IMAGE_DESCRIBE")
                        (object ["image" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "IMAGE_DESCRIBE: image is empty")

  -- ----------------------------------------------------------------------
  -- TEXT_TO_SPEECH
  -- ----------------------------------------------------------------------
  describe "TEXT_TO_SPEECH" $ do
    it "\"Read 'Hello, world.' aloud.\" -> TEXT_TO_SPEECH -> fail-closed (no provider)" $ do
      let op = textToSpeechOp noTtsProvider
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "TEXT_TO_SPEECH")
                        (object ["text" .= ("Hello, world." :: Text)]))
      case r of
        Right res -> do
          orIsError res `shouldBe` True
          case orParts res of
            [TrpText t] -> "no TTS provider" `T.isInfixOf` t `shouldBe` True
            _          -> expectationFailure "expected text part"
          orRecorded res `shouldBe` object ["text" .= ("Hello, world." :: Text)]
        Left e -> expectationFailure ("dispatch failed: " <> show e)

    it "\"Synthesize empty text.\" -> TEXT_TO_SPEECH empty text -> Denied" $ do
      let op = textToSpeechOp noTtsProvider
          reg = Registry.mkRegistry [op]
      r <- runTestApp (dispatchOne reg (OpName "TEXT_TO_SPEECH")
                        (object ["text" .= ("" :: Text)]))
      r `shouldBe` Left (Denied "TEXT_TO_SPEECH: text is empty")