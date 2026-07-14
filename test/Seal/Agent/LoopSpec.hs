{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.LoopSpec (spec) where

import Control.Monad (zipWithM_)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import qualified Data.Vector as V

import Seal.Channel.Caps (ChannelCaps (..))
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
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.Transcript.Reconstruct (reconstruct)
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Agent.Env
import Seal.Tools.Exec.Types (ExecBackend (..), LocalExecHandle (..), mkLocalExecHandlePlaceholder)
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

runTestApp :: App a -> IO a
runTestApp act = do
  env <- mkEnv defaultConfig
  runApp env act

spec :: Spec
spec = describe "Seal.Agent.Loop" $ do
  it "dispatches a tool call then emits the final text" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    ran <- newIORef (0 :: Int)
    let caps = ChannelCaps
                 (\t -> modifyIORef' sent (++ [t]))
                 (\_ -> pure "")
                 (\_ -> pure "")
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
                (SomeProvider (ScriptProvider ref))
                "ollama"
                (ModelId "m")
                Nothing
                (mkRegistry [stubOp])
                h
                localBackend
                (EbLocal mkLocalExecHandlePlaceholder)
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
                Nothing
                Full
                approvals
                Nothing
                (pure ())
    runTestApp (runTurn env "hello")
    readIORef ran `shouldReturn` 1
    readIORef sent `shouldReturn` ["ollama/m> all done"]

  it "writes the conversation + entries to the two-file transcript" $ do
    approvals <- newApprovalCache
    sent <- newIORef ([] :: [Text])
    let caps = ChannelCaps
                 (\t -> modifyIORef' sent (++ [t]))
                 (\_ -> pure "")
                 (\_ -> pure "")
        script =
          [ CompletionResponse [CbText "reply"] StopEnd (Usage 1 2) ]
    ref <- newIORef script
    (h, readState) <- fakeTwoFileTranscript
    let env = AgentEnv
                (SomeProvider (ScriptProvider ref))
                "ollama"
                (ModelId "m")
                Nothing
                (mkRegistry [])
                h
                localBackend
                (EbLocal mkLocalExecHandlePlaceholder)
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
                Nothing
                Full
                approvals
                Nothing
                (pure ())
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
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\_ -> pure "")
                   (\_ -> pure "")
          -- Two scripted responses: turn 1 replies "hi back"; turn 2 replies
          -- "ok". The script is consumed top-to-bottom across both turns.
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      (SomeProvider (ScriptProvider ref))
                      "ollama"
                      (ModelId "m")
                      Nothing
                      (mkRegistry [])
                      h
                      localBackend
                      (EbLocal mkLocalExecHandlePlaceholder)
                      caps
                      (either (error "sid") id (mkSessionId "s1"))
                      8
                      Nothing
                      Full
                      approvals
                      Nothing
                      (pure ())
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
      readIORef sent `shouldReturn` ["ollama/m> hi back", "ollama/m> ok"]

  -- Debug-transcript: when aeDebugRequestsPath is set, each LLM request is
  -- written in full (including the complete message history) to requests.jsonl,
  -- one line per request. This lets us verify the model actually received the
  -- full conversation history (the bug hypothesis: the two-file storage format's
  -- reconstruction was only surfacing the latest message, not the history).
  it "writes the full CompletionRequest to requests.jsonl when aeDebugRequestsPath is set" $
    withSystemTempDirectory "seal-loop-debug" $ \dir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\_ -> pure "")
                   (\_ -> pure "")
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      let reqPath = dir </> "requests.jsonl"
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      (SomeProvider (ScriptProvider ref))
                      "ollama"
                      (ModelId "m")
                      Nothing
                      (mkRegistry [])
                      h
                      localBackend
                      (EbLocal mkLocalExecHandlePlaceholder)
                      caps
                      (either (error "sid") id (mkSessionId "s1"))
                      8
                      Nothing
                      Full
                      approvals
                      (Just reqPath)
                      (pure ())
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
  -- + entries.jsonl) must match the actual CompletionRequests sent to the LLM
  -- (captured in requests.jsonl via the debug flag). This is the contract
  -- verification: the "View raw JSON" modal shows exactly what the provider
  -- received — the full conversation history, not just the latest message.
  it "reconstructed request payloads match the requests.jsonl debug file" $
    withSystemTempDirectory "seal-loop-recon" $ \dir -> do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\_ -> pure "")
                   (\_ -> pure "")
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      let reqPath = dir </> "requests.jsonl"
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      (SomeProvider (ScriptProvider ref))
                      "ollama"
                      (ModelId "m")
                      Nothing
                      (mkRegistry [])
                      h
                      localBackend
                      (EbLocal mkLocalExecHandlePlaceholder)
                      caps
                      (either (error "sid") id (mkSessionId "s1"))
                      8
                      Nothing
                      Full
                      approvals
                      (Just reqPath)
                      (pure ())
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
          decodeReq bs = case A.eitherDecodeStrict bs :: Either String CompletionRequest of
            Right r  -> r
            Left _   -> error "failed to decode request line"
          debugReqs = map decodeReq (BS8.lines reqBs)
          debugMsgCounts = map (length . crMessages) debugReqs
      -- The number of reconstructed Request entries must match the number of
      -- debug requests (one per provider call).
      length reconMsgCounts `shouldBe` length debugMsgCounts
      -- Each reconstructed request's message count must match the
      -- corresponding debug request's message count — the full conversation
      -- history, not just the latest message.
      zipWithM_ shouldBe reconMsgCounts debugMsgCounts

  -- -----------------------------------------------------------------------
  -- Human-confirmation gate (Supervised autonomy)
  -- -----------------------------------------------------------------------

  describe "human-confirmation gate" $ do
    let mkRecordBackend :: IO (IORef Bool, ExecBackend)
        mkRecordBackend = do
          ran <- newIORef False
          let handle = LocalExecHandle
                { lehExecShell = \_ _ -> do
                    writeIORef ran True
                    pure (Right "executed")
                , lehExecProgram = \_ _ -> do
                    writeIORef ran True
                    pure (Right "executed")
                }
          pure (ran, EbLocal handle)
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
      (ran, backend) <- mkRecordBackend
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\q -> modifyIORef' prompts (++ [q]) >> pure "once")
                   (\_ -> pure "")
          wsRoot = WorkspaceRoot "/ws"
          policy = SecurityPolicy AllowAll Supervised
          reg = mkRegistry [shellExecOp wsRoot policy backend]
      ref <- newIORef shellScript
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  (SomeProvider (ScriptProvider ref))
                  "ollama" (ModelId "m") Nothing reg h localBackend
                  backend caps (either (error "sid") id (mkSessionId "s1")) 8 Nothing Supervised approvals Nothing (pure ())
      runTestApp (runTurn env "run echo hi")
      readIORef ran `shouldReturn` True

    it "Supervised + 'rejected' reply → the opcode is denied, not executed" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      (ran, backend) <- mkRecordBackend
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\q -> modifyIORef' prompts (++ [q]) >> pure "rejected")
                   (\_ -> pure "")
          wsRoot = WorkspaceRoot "/ws"
          policy = SecurityPolicy AllowAll Supervised
          reg = mkRegistry [shellExecOp wsRoot policy backend]
      ref <- newIORef shellScript
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  (SomeProvider (ScriptProvider ref))
                  "ollama" (ModelId "m") Nothing reg h localBackend
                  backend caps (either (error "sid") id (mkSessionId "s1")) 8 Nothing Supervised approvals Nothing (pure ())
      runTestApp (runTurn env "run echo hi")
      readIORef ran `shouldReturn` False

    it "Full autonomy → no prompt, the opcode executes" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      (ran, backend) <- mkRecordBackend
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\q -> modifyIORef' prompts (++ [q]) >> pure "irrelevant")
                   (\_ -> pure "")
          wsRoot = WorkspaceRoot "/ws"
          policy = SecurityPolicy AllowAll Full
          reg = mkRegistry [shellExecOp wsRoot policy backend]
      ref <- newIORef shellScript
      (h, _) <- fakeTwoFileTranscript
      let env = AgentEnv
                  (SomeProvider (ScriptProvider ref))
                  "ollama" (ModelId "m") Nothing reg h localBackend
                  backend caps (either (error "sid") id (mkSessionId "s1")) 8 Nothing Full approvals Nothing (pure ())
      runTestApp (runTurn env "run echo hi")
      readIORef ran `shouldReturn` True
      readIORef prompts `shouldReturn` ([] :: [Text])

    it "Supervised + Trusted opcode → no prompt, the opcode executes" $ do
      approvals <- newApprovalCache
      sent <- newIORef ([] :: [Text])
      prompts <- newIORef ([] :: [Text])
      ran <- newIORef (0 :: Int)
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\q -> modifyIORef' prompts (++ [q]) >> pure "rejected")
                   (\_ -> pure "")
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
                  (SomeProvider (ScriptProvider ref))
                  "ollama" (ModelId "m") Nothing reg h localBackend
                  (EbLocal mkLocalExecHandlePlaceholder) caps
                  (either (error "sid") id (mkSessionId "s1")) 8 Nothing Supervised approvals Nothing (pure ())
      runTestApp (runTurn env "ping")
      readIORef ran `shouldReturn` 1
      readIORef prompts `shouldReturn` ([] :: [Text])
