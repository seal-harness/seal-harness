-- | The agent's capability bundle — everything 'runTurn' needs, injected so the
-- loop is fully fakeable (no concrete provider/IO in its type).
module Seal.Agent.Env
  ( AgentEnv (..)
  ) where

import Data.Text (Text)

import Seal.Channel.Caps (ChannelCaps)
import Seal.Core.MessageSource (MessageSource)
import Seal.Core.Types (ModelId, SessionId)
import Seal.Handles.Transcript (TwoFileHandle (..))
import Seal.ISA.Opcode (BackendExec)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)

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
  }
