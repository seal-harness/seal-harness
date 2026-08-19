-- | The agent's capability bundle — everything 'runTurn' needs, injected so the
-- loop is fully fakeable (no concrete provider/IO in its type).
module Seal.Agent.Env
  ( AgentEnv (..)
  , TurnEnv (..)
  , mkSessionAgentEnv
  ) where

import Data.Text (Text)

import Seal.Channel.Caps (ChannelCaps)
import Seal.Core.MessageSource (MessageSource)
import Seal.Core.Types (ModelId, SessionId)
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Handles.Transcript (TwoFileHandle (..))
import Seal.ISA.Opcode (BackendExec, localBackend)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)
import Seal.Security.Policy (AutonomyLevel)
import Seal.Tools.Exec.Abort (AbortFlag)
import Seal.Tools.Exec.UIO.Internal (UIOEnv)
import Seal.Tools.Timeout (ToolTimeoutConfig)

data AgentEnv = AgentEnv
  { aeProvider :: SomeProvider
    -- | The provider's label (e.g. @\"ollama\"@), used only for display —
    -- 'aeProvider' is existential and carries no name of its own.
  , aeProviderLabel :: Text
  , aeModel :: ModelId
  , aeSystem :: Maybe Text
    -- ^ The system prompt injected at the start of every turn. For the
    -- main session this comes from the bound default agent's 'adSystem';
    -- for a forked sub-agent it comes from the def's 'adSystem'.
  , aeRegistry :: Registry
  , aeTranscript :: TwoFileHandle
  , aeBackend :: BackendExec
  , aeUIOEnv :: UIOEnv
    -- ^ The untrusted-execution environment (carrying the 'UntrustedIO'
    -- capability handle + the Git 'CloneDeps' surface), threaded to
    -- 'Seal.ISA.Dispatch.dispatch' for Untrusted opcodes. Backend (local
    -- FS vs SSH transport) is selected once at wiring time via
    -- 'mkSessionExec' (which builds the 'UIOEnv' from the 'SecurityConfig');
    -- the opcode never sees the backend, only the capability. Trusted/Audited
    -- opcodes ignore it (the GADT 'Opcode' has no 'UIOEnv' field for them —
    -- type-level capability scoping, spec §4/§8). The 'CloneDeps' lives
    -- inside the 'UIOEnv' (via 'uieCloneDeps'), so Git opcodes source it
    -- from here rather than a separate field.
  , aeAbortFlag :: AbortFlag
    -- ^ The session-scoped abort flag. Set by the channel layer (Signal
    -- @\/stop@, CLI Ctrl+C, Web @POST /api/sessions/:id/stop@) to cancel
    -- in-flight tool calls. Polled by the dispatch wrapper
    -- ('Seal.Tools.Exec.Timeout.runWithTimeoutAbortRetry') during the
    -- three-way race. Cleared once at 'runTurn' entry (before any tool
    -- call); a mid-turn abort keeps the flag set until the next turn.
    -- Looked up from a 'Seal.Tools.Exec.Abort.SessionAbortRegistry' by
    -- 'SessionId' (the web gateway has no 'AgentEnv' at the @/stop@ call
    -- site — the registry is the vehicle, design Blocker Resolution #2).
  , aeToolTimeout :: ToolTimeoutConfig
    -- ^ The per-call timeout/retry config (default 120s, max 600s, 3
    -- retries, 2s base delay, 2.0 backoff, 50KB output cap). Loaded from
    -- @config.toml@ @[tool_timeout]@ at startup via
    -- 'Seal.Config.File.toolTimeoutConfig'.
  , aeCaps :: ChannelCaps
  , aeSession :: SessionId
  , aeMaxTurns :: Int
  , aeChannel :: Text
    -- ^ The channel this turn's message arrived on (e.g. @\"telegram\"@,
    -- @\"web\"@, @\"cli\"@). This is the /arrival/ channel, NOT the
    -- session's channel-of-origin — a web message sent to a
    -- Telegram-created session carries @\"web\"@, not @\"telegram\"@. Each
    -- wiring site passes the channel the message actually came in on:
    -- the web gateway passes @"web"@, the CLI passes @"cli"@, and the
    -- inbox-channel loop passes @smChannel@ (correct because an inbox
    -- session is always created on the channel its messages arrive on).
    -- 'runTurn' stamps this into every request entry's @erMeta@ @channel@
    -- field so the frontend can attribute every user message to the
    -- channel it came from. This is the single source of truth for channel
    -- provenance — 'MessageSource' carries the finer-grained conversation
    -- id + user id, but the channel label itself always comes from here.
  , aeMessageSource :: Maybe MessageSource
    -- ^ The authenticated-transport identity of the inbound message this
    -- turn is answering. 'Nothing' for the CLI TUI and the web (which
    -- bypass 'MessageSource'); @'Just' ms@ for channels that carry one
    -- (Signal, Telegram). 'runTurn' folds the 'msConversationId' into the
    -- request 'EntryRecord's @erMeta@ @conversationId@ field. The
    -- @channel@ field comes from 'aeChannel' (above), NOT from here, so
    -- every channel — including those with no 'MessageSource' — is
    -- attributed.
  , aeAutonomy :: AutonomyLevel
    -- ^ The operator-selected autonomy level. 'Full' (@--yolo@) bypasses the
    -- human-confirmation gate for Untrusted opcodes (they run immediately after
    -- the ACK-before-execute audit). 'Supervised' (the default) prompts the
    -- human via 'ccPrompt' before executing any Untrusted opcode; a non-"yes"
    -- reply cancels the call (the model sees a denied result). 'Deny' is
    -- enforced by the opcode's own authorize gate (rejected before the
    -- dispatcher runs).
  , aeApprovals :: ApprovalCache
    -- ^ The approval cache for Untrusted opcodes under 'Supervised' autonomy.
    -- Records "for this session" and "always" approvals so subsequent calls
    -- to the same opcode skip the prompt. 'ScopeRejected' entries short-
    -- circuit to denied. Threaded from the channel wiring (web, CLI, Signal).
  , aeDebugRequestsPath :: Maybe FilePath
    -- ^ When 'Just', every 'CompletionRequest' sent to the LLM is appended
    -- (redundantly, in full) to this file as one JSONL line per request.
    -- The contract: each line is the complete 'CompletionRequest' exactly as
    -- passed to the provider — including the full 'crMessages' history — so
    -- we can debug whether the two-file storage format is correctly feeding
    -- the session history to the LLM. 'Nothing' (the default) means no
    -- debug file is written.
  , aeOnEntry :: IO ()
    -- ^ A hook called by the loop after each transcript entry is recorded
    -- (response entries, tool-result entries, approval-evidence entries).
    -- The web channel wires this to 'broadcastNewEntries' so the frontend
    -- sees new entries live — including tool calls that are pending
    -- confirmation — rather than only at the end of the turn. The CLI and
    -- Signal channels set this to @pure ()@ (no live broadcast needed).
  , aeOnUserMessage :: Maybe (IO ())
    -- ^ When 'Just action', the loop records the initial user message with
    -- 'tfwRecordAndAck' (synchronously fsync'd) and then runs @action@ —
    -- guaranteeing the user message is durable on disk before @action@
    -- runs. Used by the @/bg@ channel path to broadcast a @lists@ snapshot
    -- whose snippet (the first user message) is populated, so the web
    -- sidebar shows the session name immediately rather than after the
    -- first LLM response. 'Nothing' (the default) keeps the async
    -- 'tfwRecordAsync' write (no fsync latency at turn start).
  , aeOnStop :: Maybe (Text -> IO ())
    -- ^ When 'Just fanout', the loop calls @fanout text@ with the final
    -- user-visible text at every stop branch (final answer, truncation
    -- give-up, max-turns stop, provider error). This is the chat-channel
    -- notification hook: wiring sites bind it to 'replyFanout' against the
    -- session's 'ReplyRegistry' so every subscribed chat channel (Telegram,
    -- Signal, …) attached to the tab receives the stop notice — not just
    -- the arrival channel (which 'ccSend' covers). 'Nothing' (the default
    -- for tests and the standalone CLI) means no fan-out; the arrival
    -- channel alone is notified via 'ccSend'.
  , aeOnDemandSchemas :: Bool
    -- ^ When 'True', the loop emits stub @input_schema@s in the @tools@
    -- field (via 'Seal.ISA.Registry.registryToolDefs'') to save tokens,
    -- and the registry is expected to include the @OPCODE_DESCRIBE@ /
    -- @OPCODE_LIST@ opcodes so the model can fetch full schemas on demand.
    -- 'False' (the default) sends full schemas inline, matching the
    -- pre-flag behavior.
  , aeLogPath :: Maybe FilePath
    -- ^ When 'Just', turn lifecycle events (start/end/duration) and failures
    -- (exceptions, provider errors) are appended to this per-session log file
    -- (@\<sessionDir\>\/seal.log@). Best-effort: a write error is swallowed.
    -- Records ONLY events not already in @entries.jsonl@ / @conversation.jsonl@.
    -- 'Nothing' disables per-session logging (the default for tests / fake
    -- transcripts).
  }

-- | A parameter object bundling the per-turn inputs to 'mkSessionAgentEnv'.
-- The fields are collected into one record so call sites construct it with
-- named-field syntax (no positional-counting mistakes) and future additions
-- are a one-field change. Lives here (next to 'AgentEnv') so the unified
-- turn engine ('Seal.Core.TurnEngine') can import it without a cycle with
-- 'Seal.Channel.Cli'.
data TurnEnv = TurnEnv
  { teCaps          :: ChannelCaps
  , teProvider      :: SomeProvider
  , teProviderLabel :: Text
  , teModel         :: ModelId
  , teSession       :: SessionId
  , teSystem        :: Maybe Text
  , teRegistry      :: Registry
  , teTranscript    :: TwoFileHandle
  , teUioEnv        :: UIOEnv
  , teDebugReqPath  :: Maybe FilePath
  , teAutonomy      :: AutonomyLevel
  , teApprovals     :: ApprovalCache
  , teOnEntry       :: IO ()
  , teOnDemand      :: Bool
  , teLogPath       :: Maybe FilePath
  , teMaxTurns      :: Int
  , teOnUserMessage :: Maybe (IO ())
  , teChannel       :: Text
  , teOnStop        :: Maybe (Text -> IO ())
  , teAbortFlag     :: AbortFlag
  , teToolTimeout   :: ToolTimeoutConfig
  }

-- | Build the per-turn 'AgentEnv' from a 'TurnEnv'. The 'aeBackend' is
-- always 'localBackend' (Trusted/Audited opcodes run in-process; Untrusted
-- opcodes source their backend from 'aeUIOEnv', not from here). The
-- 'aeMessageSource' is left 'Nothing' here — the unified turn engine sets
-- it via a record update after construction (it's an inbound-property, not
-- a per-turn-env field).
mkSessionAgentEnv :: TurnEnv -> AgentEnv
mkSessionAgentEnv te = AgentEnv
  { aeProvider   = teProvider te
  , aeProviderLabel = teProviderLabel te
  , aeModel      = teModel te
  , aeSystem     = teSystem te
  , aeRegistry   = teRegistry te
  , aeTranscript = teTranscript te
  , aeBackend    = localBackend
  , aeUIOEnv     = teUioEnv te
  , aeCaps       = teCaps te
  , aeSession    = teSession te
  , aeMaxTurns   = teMaxTurns te
  , aeChannel    = teChannel te
  , aeMessageSource = Nothing
  , aeAutonomy   = teAutonomy te
  , aeApprovals  = teApprovals te
  , aeDebugRequestsPath = teDebugReqPath te
  , aeOnEntry    = teOnEntry te
  , aeOnUserMessage = teOnUserMessage te
  , aeOnStop     = teOnStop te
  , aeOnDemandSchemas = teOnDemand te
  , aeLogPath    = teLogPath te
  , aeAbortFlag  = teAbortFlag te
  , aeToolTimeout = teToolTimeout te
  }
