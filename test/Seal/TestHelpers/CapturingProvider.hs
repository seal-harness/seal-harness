{-# LANGUAGE OverloadedStrings #-}
-- | A test provider that records every request it is handed and replies from
-- a scripted queue.
--
-- The shared 'Seal.TestHelpers.ScriptProvider' discards the request: it can
-- prove that a turn produced output, not /what the model was sent/. The
-- subagent-`continue` work needs the latter — a resumed child must see its own
-- prior conversation (S1), must not have its stored goal replayed (S2), and a
-- child killed mid-dispatch must not be sent a dangling @tool_use@ (S5).
--
-- Each 'CapturingProvider' owns its own script queue, so a test that installs
-- one via 'atoChildProviderFn' does not race the parent turn's queue (the
-- ScriptProvider race documented in @AgentIntegrationSpec@). Requests are
-- recorded with the 'ThreadId' that served them, which lets a test compare the
-- thread a wake ran on against the thread that ran the child.
module Seal.TestHelpers.CapturingProvider
  ( CapturingProvider (..)
  , CapturedRequest (..)
  , newCapturingProvider
  , pushScript
  , capturedRequests
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Data.IORef
  (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..), ContentBlock (..)
  , Message, Provider (..), StopReason (..), Usage (..) )

-- | One request the provider was handed: the conversation as the model saw it,
-- and the thread that served it.
data CapturedRequest = CapturedRequest
  { creqThread   :: !ThreadId
  , creqMessages :: ![Message]
  } deriving stock (Show)

-- | The provider: a script queue plus the capture log (oldest first).
data CapturingProvider = CapturingProvider
  { cpScript   :: !(IORef [CompletionResponse])
  , cpCaptured :: !(IORef [CapturedRequest])
  }

instance Provider CapturingProvider where
  complete p req = do
    tid <- myThreadId
    modifyIORef' (cpCaptured p)
      (++ [CapturedRequest tid (crMessages req)])
    let pop rs = case rs of
          (r : rest) -> (rest, Just r)
          []         -> ([], Nothing)
    mResp <- atomicModifyIORef' (cpScript p) pop
    pure (Right (fromMaybe defaultResponse mResp))
  listModels _ = pure (Right [ModelId "llama3.2"])

-- | What an exhausted script yields: a terminal text turn, so a child that
-- runs out of scripted replies still finishes instead of hanging.
defaultResponse :: CompletionResponse
defaultResponse = CompletionResponse [CbText "done"] StopEnd (Usage 0 0)

-- | A provider with the given script. The script is consumed in order across
-- every run the provider serves (spawn, then each continue), which is what
-- makes a multi-run conversation deterministic.
newCapturingProvider :: [CompletionResponse] -> IO CapturingProvider
newCapturingProvider script = do
  scriptRef <- newIORef script
  capturedRef <- newIORef []
  pure CapturingProvider { cpScript = scriptRef, cpCaptured = capturedRef }

-- | Append responses to the script (for a run whose replies are only known
-- once an earlier run has been observed).
pushScript :: CapturingProvider -> [CompletionResponse] -> IO ()
pushScript p rs = modifyIORef' (cpScript p) (++ rs)

-- | Every request so far, oldest first.
capturedRequests :: CapturingProvider -> IO [CapturedRequest]
capturedRequests = readIORef . cpCaptured
