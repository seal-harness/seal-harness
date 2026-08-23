{-# LANGUAGE OverloadedStrings #-}
-- | WU-A: Debug-log redaction spec (addresses review blocker B1).
--
-- Asserts that 'logExecDebug' redacts the values of secret-bearing env
-- keys ('GH_TOKEN', 'GITHUB_TOKEN', 'http.extraHeader') before rendering
-- the log message, so the raw secret never reaches the debug log (and
-- thus never lands on disk if stderr is redirected). The redaction is a
-- defense-in-depth seam on 'logExecDebug' itself, not caller discipline.
--
-- Strategy: install a capture scribe as the process-global logger via
-- 'setGlobalLogger' (the same seam 'logExecDebug' uses via 'globalLogIO'),
-- call 'logExecDebug' (directly, and via the remote-arm 'uioBinExecEnv'
-- which routes through 'runRemoteShellTextEnv'), assert the captured
-- log lines contain @KEY=<redacted>@ and NOT the raw secret. The global
-- logger is restored to the no-op default via 'unsetGlobalLogger' after
-- each test so subsequent tests are unaffected.
module Seal.Tools.Exec.LogRedactionSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Logging.Global (setGlobalLogger, unsetGlobalLogger)
import Seal.Logging.Logger (closeSealLogger, newSealLoggerWithScribe)
import Seal.Tools.Args (mkBinArg, mkBinName)
import Seal.Tools.Exec.Remote (mkFakeRemoteRunner)
import Seal.Tools.Exec.Types
  ( SshConfig (..), mkRemotePath, mkSshHost, mkSshUser
  )
import Seal.Tools.Exec.UntrustedIO (UntrustedIO (..), logExecDebug, mkRemoteUntrustedIO)

import Katip (Severity (..), Scribe (..), permitItem, jsonFormat, Verbosity (V2))

-- | A test scribe that captures log items into an IORef for assertions.
-- Mirrors 'Seal.Logging.LoggerSpec.mkCaptureScribe'.
mkCaptureScribe :: IO (Scribe, IORef [Text])
mkCaptureScribe = do
  ref <- newIORef []
  let scribe = Scribe
        { liPush = \item -> do
            let rendered = jsonFormat False V2 item
            modifyIORef' ref (T.pack (show rendered) :)
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  pure (scribe, ref)

-- | Install a capture scribe as the global logger, run an action, then
-- close the logger and return the captured lines. The global logger ref
-- is always restored to the no-op default (Nothing) after, via
-- 'unsetGlobalLogger', so subsequent tests are unaffected.
withCaptureGlobalLogger :: IO a -> IO (a, [Text])
withCaptureGlobalLogger action = do
  (scribe, ref) <- mkCaptureScribe
  logger <- newSealLoggerWithScribe scribe DebugS
  setGlobalLogger logger
  result <- action
  closeSealLogger logger
  lines_ <- readIORef ref
  unsetGlobalLogger
  pure (result, lines_)

spec :: Spec
spec = describe "Seal.Tools.Exec.UntrustedIO logExecDebug (shows real values for debugging)" $ do

  -- The harness machine is trusted and debug logs are for debugging only.
  -- The real env values (including secrets like GH_TOKEN) are shown so
  -- operators can diagnose credential-injection issues. The redaction
  -- seam (secretEnvKeys/redactEnv) is kept available for future use cases
  -- where logs might be shipped to an untrusted aggregator, but
  -- logExecDebug itself does NOT redact.

  it "shows the real GH_TOKEN value in the env extras (local arm shape)" $ do
    (_, lines_) <- withCaptureGlobalLogger $
      logExecDebug "[local]" ["/bin/sh", "-c", "gh pr create"] Nothing
        [("GH_TOKEN", "ghp_secret123"), ("GIT_TERMINAL_PROMPT", "0")]
    let allText = T.unlines lines_
    allText `shouldSatisfy` ("GH_TOKEN=ghp_secret123" `T.isInfixOf`)
    allText `shouldSatisfy` ("GIT_TERMINAL_PROMPT=0" `T.isInfixOf`)

  it "shows the real GITHUB_TOKEN value in the env extras" $ do
    (_, lines_) <- withCaptureGlobalLogger $
      logExecDebug "[local]" ["/bin/sh", "-c", "gh pr create"] Nothing
        [("GITHUB_TOKEN", "ghp_secretABC")]
    let allText = T.unlines lines_
    allText `shouldSatisfy` ("GITHUB_TOKEN=ghp_secretABC" `T.isInfixOf`)

  it "shows the real http.extraHeader value (defense-in-depth)" $ do
    (_, lines_) <- withCaptureGlobalLogger $
      logExecDebug "[local]" ["/bin/sh", "-c", "git fetch"] Nothing
        [("http.extraHeader", "Authorization: Basic c2VjcmV0")]
    let allText = T.unlines lines_
    allText `shouldSatisfy` ("http.extraHeader=Authorization: Basic c2VjcmV0" `T.isInfixOf`)

  it "preserves non-secret env keys unchanged" $ do
    (_, lines_) <- withCaptureGlobalLogger $
      logExecDebug "[local]" ["/bin/sh", "-c", "git status"] Nothing
        [("GIT_TERMINAL_PROMPT", "0"), ("SSH_AUTH_SOCK", "/tmp/agent.sock")]
    let allText = T.unlines lines_
    allText `shouldSatisfy` ("GIT_TERMINAL_PROMPT=0" `T.isInfixOf`)
    allText `shouldSatisfy` ("SSH_AUTH_SOCK=/tmp/agent.sock" `T.isInfixOf`)

  it "shows the real token in the remote arm's logged message (uioBinExecEnv)" $ do
    let runner = mkFakeRemoteRunner (Right "")
        uio = mkRemoteUntrustedIO sshCfg runner
    bin <- either (const (error "fixture")) pure (mkBinName "gh")
    arg <- either (const (error "fixture")) pure (mkBinArg "pr")
    (_, lines_) <- withCaptureGlobalLogger $
      uioBinExecEnv uio [("GH_TOKEN", "ghp_secretXYZ")] bin [arg] Nothing
    let allText = T.unlines lines_
    allText `shouldSatisfy` ("GH_TOKEN=ghp_secretXYZ" `T.isInfixOf`)

-- | A placeholder SSH config for the remote-arm test (the fake runner
-- ignores the connection details; only the workspace root matters for
-- SafePath confinement).
sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = case mkRemotePath "/srv/agent-workspace" of
      Right rp -> rp
      Left e  -> error ("fixture: bad remote path: " <> T.unpack e)
  }