{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.ISA.DispatchSpec (spec) where

import Data.Default (def)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Functor (($>))
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Core.Types
import Seal.Handles.Transcript (TwoFileHandle (..), fakeTwoFileTranscript)
import Seal.ISA.Dispatch
import Seal.ISA.Opcode
import Seal.ISA.Ops.Shell (shellExecSchema)
import Seal.ISA.Ops.Bin (binExecSchema)
import Seal.ISA.Ops.Human (askHumanOp)
import Seal.ISA.Registry
import Seal.Channel.Caps
import Seal.Handles.AskReply
  ( AskReply (..), ApprovalScope (..), askHuman
  , deliverAnswer, newAskReplyStore, pendingForSession, pqiId )
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..), ToolResultPart (..))
import Seal.Tools.Exec.Abort (AbortFlag, newAbortFlag)
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub, UntrustedIO)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Exec.UIO qualified as UIO (uioLiftIO)
import Seal.Tools.Timeout (defaultToolTimeoutConfig, ToolTimeoutConfig (..))
import Seal.Transcript.Entries (erMeta)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)

-- | A shared test abort flag (top-level, created once via unsafePerformIO).
testAbortFlag :: AbortFlag
testAbortFlag = unsafePerformIO newAbortFlag
{-# NOINLINE testAbortFlag #-}

-- | A two-file transcript handle that records @"ack"@ for a 'tfwRecordAndAck'
-- call and @"async"@ for a 'tfwRecordAsync' call, so the test asserts the
-- ACK-before-execute ordering for Untrusted opcodes. Returns a probe
-- opcode of the requested trust level (Trusted or Untrusted).
probe :: IORef [String] -> TrustLevel -> (TwoFileHandle, Opcode)
probe ref tl =
  ( TwoFileHandle
      { tfwRecordAndAck = \_ -> modifyIORef' ref (++ ["ack"])
      , tfwRecordAsync  = \_ -> modifyIORef' ref (++ ["async"])
      , tfwReadConversation = pure []
      , tfwReadEntries     = pure []
      , tfwSetSecretOps    = \_ -> pure ()
      , tfwCloseTranscript = pure ()
      , tfwIsAlive         = pure True
      }
  , mkProbeOpcode ref tl
  )

-- | A variant of 'probe' that returns just the transcript handle (for when
-- the test supplies its own opcode, e.g. ASK_HUMAN).
probeHandle :: IORef [String] -> TwoFileHandle
probeHandle ref =
  TwoFileHandle
    { tfwRecordAndAck = \_ -> modifyIORef' ref (++ ["ack"])
    , tfwRecordAsync  = \_ -> modifyIORef' ref (++ ["async"])
    , tfwReadConversation = pure []
    , tfwReadEntries     = pure []
    , tfwSetSecretOps    = \_ -> pure ()
    , tfwCloseTranscript = pure ()
    , tfwIsAlive         = pure True
    }

mkProbeOpcode :: IORef [String] -> TrustLevel -> Opcode
mkProbeOpcode ref = \case
  Trusted  -> TrustedOpcode (OpName "P") Trusted "p" (object []) (object [])
                            (const (Right ())) False (\_ _ -> recordRunTrusted)
  Audited  -> TrustedOpcode (OpName "P") Audited "p" (object []) (object [])
                            (const (Right ())) False (\_ _ -> recordRunTrusted)
  Untrusted -> UntrustedOpcode (OpName "P") "p" (object []) (object [])
                               (const (Right ())) (const recordRunUntrusted)
  where
    recordRunTrusted = liftIO (modifyIORef' ref (++ ["run"])) $> OpResult [] False Null
    recordRunUntrusted = UIO.uioLiftIO (modifyIORef' ref (++ ["run"])) $> OpResult [] False Null

-- | A blocking Trusted opcode that sleeps for longer than the test timeout.
-- Used to verify that blocking opcodes bypass the timeout/abort/retry race.
mkBlockingProbeOpcode :: IORef [String] -> Opcode
mkBlockingProbeOpcode ref =
  TrustedOpcode (OpName "BLOCKING") Trusted "blocking" (object []) (object [])
                (const (Right ())) True (\_ _ -> do
    liftIO (threadDelay 500000)  -- 0.5s — longer than the 50ms test timeout
    liftIO (modifyIORef' ref (++ ["run"]))
    pure (OpResult [] False Null))

-- | The fail-closed 'UntrustedIO' handle the dispatcher threads for
-- Untrusted opcodes in these tests. Every method returns
-- 'UeExec ExecNotImplemented' — the probe opcode's 'uoRun' ignores it.
testUntrustedIO :: UntrustedIO
testUntrustedIO = mkRemoteUntrustedIOStub

runTestApp :: App a -> IO a
runTestApp act = do
  logger <- testSealLogger
  env <- mkEnv logger defaultConfig
  runApp env act

-- | A 'ToolTimeoutConfig' with a very short timeout (50ms) and no retries,
-- so a blocking opcode that takes longer will fail the test fast if the
-- dispatcher incorrectly applies the timeout.
shortTimeoutConfig :: ToolTimeoutConfig
shortTimeoutConfig = defaultToolTimeoutConfig
  { ttcDefaultSeconds = 0  -- 0 → extractPerCallTimeout returns 0*1M = 0 microseconds
  , ttcRetryMax = 1
  }

spec :: Spec
spec = describe "Seal.ISA.Dispatch" $ do
  describe "blocking opcodes bypass the timeout/abort/retry race" $ do
    it "a blocking Trusted opcode is NOT killed by the dispatcher timeout" $ do
      -- A blocking opcode (e.g. ASK_HUMAN) blocks on a human reply, which
      -- can take arbitrarily long. The dispatcher must NOT wrap it in the
      -- timeout/abort/retry race — otherwise the 120s default timeout
      -- kills the ccPrompt call before the human answers.
      ref <- newIORef []
      let h = probeHandle ref
          blockingOp = mkBlockingProbeOpcode ref
          reg = mkRegistry [blockingOp]
      r <- runTestApp (dispatch reg h localBackend (mkTestUIOEnv testUntrustedIO stubCloneDeps) shortTimeoutConfig testAbortFlag (OpName "BLOCKING") (object []))
      case r of
        Left (ExecFailed msg) -> expectationFailure ("blocking opcode was killed by timeout: " <> T.unpack msg)
        Left other -> expectationFailure ("unexpected dispatch error: " <> show other)
        Right _ -> readIORef ref `shouldReturn` ["async", "run"]

    it "ASK_HUMAN blocks past the timeout and returns the human's answer" $ do
      -- End-to-end: build an ASK_HUMAN opcode with a real AskReplyStore,
      -- dispatch it with a short timeout, deliver the answer after a delay,
      -- and verify the answer reaches the opcode (not a timeout error).
      store <- newAskReplyStore 0
      sid <- case mkSessionId "test-blocking" of
        Right s -> pure s
        Left e  -> error ("test session id: " <> T.unpack e)
      ref <- newIORef []
      let h = probeHandle ref
          caps = def { ccPrompt = \(AskPrompt q _opts) -> do
                         r <- askHuman store sid q (\_ -> pure ())
                         pure (case r of Right t -> t; Left _ -> "") }
          askOp = askHumanOp caps
          reg = mkRegistry [askOp]
      resultVar <- newEmptyMVar
      _ <- forkIO $ do
        r <- runTestApp (dispatch reg h localBackend (mkTestUIOEnv testUntrustedIO stubCloneDeps) shortTimeoutConfig testAbortFlag (OpName "ASK_HUMAN") (object ["question" .= ("what?" :: Text)]))
        putMVar resultVar r
      threadDelay 100000  -- 100ms — let the dispatch register the ask
      ps <- pendingForSession store sid
      length ps `shouldBe` 1
      case ps of
        [info] -> do
          let qid = pqiId info
          _ <- deliverAnswer store qid (AskReply ScopeOnce "42")
          r <- takeMVar resultVar
          case r of
            Left (ExecFailed msg) -> expectationFailure ("ASK_HUMAN was killed by timeout: " <> T.unpack msg)
            Left other -> expectationFailure ("unexpected dispatch error: " <> show other)
            Right opResult -> orParts opResult `shouldSatisfy` \parts ->
              any (\(TrpText t) -> t == "42") parts
        _ -> expectationFailure "expected exactly one pending question"

  it "Untrusted: ack precedes run" $ do
    ref <- newIORef []
    let (h, op) = probe ref Untrusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h localBackend (mkTestUIOEnv testUntrustedIO stubCloneDeps) defaultToolTimeoutConfig testAbortFlag (OpName "P") (object []))
    readIORef ref `shouldReturn` ["ack", "run"]

  it "Trusted: async then run (no ACK gate)" $ do
    ref <- newIORef []
    let (h, op) = probe ref Trusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h localBackend (mkTestUIOEnv testUntrustedIO stubCloneDeps) defaultToolTimeoutConfig testAbortFlag (OpName "P") (object []))
    readIORef ref `shouldReturn` ["async", "run"]

  it "missing opcode -> OpNotFound" $ do
    ref <- newIORef []
    let (h, _) = probe ref Trusted
    res <- runTestApp (dispatch (mkRegistry []) h localBackend (mkTestUIOEnv testUntrustedIO stubCloneDeps) defaultToolTimeoutConfig testAbortFlag (OpName "Z") (object []))
    res `shouldBe` Left (OpNotFound (OpName "Z"))

  it "failed authorization -> Denied, never runs" $ do
    ref <- newIORef []
    let (h, base) = probe ref Trusted
        op = withAuthorize base (const (Left "nope"))
    res <- runTestApp (dispatch (mkRegistry [op]) h localBackend (mkTestUIOEnv testUntrustedIO stubCloneDeps) defaultToolTimeoutConfig testAbortFlag (OpName "P") (object []))
    res `shouldBe` Left (Denied "nope")
    readIORef ref `shouldReturn` []

  describe "schema advertisement (Task 8)" $ do
    it "SHELL_EXEC schema declares the optional 'timeout' field" $ do
      let schema = shellExecSchema
          props = case schema of
            A.Object o -> KeyMap.lookup (Key.fromText "properties") o
            _ -> Nothing
      props `shouldSatisfy` isJust
      case props of
        Just (A.Object ps) ->
          KeyMap.member (Key.fromText "timeout") ps `shouldBe` True
        _ -> expectationFailure "expected properties object"

    it "BIN_EXEC schema declares the optional 'timeout' field" $ do
      let schema = binExecSchema
          props = case schema of
            A.Object o -> KeyMap.lookup (Key.fromText "properties") o
            _ -> Nothing
      props `shouldSatisfy` isJust
      case props of
        Just (A.Object ps) ->
          KeyMap.member (Key.fromText "timeout") ps `shouldBe` True
        _ -> expectationFailure "expected properties object"

  describe "recordSkillLoadResult" $ do
    -- | Regression: /skill load displays the "Command output" box but the
    -- skill body never reaches the model's context. The agent loop builds
    -- its next-turn context from @conversation.jsonl@ (Loop.hs:61 reads
    -- @tfwReadConversation@), but @recordSkillLoadResult@ wrote only an
    -- @EKHarness@ entry to @entries.jsonl@ with an EMPTY message list —
    -- so the skill body was invisible to the next turn. The fix: the
    -- skill body must be appended to @conversation.jsonl@ as a User
    -- message carrying the rendered body, so @runTurn@'s @prior@ read
    -- picks it up.
    it "writes the skill body to conversation.jsonl so the next turn sees it" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "# greet\n\ngreeting skill\n\n---\n\nsay hi"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object
                [ "id" .= ("greet" :: Text)
                , "description" .= ("greeting skill" :: Text)
                , "body" .= ("say hi" :: Text)
                ]
            }
      recordSkillLoadResult h (OpName "SKILL_LOAD") (object ["id" .= ("greet" :: Text)]) result Nothing
      (conv, _entries) <- readState
      -- The skill body must land in the conversation (the model's context
      -- source), not just the entries sidecar.
      let bodies = [ t | Message _ bs <- conv, CbText t <- bs ]
      T.unlines bodies `shouldSatisfy` ("say hi" `T.isInfixOf`)

    it "does not write to conversation.jsonl for non-SKILL_LOAD opcodes" $ do
      (h, readState) <- fakeTwoFileTranscript
      let result = OpResult
            { orParts = [TrpText "ok"]
            , orIsError = False
            , orRecorded = object []
            }
      recordSkillLoadResult h (OpName "SHELL_EXEC") (object []) result Nothing
      (conv, _entries) <- readState
      conv `shouldBe` []

    it "does not write to conversation.jsonl for error results" $ do
      (h, readState) <- fakeTwoFileTranscript
      let result = OpResult
            { orParts = [TrpText "skill not found"]
            , orIsError = True
            , orRecorded = object ["id" .= ("nope" :: Text)]
            }
      recordSkillLoadResult h (OpName "SKILL_LOAD") (object ["id" .= ("nope" :: Text)]) result Nothing
      (conv, _entries) <- readState
      conv `shouldBe` []

    it "stamps the channel label into erMeta so the frontend can surface origin" $ do
      (h, readState) <- fakeTwoFileTranscript
      let result = OpResult
            { orParts = [TrpText "body"]
            , orIsError = False
            , orRecorded = object ["id" .= ("greet" :: Text)]
            }
      recordSkillLoadResult h (OpName "SKILL_LOAD") (object ["id" .= ("greet" :: Text)]) result (Just "telegram")
      (_conv, entries) <- readState
      case entries of
        [e] -> case Map.lookup "channel" (erMeta e) of
          Just (String ch) -> ch `shouldBe` "telegram"
          other -> expectationFailure ("expected channel=telegram in erMeta, got " <> show other)
        _ -> expectationFailure ("expected exactly one entry, got " <> show (length entries))

    it "omits the channel key from erMeta when Nothing is supplied" $ do
      (h, readState) <- fakeTwoFileTranscript
      let result = OpResult
            { orParts = [TrpText "body"]
            , orIsError = False
            , orRecorded = object ["id" .= ("greet" :: Text)]
            }
      recordSkillLoadResult h (OpName "SKILL_LOAD") (object ["id" .= ("greet" :: Text)]) result Nothing
      (_conv, entries) <- readState
      case entries of
        [e] -> Map.notMember "channel" (erMeta e) `shouldBe` True
        _ -> expectationFailure ("expected exactly one entry, got " <> show (length entries))

    it "writes only the skill body (the trailing message is NOT written — the follow-up turn handles it)" $ do
      -- /skill load start #123 → the skill body lands in conversation.jsonl
      -- as an Assistant message. The trailing message "#123" is NOT written
      -- here — the command's follow-up turn writes it as a User message via
      -- runTurn, so the model sees the skill followed by the user's request.
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "# start\n\nstart skill\n\n---\n\nbody"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object ["id" .= ("start" :: Text)]
            }
          input = object
            [ "id" .= ("start" :: Text)
            , "message" .= ("#123" :: Text)
            ]
      recordSkillLoadResult h (OpName "SKILL_LOAD") input result Nothing
      (conv, _entries) <- readState
      -- Only the skill body is written (the trailing message is NOT).
      let texts = [ t | Message _ bs <- conv, CbText t <- bs ]
      texts `shouldBe` [bodyText]

    it "writes only the skill body when the message is blank" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "skill body"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object ["id" .= ("greet" :: Text)]
            }
          input = object
            [ "id" .= ("greet" :: Text)
            , "message" .= ("" :: Text)
            ]
      recordSkillLoadResult h (OpName "SKILL_LOAD") input result Nothing
      (conv, _entries) <- readState
      let texts = [ t | Message _ bs <- conv, CbText t <- bs ]
      texts `shouldBe` [bodyText]

    it "writes only the skill body when the message key is absent" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "skill body"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object ["id" .= ("greet" :: Text)]
            }
          input = object ["id" .= ("greet" :: Text)]
      recordSkillLoadResult h (OpName "SKILL_LOAD") input result Nothing
      (conv, _entries) <- readState
      let texts = [ t | Message _ bs <- conv, CbText t <- bs ]
      texts `shouldBe` [bodyText]

    it "writes the skill body as an Assistant message (harness output, not user input)" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "skill body"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object ["id" .= ("greet" :: Text)]
            }
      recordSkillLoadResult h (OpName "SKILL_LOAD") (object ["id" .= ("greet" :: Text)]) result Nothing
      (conv, _entries) <- readState
      case conv of
        [m] -> msgRole m `shouldBe` Assistant
        _   -> expectationFailure ("expected exactly one message, got " <> show (length conv))

    it "does NOT write the trailing message (the follow-up turn handles it)" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "# start\n\nstart skill\n\n---\n\nbody"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object ["id" .= ("start" :: Text)]
            }
          input = object
            [ "id" .= ("start" :: Text)
            , "message" .= ("#123" :: Text)
            ]
      recordSkillLoadResult h (OpName "SKILL_LOAD") input result Nothing
      (conv, _entries) <- readState
      -- Only the skill body (Assistant) is written. The trailing message
      -- is NOT written by recordSkillLoadResult — the follow-up turn
      -- triggered by loadCmd writes it as a User message via runTurn.
      case conv of
        [skillMsg] -> msgRole skillMsg `shouldBe` Assistant
        _ -> expectationFailure ("expected exactly one message, got " <> show (length conv))

  describe "recordSetupRepoResult" $ do
    it "writes the clone result as an Assistant message (harness output, not user input)" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "Cloned git@github.com:seal-harness/seal-harness.git into seal-harness (shallow)."
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = False
            , orRecorded = object ["target" .= ("seal-harness" :: Text), "status" .= ("cloned" :: Text)]
            }
      recordSetupRepoResult h (OpName "SETUP_REPO") (object ["url" .= ("git@github.com:seal-harness/seal-harness.git" :: Text)]) result Nothing
      (conv, _entries) <- readState
      case conv of
        [m] -> msgRole m `shouldBe` Assistant
        _ -> expectationFailure ("expected exactly one message, got " <> show (length conv))

    it "writes the clone failure as an Assistant message" $ do
      (h, readState) <- fakeTwoFileTranscript
      let bodyText :: Text
          bodyText = "SETUP_REPO: clone failed: connection refused"
          result = OpResult
            { orParts = [TrpText bodyText]
            , orIsError = True
            , orRecorded = object ["target" .= ("" :: Text), "status" .= ("failed" :: Text)]
            }
      recordSetupRepoResult h (OpName "SETUP_REPO") (object ["url" .= ("https://example.com/repo.git" :: Text)]) result Nothing
      (conv, _entries) <- readState
      case conv of
        [m] -> msgRole m `shouldBe` Assistant
        _ -> expectationFailure ("expected exactly one message, got " <> show (length conv))
