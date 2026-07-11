{-# LANGUAGE OverloadedStrings #-}
-- | The turn loop: user message -> provider completion -> opcode dispatch ->
-- tool results -> repeat until no tool calls, then emit the final text. Fed only
-- after Seal.Ingest has classified input as a PlainMessage. Bounded by aeMaxTurns.
module Seal.Agent.Loop
  ( runTurn
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)

import Seal.Agent.Env (AgentEnv (..))
import Seal.Core.ChannelKind (channelKindToText)
import Seal.Core.MessageSource
  ( MessageSource (..), conversationIdText )
import Seal.Core.Types (ModelId (..))
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..))
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (OpResult (..))
import Seal.ISA.Registry (registryToolDefs)
import Seal.Providers.Class
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
          , edTools = Just (registryToolDefs (aeRegistry env))
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
    go 0 _ = liftIO (ccSend (aeCaps env) "(stopped: too many tool turns)")
    go n msgs = do
      let req = CompletionRequest
                  { crModel = aeModel env
                  , crSystem = aeSystem env
                  , crMessages = msgs
                  , crTools = registryToolDefs (aeRegistry env)
                  , crToolChoice = ToolAuto
                  , crMaxTokens = 4096
                  }
      eresp <- liftIO (providerComplete (aeProvider env) req)
      case eresp of
        Left err ->
          liftIO (ccSend (aeCaps env) ("provider error: " <> err))
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
            tfwRecordAsync (aeTranscript env) (TwoFileWrite conv entry)
          let toolUses = [b | b@CbToolUse{} <- rsContent resp]
          if null toolUses
            then liftIO $
                   let ModelId m = aeModel env
                       prefix    = aeProviderLabel env <> "/" <> m <> "> "
                   in ccSend (aeCaps env)
                        (prefix <> T.intercalate "\n" [t | CbText t <- rsContent resp])
            else do
              results <- mapM dispatchOne toolUses
              let assistantMsg = Message Assistant (rsContent resp)
                  resultMsg = Message User results
              go (n - 1) (msgs <> [assistantMsg, resultMsg])

    dispatchOne :: ContentBlock -> App ContentBlock
    dispatchOne (CbToolUse tcid name input) = do
      res <- dispatch (aeRegistry env) (aeTranscript env) (aeBackend env) (aeExecBackend env) name input
      pure $ case res of
        Left e -> CbToolResult tcid [TrpText (T.pack (show e))] True
        Right r -> CbToolResult tcid (orParts r) (orIsError r)
    dispatchOne other = pure other  -- non-tool blocks never reach dispatchOne

providerComplete :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
providerComplete (SomeProvider p) = complete p