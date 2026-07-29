{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.DispatchSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Functor (($>))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Core.Types
import Seal.Handles.Transcript (TwoFileHandle (..), fakeTwoFileTranscript)
import Seal.ISA.Dispatch
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Providers.Class (ContentBlock (..), Message (..), ToolResultPart (..))
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub, UntrustedIO)
import Seal.Transcript.Entries (erMeta)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)

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

mkProbeOpcode :: IORef [String] -> TrustLevel -> Opcode
mkProbeOpcode ref = \case
  Trusted  -> TrustedOpcode (OpName "P") Trusted "p" (object []) (object [])
                            (const (Right ())) (\_ _ -> recordRun)
  Audited  -> TrustedOpcode (OpName "P") Audited "p" (object []) (object [])
                            (const (Right ())) (\_ _ -> recordRun)
  Untrusted -> UntrustedOpcode (OpName "P") "p" (object []) (object [])
                               (const (Right ())) (\_ _ -> recordRun)
  where
    recordRun = liftIO (modifyIORef' ref (++ ["run"])) $> OpResult [] False Null

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

spec :: Spec
spec = describe "Seal.ISA.Dispatch" $ do
  it "Untrusted: ack precedes run" $ do
    ref <- newIORef []
    let (h, op) = probe ref Untrusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h localBackend testUntrustedIO (OpName "P") (object []))
    readIORef ref `shouldReturn` ["ack", "run"]

  it "Trusted: async then run (no ACK gate)" $ do
    ref <- newIORef []
    let (h, op) = probe ref Trusted
        reg = mkRegistry [op]
    _ <- runTestApp (dispatch reg h localBackend testUntrustedIO (OpName "P") (object []))
    readIORef ref `shouldReturn` ["async", "run"]

  it "missing opcode -> OpNotFound" $ do
    ref <- newIORef []
    let (h, _) = probe ref Trusted
    res <- runTestApp (dispatch (mkRegistry []) h localBackend testUntrustedIO (OpName "Z") (object []))
    res `shouldBe` Left (OpNotFound (OpName "Z"))

  it "failed authorization -> Denied, never runs" $ do
    ref <- newIORef []
    let (h, base) = probe ref Trusted
        op = withAuthorize base (const (Left "nope"))
    res <- runTestApp (dispatch (mkRegistry [op]) h localBackend testUntrustedIO (OpName "P") (object []))
    res `shouldBe` Left (Denied "nope")
    readIORef ref `shouldReturn` []

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

    it "appends the trailing message to conversation.jsonl after the skill body" $ do
      -- /skill load start #123 → the skill body lands in conversation.jsonl
      -- as a User message, then the trailing message "#123" is appended as
      -- a SECOND User message so the model sees the skill followed by the
      -- user's request on the next turn.
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
      -- Two User messages: the skill body, then the trailing message.
      let texts = [ t | Message _ bs <- conv, CbText t <- bs ]
      length texts `shouldBe` 2
      texts `shouldBe` [bodyText, "#123"]

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