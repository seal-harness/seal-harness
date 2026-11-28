{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Classifying a failed turn into one user-facing descriptor.
--
-- The harness already catches turn exceptions and logs them
-- ('Seal.Logging.Exceptions.withExceptionLogging'), but on the web surface the
-- sanitized result was dropped on the floor, so a failed turn was
-- indistinguishable from a completed one. This module owns the /vocabulary/ of
-- that failure: what kind it is, how it is phrased for each surface, and what
-- crosses the wire.
--
-- == Why the cause is a closed enum and not @show e@
--
-- The first design draft carried @T.pack (show e)@ as the cause. That was
-- wrong, and the design review caught it: the harness's redaction machinery
-- ('Seal.Handles.Transcript.redactMessages') is /provenance/-based — it blanks
-- tool results whose opcode is in @secretOpcodes@ — and there is no
-- secret-/value/ scrubber anywhere in the tree. An arbitrary exception message
-- can embed a vault value, a credential in a URI, or a path under @~/.seal@.
-- That text would have been written into @conversation.jsonl@ (which the model
-- reads) and fanned out to Telegram/Signal (which cannot be un-sent).
--
-- So the cause is a closed 'FailureCause' vocabulary. Leaks are structurally
-- impossible rather than scrubbed after the fact, matching the harness's actual
-- invariant: 'Seal.ISA.Opcode.orRecorded' is documented as "what the transcript
-- records (secret-free)" — exclusion by construction.
--
-- The full raw @show e@ still goes to @seal.log@, joined to the user-facing
-- report by 'tfRef'.
module Seal.Transcript.TurnFailure
  ( TurnFailure (..)
  , FailureCause (..)
  , classify
  , renderCause
  , renderForUser
  , renderForChat
  , renderForLog
  , renderForModel
  , causeWire
  , parseCause
  ) where

import Control.Exception (ErrorCall, SomeException, displayException, fromException)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Providers.Class
  ( ContentBlock (..), Message, pattern Message, Role (..) )
import Seal.Transcript.Error (TranscriptError (..))

-- | What went wrong, as a closed vocabulary. Adding a constructor is a wire
-- change: update 'causeWire' and 'parseCause' together.
data FailureCause
  = CauseUnicode            -- ^ invalid UTF-8 in tool/process output
  | CauseNoSpace            -- ^ ENOSPC, rendered as "No space left on device"
  | CauseTooManyFiles       -- ^ EMFILE, rendered as "Too many open files"
  | CauseTranscriptDead     -- ^ the transcript writer died or was unreachable
  | CauseProviderUnresolved -- ^ provider/model/vault-key resolution failed
  | CauseOther Text         -- ^ exception TYPE name only — never a message
  deriving stock (Eq, Show)

-- | One failed turn, normalized for every surface.
--
-- The JSON instance emits exactly @{headline, cause, ref}@ and nothing else
-- (design §3.2 — deliberately no @kind@ field: 'FailureCause' is the only
-- taxonomy, so a second discriminator could only drift from it).
data TurnFailure = TurnFailure
  { tfHeadline :: !Text
  -- ^ Plain language, user-facing, e.g. "invalid UTF-8 in tool output".
  , tfCause    :: FailureCause
  , tfRef      :: !Text
  -- ^ 8-hex correlation id. The SAME id 'Seal.Logging.Exceptions' logged, so
  -- the operator can find the full detail in @seal.log@.
  }
  deriving stock (Eq, Show)

-- | Classify an exception. /Pure/ on purpose: the caller supplies the
-- transcript daemon's recorded inner cause (which is an @IO@ read), so this
-- stays testable without IO. Precedence is most-specific first.
--
-- @mInner@ matters because the motivating incident threw a 'TranscriptError'
-- whose own message ("the writer died") said nothing about the real cause (a
-- strict UTF-8 decode). Reporting the wrapper would have been useless; reporting
-- the inner exception is the whole point.
classify :: Maybe SomeException -> SomeException -> Text -> TurnFailure
classify mInner outer ref =
  let cause = case fromException outer of
        Just (TranscriptError _ inner) ->
          maybe CauseTranscriptDead classifyCause (inner `firstJust` mInner)
        Nothing -> classifyCause outer
  in TurnFailure (headlineFor cause) cause ref

firstJust :: Maybe a -> Maybe a -> Maybe a
firstJust (Just x) _ = Just x
firstJust Nothing  y = y

-- | The exception -> cause mapping, after 'TranscriptError' unwrapping.
classifyCause :: SomeException -> FailureCause
classifyCause e
  | isUnicode e      = CauseUnicode
  | isNoSpace e      = CauseNoSpace
  | isTooManyFiles e = CauseTooManyFiles
  | otherwise        = CauseOther (typeName e)
  where
    shown = displayException e
    -- 'UnicodeException' exposes no constructor we can match, so the only
    -- faithful probe is the rendered message. Both phrasings are GHC's.
    isUnicode ex =
      let m = displayException ex
      in "Cannot decode byte" `isInfixOf` m || "Invalid UTF-8" `isInfixOf` m
    -- GHC renders ENOSPC/EMFILE as words: "resource exhausted (No space left
    -- on device)" / "(Too many open files)". The literal tokens never appear in
    -- the rendering, so probing for them would be dead code.
    isNoSpace _ = "No space left on device" `isInfixOf` shown
    isTooManyFiles _ = "Too many open files" `isInfixOf` shown

