-- | The agent's capability bundle — everything 'runTurn' needs, injected so the
-- loop is fully fakeable (no concrete provider/IO in its type).
module Seal.Agent.Env
  ( AgentEnv (..)
  ) where

import Data.Text (Text)

import Seal.Channel.Caps (ChannelCaps)
import Seal.Core.MessageSource (MessageSource)
import Seal.Core.Types (ModelId, SessionId)
import Seal.Handles.AskReply (ApprovalCache)
import Seal.Handles.Transcript (TwoFileHandle (..))
import Seal.ISA.Opcode (BackendExec)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)
import Seal.Security.Policy (AutonomyLevel)
import Seal.Tools.Exec.Types (ExecBackend)

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
  , aeExecBackend :: ExecBackend
    -- ^ The untrusted-execution backend (Local vs Remote SSH) threaded to
    -- 'Seal.ISA.Dispatch.dispatch' for Untrusted opcodes. Trusted/Audited
    -- opcodes ignore it (the GADT 'Opcode' has no 'ExecBackend' field for
    -- them — type-level capability scoping, spec §4/§8). 4b-T3 wires this
    -- from the runtime 'UntrustedExecConfig'; 4b-T1 threads it through.
  , aeCaps :: ChannelCaps
  , aeSession :: SessionId
  , aeMaxTurns :: Int
  , aeMessageSource :: Maybe MessageSource
    -- ^ The authenticated-transport identity of the inbound message this
    -- turn is answering. 'Nothing' for the CLI TUI (which bypasses
    -- 'MessageSource'); @'Just' ms@ for channels that carry one (Signal).
    -- 'runTurn' folds the 'msChannelKind' into the request 'EntryRecord's
    -- @erMeta@ @channel@ field and the 'msConversationId' into
    -- @conversationId@, so the transcript records which channel + conversation
    -- each turn served.
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
  , aeOnDemandSchemas :: Bool
    -- ^ When 'True', the loop emits stub @input_schema@s in the @tools@
    -- field (via 'Seal.ISA.Registry.registryToolDefs'') to save tokens,
    -- and the registry is expected to include the @OPCODE_DESCRIBE@ /
    -- @OPCODE_LIST@ opcodes so the model can fetch full schemas on demand.
    -- 'False' (the default) sends full schemas inline, matching the
    -- pre-flag behavior.
  }
