{-# LANGUAGE OverloadedStrings #-}
-- | TOFU (Trust On First Use) host-key adoption with human confirmation.
--
-- When the harness connects to a remote execution machine via SSH and the
-- host key is not in the pinned @known_hosts@ file, SSH fails with
-- @StrictHostKeyChecking=yes@ + @BatchMode=yes@. This module provides the
-- capability to adopt the key: probe the host via @ssh-keyscan@, display the
-- fingerprint, ask the human for confirmation, and append the key to the
-- @known_hosts@ file on approval.
--
-- Security properties:
--
--   * Only @ExecHostKeyUnknown@ (no key known) triggers adoption — a key
--     mismatch (@ExecHostKeyMismatch@, the key CHANGED) is a hard failure
--     that NEVER offers adoption (possible MITM).
--   * The human sees the host, the key type, and the fingerprint before
--     approving.
--   * The key is appended to the pinned @known_hosts@ file (the same file
--     @ssh -o UserKnownHostsFile=\<pinned\>@ uses), not the default
--     @~/.ssh/known_hosts@.
--   * On rejection or failure, returns @Left@ with a descriptive message;
--     the caller fail-closes.
--
--   * This module writes to @~/.seal/exec-known-hosts@ — a security-sensitive
--     file under the @~/.seal/@ tree (see CONTRIBUTING.md §"Security-first").
--     This is **not** an opcode; it is a harness-level capability invoked at
--     session-exec build time (before any agent turn), gated by a
--     human-confirmation callback. No agent-driven opcode can reach this
--     path — the @HostKeyAdoption@ handle is threaded through @TurnDeps@,
--     not through the @UIO@/@UntrustedIO@ capability surface.
module Seal.Tools.Exec.HostKeyAdoption
  ( HostKeyAdoption (..)
  , mkHostKeyAdoption
  , mkHostKeyAdoptionStub
  , mkHostKeyAdoptionWithProbe
  , probeHostKey
  , adoptHostKeyIO
  , HostKeyInfo (..)
  , extractFirstKeyLine
  , buildAdoptionPrompt
  ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (hClose)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  , withCreateProcess
  )

import Seal.Logging.Global (globalLogIO)
import Seal.Tools.Exec.Types
  ( SshConfig (..)
  , getSshHost
  , getSshUser
  )
import Katip (Severity (..))
import Katip qualified as K (ls)

-- | The capability handle for host-key adoption. The single method probes
-- the remote host, presents the key to the human, and on approval appends
-- it to the pinned @known_hosts@ file. The constructor is NOT exported;
-- use 'mkHostKeyAdoption' (production) or 'mkHostKeyAdoptionStub' (tests).
newtype HostKeyAdoption = HostKeyAdoption
  { hkaAdopt :: SshConfig -> IO (Either Text ())
    -- ^ Probe the host, ask the human, append the key on approval.
    -- Returns @Right ()@ on success (key adopted), @Left msg@ on
    -- rejection or failure.
  }

-- | Information about a host key discovered by @ssh-keyscan@.
data HostKeyInfo = HostKeyInfo
  { hkiHost    :: Text
    -- ^ The host (user@host form for display)
  , hkiKeyType :: Text
    -- ^ e.g. @ssh-ed25519@
  , hkiKeyLine :: Text
    -- ^ The full @ssh-keyscan@ output line (host keytype keydata)
  , hkiFingerprint :: Text
    -- ^ The SHA256 fingerprint (computed via @ssh-keygen -lf@)
  }

-- | Production host-key adoption. Probes via @ssh-keyscan@, shows the
-- fingerprint, calls the @confirm@ callback, and appends the key to the
-- pinned @known_hosts@ file on approval. The @confirm@ callback is the
-- human-interaction seam (e.g. @ccPrompt@ from 'ChannelCaps').
mkHostKeyAdoption
  :: (Text -> IO Bool)
  -- ^ Confirm callback: given the prompt text, returns @True@ to approve,
  -- @False@ to reject.
  -> HostKeyAdoption
mkHostKeyAdoption confirm =
  HostKeyAdoption
    { hkaAdopt = adoptHostKeyIO confirm
    }

-- | A stub that always returns @Left "host-key adoption not available"@.
-- Used in tests or when no human-interaction surface is wired.
mkHostKeyAdoptionStub :: HostKeyAdoption
mkHostKeyAdoptionStub =
  HostKeyAdoption
    { hkaAdopt = \_ -> pure (Left "host-key adoption not available")
    }

-- | Like 'mkHostKeyAdoption' but with an injected probe function (tests).
-- The probe returns the 'HostKeyInfo' (or an error message). The real
-- 'probeHostKey' runs @ssh-keyscan@ + @ssh-keygen -lf@.
mkHostKeyAdoptionWithProbe
  :: (SshConfig -> IO (Either Text HostKeyInfo))
  -- ^ Injected probe (replaces 'probeHostKey')
  -> (Text -> IO Bool)
  -- ^ Confirm callback
  -> HostKeyAdoption
mkHostKeyAdoptionWithProbe probe confirm =
  HostKeyAdoption
    { hkaAdopt = \cfg -> do
        eInfo <- probe cfg
        case eInfo of
          Left err -> pure (Left err)
          Right info -> do
            let prompt = buildAdoptionPrompt info
            approved <- confirm prompt
            if approved
              then appendKeyToKnownHosts (scKnownHosts cfg) (hkiKeyLine info)
              else pure (Left ("host-key adoption rejected for " <> hkiHost info))
    }

-- | The full adoption flow: probe → display → confirm → append.
-- Used by 'mkHostKeyAdoption'; exported for direct testing.
adoptHostKeyIO :: (Text -> IO Bool) -> SshConfig -> IO (Either Text ())
adoptHostKeyIO confirm cfg = do
  eInfo <- probeHostKey cfg
  case eInfo of
    Left err -> pure (Left err)
    Right info -> do
      let prompt = buildAdoptionPrompt info
      globalLogIO InfoS (K.ls ("Host-key adoption prompt: " <> prompt))
      approved <- confirm prompt
      if approved
        then do
          r <- appendKeyToKnownHosts (scKnownHosts cfg) (hkiKeyLine info)
          case r of
            Left err -> pure (Left err)
            Right _  -> pure (Right ())
        else pure (Left ("host-key adoption rejected for " <> hkiHost info))

-- | Probe a remote host via @ssh-keyscan -t ed25519,rsa,ecdsa <host>@
-- and compute the fingerprint via @ssh-keygen -lf -@. Returns the
-- 'HostKeyInfo' or an error message.
probeHostKey :: SshConfig -> IO (Either Text HostKeyInfo)
probeHostKey cfg = do
  let host = T.unpack (getSshHost (scHost cfg))
      port = scPort cfg
      keyTypes = "ed25519,rsa,ecdsa"
      portArg = if port == 22 then [] else ["-p", show port]
      scanArgv = ["ssh-keyscan", "-T", "10"] <> portArg
                 <> ["-t", keyTypes, host]
  eScanOutput <- try (readProcessWithStderr scanArgv)
                    :: IO (Either IOException (ExitCode, Text, Text))
  case eScanOutput of
    Left ioErr -> pure (Left ("ssh-keyscan failed: " <> T.pack (show ioErr)))
    Right (ExitSuccess, stdout, _stderr) ->
      case extractFirstKeyLine stdout of
        Nothing -> pure (Left ("ssh-keyscan returned no keys for " <> T.pack host))
        Just (keyType, keyLine) -> do
          eFp <- computeFingerprint keyLine
          case eFp of
            Left err -> pure (Left err)
            Right fp -> pure (Right HostKeyInfo
              { hkiHost = getSshUser (scUser cfg) <> "@" <> T.pack host
              , hkiKeyType = keyType
              , hkiKeyLine = keyLine
              , hkiFingerprint = fp
              })
    Right (ExitFailure n, _stdout, stderr) ->
      pure (Left ("ssh-keyscan exited " <> T.pack (show n) <> ": " <> stderr))

-- | Extract the first key line from @ssh-keyscan@ output. Returns the key
-- type and the full line. @ssh-keyscan@ output format:
-- @<host> <keytype> <keydata>@
extractFirstKeyLine :: Text -> Maybe (Text, Text)
extractFirstKeyLine output =
  case [ l | l <- T.lines output, not (T.null (T.strip l)), not ("#" `T.isPrefixOf` T.strip l) ] of
    (line : _) ->
      let parts = T.words line
      in case parts of
           (_host : keyType : _) -> Just (keyType, line)
           _ -> Nothing
    [] -> Nothing

-- | Compute the SHA256 fingerprint of a host key line via
-- @ssh-keygen -lf -@ (the key line on stdin).
computeFingerprint :: Text -> IO (Either Text Text)
computeFingerprint keyLine = do
  let argv = ["ssh-keygen", "-lf", "-"]
  eRes <- try (readProcessWithStdin argv (TE.encodeUtf8 keyLine))
            :: IO (Either IOException (ExitCode, Text, Text))
  case eRes of
    Left ioErr -> pure (Left ("ssh-keygen failed: " <> T.pack (show ioErr)))
    Right (ExitSuccess, stdout, _stderr) ->
      case T.lines (T.strip stdout) of
        (fpLine : _) -> pure (Right (T.strip fpLine))
        [] -> pure (Left "ssh-keygen returned no fingerprint")
    Right (ExitFailure n, _stdout, stderr) ->
      pure (Left ("ssh-keygen exited " <> T.pack (show n) <> ": " <> stderr))

-- | Build the human-facing adoption prompt.
buildAdoptionPrompt :: HostKeyInfo -> Text
buildAdoptionPrompt info =
  "The remote execution host " <> hkiHost info
  <> " is not in the known_hosts file.\n"
  <> "Key type: " <> hkiKeyType info <> "\n"
  <> "Fingerprint: " <> hkiFingerprint info <> "\n"
  <> "Adopt this host key? [y/N]"

-- | Append a key line to the @known_hosts@ file. Creates the file if it
-- does not exist (the parent directory must already exist). Avoids
-- duplicate entries: skips if the key line is already present.
appendKeyToKnownHosts :: FilePath -> Text -> IO (Either Text ())
appendKeyToKnownHosts knownHostsPath keyLine = do
  exists <- doesFileExist knownHostsPath
  if not exists
    then do
      let dir = takeDirectory knownHostsPath
      dirExists <- doesDirectoryExist dir
      if not dirExists
        then pure (Left ("known_hosts directory does not exist: " <> T.pack dir))
        else do
          TIO.writeFile knownHostsPath (keyLine <> "\n")
          pure (Right ())
    else do
      existing <- TIO.readFile knownHostsPath
      if keyLine `T.isInfixOf` existing
        then pure (Right ())
        else do
          TIO.appendFile knownHostsPath (keyLine <> "\n")
          pure (Right ())

-- ---------------------------------------------------------------------------
-- Process helpers (local, not through UntrustedIO — this is harness-level IO)
-- ---------------------------------------------------------------------------

-- | Run a process with stdout+stderr captured, no stdin.
readProcessWithStderr :: [String] -> IO (ExitCode, Text, Text)
readProcessWithStderr argv = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "readProcessWithStderr: empty argv (unreachable)"
      cp = (proc program args)
              { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
              }
  withCreateProcess cp $ \_ mOut mErr ph -> do
    outTxt <- maybe (pure "") TIO.hGetContents mOut
    errTxt <- maybe (pure "") TIO.hGetContents mErr
    ec <- waitForProcess ph
    pure (ec, outTxt, errTxt)

-- | Run a process with a stdin payload, stdout+stderr captured.
readProcessWithStdin :: [String] -> ByteString -> IO (ExitCode, Text, Text)
readProcessWithStdin argv stdinBytes = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "readProcessWithStdin: empty argv (unreachable)"
      cp = (proc program args)
              { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe
              }
  withCreateProcess cp $ \mIn mOut mErr ph -> do
    case mIn of
      Just hIn -> do
        BS.hPut hIn stdinBytes
        hClose hIn
      Nothing -> pure ()
    outTxt <- maybe (pure "") TIO.hGetContents mOut
    errTxt <- maybe (pure "") TIO.hGetContents mErr
    ec <- waitForProcess ph
    pure (ec, outTxt, errTxt)