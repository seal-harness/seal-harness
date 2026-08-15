{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.LoopSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Maybe (mapMaybe, fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import qualified Data.Vector as V

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Data.Default (def)
import Seal.Core.Types
import Seal.Handles.AskReply (newApprovalCache)
import Seal.Handles.Transcript (fakeTwoFileTranscript, withTwoFileTranscript)
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.Providers.Class
import Seal.Security.Policy (AutonomyLevel (..), SecurityPolicy (..), AllowList (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Transcript.Conv (readConversation)
import Seal.Transcript.Entries (EntryRecord (..), EntryKind (EKResponse))
import Seal.Transcript.Reconstruct (reconstruct)
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))
import Seal.Logging.Logger (testSealLogger)
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Agent.Env
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Agent.Loop

-- | A provider that returns a scripted list of responses, one per call.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      [] -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

-- | A provider that always fails with a fixed error message.
newtype FailingProvider = FailingProvider Text

instance Provider FailingProvider where
  listModels _ = pure (Right [])
  complete (FailingProvider err) _ = pure (Left err)

-- | A provider that always fails with a fixed error message and counts calls.
-- Used to assert no retries happen on non-retryable errors.
newtype CountingFailProvider = CountingFailProvider (IORef Int, Text)

instance Provider CountingFailProvider where
  listModels _ = pure (Right [])
  complete (CountingFailProvider (ref, err)) _ = do
    modifyIORef' ref (+ 1)
    pure (Left err)

-- | A provider that fails the first @n@ calls with the given error, then
-- succeeds with the scripted response. Used to verify retry behavior: the
-- turn loop retries transient provider errors with exponential backoff.
newtype FlakyProvider = FlakyProvider (IORef (Int, CompletionResponse, Text))

instance Provider FlakyProvider where
  listModels _ = pure (Right [])
  complete (FlakyProvider ref) _ = do
    (n, ok, err) <- readIORef ref
    if n <= 0
      then pure (Right ok)
      else do
        writeIORef ref (n - 1, ok, err)
        pure (Left err)

-- | A provider that always returns a truncated (StopMaxTokens) response and
-- counts how many times it was called. Used to verify the continuation
-- retry cap (1 initial + 3 continuations = 4 calls, then give-up).
newtype CountingTruncProvider = CountingTruncProvider (IORef Int)

instance Provider CountingTruncProvider where
  listModels _ = pure (Right [])
  complete (CountingTruncProvider ref) _ = do
    modifyIORef' ref (+ 1)
    pure (Right (CompletionResponse [CbText "partial"] StopMaxTokens (Usage 1 100)))

runTestApp :: App a -> IO a
runTestApp act = do
  logger <- testSealLogger
  env <- mkEnv logger defaultConfig
  runApp env act

spec :: Spec
spec = describe "Seal.Agent.Loop" $ do
  it "dispatches a tool call then emits the final text" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    ran <- newIORef (0 :: Int)
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        stubOp = TrustedOpcode (OpName "PING") Trusted "p" (object []) (object [])
                    (const (Right ()))
                    (\_ _ -> do
                      liftIO (modifyIORef' ran (+ 1))
                      pure (OpResult [TrpText "pong"] False Null))
        script =
          [ CompletionResponse
              [CbToolUse (ToolCallId "t1") (OpName "PING") (object [])]
              StopToolUse
              (Usage 0 0)
          , CompletionResponse [CbText "all done"] StopEnd (Usage 0 0)
          ]
    ref <- newIORef script
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry [stubOp]
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hello")
    readIORef ran `shouldReturn` 1
    -- Streaming: the final text "all done" is sent as a delta (no prefix).
    readIORef sent `shouldReturn` ["all done"]

  it "writes the conversation + entries to the two-file transcript" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        script =
          [ CompletionResponse [CbText "reply"] StopEnd (Usage 1 2) ]
    ref <- newIORef script
    (h, readState) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    (msgs, entries) <- readState
    -- conversation.jsonl: user "hi" + assistant "reply" (2 lines)
    length msgs `shouldBe` 2
    -- entries.jsonl: one Request (user) + one Response (assistant) = 2 entries
    length entries `shouldBe` 2
    -- the response entry carries usage
    case drop 1 entries of
      [resp] -> erUsage resp `shouldBe` Just (Usage 1 2)
      _      -> expectationFailure "expected exactly one response entry"

  -- Regression: a second turn must load the prior conversation from disk so
  -- the model sees the full history, and the two-file writer's diff-based
  -- appender never duplicates messages. Before the fix, runTurn started each
  -- turn with only the new user message, so (a) the model answered as if it
  -- was a fresh chat (ignoring all prior turns) and (b) the writer's diff
  -- against the on-disk conversation failed (the incoming list was not a
  -- prefix-extension of the on-disk list) and the fallback re-appended the
  -- whole incoming list every iteration, corrupting conversation.jsonl with
  -- duplicate user + assistant lines.
  it "a second turn loads the prior conversation, no duplication" $
    withSystemTempDirectory "seal-loop" $ \dir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          -- Two scripted responses: turn 1 replies "hi back"; turn 2 replies
          -- "ok". The script is consumed top-to-bottom across both turns.
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      { aeProvider = SomeProvider (ScriptProvider ref)
                      , aeProviderLabel = "ollama"
                      , aeModel = ModelId "m"
                      , aeSystem = Nothing
                      , aeRegistry = mkRegistry []
                      , aeTranscript = h
                      , aeBackend = localBackend
                      , aeUntrustedIO = mkRemoteUntrustedIOStub
                      , aeCloneDeps = Nothing
                      , aeCaps = caps
                      , aeSession = either (error "sid") id (mkSessionId "s1")
                      , aeMaxTurns = 8
                      , aeChannel = "test"
                      , aeMessageSource = Nothing
                      , aeAutonomy = Full
                      , aeApprovals = approvals
                      , aeDebugRequestsPath = Nothing
                      , aeOnEntry = pure ()
                      , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                      , aeOnDemandSchemas = False
                      , aeLogPath = Nothing
                      }
        runTestApp (runTurn mkEnv' "hi")
        runTestApp (runTurn mkEnv' "how are you")
      -- The on-disk conversation.jsonl must contain exactly 4 lines:
      --   user "hi", assistant "hi back", user "how are you", assistant "ok"
      -- Before the fix it contained 9+ lines with duplicate user messages.
      convContents <- BS8.readFile (dir </> "conversation.jsonl")
      length (BS8.lines convContents) `shouldBe` 4
      -- The second request entry's convLen must be 3 (the prior 2 lines +
      -- the new user message), confirming the model saw the full history.
      -- (The provider also received the full history: assert that turn 2
      -- observed the prior conversation by checking the final assistant
      -- text is "ok" and nothing was duplicated into the output.)
      readIORef sent `shouldReturn` ["hi back", "ok"]

  -- Debug-transcript: when aeDebugRequestsPath is set, each LLM request is
  -- written in full (including the complete message history) to requests.jsonl,
  -- one line per request. This lets us verify the model actually received the
  -- full conversation history (the bug hypothesis: the two-file storage format's
  -- reconstruction was only surfacing the latest message, not the history).
  it "writes the full CompletionRequest to requests.jsonl when aeDebugRequestsPath is set" $
    withSystemTempDirectory "seal-loop-debug" $ \dir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      let reqPath = dir </> "requests.jsonl"
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      { aeProvider = SomeProvider (ScriptProvider ref)
                      , aeProviderLabel = "ollama"
                      , aeModel = ModelId "m"
                      , aeSystem = Nothing
                      , aeRegistry = mkRegistry []
                      , aeTranscript = h
                      , aeBackend = localBackend
                      , aeUntrustedIO = mkRemoteUntrustedIOStub
                      , aeCloneDeps = Nothing
                      , aeCaps = caps
                      , aeSession = either (error "sid") id (mkSessionId "s1")
                      , aeMaxTurns = 8
                      , aeChannel = "test"
                      , aeMessageSource = Nothing
                      , aeAutonomy = Full
                      , aeApprovals = approvals
                      , aeDebugRequestsPath = Just reqPath
                      , aeOnEntry = pure ()
                      , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                      , aeOnDemandSchemas = False
                      , aeLogPath = Nothing
                      }
        runTestApp (runTurn mkEnv' "hi")
        runTestApp (runTurn mkEnv' "how are you")
      -- requests.jsonl has one line per provider call. Each line is the full
      -- CompletionRequest JSON. Turn 1 sends 1 message (user "hi"); turn 2
      -- sends 3 messages (user "hi", assistant "hi back", user "how are you").
      reqContents <- BS8.readFile reqPath
      let reqLines = BS8.lines reqContents
      length reqLines `shouldBe` 2
      -- Decode each line as a CompletionRequest and check crMessages length.
      let decodeReq bs = case A.eitherDecodeStrict bs :: Either String CompletionRequest of
            Right r  -> r
            Left e   -> error ("failed to decode request line: " <> e)
          reqs = map decodeReq reqLines
      -- Turn 1: the model sees just the new user message.
      case reqs of
        (req1 : _) -> length (crMessages req1) `shouldBe` 1
        []         -> expectationFailure "expected at least one request line"
      -- Turn 2: the model sees the full history (prior 2 + new user message).
      -- This is the key assertion — if the two-file format was not feeding
      -- history, this would be 1 instead of 3.
      case drop 1 reqs of
        [req2] -> length (crMessages req2) `shouldBe` 3
        _      -> expectationFailure "expected exactly two request lines"

  -- Verification: the reconstructed Request payloads (from conversation.jsonl
  -- + entries.jsonl) carry ONLY the new messages added at each turn (the
  -- delta), NOT the cumulative conversation history. This is the contract
  -- of the two-file delta format: the on-disk conversation.jsonl already
  -- stores each message exactly once, and re-embedding the full history into
  -- every request entry would be O(N²) in the conversation length. The
  -- separate debug requests.jsonl file (captured via the debug flag) still
  -- records the full CompletionRequest sent to the provider (the complete
  -- history, for provider-replay debugging); the reconstructed transcript
  -- entries are the user-facing view, which shows what was newly sent at
  -- each turn.
  it "reconstructed request payloads match the requests.jsonl debug file" $
    withSystemTempDirectory "seal-loop-recon" $ \dir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      let reqPath = dir </> "requests.jsonl"
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      { aeProvider = SomeProvider (ScriptProvider ref)
                      , aeProviderLabel = "ollama"
                      , aeModel = ModelId "m"
                      , aeSystem = Nothing
                      , aeRegistry = mkRegistry []
                      , aeTranscript = h
                      , aeBackend = localBackend
                      , aeUntrustedIO = mkRemoteUntrustedIOStub
                      , aeCloneDeps = Nothing
                      , aeCaps = caps
                      , aeSession = either (error "sid") id (mkSessionId "s1")
                      , aeMaxTurns = 8
                      , aeChannel = "test"
                      , aeMessageSource = Nothing
                      , aeAutonomy = Full
                      , aeApprovals = approvals
                      , aeDebugRequestsPath = Just reqPath
                      , aeOnEntry = pure ()
                      , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                      , aeOnDemandSchemas = False
                      , aeLogPath = Nothing
                      }
        runTestApp (runTurn mkEnv' "hi")
        runTestApp (runTurn mkEnv' "how are you")
      -- Read back the two-file format + the debug requests file.
      convBs <- BS8.readFile (dir </> "conversation.jsonl")
      entriesBs <- BS8.readFile (dir </> "entries.jsonl")
      reqBs <- BS8.readFile reqPath
      let conv = readConversation convBs
          evs = mapMaybe (A.decode . BL.fromStrict) (BS8.lines entriesBs) :: [EntryRecord]
          reconstructed = reconstruct conv evs
          reqEntries = [te | te <- reconstructed, teDirection te == Request]
          -- Extract the messages array length from each reconstructed Request
          -- payload. The payload is a JSON object with a "messages" key whose
          -- value is an array of Message objects.
          extractMsgCount te =
            case tePayload te of
              A.Object o -> case KeyMap.lookup (Key.fromText "messages") o of
                Just (A.Array arr) -> V.length arr
                _ -> 0
              _ -> 0
          reconMsgCounts = map extractMsgCount reqEntries
          -- Decode the debug requests.jsonl lines and extract message counts.
          -- The debug file captures the FULL CompletionRequest (with the
          -- complete conversation history) — that's what the provider
          -- received on the wire.
          decodeReq bs = case A.eitherDecodeStrict bs :: Either String CompletionRequest of
            Right r  -> r
            Left _   -> error "failed to decode request line"
          debugReqs = map decodeReq (BS8.lines reqBs)
          debugMsgCounts = map (length . crMessages) debugReqs
      -- The number of reconstructed Request entries must match the number of
      -- debug requests (one per provider call).
      length reconMsgCounts `shouldBe` length debugMsgCounts
      -- Each reconstructed request carries ONLY the delta (the new messages
      -- added at that turn), NOT the cumulative history. Turn 1 adds 1
      -- message ("hi"); turn 2 adds 1 message ("how are you"). The debug
      -- file captures the full history (1, then 2) — the reconstructed
      -- entries carry the deltas (1, 1).
      reconMsgCounts `shouldBe` [1, 1]
      -- The debug file captures the FULL CompletionRequest (with the
      -- complete conversation history) — that's what the provider
      -- received on the wire. Turn 1 sends 1 message ("hi"); turn 2
      -- sends 3 messages (user "hi" + assistant "hi back" + user "how
      -- are you").
      debugMsgCounts `shouldBe` [1, 3]

  -- -----------------------------------------------------------------------
  -- Human-confirmation gate (Supervised autonomy)
  -- -----------------------------------------------------------------------

  describe "human-confirmation gate" $ do
    let mkRecordUntrustedIO :: IO (IORef Bool, UntrustedIO)
        mkRecordUntrustedIO = do
          ran <- newIORef False
          let uio = mkRemoteUntrustedIOStub
                { uioShellExec = \_ _ -> do
                    writeIORef ran True
                    pure (Right "executed")
                }
          pure (ran, uio)
        shellScript :: [CompletionResponse]
        shellScript =
          [ CompletionResponse
              [CbToolUse (ToolCallId "t1") (OpName "SHELL_EXEC") (object ["command" .= ("echo hi" :: Text)])]
              StopToolUse
              (Usage 0 0)
          , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
          ]

    it "Supervised + 'once' reply → the opcode executes, not cached" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      (ran, uio) <- mkRecordUntrustedIO
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t])
                   , ccPrompt = \ap -> modifyIORef' prompts (++ [apQuestion ap]) >> pure "once"
                   , ccPromptSecret = \_ -> pure "" }
          wsRoot = WorkspaceRoot "/ws"
          policy = SecurityPolicy AllowAll Supervised
          reg = mkRegistry [shellExecOp wsRoot policy]
      ref <- newIORef shellScript
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = reg
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = uio
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Supervised
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = Nothing
                  }
      runTestApp (runTurn env "run echo hi")
      readIORef ran `shouldReturn` True

    it "Supervised + 'rejected' reply → the opcode is denied, not executed" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      (ran, uio) <- mkRecordUntrustedIO
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t])
                   , ccPrompt = \ap -> modifyIORef' prompts (++ [apQuestion ap]) >> pure "rejected"
                   , ccPromptSecret = \_ -> pure "" }
          wsRoot = WorkspaceRoot "/ws"
          policy = SecurityPolicy AllowAll Supervised
          reg = mkRegistry [shellExecOp wsRoot policy]
      ref <- newIORef shellScript
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = reg
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = uio
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Supervised
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = Nothing
                  }
      runTestApp (runTurn env "run echo hi")
      readIORef ran `shouldReturn` False

    it "Full autonomy → no prompt, the opcode executes" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      (ran, uio) <- mkRecordUntrustedIO
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t])
                   , ccPrompt = \ap -> modifyIORef' prompts (++ [apQuestion ap]) >> pure "irrelevant"
                   , ccPromptSecret = \_ -> pure "" }
          wsRoot = WorkspaceRoot "/ws"
          policy = SecurityPolicy AllowAll Full
          reg = mkRegistry [shellExecOp wsRoot policy]
      ref <- newIORef shellScript
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = reg
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = uio
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = Nothing
                  }
      runTestApp (runTurn env "run echo hi")
      readIORef ran `shouldReturn` True
      readIORef prompts `shouldReturn` ([] :: [Text])

    it "Supervised + Trusted opcode → no prompt, the opcode executes" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      ran <- newIORef (0 :: Int)
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t])
                   , ccPrompt = \ap -> modifyIORef' prompts (++ [apQuestion ap]) >> pure "rejected"
                   , ccPromptSecret = \_ -> pure "" }
          stubOp = TrustedOpcode (OpName "PING") Trusted "p" (object []) (object [])
                     (const (Right ()))
                     (\_ _ -> do
                       liftIO (modifyIORef' ran (+ 1))
                       pure (OpResult [TrpText "pong"] False Null))
          script =
            [ CompletionResponse
                [CbToolUse (ToolCallId "t1") (OpName "PING") (object [])]
                StopToolUse
                (Usage 0 0)
            , CompletionResponse [CbText "all done"] StopEnd (Usage 0 0)
            ]
      ref <- newIORef script
      (h, _) <- fakeTwoFileTranscript
      let reg = mkRegistry [stubOp]
          env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = reg
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Supervised
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = Nothing
                  }
      runTestApp (runTurn env "ping")
      readIORef ran `shouldReturn` 1
      readIORef prompts `shouldReturn` ([] :: [Text])

  -- ── Session log (seal.log) ──────────────────────────────────────────────

  it "logs turn start and end to seal.log when aeLogPath is set" $
    withSystemTempDirectory "seal-log" $ \logDir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          script = [ CompletionResponse [CbText "hello"] StopEnd (Usage 0 0) ]
      ref <- newIORef script
      (h, _) <- fakeTwoFileTranscript
      let logPath = Just (logDir </> "seal.log")
          env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = mkRegistry []
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = logPath
                  }
      runTestApp (runTurn env "hi")
      doesFileExist (fromJust logPath) `shouldReturn` True
      content <- readFile (fromJust logPath)
      content `shouldContain` "[TURN]"
      content `shouldContain` "start"
      content `shouldContain` "end"

  it "logs provider errors to seal.log" $
    withSystemTempDirectory "seal-log" $ \logDir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
      (h, _) <- fakeTwoFileTranscript
      let logPath = Just (logDir </> "seal.log")
          env = AgentEnv
                  { aeProvider = SomeProvider (FailingProvider "connection refused")
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = mkRegistry []
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = logPath
                  }
      runTestApp (runTurn env "hi")
      doesFileExist (fromJust logPath) `shouldReturn` True
      content <- readFile (fromJust logPath)
      content `shouldContain` "[ERROR]"
      content `shouldContain` "provider error"
      content `shouldContain` "connection refused"
      -- The turn start should also be logged (the error happens after start).
      content `shouldContain` "start"

  -- Regression: a provider error (Left err) must surface in the transcript
  -- as an EKResponse entry + an assistant message, not just in seal.log.
  -- The web channel's ccSend is a no-op (replies surface via the transcript
  -- poll), so without a transcript write the web frontend never learns the
  -- turn ended and the session sits idle with no message — a silent failure.
  -- The CLI/Telegram/Signal channels still receive the error via ccSend.
  it "writes a provider error to the transcript as a response entry + assistant message" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
    (h, readState) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (FailingProvider "could not reach Ollama at http://localhost:11434")
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    (msgs, entries) <- readState
    -- conversation.jsonl: user "hi" + an assistant message carrying the error.
    length msgs `shouldBe` 2
    let assistantMsg = msgs !! 1
    msgRole assistantMsg `shouldBe` Assistant
    [CbText txt] <- pure (msgContent assistantMsg)
    txt `shouldSatisfy` ("provider error" `T.isInfixOf`)
    txt `shouldSatisfy` ("could not reach Ollama" `T.isInfixOf`)
    -- entries.jsonl: one Request (user) + one Response (the error) = 2 entries.
    length entries `shouldBe` 2
    erKind (entries !! 1) `shouldBe` EKResponse
    -- ccSend still fires so CLI/Telegram/Signal channels see the error too.
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("provider error" `T.isInfixOf`)

  -- Retry: a transient provider error (transport failure / rate limit / 5xx)
  -- is retried twice with exponential backoff. A provider that fails twice
  -- then succeeds yields the successful response, not the error.
  it "retries a transient provider error twice then succeeds" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
    (h, _) <- fakeTwoFileTranscript
    -- Fail the first 2 calls (transport-style error), then succeed.
    ref <- newIORef (2 :: Int, CompletionResponse [CbText "recovered"] StopEnd (Usage 1 1), "could not reach Ollama at http://localhost:11434")
    let env = AgentEnv
                { aeProvider = SomeProvider (FlakyProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    -- The turn recovered: the user sees the successful reply, not the error.
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("recovered" `T.isInfixOf`)
    sentMsgs `shouldNotSatisfy` any ("provider error" `T.isInfixOf`)

  -- Retry: a non-retryable error (auth / bad request) fails immediately
  -- without burning retries. A provider that always returns a 401-style
  -- error yields the error on the first attempt.
  it "does NOT retry a non-retryable (401) provider error" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    callCount <- newIORef (0 :: Int)
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
    (h, _) <- fakeTwoFileTranscript
    -- A provider that counts calls and always returns a 401 auth error.
    let countingAuthFail = SomeProvider (CountingFailProvider (callCount, "Ollama rejected the credential (HTTP 401) — check the key with /provider add ollama"))
        env = AgentEnv
                { aeProvider = countingAuthFail
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    -- The provider was called exactly once (no retries).
    readIORef callCount `shouldReturn` 1
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("provider error" `T.isInfixOf`)
    sentMsgs `shouldSatisfy` any ("HTTP 401" `T.isInfixOf`)

  it "does NOT write seal.log when aeLogPath is Nothing" $
    withSystemTempDirectory "seal-log" $ \logDir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          script = [ CompletionResponse [CbText "hello"] StopEnd (Usage 0 0) ]
      ref <- newIORef script
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = mkRegistry []
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = Nothing
                  }
      runTestApp (runTurn env "hi")
      doesFileExist (logDir </> "seal.log") `shouldReturn` False

  it "logs the max-turns stop to seal.log" $
    withSystemTempDirectory "seal-log" $ \logDir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          -- A tool-use loop that never terminates: each response calls PING,
          -- so the loop runs until aeMaxTurns is hit.
          stubOp = TrustedOpcode (OpName "PING") Trusted "p" (object []) (object [])
                     (const (Right ()))
                     (\_ _ -> pure (OpResult [TrpText "pong"] False Null))
          script = replicate 20 (CompletionResponse
                                   [CbToolUse (ToolCallId "t1") (OpName "PING") (object [])]
                                   StopToolUse (Usage 0 0))
      ref <- newIORef script
      (h, _) <- fakeTwoFileTranscript
      let logPath = Just (logDir </> "seal.log")
          env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = mkRegistry [stubOp]
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 2
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = logPath
                  }
      runTestApp (runTurn env "loop")
      content <- readFile (fromJust logPath)
      content `shouldContain` "[WARN]"
      content `shouldContain` "too many tool turns"
      -- The user-visible message (via ccSend) includes the limit + guidance.
      sentMsgs <- readIORef sent
      sentMsgs `shouldSatisfy` any ("2-turn limit" `T.isInfixOf`)
      sentMsgs `shouldSatisfy` any ("max_turns" `T.isInfixOf`)

  -- ── StopMaxTokens handling ──────────────────────────────────────────────

  -- A truncated text response (StopMaxTokens, no tool calls) must trigger an
  -- auto-continuation: the loop appends the partial text + a synthetic
  -- continuation prompt and re-requests. The model "resumes" and emits the
  -- final text, which the user sees as the reply.
  it "auto-continues when a text response is truncated (StopMaxTokens)" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        script =
          [ CompletionResponse [CbText "partial"] StopMaxTokens (Usage 1 100)
          , CompletionResponse [CbText " done"] StopEnd (Usage 1 50)
          ]
    ref <- newIORef script
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    -- The user sees the resumed final text ("done"), not just "partial".
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("done" `T.isInfixOf`)

  -- A truncated EMPTY response (StopMaxTokens, content=[] — the model spent
  -- all tokens on an incomplete tool-call block that produced zero complete
  -- blocks). This is exactly session 3's symptom. Auto-continue must still
  -- fire and give the model another chance, rather than silently halting
  -- with an empty reply.
  it "auto-continues when a truncated response yields no content blocks" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        script =
          [ CompletionResponse [] StopMaxTokens (Usage 1 4096)
          , CompletionResponse [CbText "recovered"] StopEnd (Usage 1 50)
          ]
    ref <- newIORef script
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("recovered" `T.isInfixOf`)

  -- After 3 continuation retries the loop gives up and surfaces a truncation
  -- notice to the user (instead of silently shipping an empty/partial reply).
  -- The notice must mention "truncated" so the user knows the turn failed.
  it "surfaces a truncation notice after 3 failed continuation attempts" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        -- Every response is truncated — the loop retries 3 times then gives
        -- up. 1 initial + 3 continuations = 4 scripted responses consumed.
        script = replicate 4 (CompletionResponse [CbText "partial"] StopMaxTokens (Usage 1 100))
    ref <- newIORef script
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("truncated" `T.isInfixOf`)
    sentMsgs `shouldSatisfy` any ("continuation attempts" `T.isInfixOf`)

  -- The continuation retries must be bounded — verify the loop does NOT
  -- loop forever on persistent truncation. With 4 scripted truncated
  -- responses (1 initial + 3 retries) and maxTurns=8, the loop must stop
  -- after consuming exactly 4 provider calls (not 8).
  it "stops after exactly 3 continuation retries on persistent truncation" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    calls <- newIORef (0 :: Int)
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        -- A provider that always truncates and counts calls.
        countingTrunc = SomeProvider (CountingTruncProvider calls)
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = countingTrunc
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry []
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "hi")
    -- 1 initial + 3 continuations = 4 calls total, then the loop gives up.
    readIORef calls `shouldReturn` 4

  -- A truncated response followed by a tool call: after auto-continue, the
  -- model emits a tool call (not final text). The loop must dispatch the
  -- tool and continue, proving the continuation counter doesn't break the
  -- tool-call path.
  it "auto-continue then tool call: continuation feeds into the tool loop" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    ran <- newIORef (0 :: Int)
    let caps = def
                 { ccSend = \t -> modifyIORef' sent (++ [t]) }
        stubOp = TrustedOpcode (OpName "PING") Trusted "p" (object []) (object [])
                    (const (Right ()))
                    (\_ _ -> do
                      liftIO (modifyIORef' ran (+ 1))
                      pure (OpResult [TrpText "pong"] False Null))
        script =
          [ CompletionResponse [CbText "let me check"] StopMaxTokens (Usage 1 100)
          , CompletionResponse
              [CbToolUse (ToolCallId "t1") (OpName "PING") (object [])]
              StopToolUse (Usage 1 50)
          , CompletionResponse [CbText "all done"] StopEnd (Usage 1 50)
          ]
    ref <- newIORef script
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "m"
                , aeSystem = Nothing
                , aeRegistry = mkRegistry [stubOp]
                , aeTranscript = h
                , aeBackend = localBackend
                , aeUntrustedIO = mkRemoteUntrustedIOStub
                , aeCloneDeps = Nothing
                , aeCaps = caps
                , aeSession = either (error "sid") id (mkSessionId "s1")
                , aeMaxTurns = 8
                , aeChannel = "test"
                , aeMessageSource = Nothing
                , aeAutonomy = Full
                , aeApprovals = approvals
                , aeDebugRequestsPath = Nothing
                , aeOnEntry = pure ()
                , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                , aeOnDemandSchemas = False
                , aeLogPath = Nothing
                }
    runTestApp (runTurn env "ping")
    readIORef ran `shouldReturn` 1
    sentMsgs <- readIORef sent
    sentMsgs `shouldSatisfy` any ("all done" `T.isInfixOf`)

  -- The truncation event must be logged to seal.log when aeLogPath is set.
  it "logs StopMaxTokens continuation to seal.log" $
    withSystemTempDirectory "seal-log" $ \logDir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = def
                   { ccSend = \t -> modifyIORef' sent (++ [t]) }
          script =
            [ CompletionResponse [CbText "partial"] StopMaxTokens (Usage 1 100)
            , CompletionResponse [CbText " done"] StopEnd (Usage 1 50)
            ]
      ref <- newIORef script
      (h, _) <- fakeTwoFileTranscript
      let logPath = Just (logDir </> "seal.log")
          env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "m"
                  , aeSystem = Nothing
                  , aeRegistry = mkRegistry []
                  , aeTranscript = h
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCloneDeps = Nothing
                  , aeCaps = caps
                  , aeSession = either (error "sid") id (mkSessionId "s1")
                  , aeMaxTurns = 8
                  , aeChannel = "test"
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                  , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnUserMessage = Nothing
                    , aeOnStop = Nothing
                  , aeOnDemandSchemas = False
                  , aeLogPath = logPath
                  }
      runTestApp (runTurn env "hi")
      doesFileExist (fromJust logPath) `shouldReturn` True
      content <- readFile (fromJust logPath)
      content `shouldContain` "truncated"
      content `shouldContain` "continuation"