-- | The exception's TYPE NAME only — never its message, which may carry
-- secrets or paths. 'SomeException' erases the type, so this probes the handful
-- of types the harness actually raises and otherwise reports a fixed literal.
typeName :: SomeException -> Text
typeName e =
  case fromException e :: Maybe IOError of
    Just _  -> "IOError"
    Nothing -> case fromException e :: Maybe ErrorCall of
      Just _  -> "ErrorCall"
      Nothing -> "Exception"

-- | The plain-language headline shown to the user.
headlineFor :: FailureCause -> Text
headlineFor = \case
  CauseUnicode            -> "invalid UTF-8 in tool output"
  CauseNoSpace            -> "out of disk space"
  CauseTooManyFiles       -> "out of open file handles"
  CauseTranscriptDead     -> "the session transcript became unavailable"
  CauseProviderUnresolved -> "the model provider could not be resolved"
  CauseOther _            -> "an internal error stopped the turn"

-- | The cause line. Fixed strings only: an exception /type name/ is not a
-- secret under constraint 1, whereas its message body can be.
renderCause :: FailureCause -> Text
renderCause = \case
  CauseUnicode            -> "UnicodeException"
  CauseNoSpace            -> "resource exhausted (No space left on device)"
  CauseTooManyFiles       -> "resource exhausted (Too many open files)"
  CauseTranscriptDead     -> "session transcript unavailable"
  CauseProviderUnresolved -> "model provider could not be resolved"
  CauseOther tn           -> tn

-- | The full user-facing report: the web transcript entry and the CLI line.
renderForUser :: TurnFailure -> Text
renderForUser f =
  "Turn failed \8212 " <> tfHeadline f <> "\n\n"
  <> "Cause: " <> renderCause (tfCause f) <> "\n"
  <> "Reference: " <> tfRef f

-- | The chat-channel message (Telegram/Signal): headline + reference only.
--
-- This is the one surface that leaves the machine and cannot be un-sent, so it
-- carries the least text. Requirement 6 asks only that a phone user learns the
-- turn failed; it does not ask for the cause.
renderForChat :: TurnFailure -> Text
renderForChat f =
  "Turn failed \8212 " <> tfHeadline f <> " (ref " <> tfRef f <> ")"

-- | The operator-log line, joined to the full detail in @seal.log@ by 'tfRef'.
renderForLog :: TurnFailure -> Text
renderForLog f =
  "turn failure: " <> tfHeadline f
  <> "; cause=" <> renderCause (tfCause f)
  <> "; ref=" <> tfRef f

-- | What the /model/ sees on the next turn: decision 1 accepts that it should
-- know its own prior turn failed, so it does not repeat the same mistake.
-- Deliberately terse and closed-vocabulary, so a context full of prior failures
-- does not derail the next attempt.
renderForModel :: TurnFailure -> Message
renderForModel f = Message Assistant [CbText text]
  where
    text = "A previous turn failed: " <> tfHeadline f
      <> " (cause: " <> renderCause (tfCause f)
      <> ", ref " <> tfRef f <> ")"

-- | The wire tag for a cause. Lowercase kebab-case, matching the repo's
-- existing event vocabulary (@harness-status@, @reply-delivered@).
causeWire :: FailureCause -> Text
causeWire = \case
  CauseUnicode            -> "unicode"
  CauseNoSpace            -> "no-space"
  CauseTooManyFiles       -> "too-many-files"
  CauseTranscriptDead     -> "transcript-dead"
  CauseProviderUnresolved -> "provider-unresolved"
  CauseOther tn           -> "other:" <> tn

-- | Parse a wire tag. An /unknown/ tag degrades to 'CauseOther' carrying the
-- raw string rather than failing: this entry type is tag-filtered and will
-- outlive several deploys, so it must be forward-compatible for free.
parseCause :: Text -> FailureCause
parseCause t = case t of
  "unicode"             -> CauseUnicode
  "no-space"            -> CauseNoSpace
  "too-many-files"      -> CauseTooManyFiles
  "transcript-dead"     -> CauseTranscriptDead
  "provider-unresolved" -> CauseProviderUnresolved
  other                 -> maybe (CauseOther other) CauseOther (T.stripPrefix "other:" other)

instance ToJSON TurnFailure where
  toJSON f = object
    [ "headline" .= tfHeadline f
    , "cause"    .= causeWire (tfCause f)
    , "ref"      .= tfRef f
    ]

instance FromJSON TurnFailure where
  parseJSON = withObject "TurnFailure" $ \o ->
    TurnFailure
      <$> o .: "headline"
      <*> (parseCause <$> o .: "cause")
      <*> o .: "ref"
