{-# LANGUAGE OverloadedStrings #-}
-- | The turn loop: user message -> provider completion -> opcode dispatch ->
-- tool results -> repeat until no tool calls, then emit the final text. Fed only
-- after Seal.Ingest has classified input as a PlainMessage. Bounded by aeMaxTurns.
module Seal.Agent.Loop
  ( runTurn
  ) where

import Control.Exception (SomeException, catch)
import Control.Monad.IO.Class (liftIO)
import Control.Retry
  ( RetryPolicyM, exponentialBackoff, limitRetries, retrying )
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)
import qualified System.IO as IO

import Seal.Agent.Env (AgentEnv (..))
import Seal.Core.MessageSource
  ( MessageSource (..), conversationIdText )
import Seal.Core.Types (ModelId (..), OpName (..), TrustLevel (..))
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Handles.AskReply
  ( ApprovalScope (..), checkApproval, parseApprovalScope, recordApproval )
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Dispatch (DispatchError (..), dispatch)
import Seal.ISA.Opcode (OpResult (..), Opcode, opTrust)
import Seal.ISA.Registry (registryToolDefs', lookupOp)
import Seal.Providers.Class
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Session.Log
  ( logTurnStart, logTurnEnd, logProviderError, logMaxTurns
  , logTruncation, logTruncationGiveUp, maxLengthContinueRetries )
import Seal.Transcript.Entries
  ( EnvelopeDelta (..), EntryKind (..), EntryRecord (..) )
import Seal.Types.App (App)

-- | The output-token cap sent to the provider on every completion request.
-- Raised from 4096 to 8192 so tool-using agents (which often emit large
-- tool-call inputs, e.g. embedding file contents into @task@ prompts) have
-- headroom and are less likely to hit 'StopMaxTokens'. This alone does not
-- fix truncation handling — the loop must still handle 'StopMaxTokens'
-- explicitly (see 'go') — but it reduces the frequency.
defaultMaxTokens :: Int
defaultMaxTokens = 8192

-- | The synthetic user message appended after a 'StopMaxTokens' truncation
-- with no tool calls, asking the model to continue exactly where it left off
-- without repeating prior text. Mirrors Hermes' @_get_continuation_prompt@.
continuationPrompt :: Text
continuationPrompt =
  "[System: Your previous response was truncated by the output length \
  \limit. Continue exactly where you left off. Do not restart or repeat \
  \prior text. Finish the answer directly.]"

-- | Build the request @erMeta@: a @channel@ key (always present, sourced
-- from 'aeChannel' so every channel — including web/CLI with no
-- 'MessageSource' — is attributed) plus a @conversationId@ key when
-- 'aeMessageSource' is present (carrying the server-derived conversation
-- id for channels that have one). This is the single place channel
-- provenance is stamped into the transcript, so every turn is attributed
-- regardless of the source channel.
requestMeta :: Text -> Maybe MessageSource -> Map.Map Text Value
requestMeta channel mSrc =
  Map.fromList
    ([ ("channel", String channel)
     ] <> conversationIdField)
  where
    conversationIdField = case mSrc of
      Nothing -> []
      Just ms -> [("conversationId", String (conversationIdText (msConversationId ms)))]

runTurn :: AgentEnv -> Text -> App ()
runTurn env userText = do
  -- Load the prior conversation from disk so the model sees the full history
  -- (not just this turn's new message). The two-file writer's diff-based
  -- appender requires the incoming message list to be a prefix-extension of
  -- the on-disk conversation; without the prior messages, the diff falls back
  -- to re-appending the whole list every iteration, corrupting
  -- @conversation.jsonl@ with duplicate user + assistant lines.
  prior <- liftIO (tfwReadConversation (aeTranscript env))
  let userMsg = textMsg User userText
      turn0   = prior <> [userMsg]
  -- Record the initial user message as a Request entry. The envelope delta
  -- carries the full envelope in effect for this turn (model / system / tools
  -- / maxTokens), so reconstruction can rebuild the exact CompletionRequest.
  -- The request's @erMeta@ carries the channel + conversation id when
  -- 'aeMessageSource' is present (Signal), so the transcript records which
  -- channel + conversation this turn served. @erConvLen@ is the full
  -- conversation length in effect at this request (prior + new user message),
  -- so reconstruction can slice the right prefix from @conversation.jsonl@.
  liftIO $ do
    now <- getCurrentTime
    let env0 = EnvelopeDelta
          { edModel = Just (aeModel env)
          , edSystem = Just (aeSystem env)
          , edTools = Just (registryToolDefs' (aeOnDemandSchemas env) (aeRegistry env))
          , edToolChoice = Just ToolAuto
          , edMaxTokens = Just defaultMaxTokens
          }
        entry = EntryRecord
          { erId = ""
          , erTimestamp = now
          , erKind = EKRequest
          , erConvLen = length turn0
          , erEnvelope = Just env0
          , erUsage = Nothing
          , erStop = Nothing
          , erDurationMs = Nothing
          , erHarness = Nothing
          , erCorrelation = Nothing
          , erMeta = requestMeta (aeChannel env) (aeMessageSource env)
          }
    -- When a caller wants to react to the user message being durable
    -- (e.g. the /bg path broadcasts a lists snapshot so the sidebar shows
    -- the session name immediately), record it with tfwRecordAndAck
    -- (synchronously fsync'd) and run the hook. Otherwise keep the async
    -- write (no fsync latency at turn start).
    case aeOnUserMessage env of
      Just after -> do
        tfwRecordAndAck (aeTranscript env) (TwoFileWrite turn0 entry)
        liftIO after
      Nothing ->
        tfwRecordAsync (aeTranscript env) (TwoFileWrite turn0 entry)
  go (aeMaxTurns env) 0 turn0
  where
    go :: Int -> Int -> [Message] -> App ()
    go 0 _ msgs = liftIO $ do
      logMaxTurns (aeLogPath env)
      let stopMsg = "(stopped: reached the " <> T.pack (show (aeMaxTurns env))
            <> "-turn limit for this message. Ask again to continue, "
            <> "or raise `max_turns` in config.toml.)"
          assistantMsg = Message Assistant [CbText stopMsg]
          conv = msgs <> [assistantMsg]
      now <- getCurrentTime
      let entry = EntryRecord
            { erId = ""
            , erTimestamp = now
            , erKind = EKResponse
            , erConvLen = length conv
            , erEnvelope = Nothing
            , erUsage = Nothing
            , erStop = Nothing
            , erDurationMs = Nothing
            , erHarness = Nothing
            , erCorrelation = Nothing
            , erMeta = Map.empty
            }
      tfwRecordAndAck (aeTranscript env) (TwoFileWrite conv entry)
      aeOnEntry env
      ccSend (aeCaps env) stopMsg
    go n lenContinue msgs = do
      liftIO (logTurnStart (aeLogPath env) n)
      tStart <- liftIO getCurrentTime
      let req = CompletionRequest
                  { crModel = aeModel env
                  , crSystem = aeSystem env
                  , crMessages = msgs
                  , crTools = registryToolDefs' (aeOnDemandSchemas env) (aeRegistry env)
                  , crToolChoice = ToolAuto
                  , crMaxTokens = defaultMaxTokens
                  }
      liftIO (appendDebugRequest (aeDebugRequestsPath env) req)
      eresp <- liftIO (providerCompleteWithRetry (aeProvider env) req)
      case eresp of
        Left err -> liftIO $ do
          logProviderError (aeLogPath env) err
          -- Record the provider error as a response entry + an assistant
          -- message so every channel surfaces it. The web channel's ccSend
          -- is a no-op (replies surface via the transcript poll); without
          -- this transcript write the web frontend would never learn the
          -- turn ended and the session would sit idle with no message — a
          -- silent failure. Mirrors the max-turns stop branch below.
          let errMsg = "provider error: " <> err
              assistantMsg = Message Assistant [CbText errMsg]
              conv = msgs <> [assistantMsg]
          now <- getCurrentTime
          let entry = EntryRecord
                { erId = ""
                , erTimestamp = now
                , erKind = EKResponse
                , erConvLen = length conv
                , erEnvelope = Nothing
                , erUsage = Nothing
                , erStop = Nothing
                , erDurationMs = Nothing
                , erHarness = Nothing
                , erCorrelation = Nothing
                , erMeta = Map.empty
                }
          tfwRecordAndAck (aeTranscript env) (TwoFileWrite conv entry)
          aeOnEntry env
          ccSend (aeCaps env) errMsg
        Right resp -> do
          -- Record the provider response. Safe because CompletionResponse only
          -- contains CbText and CbToolUse blocks (model output + tool-call
          -- INPUTS). It never contains CbToolResult, so a vault secret value
          -- cannot appear here. The assistant message is appended to the
          -- conversation file; the response metadata (usage / stop) goes to
          -- the entries file.
          liftIO $ do
            now <- getCurrentTime
            let assistantMsg = Message Assistant (rsContent resp)
                conv = msgs <> [assistantMsg]
                entry = EntryRecord
                  { erId = ""
                  , erTimestamp = now
                  , erKind = EKResponse
                  , erConvLen = length conv
                  , erEnvelope = Nothing
                  , erUsage = Just (rsUsage resp)
                  , erStop = Just (rsStop resp)
                  , erDurationMs = Nothing
                  , erHarness = Nothing
                  , erCorrelation = Nothing
                  , erMeta = Map.empty
                  }
            tfwRecordAndAck (aeTranscript env) (TwoFileWrite conv entry)
            aeOnEntry env
          let toolUses = [b | b@CbToolUse{} <- rsContent resp]
          if null toolUses
            then
              -- No complete tool-call blocks. Two sub-cases:
              --   (a) StopMaxTokens: the model was truncated mid-generation
              --       (almost always mid-text or mid-tool-call-block, the
              --       latter leaving no complete CbToolUse). Auto-continue
              --       with a synthetic continuation prompt, capped at
              --       'maxLengthContinueRetries'. After the cap, surface a
              --       user-visible truncation notice and stop. This fixes
              --       the "stopped suddenly with no response" silent-halt
              --       bug where truncated output was shipped as a final
              --       answer.
              --   (b) any other stop reason (StopEnd / StopOther): a genuine
              --       final text answer — emit it and finish the turn.
              if rsStop resp == StopMaxTokens && lenContinue < maxLengthContinueRetries
                then do
                  liftIO (logTruncation (aeLogPath env) (lenContinue + 1))
                  -- Append the partial assistant message (whatever text
                  -- survived truncation) + a synthetic continuation user
                  -- message, then re-loop. The model resumes from the
                  -- partial text. Consume a turn (n - 1) so the max-turns
                  -- guard still bounds total work.
                  let assistantMsg = Message Assistant (rsContent resp)
                      contMsg = textMsg User continuationPrompt
                      conv2 = msgs <> [assistantMsg, contMsg]
                  liftIO $ do
                    now2 <- getCurrentTime
                    let entry2 = EntryRecord
                          { erId = ""
                          , erTimestamp = now2
                          , erKind = EKRequest
                          , erConvLen = length conv2
                          , erEnvelope = Nothing
                          , erUsage = Nothing
                          , erStop = Nothing
                          , erDurationMs = Nothing
                          , erHarness = Nothing
                          , erCorrelation = Nothing
                          , erMeta = Map.empty
                          }
                    tfwRecordAndAck (aeTranscript env) (TwoFileWrite conv2 entry2)
                    aeOnEntry env
                  tEnd <- liftIO getCurrentTime
                  liftIO (logTurnEnd (aeLogPath env) (n - 1) (msDiff tStart tEnd))
                  go (n - 1) (lenContinue + 1) conv2
                else liftIO $ do
                  tEnd <- getCurrentTime
                  logTurnEnd (aeLogPath env) (n - 1) (msDiff tStart tEnd)
                  -- If we exhausted continuation retries on truncation,
                  -- surface a clear truncation notice so the user knows the
                  -- turn did not complete (instead of silently shipping an
                  -- empty/partial reply as a final answer). The partial
                  -- response entry was already recorded above; ccSend adds
                  -- the notice for the CLI/Telegram/Signal channels.
                  let texts = [t | CbText t <- rsContent resp]
                      ModelId m = aeModel env
                      prefix = aeProviderLabel env <> "/" <> m <> "> "
                  if rsStop resp == StopMaxTokens
                    then do
                      logTruncationGiveUp (aeLogPath env)
                      let notice = "(stopped: response truncated at the "
                            <> T.pack (show defaultMaxTokens)
                            <> "-token output limit after "
                            <> T.pack (show maxLengthContinueRetries)
                            <> " continuation attempts. Send any message to \
                            \continue.)"
                          combined = case texts of
                            [] -> notice
                            ts -> T.intercalate "\n" ts <> "\n\n" <> notice
                      ccSend (aeCaps env) (prefix <> combined)
                    else do
                      ccSend (aeCaps env)
                           (prefix <> T.intercalate "\n" texts)
            else do
              results <- mapM dispatchOne toolUses
              let assistantMsg = Message Assistant (rsContent resp)
                  resultMsg = Message User results
              -- Record the tool results to the transcript immediately so
              -- the frontend sees them as soon as each tool call completes
              -- (the dispatchOne calls above already recorded any approval
              -- evidence + the dispatcher's own opcode-invocation entries).
              liftIO $ do
                now2 <- getCurrentTime
                let conv2 = msgs <> [assistantMsg, resultMsg]
                    entry2 = EntryRecord
                      { erId = ""
                      , erTimestamp = now2
                      , erKind = EKRequest
                      , erConvLen = length conv2
                      , erEnvelope = Nothing
                      , erUsage = Nothing
                      , erStop = Nothing
                      , erDurationMs = Nothing
                      , erHarness = Nothing
                      , erCorrelation = Nothing
                      , erMeta = Map.empty
                      }
                tfwRecordAndAck (aeTranscript env) (TwoFileWrite conv2 entry2)
                aeOnEntry env
              tEnd <- liftIO getCurrentTime
              liftIO (logTurnEnd (aeLogPath env) (n - 1) (msDiff tStart tEnd))
              -- A successful tool-call turn made progress, so reset the
              -- length-continuation counter.
              go (n - 1) 0 (msgs <> [assistantMsg, resultMsg])

    dispatchOne :: ContentBlock -> App ContentBlock
    dispatchOne (CbToolUse tcid name input) = do
      let mOp = lookupOp (aeRegistry env) name
      mConfirmed <- checkConfirmation name mOp input
      res <- case mConfirmed of
        Left denyMsg -> pure (Left (Denied denyMsg))
        Right () -> dispatch (aeRegistry env) (aeTranscript env) (aeBackend env) (aeUntrustedIO env) name input
      pure $ case res of
        Left e -> CbToolResult tcid [TrpText (T.pack (show e))] True
        Right r -> CbToolResult tcid (orParts r) (orIsError r)
      where
        -- | The human-confirmation gate. 'Full' autonomy (@--yolo@) bypasses
        -- the gate. 'Supervised' checks the approval cache first; on a miss,
        -- prompts the human via 'ccPrompt' (the reply text is the approval
        -- scope's wire form: @"once"@, @"for_session"@, @"always"@, or
        -- @"rejected"@ on the web; on the CLI, @"y"/@"yes"@ → 'ScopeOnce',
        -- anything else → 'ScopeRejected'). On a hit, records the approval
        -- scope in the transcript, then proceeds (or denies for 'ScopeRejected').
        -- Trusted opcodes skip the gate.
        checkConfirmation :: OpName -> Maybe Opcode -> Value -> App (Either Text ())
        checkConfirmation opName' mOp input' =
          case aeAutonomy env of
            Full -> pure (Right ())
            _ ->
              case mOp of
                Nothing -> pure (Right ())
                Just op ->
                  case opTrust op of
                    Untrusted -> do
                      mCached <- liftIO (checkApproval (aeApprovals env) (aeSession env) opName')
                      case mCached of
                        Just ScopeRejected -> do
                          recordApprovalEvidence opName' input' ScopeRejected
                          pure (Left ("SHELL_EXEC denied by human" <> suffixFor opName'))
                        Just ScopeForSession -> do
                          recordApprovalEvidence opName' input' ScopeForSession
                          pure (Right ())
                        Just ScopeAlways -> do
                          recordApprovalEvidence opName' input' ScopeAlways
                          pure (Right ())
                        Just ScopeOnce -> do
                          -- ScopeOnce is never cached (recordApproval is a
                          -- no-op for it), so this branch is unreachable.
                          -- If it somehow appears, treat it as a cache miss.
                          recordApprovalEvidence opName' input' ScopeOnce
                          pure (Right ())
                        Nothing -> do
                          let prompt = buildConfirmationPrompt opName' input'
                          reply <- liftIO (ccPrompt (aeCaps env) prompt)
                          let scope = parseScopeReply reply
                          liftIO (recordApproval (aeApprovals env) (aeSession env) opName' scope)
                          recordApprovalEvidence opName' input' scope
                          case scope of
                            ScopeRejected -> pure (Left ("SHELL_EXEC denied by human" <> suffixFor opName'))
                            _ -> pure (Right ())
                    _ -> pure (Right ())
        -- | Parse the 'ccPrompt' reply into an 'ApprovalScope'. The web
        -- returns the scope's wire form (@once@, @for_session@, @always@,
        -- @rejected@). The CLI returns free text (@y@/@yes@ → 'ScopeOnce',
        -- anything else → 'ScopeRejected').
        parseScopeReply :: Text -> ApprovalScope
        parseScopeReply reply =
          case parseApprovalScope reply of
            Right scope -> scope
            Left _ ->
              let lower = T.toLower (T.strip reply) in
              if lower == "y" || lower == "yes"
                then ScopeOnce
                else ScopeRejected
        buildConfirmationPrompt :: OpName -> Value -> Text
        buildConfirmationPrompt (OpName n) inp =
          "Allow " <> n <> " " <> T.pack (BLC.unpack (A.encode inp)) <> "? [y/N] "
        suffixFor :: OpName -> Text
        suffixFor (OpName n) = " (" <> n <> ")"
        -- | Record an EKHarness entry in the transcript carrying the opcode
        -- name, input, and approval scope as evidence of the human's
        -- decision. This is separate from the dispatcher's own entry (which
        -- records the invocation, not the approval).
        recordApprovalEvidence :: OpName -> Value -> ApprovalScope -> App ()
        recordApprovalEvidence opName' input' scope = liftIO $ do
          now <- getCurrentTime
          let entry = EntryRecord
                { erId = ""
                , erTimestamp = now
                , erKind = EKHarness
                , erConvLen = 0
                , erEnvelope = Nothing
                , erUsage = Nothing
                , erStop = Nothing
                , erDurationMs = Nothing
                , erHarness = Nothing
                , erCorrelation = Nothing
                , erMeta = Map.fromList
                    [ ("op", object ["name" .= opName'])
                    , ("input", input')
                    , ("approval", object ["scope" .= scope])
                    ]
                }
          tfwRecordAndAck (aeTranscript env) (TwoFileWrite [] entry)
          aeOnEntry env
    dispatchOne other = pure other  -- non-tool blocks never reach dispatchOne

providerComplete :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
providerComplete (SomeProvider p) = complete p

-- | Retry policy for transient provider failures: up to 2 retries after the
-- initial attempt (3 attempts total), with exponential backoff starting at
-- 50ms growing as 50ms, 100ms, 200ms. With only 2 retries the delays stay
-- small, keeping recovery fast while a wedged daemon comes back.
providerRetryPolicy :: RetryPolicyM IO
providerRetryPolicy =
  exponentialBackoff 50_000 <> limitRetries 2

-- | Is a provider error text transient (worth retrying)? Transport failures
-- (the common "Ollama not running" case), rate limits (HTTP 429), and server
-- errors (HTTP 5xx) are transient — the daemon might come back, a rate limit
-- might clear, a 5xx might be a transient upstream fault. Auth errors (401),
-- bad requests (400), and decode failures are permanent — retrying wastes
-- time and delays surfacing the real problem to the user.
isTransientError :: Text -> Bool
isTransientError err =
  any (`T.isInfixOf` err) transientMarkers
  where
    transientMarkers =
      [ "could not reach"           -- Ollama transport failure
      , "connection or transport error"  -- Anthropic transport failure
      , "HTTP 429"                  -- rate limit (Anthropic + Ollama)
      , "HTTP 500"                  -- server error
      , "HTTP 502"                  -- bad gateway
      , "HTTP 503"                  -- service unavailable
      , "HTTP 504"                  -- gateway timeout
      ]

-- | Call the provider with retry: up to 2 retries on transient errors with
-- exponential backoff. A non-retryable error (auth, bad request) returns
-- immediately after the first attempt. The final result (success or the last
-- error) is returned to the caller, which records it in the transcript.
providerCompleteWithRetry
  :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
providerCompleteWithRetry sp req =
  retrying providerRetryPolicy shouldRetry $ \_ -> providerComplete sp req
  where
    shouldRetry _ (Left err) = pure (isTransientError err)
    shouldRetry _ (Right _)  = pure False

-- | When the debug-transcript flag is set ('aeDebugRequestsPath' = 'Just path'),
-- append the full 'CompletionRequest' (one JSONL line, with trailing newline)
-- to @requests.jsonl@. The contract: each line is the complete request exactly
-- as sent to the LLM, including the full 'crMessages' history. When the path
-- is 'Nothing' (the default), this is a no-op. Best-effort: an IO error is
-- swallowed (the debug file must never break the agent loop).
appendDebugRequest :: Maybe FilePath -> CompletionRequest -> IO ()
appendDebugRequest Nothing _ = pure ()
appendDebugRequest (Just path) req =
  let line = BL.toStrict (A.encode req) <> "\n"
  in IO.withFile path IO.AppendMode (`BS.hPutStr` line)
     `catch` \(_ :: SomeException) -> pure ()

-- | Compute the millisecond difference between two 'UTCTime' timestamps
-- (for turn-duration logging).
msDiff :: UTCTime -> UTCTime -> Integer
msDiff start end = round (realToFrac (diffUTCTime end start) * 1000 :: Double)