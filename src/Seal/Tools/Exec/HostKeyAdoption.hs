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
  , HostKeyPaths (..)
  , defaultHostKeyPaths
  , isSelfHostKey
  ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.Maybe (mapMaybe)
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

import Seal.Config.Machines (MachineName, machineNameText)
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
  { hkaAdopt :: MachineName -> SshConfig -> IO (Either Text ())
    -- ^ Probe the host, ask the human, append the key on approval.
    -- The machine name is an argument, not a field of 'SshConfig': §2.2
    -- keeps 'MtSsh' name-free (the map key is the name), so the only place
    -- it can reach the prompt is here.
    -- Returns @Right ()@ on success (key adopted), @Left msg@ on
    -- rejection or failure.
  }
-- | Information about a host key discovered by @ssh-keyscan@.
data HostKeyInfo = HostKeyInfo
  { hkiMachine :: !(Maybe MachineName)
    -- ^ Which configured machine this key belongs to. 'Maybe' because the
    -- probe can run outside a machine context (a bare @ssh-keyscan@); the
    -- adoption path always supplies it, and the prompt names it.
  , hkiHost    :: Text
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
    { hkaAdopt = \_ _ -> pure (Left "host-key adoption not available")
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
    { hkaAdopt = \name cfg -> do
        eInfo <- probe cfg
        case eInfo of
          Left err -> pure (Left err)
          Right info0 -> do
            -- The probe cannot know the machine name (§2.2: `MtSsh` is
            -- name-free), so it is stamped on here, from the caller.
            let info = info0 { hkiMachine = Just name }
                prompt = buildAdoptionPrompt info
            approved <- confirm prompt
            if approved
              then appendKeyToKnownHosts (scKnownHosts cfg) (hkiKeyLine info)
              else pure (Left ("host-key adoption rejected for " <> hkiHost info))
    }

-- | The full adoption flow: probe → display → confirm → append.
-- Used by 'mkHostKeyAdoption'; exported for direct testing.
adoptHostKeyIO :: (Text -> IO Bool) -> MachineName -> SshConfig -> IO (Either Text ())
adoptHostKeyIO confirm name cfg = do
  eInfo <- probeHostKey cfg
  case eInfo of
    Left err -> pure (Left err)
    Right info0 -> do
      let info = info0 { hkiMachine = Just name }
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
              { hkiMachine = Nothing
              , hkiHost = getSshUser (scUser cfg) <> "@" <> T.pack host
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
--
-- __The copy is frozen__ (T-STR-7): four lines, a two-space indent on the
-- detail rows, and @key:  @ padded so the two values align. Asserted as exact
-- equality, so the padding is part of the string — not formatting to be
-- tidied.
--
-- The machine name is the first line's subject rather than the host: a human
-- confirming twice in one install must be able to tell WHICH machine they are
-- trusting. Two machines can share a host string (a load balancer, a rebuilt
-- box reusing a DNS name), and a prompt keyed on the host alone makes those
-- indistinguishable at exactly the moment the answer matters.
buildAdoptionPrompt :: HostKeyInfo -> Text
buildAdoptionPrompt info = T.unlines
  [ "machine \"" <> subject <> "\" is not yet known."
  , "  host: " <> hkiHost info
  , "  key:  " <> hkiKeyType info <> " " <> hkiFingerprint info
  , "Trust this key? [y/N]"
  ]
  where
    -- The machine name when known; the host otherwise, so a probe outside a
    -- machine context still produces a usable prompt. Quoted either way, which
    -- is what the frozen copy does.
    subject = maybe (hkiHost info) machineNameText (hkiMachine info)

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

-- ---------------------------------------------------------------------------
-- Self-key guard (§3.2 layer 3)
-- ---------------------------------------------------------------------------

-- | Where the harness machine's own sshd host keys live.
--
-- A VALUE, not a constant, so the guard is testable against a fixture. Design
-- §3.2 records why this matters: revision 1 hardcoded @~\/.ssh@, where sshd does
-- not keep its host keys, so the check silently never fired — a security guard
-- that reads the wrong file is worse than no guard, because it reports success.
newtype HostKeyPaths = HostKeyPaths
  { hkpSystemKeys :: [FilePath]
    -- ^ Public key files, @/etc/ssh/ssh_host_*_key.pub@ by default.
  }
  deriving stock (Eq, Show)

-- | The production paths. Globbed lazily by 'isSelfHostKey' rather than
-- enumerated, so a machine with only RSA keys still gets checked.
defaultHostKeyPaths :: HostKeyPaths
defaultHostKeyPaths = HostKeyPaths
  [ "/etc/ssh/ssh_host_ed25519_key.pub"
  , "/etc/ssh/ssh_host_ecdsa_key.pub"
  , "/etc/ssh/ssh_host_rsa_key.pub"
  ]

-- | Does this presented key match any of the harness machine's own host keys?
--
-- __Compares key MATERIAL, not lines.__ The two sources spell a host key
-- differently: @ssh-keyscan@ yields @\<host\> \<type\> \<blob\>@ while
-- @/etc/ssh/*.pub@ yields @\<type\> \<blob\> [comment]@. Comparing whole lines
-- would therefore never match, and the guard would be silently inert. The blob
-- (the base64 field) is the identity.
--
-- Unreadable key files are SKIPPED, not fatal (design §3.2 layer 3): a distro
-- that keeps its keys elsewhere degrades from two defences to one rather than
-- refusing every connection.
--
-- Only the FIRST key line of a multi-line input is used — @ssh-keyscan@ may
-- return several key types, and the caller is expected to check the one it will
-- actually pin.
isSelfHostKey :: HostKeyPaths -> Text -> IO Bool
isSelfHostKey paths presented = do
  let mBlob = keyBlob presented
  case mBlob of
    Nothing   -> pure False
    Just blob -> do
      ownBlobs <- concat <$> mapM blobsIn (hkpSystemKeys paths)
      pure (blob `elem` ownBlobs)
  where
    blobsIn path = do
      eExists <- try (doesFileExist path) :: IO (Either IOException Bool)
      case eExists of
        Left _        -> pure []   -- unreadable ⇒ skipped (§3.2 layer 3)
        Right False   -> pure []
        Right True    -> do
          eContent <- try (TIO.readFile path) :: IO (Either IOException Text)
          case eContent of
            Left _   -> pure []
            Right t  -> pure (mapMaybe keyBlob (T.lines t))

-- | The key blob (third whitespace field) of a host-key line, whichever of the
-- two spellings it uses.
--
-- @ssh-keyscan@: @host type blob@ → the blob is field 3.
-- @/etc/ssh/*.pub@: @type blob comment…@ → the blob is field 2.
--
-- Distinguished by whether the first field looks like a host: the two shapes
-- differ in that a key TYPE always starts with @ssh-@, @ecdsa-@ or @sk-@.
keyBlob :: Text -> Maybe Text
keyBlob line =
  case T.words (T.strip line) of
    (a : _b : c : _) | looksLikeHost a      -> Just c
    (a : b : _)      | looksLikeKeyType a   -> Just b
    _               -> Nothing
  where
    looksLikeHost t = not (looksLikeKeyType t)
    looksLikeKeyType t = any (`T.isPrefixOf` t)
      ["ssh-", "ecdsa-", "sk-", "rsa-"]
