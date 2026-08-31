{-# LANGUAGE OverloadedStrings #-}
-- | The turn loop: user message -> provider completion -> opcode dispatch ->
-- tool results -> repeat until no tool calls, then emit the final text. Fed only
-- after Seal.Ingest has classified input as a PlainMessage. Bounded by aeMaxTurns.
module Seal.Agent.Loop
  ( runTurn
  , defaultMaxTokens
  , aggregateStreamEvents
  , stripToolCallXml
  ) where

import Control.Exception (SomeException, catch)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)
import qualified System.IO as IO
import System.Timeout (timeout)

import Seal.Agent.Env (AgentEnv (..))
import Seal.Core.MessageSource
  ( MessageSource (..), conversationIdText )
import Seal.Core.Types (ModelId (..), OpName (..), TrustLevel (..))
import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Handles.AskReply
  ( ApprovalScope (..), checkApproval, parseApprovalScope, recordApproval )
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Dispatch (DispatchError (..), dispatch)
import Seal.Tools.Exec.Abort (clearAbort, isAborted)
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

-- | Hard timeout for a single provider streaming call, in microseconds.
-- 5 minutes gives generous headroom for large contexts on remote models
-- (the Ollama HTTP client has its own 5-minute response timeout; this is
-- a safety net for a stalled connection that never closes). If the stream
-- does not complete within this window, the turn aborts with a provider
-- error so the session does not hang forever in "thinking" with no log
-- output. The error is logged to seal.log and surfaced to the user as a
-- normal provider error (not an exception), so the bracket cleanup in
-- the send path still fires the idle broadcast.
streamTimeoutUs :: Int
streamTimeoutUs = 5 * 60 * 1_000_000

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
  -- Clear the per-turn abort flag at turn entry (design: clearAbort fires
  -- once at runTurn entry, before any tool call; a mid-turn abort keeps the
  -- flag set until the next turn begins).
  liftIO (clearAbort (aeAbortFlag env))
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
    -- write (no fsync latency at turn start). In the fsync path, also fire
    -- the per-entry broadcast hook (aeOnEntry) so the web frontend sees the
    -- user's message appear live — without this, the user message is
    -- written but never broadcast, so the transcript area stays blank
    -- until the first response entry lands (after the full LLM stream
    -- completes). The async path skips aeOnEntry because the entry may
    -- not be on disk yet (the read would return stale data).
    case aeOnUserMessage env of
      Just after -> do
        tfwRecordAndAck (aeTranscript env) (TwoFileWrite turn0 entry)
        liftIO after
        liftIO (aeOnEntry env)
      Nothing ->
        tfwRecordAsync (aeTranscript env) (TwoFileWrite turn0 entry)
  go (aeMaxTurns env) 0 turn0
  where
    -- | Fan out the final user-visible text to every chat channel subscribed
    -- to the session ('aeOnStop'). This does NOT call 'ccSend' (the arrival
    -- channel); the stop branches handle that separately, guarded by
    -- 'alreadySentText' so the arrival channel doesn't get double-delivered
    -- when text was already streamed.
    notifyStop :: Text -> IO ()
    notifyStop text =
      case aeOnStop env of
        Just fanout -> fanout text
        Nothing     -> pure ()
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
      notifyStop stopMsg
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
      -- Stream the completion, aggregating events into ContentBlocks. Text
      -- deltas are broadcast live via ccSend (CLI/Telegram/Signal) so the
      -- user sees incremental output. This replaces the blocking
      -- providerCompleteWithRetry call — the first token arrives in ~2s
      -- instead of waiting for the entire response (which could take 74+s
      -- for large contexts on remote models, hitting the 90s timeout).
      -- Events are collected in an IORef so we can reconstruct the final
      -- ContentBlocks for the transcript entry after the stream completes.
      collectedRef <- liftIO (newIORef ([] :: [StreamEvent]))
      let streamSends = ccStreaming (aeCaps env)
      let isTransient = isTransientError
      -- Wrap the stream in a hard timeout so a stalled provider
      -- connection (TCP open but no data) cannot hang the session
      -- forever in "thinking". On timeout, the turn surfaces a provider
      -- error — logged to seal.log + the transcript — and the bracket@.
      -- cleanup in the send path fires the idle broadcast.
      -- Race the provider stream against the abort-poll so a /stop
      -- (web POST /api/sessions/:id/stop, CLI Ctrl+C, channel /stop)
      -- interrupts the in-flight LLM call, not just tool calls. When
      -- abort wins the race, the stream is cancelled and a "(stopped)"
      -- message is recorded — the user can immediately send a new
      -- prompt. The abort poll interval matches the tool-call poll
      -- (100ms, from ttcAbortPollMicros).
      let abortPoll = do
            aborted <- isAborted (aeAbortFlag env)
            if aborted then pure () else do
              threadDelay 100_000
              abortPoll
      mResult <- liftIO (timeout streamTimeoutUs $
        race abortPoll
             (providerStreamWithRetry (aeProvider env) isTransient req (\ev -> do
               case ev of
                 StreamTextChunk delta
                   | streamSends -> ccSend (aeCaps env) delta
                 _ -> pure ()
               modifyIORef' collectedRef (++ [ev])
               pure True)))
      let estream = case mResult of
            Nothing -> Left "stream timed out (no data for 5 minutes)"
            Just (Left ()) -> Left "(stopped)"
            Just (Right r) -> r
      case estream of
        Left err -> liftIO $ do
          -- Distinguish a user-initiated stop from a genuine provider
          -- error. "(stopped)" is the abort-signal message; everything
          -- else is a provider failure.
          let isStop = err == "(stopped)"
          unless isStop $ logProviderError (aeLogPath env) err
          let errMsg = if isStop then err else "provider error: " <> err
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
          notifyStop errMsg
        Right outcome -> do
          events <- liftIO (readIORef collectedRef)
          let resp = aggregateStreamEvents events outcome
          handleResponse env tStart n lenContinue msgs resp streamSends

    -- | Handle a completed provider response: record it to the transcript,
    -- then branch on tool calls vs final text vs StopMaxTokens. When
    -- @alreadySentText@ is True, the text was already streamed live via
    -- ccSend (streaming path) — don't re-send the full text, only send the
    -- prefix / truncation notice if applicable.
    handleResponse :: AgentEnv -> UTCTime -> Int -> Int -> [Message] -> CompletionResponse -> Bool -> App ()
    handleResponse env' tStart n lenContinue msgs resp _alreadySentText = do
      -- Record the provider response.
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
        tfwRecordAndAck (aeTranscript env') (TwoFileWrite conv entry)
        aeOnEntry env'
      let toolUses = [b | b@CbToolUse{} <- rsContent resp]
      if null toolUses
        then
          if rsStop resp == StopMaxTokens && lenContinue < maxLengthContinueRetries
            then do
              liftIO (logTruncation (aeLogPath env') (lenContinue + 1))
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
                tfwRecordAndAck (aeTranscript env') (TwoFileWrite conv2 entry2)
                aeOnEntry env'
              tEnd <- liftIO getCurrentTime
              liftIO (logTurnEnd (aeLogPath env') (n - 1) (msDiff tStart tEnd))
              go (n - 1) (lenContinue + 1) conv2
            else liftIO $ do
              tEnd <- getCurrentTime
              logTurnEnd (aeLogPath env') (n - 1) (msDiff tStart tEnd)
              let texts = [t | CbText t <- rsContent resp]
                  ModelId m = aeModel env'
                  prefix = aeProviderLabel env' <> "/" <> m <> "> "
              if rsStop resp == StopMaxTokens
                then do
                  logTruncationGiveUp (aeLogPath env')
                  let notice = "(stopped: response truncated at the "
                        <> T.pack (show defaultMaxTokens)
                        <> "-token output limit after "
                        <> T.pack (show maxLengthContinueRetries)
                        <> " continuation attempts. Send any message to \
                        \continue.)"
                      combined = case texts of
                        [] -> notice
                        ts -> T.intercalate "\n" ts <> "\n\n" <> notice
                  -- The truncation notice is always sent to the arrival
                  -- channel (it's new information — the user needs to know
                  -- the turn was truncated), even if the partial text was
                  -- already streamed.
                  ccSend (aeCaps env') (prefix <> combined)
                  notifyStop (prefix <> combined)
                else do
                  -- Normal final answer: text was already streamed live;
                  -- don't re-send via ccSend (would double-deliver). Only
                  -- fan out to other chat channels via notifyStop.
                  -- For non-streaming channels (Telegram, Signal — chStreaming
                  -- = False), alreadySentText is False, so ccSend would fire.
                  -- But notifyStop (replyFanout) already sends to ALL
                  -- subscribed channels INCLUDING the arrival channel. So
                  -- ccSend would double-deliver. Fix: skip ccSend entirely;
                  -- replyFanout handles all delivery (it sends to every
                  -- subscribed channel, which includes the arrival one).
                  notifyStop (prefix <> T.intercalate "\n" texts)
        else do
          results <- mapM dispatchOne toolUses
          -- Abort guard: if a tool call was aborted mid-flight (the user
          -- clicked stop, set the abort flag), terminate the turn
          -- immediately instead of feeding the aborted tool results back
          -- to the LLM and continuing. Without this guard the loop would
          -- recurse into `go`, the LLM would emit a follow-up response,
          -- and the tab would stay "thinking" until that response
          -- completes — the user-visible stop button would appear to do
          -- nothing. Mirrors the stream-abort `Left "(stopped)"` path
          -- above so the bracket cleanup fires the idle broadcast.
          aborted <- liftIO (isAborted (aeAbortFlag env'))
          if aborted
            then liftIO $ do
              let stopMsg = "(stopped)"
                  assistantMsg = Message Assistant (rsContent resp)
                  resultMsg = Message User results
                  conv = msgs <> [assistantMsg, resultMsg]
                          <> [Message Assistant [CbText stopMsg]]
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
              tfwRecordAndAck (aeTranscript env') (TwoFileWrite conv entry)
              aeOnEntry env'
              ccSend (aeCaps env') stopMsg
              notifyStop stopMsg
            else do
              let assistantMsg = Message Assistant (rsContent resp)
                  resultMsg = Message User results
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
                tfwRecordAndAck (aeTranscript env') (TwoFileWrite conv2 entry2)
                aeOnEntry env'
              tEnd <- liftIO getCurrentTime
              liftIO (logTurnEnd (aeLogPath env') (n - 1) (msDiff tStart tEnd))
              go (n - 1) 0 (msgs <> [assistantMsg, resultMsg])

    dispatchOne :: ContentBlock -> App ContentBlock
    dispatchOne (CbToolUse tcid name input) = do
      let mOp = lookupOp (aeRegistry env) name
      mConfirmed <- checkConfirmation name mOp input
      res <- case mConfirmed of
        Left denyMsg -> pure (Left (Denied denyMsg))
        Right () -> dispatch (aeRegistry env) (aeTranscript env) (aeBackend env) (aeUIOEnv env) (aeToolTimeout env) (aeAbortFlag env) name input
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
                          -- The confirmation gate's prompt (Allow <NAME>
                          -- <JSON>? [y/N]) is NOT model text, so it must be
                          -- sent to the channel. ccPrompt no longer sends
                          -- (the model already streamed ASK_HUMAN text), so
                          -- we send here.
                          liftIO (ccSend (aeCaps env) prompt)
                          reply <- liftIO (ccPrompt (aeCaps env) (AskPrompt prompt []))
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

-- | Aggregate a list of 'StreamEvent's (collected during streaming) into a
-- 'CompletionResponse' for the transcript. Text chunks are concatenated into
-- a single 'CbText' block (with stray tool-call XML stripped — see
-- 'stripToolCallXml'); tool-call start/end pairs become 'CbToolUse'
-- blocks. The stop reason + usage come from the 'StreamOutcome'.
aggregateStreamEvents :: [StreamEvent] -> StreamOutcome -> CompletionResponse
aggregateStreamEvents events outcome =
  CompletionResponse blocks (soStop outcome) (soUsage outcome)
  where
    textChunks = [t | StreamTextChunk t <- events]
    textBlocks = [CbText (stripToolCallXml (T.intercalate "" textChunks))
                 | not (null textChunks)]
    toolBlocks = [CbToolUse tcid name args
                | StreamToolEnd tcid name args <- events]
    blocks = textBlocks <> toolBlocks

-- | Upper bound on how far back a truncation-tail scan looks (chars). The
-- tail of a StopMaxTokens response can contain a partial tool-call XML
-- opening tag (e.g. @\<invoke name="FILE_RE@); if the continuation prepends
-- the last chunk of the prior text (which carries that partial tag) to the
-- new stream's first chunk, the strip below would otherwise have to rescan
-- the entire continuation text. Cap the re-scan window so stripping stays
-- O(1) amortized per continuation.
maxPartialTagScan :: Int
maxPartialTagScan = 512

-- | Strip leaked tool-call XML from streamed assistant text.
--
-- Some provider stacks (observed with GLM via Ollama's cloud endpoint, in
-- sessions 20260831-162314-870 / 20260831-162806-923) occasionally emit a
-- tool call as XML in the text stream instead of a structured tool_calls
-- chunk — e.g. @\<invoke name="FILE_READ">\<^arg_key>path\<^\/arg_key>...\<\/invoke>@.
-- If that text lands in the transcript as @CbText@ it (a) confuses the
-- model on subsequent turns (it reads its own half-parsed tool call as
-- prose) and (b) renders as garbage in the frontend. When the provider
-- ALSO surfaces the structured @tool_calls@ for the same call (the normal
-- case), the XML is redundant; when it does not, the call is unactionable
-- markup either way. Strip it, but leave normal prose (including literal
-- XML in fenced code contexts that doesn't match the tool-call shape) alone.
--
-- Stripped shapes (case-insensitive, allow whitespace around tags):
--
--   * a complete @\<invoke name="..."\>...\<\/invoke>@ block
--   * orphan @\<\/invoke>@ / @\<function_calls>@ / @\<\/function_calls>@ /
--     @\<tool_call>@ / @\<\/tool_call>@ tags
stripToolCallXml :: Text -> Text
stripToolCallXml t0 =
  let -- 0. Remove complete blocks FIRST: an intact closer at the tail
      -- must not be mistaken for a truncation cut by the partial-tail
      -- scan below (which would otherwise eat real content).
      t2 = dropBlocks "<invoke" "</invoke>"
                  (dropToolCallBlock t0)
      -- 1. Drop a trailing partial opening tag (a StopMaxTokens cut can
      --    leave e.g. an unfinished '<invoke na' at the end of the text).
      t1b = dropTrailingPartialTag t2
      -- 2. Remove orphan tags (unterminated blocks whose opener was cut,
      --    or a stray close tag the provider emitted).
      t3 = T.replace oInvokeClose "" t1b
      t4 = T.replace oFcOpen "" t3
      t5 = T.replace oFcClose "" t4
      t6 = T.replace oToolOpen "" t5
      t7 = T.replace oToolClose "" t6
      -- 3. Remove orphan param tags (leaked args wrap key/value in
      --    \<arg_key\>/\<arg_value\> tags; when the surrounding
      --    \<invoke\> block was already removed these are strays).
      t8 = T.replace paramKeyOpen "" t7
      t9 = T.replace paramKeyClose "" t8
      t10 = T.replace paramValOpen "" t9
      t11 = T.replace paramValClose "" t10
      -- 5. Remove a trailing unterminated opener (its closer was never
      --    emitted, e.g. a truncation cut mid-block): if an opener
      --    appears in the last maxPartialTagScan chars and no closer
      --    follows it, drop from the opener to the end of the text.
      t12 = dropTrailingUnterminated t11
  in t12
  where
    oInvokeClose = "</invoke>"
    oFcOpen      = "<function_calls>"
    oFcClose     = "</function_calls>"
    oToolOpen    = "<tool_call>"
    oToolClose   = "</tool_call>"
    paramKeyOpen  = "<arg_key>"
    paramKeyClose = "</arg_key>"
    paramValOpen  = "<arg_value>"
    paramValClose = "</arg_value>"

-- | Remove a complete @\<tool_call>...\<tool_call>\/tool_call\>@ span. The opener
-- carries no attributes, so this is a plain two-marker scan (unlike
-- 'dropBlocks', whose attribute handling misfires on JSON bodies that
-- contain no '@<@' but do contain a close tag later in the text).
dropToolCallBlock :: Text -> Text
dropToolCallBlock = go
  where
    open = "<tool_call>"
    close = "</tool_call>"
    go acc = case T.breakOn open acc of
      (before, rest)
        | T.null rest -> acc
        | otherwise   ->
            let afterOpen = T.drop (T.length open) rest
            in case T.breakOn close afterOpen of
                 (_, afterCloseRest)
                   | T.null afterCloseRest -> acc  -- no close: leave
                 (_, afterClose)           -> go (before <> T.drop (T.length close) afterClose)

-- | Remove every complete @open ... close@ span (non-greedy: up to the
-- FIRST closing tag), including the tags themselves. Unterminated blocks
-- are left alone (the orphan-tag pass handles their remnants).
dropBlocks :: Text -> Text -> Text -> Text
dropBlocks open close = go
  where
    go acc = case breakOnTag acc of
      Nothing -> acc
      Just (before, afterOpenTag) ->
        case T.breakOn close afterOpenTag of
          (_, afterCloseRest)
            | T.null afterCloseRest -> acc  -- no close: leave as-is
          (_, afterClose)           -> go (before <> T.drop (T.length close) afterClose)
    -- Find the open tag (with any attributes up to its closing '>') and
    -- return (text before it, text after the tag's '>').
    breakOnTag acc = case T.breakOn open acc of
      (before, rest)
        | T.null rest -> Nothing
        | otherwise   ->
            let afterName = T.drop (T.length open) rest
            in case T.breakOn ">" afterName of
                 (attrs, gtRest)
                   -- attrs is everything up to the first '>' — treat it
                   -- as the tag's attribute list only when it contains
                   -- no other '<' (a nested '<' means this '>' closes a
                   -- LATER tag, not this opener; the match was a false
                   -- positive on e.g. '<tool_call>{...json...}'.
                   | T.isInfixOf "<" attrs -> Nothing
                   | T.null gtRest          -> Nothing  -- no '>' at all
                   | otherwise              -> Just (before, T.drop 1 gtRest)

-- | If a tool-call opener (@<invoke@, @<function_calls@, @<tool_call@)
-- appears within the last 'maxPartialTagScan' chars and NO closer follows
-- it, the tail is an unterminated leaked tool call — drop from the opener
-- to the end of the text. Catches blocks the provider broke across a
-- truncation boundary (opener present, close never emitted).
dropTrailingUnterminated :: Text -> Text
dropTrailingUnterminated t =
  case openIdx of
    Nothing -> t
    Just i ->
      let afterOpen = T.drop i t
      in if any (`T.isInfixOf` afterOpen) closers then t else T.take i t
  where
    closers = ["</invoke>", "</function_calls>", "</tool_call>"]
    openers = ["invoke", "function_calls", "tool_call"]
    -- the LAST opener occurrence inside the trailing window (global
    -- index, with a tag-ish boundary after the name — prose like
    -- "<invoke-ish" must not match)
    openIdx =
      let window = T.takeEnd maxPartialTagScan t
          base   = T.length t - T.length window
          hits   = [ (base + i, o)
                   | o <- openers
                   , i <- reverse [0 .. T.length window - (T.length o + 1)]
                   , T.index window i == '<'
                   , Just rest <- [T.stripPrefix o (T.drop (i + 1) window)]
                   , tagBoundary rest ]
      in case hits of
           []           -> Nothing
           ((i, _) : _) -> Just i
    tagBoundary rest = case T.uncons rest of
      Nothing     -> True
      Just (c, _) -> c == ' ' || c == '>' || c == '/' || c == '\t' || c == '\n' || c == '\r'

-- | Drop a truncated tool-call XML tag at the very end of the text (a
-- StopMaxTokens cut can leave an unfinished tag as the final characters).
-- Only the last 'maxPartialTagScan' chars are scanned: a final unmatched
-- '<' that would begin one of the known tool-call tag names (case-
-- insensitive) is cut, along with everything after it. A '<' in prose
-- ("5 < 6") never matches a known tag-name prefix, so ordinary text is
-- untouched.
dropTrailingPartialTag :: Text -> Text
dropTrailingPartialTag t =
  case ltIdx of
    Nothing -> t
    Just i ->
      let afterLt = T.toLower (T.drop (i + 1) t)
      in if any (tagStart afterLt) tagPrefixes
           then T.take i t
           else t
  where
    tagPrefixes = ["invoke", "function_calls", "tool_call", "/invoke",
                   "/function_calls", "/tool_call"]
    -- The text right after '<' begins a known tag name AND the name is
    -- followed by a tag-ish boundary (whitespace, '>', '/', or end of
    -- text). A hyphen (as in prose like "<invoke-ish>") disqualifies it —
    -- that's an ordinary word, not a tag.
    tagStart after tag =
      case T.stripPrefix tag after of
        Nothing   -> False
        Just rest -> case T.uncons rest of
          Nothing     -> True  -- cut exactly after the tag name
          Just (c, _) -> c == ' ' || c == '>' || c == '/' || c == '\t' || c == '\n' || c == '\r'
    -- the last '<' within the trailing scan window (global index), if any
    ltIdx =
      let window = T.takeEnd maxPartialTagScan t
          base   = T.length t - T.length window
      in case [base + i | i <- reverse [0 .. T.length window - 1], T.index window i == '<'] of
           (i : _) -> Just i
           []      -> Nothing
