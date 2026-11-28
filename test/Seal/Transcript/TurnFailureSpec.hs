{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module Seal.Transcript.TurnFailureSpec (spec) where

import Control.Exception (SomeException, evaluate, toException, try)
import Data.Aeson (decode, encode, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Seal.Providers.Class
  ( ContentBlock (..), pattern Message, Role (..) )
import Seal.Transcript.Error (TranscriptError (..))
import Seal.Transcript.TurnFailure

-- | The exact exception that motivated this work: a strict UTF-8 decode of
-- untrusted bytes. Produced by actually forcing the decode, so this is the
-- real exception rather than a hand-built lookalike. ('decodeUtf8' is lazy in
-- its result, so the force matters — otherwise the throw lands later and the
-- test would pass for the wrong reason.)
unicodeEx :: IO SomeException
unicodeEx = do
  r <- try (evaluate (TE.decodeUtf8 (BS.pack [0xe8]) :: T.Text))
  case r of
    Left e  -> pure e
    Right _ -> error "fixture: expected a UnicodeException"

-- | An 'IOError' whose rendered message we control, to pin the
-- "resource exhausted" probes. GHC renders ENOSPC/EMFILE as words; the literal
-- tokens never appear in the rendering, so probing them would be dead code.
ioEx :: String -> SomeException
ioEx = toException . userError

spec :: Spec
spec = describe "Seal.Transcript.TurnFailure" $ do
  describe "classify" $ do
    it "classifies a UnicodeException as CauseUnicode" $ do
      e <- unicodeEx
      tfCause (classify Nothing e "r") `shouldBe` CauseUnicode

    it "gives CauseUnicode a plain-language headline naming the location" $ do
      e <- unicodeEx
      tfHeadline (classify Nothing e "r")
        `shouldBe` "invalid UTF-8 in tool output"

    it "carries the correlation id through as tfRef" $ do
      e <- unicodeEx
      tfRef (classify Nothing e "deadbeef") `shouldBe` "deadbeef"

    it "matches 'No space left on device' (GHC's rendering, not the ENOSPC token)" $
      tfCause (classify Nothing (ioEx "resource exhausted (No space left on device)") "r")
        `shouldBe` CauseNoSpace

    it "matches 'Too many open files' (GHC's rendering, not the EMFILE token)" $
      tfCause (classify Nothing (ioEx "resource exhausted (Too many open files)") "r")
        `shouldBe` CauseTooManyFiles

    it "falls back to CauseOther carrying ONLY the exception type name" $
      tfCause (classify Nothing (ioEx "odd: /Users/secret/path hunter2") "r")
        `shouldBe` CauseOther "IOError"

    it "classifies a TranscriptError as CauseTranscriptDead with no inner cause" $
      tfCause (classify Nothing (toException (TranscriptError "writer died" Nothing)) "r")
        `shouldBe` CauseTranscriptDead

    it "prefers the INNER cause when a TranscriptError wraps one" $ do
      -- The whole point of carrying the cause up: the outer error says
      -- "transcript unavailable" (useless); the inner says WHY.
      inner <- unicodeEx
      let outer = toException (TranscriptError "writer died" (Just inner))
      tfCause (classify (Just inner) outer "r") `shouldBe` CauseUnicode

  describe "constraint 1 — no secret reaches any rendered surface" $ do
    let leaky = ioEx "provider said: api_key=sk-live-abc123 at /Users/zoe/.seal/keys/x"
        f = classify Nothing leaky "r"
    it "does not render the secret or a path on any surface" $ do
      mapM_ (\t -> t `shouldNotSatisfy` T.isInfixOf "sk-live-abc123")
            [renderForUser f, renderForChat f, renderForLog f]
      mapM_ (\t -> t `shouldNotSatisfy` T.isInfixOf "/Users/")
            [renderForUser f, renderForChat f, renderForLog f]
    it "does not carry the secret into the model-visible message" $
      case renderForModel f of
        Message _ blocks ->
          T.intercalate " " [ t | CbText t <- blocks ]
            `shouldNotSatisfy` T.isInfixOf "sk-live-abc123"

  describe "renderCause" $
    it "renders each constructor distinctly, without free text" $ do
      renderCause CauseUnicode `shouldBe` "UnicodeException"
      renderCause CauseNoSpace `shouldBe` "resource exhausted (No space left on device)"
      renderCause CauseTooManyFiles `shouldBe` "resource exhausted (Too many open files)"
      renderCause CauseTranscriptDead `shouldBe` "session transcript unavailable"
      renderCause CauseProviderUnresolved `shouldBe` "model provider could not be resolved"
      renderCause (CauseOther "FooError") `shouldBe` "FooError"

  describe "rendering surfaces" $ do
    let f = TurnFailure "invalid UTF-8 in tool output" CauseUnicode "1a2b3c4d"

    it "renderForUser carries headline, cause and reference" $ do
      let t = renderForUser f
      t `shouldSatisfy` T.isInfixOf "invalid UTF-8 in tool output"
      t `shouldSatisfy` T.isInfixOf "UnicodeException"
      t `shouldSatisfy` T.isInfixOf "1a2b3c4d"

    it "renderForChat is headline + ref only, with no cause line" $ do
      -- the irreversible egress path carries the least text
      let t = renderForChat f
      t `shouldSatisfy` T.isInfixOf "invalid UTF-8 in tool output"
      t `shouldSatisfy` T.isInfixOf "1a2b3c4d"
      t `shouldNotSatisfy` T.isInfixOf "UnicodeException"

    it "renderForLog carries the reference so the operator can join seal.log" $
      renderForLog f `shouldSatisfy` T.isInfixOf "1a2b3c4d"

    it "renderForModel produces one Assistant message, closed-vocabulary only" $
      case renderForModel f of
        Message role blocks -> do
          role `shouldBe` Assistant
          let txt = T.intercalate " " [ t | CbText t <- blocks ]
          txt `shouldSatisfy` T.isInfixOf "invalid UTF-8 in tool output"
          txt `shouldSatisfy` T.isInfixOf "1a2b3c4d"

  describe "wire format" $ do
    it "serialises the cause as a lowercase kebab-case tag" $ do
      causeWire CauseUnicode `shouldBe` "unicode"
      causeWire CauseNoSpace `shouldBe` "no-space"
      causeWire CauseTooManyFiles `shouldBe` "too-many-files"
      causeWire CauseTranscriptDead `shouldBe` "transcript-dead"
      causeWire CauseProviderUnresolved `shouldBe` "provider-unresolved"
      causeWire (CauseOther "FooError") `shouldBe` "other:FooError"

    it "serialises as the documented payload shape (no 'kind' field)" $
      A.toJSON (TurnFailure "invalid UTF-8 in tool output" CauseUnicode "1a2b3c4d")
        `shouldBe` object
          [ "headline" .= ("invalid UTF-8 in tool output" :: Text)
          , "cause"    .= ("unicode" :: Text)
          , "ref"      .= ("1a2b3c4d" :: Text)
          ]

    it "round-trips through JSON" $ do
      let f = TurnFailure "h" (CauseOther "FooError") "abc"
      (decode (encode f) :: Maybe TurnFailure) `shouldBe` Just f

    it "degrades an unknown wire cause to CauseOther rather than failing" $
      -- forward compatibility: an older client against a newer server
      parseCause "some-future-cause" `shouldBe` CauseOther "some-future-cause"
