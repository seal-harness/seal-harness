{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.CallSpec (spec) where

import Data.Aeson (Value, object)
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Call
  ( callCommandSpec
  , renderOpResult
  , renderDispatchError
  , CallDispatcher
  )
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Parse (parseSlash, ParseOutcome (..))
import Seal.Command.Spec (CommandAction (..), mkRegistry)
import Seal.Core.Types (OpName (..))
import Seal.ISA.Dispatch (DispatchError (..))
import Seal.ISA.Opcode (OpResult (..))
import Seal.Providers.Class (ToolResultPart (..))

-- | A recording ChannelCaps.
recordingCaps :: IO (IORef [Text], ChannelCaps)
recordingCaps = do
  ref <- newIORef []
  pure (ref, ChannelCaps
    { ccSend = \t -> modifyIORef' ref (t :)
    , ccPrompt = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
    })

-- | A fake CallDispatcher that records the (OpName, input-encoded) pairs and
-- returns a canned 'Right' result with the given text parts.
fakeDispatcher :: IORef [(Text, Text)] -> [Text] -> Bool -> CallDispatcher
fakeDispatcher seen parts isErr _opName _val = do
  modifyIORef' seen (("FAKE", "called") :)  -- record that the dispatcher ran
  pure (Right (OpResult (map TrpText parts) isErr (object [])))

-- | A fake CallDispatcher that returns a canned 'Left' error.
fakeErrorDispatcher :: DispatchError -> CallDispatcher
fakeErrorDispatcher e _opName _val = pure (Left e)

runCommand :: CommandAction -> ChannelCaps -> IO ()
runCommand = runCommandAction

showPO :: ParseOutcome -> String
showPO (ParsedAction _)  = "ParsedAction"
showPO (ParseHelp _)    = "ParseHelp"
showPO (ParseFailure t)  = "ParseFailure " <> T.unpack t

spec :: Spec
spec = describe "Seal.Command.Call" $ do

  it "/help includes /call under the Tools group" $ do
    let reg = mkRegistry [callCommandSpec (fakeErrorDispatcher (OpNotFound (OpName "x")))]
        help = renderHelpIndex reg
    T.unpack help `shouldContain` "Tools"
    T.unpack help `shouldContain` "/call"

  it "/call OP {json} dispatches the opcode and prints the result parts" $ do
    seen <- newIORef []
    let dispatcher = fakeDispatcher seen ["line1", "line2"] False
        reg = mkRegistry [callCommandSpec dispatcher]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/call FILE_READ {\"path\":\"foo.txt\"}" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldBe` ["line2", "line1", "$ /call FILE_READ {\"path\":\"foo.txt\"}"]  -- newest-first
    called <- readIORef seen
    called `shouldBe` [("FAKE", "called")]

  it "/call OP with no JSON arg passes an empty object" $ do
    seen <- newIORef []
    let dispatcher opName val = do
          modifyIORef' seen (\acc -> (opNameText opName, encodeVal val) : acc)
          pure (Right (OpResult [TrpText "ok"] False (object [])))
        reg = mkRegistry [callCommandSpec dispatcher]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/call OPCODE_LIST" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldBe` ["ok", "$ /call OPCODE_LIST"]
    [(n, v)] <- readIORef seen
    n `shouldBe` "OPCODE_LIST"
    v `shouldBe` "{}"

  it "/call with invalid JSON -> error message" $ do
    let reg = mkRegistry [callCommandSpec (fakeErrorDispatcher (OpNotFound (OpName "x")))]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/call FILE_READ {not json}" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldSatisfy` any ("invalid JSON" `T.isInfixOf`)
    sent `shouldSatisfy` any ("$ /call FILE_READ" `T.isInfixOf`)

  it "/call with unknown opcode -> 'opcode not found'" $ do
    let reg = mkRegistry [callCommandSpec (fakeErrorDispatcher (OpNotFound (OpName "MISSING_OP")))]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/call MISSING_OP {}" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldBe` ["opcode not found: MISSING_OP", "$ /call MISSING_OP {}"]

  it "/call denied by authorize gate -> 'denied: ...'" $ do
    let reg = mkRegistry [callCommandSpec (fakeErrorDispatcher (Denied "policy says no"))]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/call SHELL_EXEC {\"command\":\"rm -rf /\"}" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldBe` ["denied: policy says no", "$ /call SHELL_EXEC {\"command\":\"rm -rf /\"}"]

  it "/call with empty opcode name -> 'invalid opcode name' error" $ do
    let reg = mkRegistry [callCommandSpec (fakeErrorDispatcher (OpNotFound (OpName "x")))]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/call " of
      ParsedAction act -> runCommand act caps
      other          -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldSatisfy` any ("invalid opcode name" `T.isInfixOf`)

  it "renderOpResult prefixes error results with [error]" $ do
    let r = OpResult [TrpText "boom"] True (object [])
    renderOpResult r `shouldBe` ["[error] boom"]

  it "renderOpResult for empty parts shows (no output)" $ do
    let r = OpResult [] False (object [])
    renderOpResult r `shouldBe` ["(no output)"]

  it "renderDispatchError renders OpNotFound" $ do
    renderDispatchError (OpNotFound (OpName "FOO")) `shouldBe` "opcode not found: FOO"

  it "renderDispatchError renders ExecFailed" $ do
    renderDispatchError (ExecFailed "segfault") `shouldBe` "exec failed: segfault"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

opNameText :: OpName -> Text
opNameText (OpName t) = t

-- | A tiny JSON-encoder for the test's recording dispatcher (avoids pulling
-- Aeson encoding into the assertion comparison). Only handles the empty
-- object case we test for the "no JSON arg" path.
encodeVal :: Value -> Text
encodeVal v = case v of
  Aeson.Object _ -> "{}"
  _              -> T.pack (show v)