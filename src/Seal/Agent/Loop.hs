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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)
import qualified System.IO as IO

import Seal.Agent.Env (AgentEnv (..))
import Seal.Core.ChannelKind (channelKindToText)
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
  ( logTurnStart, logTurnEnd, logProviderError, logMaxTurns )
import Seal.Transcript.Entries
  ( EnvelopeDelta (..), EntryKind (..), EntryRecord (..) )
import Seal.Types.App (App)

-- | Fold the 'aeMessageSource' into the request @erMeta@: a @channel@
-- key carrying the 'ChannelKind' text tag, and a @conversationId@ key
-- carrying the server-derived conversation id. 'Nothing' (the CLI TUI
-- path) yields an empty map, leaving the transcript unchanged.
requestMeta :: Maybe MessageSource -> Map.Map Text Value
requestMeta Nothing = Map.empty
requestMeta (Just ms) = Map.fromList
  [ ("channel", String (channelKindToText (msChannelKind ms)))
  , ("conversationId", String (conversationIdText (msConversationId ms)))
  ]

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
          , edMaxTokens = Just 4096
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
          , erMeta = requestMeta (aeMessageSource env)
          }
    tfwRecordAsync (aeTranscript env) (TwoFileWrite turn0 entry)
  go (aeMaxTurns env) turn0
  where
    go :: Int -> [Message] -> App ()
    go 0 msgs = liftIO $ do
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
    go n msgs = do
      liftIO (logTurnStart (aeLogPath env) n)
      tStart <- liftIO getCurrentTime
      let req = CompletionRequest
                  { crModel = aeModel env
                  , crSystem = aeSystem env
                  , crMessages = msgs
                  , crTools = registryToolDefs' (aeOnDemandSchemas env) (aeRegistry env)
                  , crToolChoice = ToolAuto
                  , crMaxTokens = 4096
                  }
      liftIO (appendDebugRequest (aeDebugRequestsPath env) req)
      eresp <- liftIO (providerComplete (aeProvider env) req)
      case eresp of
        Left err -> liftIO $ do
          logProviderError (aeLogPath env) err
          ccSend (aeCaps env) ("provider error: " <> err)
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
            then liftIO $ do
              tEnd <- getCurrentTime
              logTurnEnd (aeLogPath env) (n - 1) (msDiff tStart tEnd)
              let ModelId m = aeModel env
                  prefix    = aeProviderLabel env <> "/" <> m <> "> "
              ccSend (aeCaps env)
                   (prefix <> T.intercalate "\n" [t | CbText t <- rsContent resp])
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
              go (n - 1) (msgs <> [assistantMsg, resultMsg])

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