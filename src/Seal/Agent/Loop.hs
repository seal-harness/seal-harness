{-# LANGUAGE OverloadedStrings #-}
-- | The turn loop: user message -> provider completion -> opcode dispatch ->
-- tool results -> repeat until no tool calls, then emit the final text. Fed only
-- after Seal.Ingest has classified input as a PlainMessage. Bounded by aeMaxTurns.
module Seal.Agent.Loop
  ( runTurn
  ) where

import Control.Exception (SomeException, catch)
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
import Seal.Tools.Exec.Abort (clearAbort)
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
    -- write (no fsync latency at turn start).
    case aeOnUserMessage env of
      Just after -> do
        tfwRecordAndAck (aeTranscript env) (TwoFileWrite turn0 entry)
        liftIO after
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
      -- error — logged to seal.log + the transcript — and the bracket
      -- cleanup in the send path fires the idle broadcast.
      mResult <- liftIO (timeout streamTimeoutUs $
        providerStreamWithRetry (aeProvider env) isTransient req (\ev -> do
          case ev of
            StreamTextChunk delta
              | streamSends -> do
              ccSend (aeCaps env) delta
            _ -> pure ()
          modifyIORef' collectedRef (++ [ev])
          pure True))
      let estream = case mResult of
            Nothing -> Left "stream timed out (no data for 5 minutes)"
            Just r  -> r
      case estream of
        Left err -> liftIO $ do
          logProviderError (aeLogPath env) err
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
        Right () -> dispatch (aeRegistry env) (aeTranscript env) (aeBackend env) (aeUntrustedIO env) (aeToolTimeout env) (aeAbortFlag env) name input
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
-- a single 'CbText' block; tool-call start/end pairs become 'CbToolUse'
-- blocks. The stop reason + usage come from the 'StreamOutcome'.
aggregateStreamEvents :: [StreamEvent] -> StreamOutcome -> CompletionResponse
aggregateStreamEvents events outcome =
  CompletionResponse blocks (soStop outcome) (soUsage outcome)
  where
    textChunks = [t | StreamTextChunk t <- events]
    textBlocks = [CbText (T.intercalate "" textChunks) | not (null textChunks)]
    toolBlocks = [CbToolUse tcid name args
                | StreamToolEnd tcid name args <- events]
    blocks = textBlocks <> toolBlocks