-- | The agent's capability bundle — everything 'runTurn' needs, injected so the
-- loop is fully fakeable (no concrete provider/IO in its type).
module Seal.Agent.Env
  ( AgentEnv (..)
  ) where

import Seal.Channel.Caps (ChannelCaps)
import Seal.Core.Types (ModelId, SessionId)
import Seal.Handles.Transcript (TranscriptHandle)
import Seal.ISA.Opcode (BackendExec)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)

data AgentEnv = AgentEnv
  { aeProvider :: SomeProvider
  , aeModel :: ModelId
  , aeRegistry :: Registry
  , aeTranscript :: TranscriptHandle
  , aeBackend :: BackendExec
  , aeCaps :: ChannelCaps
  , aeSession :: SessionId
  , aeMaxTurns :: Int
  }
