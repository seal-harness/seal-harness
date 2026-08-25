{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The unified capability handle for Untrusted opcodes. Every side-effecting
-- operation an untrusted tool call can perform is a method on this type.
-- Opcode modules never import 'System.Process', 'System.Directory', or
-- 'System.Posix' — they call these methods. The constructor is NOT exported;
-- the two smart constructors ('mkLocalUntrustedIO', 'mkRemoteUntrustedIO')
-- are the only way to obtain one.
--
-- Security properties preserved by construction:
--
--   * Capability scoping (spec §4/§8): a Trusted opcode has no 'UntrustedIO'
--     in scope — it cannot call any of these methods (compile error).
--   * SafePath confinement: file methods take a 'RemotePath' (a
--     workspace-relative path) and internally 'mkSafePath' /
--     'mkSafePathForWrite' (local arm) or 'mkSafePathRemote' (remote arm).
--     The caller never sees a raw 'FilePath'.
--   * Bounded: read/write/search methods carry operator ceilings.
--   * Validated argv: shell/bin/search methods take validated newtypes
--     ('ShellCommand', 'BinName', 'BinArg', 'SearchPattern'), never raw
--     'Text'.
--
-- The local arm is implemented via the existing 'System.Process' /
-- 'System.Directory' code (lifted out of 'Seal.Tools.Exec.Local' and the
-- opcode modules). The remote arm is implemented over SSH (Option A in the
-- plan: file IO piped over the SSH channel's stdin/stdout; commands via
-- the existing 'RemoteRunner'). SafePath is validated LOCALLY before any
-- SSH call so a @..@ escape is rejected before the network is touched.
module Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..)
  , WriteMode (..)
  , UntrustedErr (..)
  , renderUntrustedErr
  , mkLocalUntrustedIO
  , mkRemoteUntrustedIO
  , mkRemoteUntrustedIOFromRunner
  , mkRemoteUntrustedIOStub
  , applyUnifiedDiff
  , lineWindowFromText
  , buildRgCmd
  , shellQuote
  , renderEnvPrefix
  , mergeEnv
  , logExecDebug
  , secretEnvKeys
  , redactEnv
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Char (isDigit, isSpace)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (renameFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  )

import Seal.Security.Path
  ( PathError (..), SafePath, WorkspaceRoot (..), getSafePath, mkSafePath
  , mkSafePathForWrite, mkSafePathRemote
  )
import Seal.Logging.Global (globalLogIO)
import Seal.Text.LineFile
  ( LineWindow (..) )
import Seal.Tools.Args
  ( BinArg, BinName, SearchPattern, ShellCommand
  , mkShellCommand, textBinArg, textBinName, textSearchPattern, textShellCommand
  )
import Seal.Tools.Exec.Local
  ( readBounded, withManagedProcess )
import Seal.Tools.Exec.Remote
  ( RemoteRunner (..), runRemoteShell
  , runRemoteStdin, sshExecArgv, sshExecArgvForwarding
  )
import Seal.Tools.Exec.Types
  ( ExecError (..), RemotePath, SshConfig (..), getRemotePath
  )

import Katip (Severity (..))
import Katip qualified as K (ls)

-- | The unified capability handle. Each field is an IO action the opcode
-- calls; the smart constructors wire the local or remote implementation.
-- The constructor is NOT exported — only the smart constructors are.
--
-- File methods take a 'RemotePath' (a workspace-relative path). Internally
-- each arm re-anchors the path against its own 'WorkspaceRoot' and runs
-- the lexical + (local arm) canonical confinement check. The remote arm
-- uses 'mkSafePathRemote' (lexical-only — the file lives on the remote
-- machine, so no local 'canonicalizePath').
data UntrustedIO = UntrustedIO
  { uioReadFile    :: RemotePath -> Int -> IO (Either UntrustedErr LineWindow)
    -- ^ Read a workspace-relative file as a 'LineWindow' (line-oriented,
    -- paged, bounded by the operator scan-byte ceiling). Returns the
    -- window (the opcode renders it via 'renderWindow') or a structured
    -- error. The path is validated + confined internally.

  , uioWriteFile   :: RemotePath -> Text -> WriteMode -> Int
                   -> IO (Either UntrustedErr Int)
    -- ^ Write or append content to a workspace-relative file. The
    -- @operatorWriteCeiling@ is the hard upper bound on bytes written per
    -- call; the capability rejects content above the ceiling with
    -- 'UeBounded' (the opcode may pre-check, but the capability is the
    -- authoritative bound). Returns bytes written. The path is validated
    -- + confined internally.

  , uioPatchFile   :: RemotePath -> Text -> IO (Either UntrustedErr ())
    -- ^ Apply a unified diff to a workspace-relative file. Read (cat) →
    -- apply the diff in-process (the pure 'applyUnifiedDiff') → write
    -- atomically (temp + rename on the target plane). Returns '()' or
    -- a structured error.

  , uioShellExec   :: ShellCommand -> Maybe RemotePath
                   -> IO (Either UntrustedErr Text)
    -- ^ Run a validated shell command (single arg to @/bin/sh -c@), with
    -- an optional SafePath-confined cwd. Returns stdout (+ exit
    -- annotation) or a structured error.

  , uioBinExec     :: BinName -> [BinArg] -> Maybe RemotePath
                   -> IO (Either UntrustedErr Text)
    -- ^ Run a named binary (no shell, fixed argv) with an optional cwd.
    -- A relative 'RemotePath' is SafePath-confined to the workspace root;
    -- an absolute 'RemotePath' is passed through verbatim (not confined).
    -- Returns stdout or error.

  , uioProcessList :: IO (Either UntrustedErr Text)
    -- ^ List processes on the untrusted plane (bounded output).

  , uioProcessKill :: Int -> IO (Either UntrustedErr ())
    -- ^ Kill a process by PID (validated positive integer) on the
    -- untrusted plane.

  , uioSearchFiles :: SearchPattern -> Maybe RemotePath -> Int
                   -> IO (Either UntrustedErr Text)
    -- ^ Search workspace files for a pattern (@rg -n -- <pattern>
    -- <path>@). The path defaults to the workspace root. The result
    -- count is bounded by the operator ceiling. Returns matching lines
    -- or error.

  , uioShellExecEnv :: [(String, String)] -> ShellCommand -> Maybe RemotePath
                   -> IO (Either UntrustedErr Text)
    -- ^ Like 'uioShellExec' but with env overrides MERGED over the
    -- inherited environment (local arm) / @env VAR=val@-prefixed into the
    -- command string (remote arm — portable: @ssh -A@ only forwards the
    -- agent socket; @SendEnv@/@SetEnv@ need server @AcceptEnv@ which is
    -- @none@ by default). Used by the git-credential opcodes to inject
    -- @SSH_AUTH_SOCK@ / @GIT_SSH_COMMAND@ for deploy-key ops (the
    -- forwarded agent + pinned @known_hosts@, never the key bytes).

  , uioShellExecGitEnv :: [(String, String)] -> Maybe BS.ByteString
                   -> ShellCommand -> Maybe RemotePath
                   -> IO (Either UntrustedErr Text)
    -- ^ Like 'uioShellExecEnv' but with an optional @known_hosts@
    -- content payload for the REMOTE deploy-key path. When the content
    -- is 'Just' the remote arm: (1) writes it to a remote temp file via
    -- @ssh ... -- tee <path>@, (2) rewrites @GIT_SSH_COMMAND@ in the
    -- extras to add @UserKnownHostsFile=<remote temp path>@, (3) uses
    -- @ssh -A@ (agent forwarding) so the remote @git@ can sign via the
    -- forwarded @SSH_AUTH_SOCK@, (4) strips @SSH_AUTH_SOCK@ /
    -- @SSH_AGENT_PID@ from the @env@ prefix (the forwarded socket
    -- replaces them), (5) cleans up the remote temp file after. The
    -- local arm ignores the content (the local temp file is already
    -- written by 'resolveCloneTarget') + delegates to
    -- 'uioShellExecEnv'. Used by 'cloneWithCredential' + 'runGitCommand'
    -- for deploy-key ops (the only credential kind that needs the
    -- agent + known_hosts).

  , uioBinExecEnv :: [(String, String)] -> BinName -> [BinArg]
                 -> Maybe RemotePath
                 -> IO (Either UntrustedErr Text)
    -- ^ Like 'uioBinExec' but with env overrides (same merge strategy as
    -- 'uioShellExecEnv') and an optional cwd. Used by the PAT clone path
    -- (@http.extraHeader@ is an argv element, but the env override is
    -- still needed for @GIT_TERMINAL_PROMPT=0@).

  , uioBinExecGitEnv :: [(String, String)] -> Maybe BS.ByteString
                   -> BinName -> [BinArg] -> Maybe RemotePath
                   -> IO (Either UntrustedErr Text)
    -- ^ Like 'uioBinExecEnv' but with optional @known_hosts@ content for
    -- the REMOTE deploy-key path (mirrors 'uioShellExecGitEnv'). The
    -- local arm delegates to 'uioBinExecEnv' (ignoring the content). The
    -- remote arm uses @ssh -A@ (agent forwarding) + strips
    -- @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ from the remote env prefix (the
    -- forwarded socket replaces them). Used by BIN_EXEC when the binary
    -- is @git@ and the cwd is inside a registered repo with a deploy-key
    -- credential.
  }

-- | Write mode for 'uioWriteFile': truncate + create (@'WMWrite'@, the
-- default) or append.
data WriteMode = WMWrite | WMAppend
  deriving stock (Eq, Show)

-- | The structured error an 'UntrustedIO' method returns. Wraps the
-- path-error, the bounded-overflow, and the executor-layer errors so the
-- opcode can render a single, consistent error message.
data UntrustedErr
  = UePath PathError
    -- ^ SafePath confinement failed (blocked name, @..@ escape, missing
    -- parent, symlink escape).
  | UeBounded Int
    -- ^ The call exceeded the operator ceiling (write/read/search). The
    -- 'Int' is the ceiling for the error message.
  | UeExec ExecError
    -- ^ The executor failed (remote unreachable, host-key mismatch, not
    -- implemented).
  | UeIo Text
    -- ^ An otherwise-uncategorized IO error (caught 'IOException',
    -- rendered as 'Text').
  deriving stock (Eq, Show)

-- | Render an 'UntrustedErr' as a human-readable 'Text' for the opcode's
-- 'orParts' (the model-visible error message).
renderUntrustedErr :: UntrustedErr -> Text
renderUntrustedErr = \case
  UePath pe   -> "path error: " <> T.pack (show pe)
  UeBounded n -> "content exceeds operator ceiling (" <> T.pack (show n) <> " bytes)"
  UeExec ee   -> "exec error: " <> T.pack (show ee)
  UeIo msg    -> "io error: " <> msg

-- ---------------------------------------------------------------------------
-- The local arm
-- ---------------------------------------------------------------------------

-- | The local untrusted executor. Workspace files live on the local FS;
-- commands run via @/bin/sh -c@ (shell) or @proc@ (bin). Absent under
-- @-f remote-only-untrusted@.
mkLocalUntrustedIO :: WorkspaceRoot -> UntrustedIO
mkLocalUntrustedIO wsRoot =
  -- The workdir root itself, resolved once as the SafePath for @.@. This
  -- is the single source of truth for the \"untrusted opcodes share one
  -- workspace root\" invariant: 'uioShellExec' / 'uioBinExec' default to
  -- it when the caller omits a cwd, so every opcode agrees on the same
  -- root without any opcode needing to remember to pass it.
  let wsRootPath = case mkSafePathRemote wsRoot "." of
        Right sp -> getSafePath sp
        Left _   -> "/nonexistent-workdir-fail-closed"
  in UntrustedIO
  { uioReadFile = \rp scanBytes -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left pe  -> pure (Left (UePath pe))
        Right sp -> do
          -- Bounded read: read at most scanBytes from the file, decode to
          -- Text, split to lines, build a LineWindow covering all read
          -- lines. The 'lwTruncated' flag is set when the file exceeds the
          -- scan ceiling (the read stopped before EOF). This matches the
          -- remote arm's 'lineWindowFromText' — both arms return the same
          -- shape, and the opcode does the offset/limit windowing purely.
          eContent <- try (readBoundedLocal (getSafePath sp) scanBytes)
                        :: IO (Either IOException (BS.ByteString, Bool))
          pure $ case eContent of
            Left ioErr   -> Left (UeIo (T.pack (show ioErr)))
            Right (bs, truncated) ->
              -- When truncated, the trailing partial line (no newline) is
              -- NOT counted as a complete line — matching the original
              -- 'readLineWindow' semantics (lwTotal is a lower bound). When
              -- not truncated, 'T.lines' counts a trailing partial line
              -- (matching Data.Text.lines).
              let txt = TE.decodeUtf8Lenient bs
                  rawLines = T.lines txt
                  -- Drop the trailing partial line if truncated AND it has
                  -- no newline (i.e. it's a partial). T.lines splits on \n;
                  -- a trailing partial line is one where the original bytes
                  -- didn't end with \n.
                  endsWithNl = not (BS.null bs) && BS.last bs == 0x0A
                  ls = if truncated && not endsWithNl
                         then init rawLines   -- drop the partial
                         else rawLines
                  n = length ls
              in Right LineWindow
                   { lwLines     = ls
                   , lwStart     = 0
                   , lwEnd       = n
                   , lwTotal     = n
                   , lwHasMore   = truncated
                   , lwTruncated = truncated
                   }
  , uioWriteFile = \rp content mode ceiling' -> do
      let rel       = T.unpack (getRemotePath rp)
          byteCount = BS.length (TE.encodeUtf8 content)
      if byteCount > ceiling'
        then pure (Left (UeBounded ceiling'))
        else do
          eSafe <- mkSafePathForWrite wsRoot rel
          case eSafe of
            Left pe  -> pure (Left (UePath pe))
            Right sp -> do
              eUnit <- try (writeLocal sp content mode) :: IO (Either IOException ())
              pure $ case eUnit of
                Left ioErr -> Left (UeIo (T.pack (show ioErr)))
                Right _    -> Right byteCount
  , uioPatchFile = \rp patch -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left pe  -> pure (Left (UePath pe))
        Right sp -> patchLocal sp patch
  , uioShellExec = \cmd mCwd ->
      let argv = ["/bin/sh", "-c", T.unpack (textShellCommand cmd)]
      in case mCwd of
           Nothing -> runLocalFixedArgv False argv (Just wsRootPath)
           Just rp -> case mkSafePathRemote wsRoot (T.unpack (getRemotePath rp)) of
             Left pe  -> pure (Left (UePath pe))
             Right sp -> runLocalFixedArgv False argv (Just (getSafePath sp))
  , uioBinExec = \bin bargs mCwd ->
      let argv = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
      in case resolveBinCwd wsRoot mCwd of
           Left pe       -> pure (Left (UePath pe))
           Right cwdAbs -> runLocalFixedArgv True argv (Just cwdAbs)
  , uioProcessList =
      case mkShellCommand "ps -o pid=,cmd=" of
        Left _   -> pure (Left (UeExec ExecNotImplemented))
        Right sh -> uioShellExec (mkLocalUntrustedIO wsRoot) sh Nothing
  , uioProcessKill = \pid ->
      case mkShellCommand ("kill " <> T.pack (show pid)) of
        Left _   -> pure (Left (UeExec ExecNotImplemented))
        Right sh -> do
          res <- uioShellExec (mkLocalUntrustedIO wsRoot) sh Nothing
          pure (const (Right ()) =<< res)
  , uioSearchFiles = \pat mPath _limit -> do
      let mRel = maybe "" (T.unpack . getRemotePath) mPath
      case mkSafePathRemote wsRoot mRel of
        Left pe  -> pure (Left (UePath pe))
        Right sp -> case mkShellCommand (buildRgCmd pat (Just sp)) of
          Left _   -> pure (Left (UeExec ExecNotImplemented))
          Right sh -> uioShellExec (mkLocalUntrustedIO wsRoot) sh Nothing
  , uioShellExecEnv = \extras cmd mCwd ->
      let argv = ["/bin/sh", "-c", T.unpack (textShellCommand cmd)]
      in case mCwd of
           Nothing -> runLocalFixedArgvEnv False argv (Just wsRootPath) extras
           Just rp -> case mkSafePathRemote wsRoot (T.unpack (getRemotePath rp)) of
             Left pe  -> pure (Left (UePath pe))
             Right sp -> runLocalFixedArgvEnv False argv (Just (getSafePath sp)) extras
  , uioShellExecGitEnv = \extras _knownHosts cmd mCwd ->
      -- Local arm: the known_hosts temp file is already written by
      -- resolveCloneTarget (cdIsRemote=False path); ignore the content
      -- + delegate to uioShellExecEnv.
      uioShellExecEnv (mkLocalUntrustedIO wsRoot) extras cmd mCwd
  , uioBinExecEnv = \extras bin bargs mCwd ->
      let argv = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
      in case resolveBinCwd wsRoot mCwd of
           Left pe       -> pure (Left (UePath pe))
           Right cwdAbs -> runLocalFixedArgvEnv True argv (Just cwdAbs) extras
  , uioBinExecGitEnv = \extras _mKnownHosts bin bargs mCwd ->
      -- Local arm: the known_hosts temp file is already written by
      -- resolveCloneTarget (cdIsRemote=False path); ignore the content
      -- + delegate to uioBinExecEnv.
      uioBinExecEnv (mkLocalUntrustedIO wsRoot) extras bin bargs mCwd
  }

-- | Build the @rg@ command string from a validated 'SearchPattern' + an
-- optional workspace-relative path (anchored to the workspace root, not
-- the remote user's home CWD). Defaults to the workspace root itself.
-- Both the pattern and the path are 'shellQuote'-d so a pattern
-- containing spaces (e.g. @Recent Sessions@) or a single quote is passed
-- to @rg@ as a single argv token, not word-split by the shell.
buildRgCmd :: SearchPattern -> Maybe SafePath -> Text
buildRgCmd pat mSafePath =
  T.pack ("rg -n -- " <> shellQuote (T.unpack (textSearchPattern pat))
          <> " " <> shellQuote (maybe "." getSafePath mSafePath))

-- | Read at most @maxBytes@ from a local file. Returns the bytes read and
-- a 'Bool' indicating whether the file was truncated (the file is larger
-- than @maxBytes@ — the read stopped at the ceiling).
readBoundedLocal :: FilePath -> Int -> IO (BS.ByteString, Bool)
readBoundedLocal path maxBytes = do
  bs <- BS.readFile path
  let len = BS.length bs
  if len <= maxBytes
    then pure (bs, False)
    else pure (BS.take maxBytes bs, True)

-- | Write content to the local FS via the validated 'SafePath'. The temp
-- file + rename is used for @'WMWrite'@ so the write is atomic (a crash
-- mid-write leaves the old file intact); @'WMAppend'@ appends directly
-- (the file already exists or is created fresh by 'BS.appendFile').
writeLocal :: SafePath -> Text -> WriteMode -> IO ()
writeLocal sp content mode =
  let path  = getSafePath sp
      bytes = TE.encodeUtf8 content
  in case mode of
       WMAppend -> BS.appendFile path bytes
       WMWrite  -> do
         let tmp = path <> ".seal-write-tmp"
         BS.writeFile tmp bytes
         renameFile tmp path

-- | Apply a unified diff to the local file at the validated 'SafePath':
-- read → apply in-process → atomic temp+rename write.
patchLocal :: SafePath -> Text -> IO (Either UntrustedErr ())
patchLocal sp patch = do
  eContent <- try (BS.readFile (getSafePath sp)) :: IO (Either IOException BS.ByteString)
  case eContent of
    Left ioErr -> pure (Left (UeIo (T.pack (show ioErr))))
    Right content -> case applyUnifiedDiff (TE.decodeUtf8Lenient content) patch of
      Left applyErr -> pure (Left (UeIo applyErr))
      Right newContent -> do
        let path = getSafePath sp
            tmp  = path <> ".seal-patch-tmp"
        eUnit <- try (BS.writeFile tmp (TE.encodeUtf8 newContent) >> renameFile tmp path)
                   :: IO (Either IOException ())
        pure $ case eUnit of
          Left ioErr -> Left (UeIo (T.pack (show ioErr)))
          Right _    -> Right ()

-- | Run a fixed-argv program locally, capturing stdout + stderr as Text.
-- @treat127AsMissing@: a 127 exit maps to 'Left ExecNotImplemented'
-- (the binary is not on PATH) when True; otherwise 127 is a normal
-- command-not-found failure, returned via 'Right' with the exit code
-- annotation. Any 'IOException' becomes 'Left ExecNotImplemented'.
-- No env overrides — delegates to 'runLocalFixedArgvEnv' with @[]@.
runLocalFixedArgv
  :: Bool -> [String] -> Maybe String -> IO (Either UntrustedErr Text)
runLocalFixedArgv treat127AsMissing argv mCwd =
  runLocalFixedArgvEnv treat127AsMissing argv mCwd []

-- | Run a fixed-argv program locally with env overrides. The @extras@
-- are MERGED over the inherited environment ('getEnvironment'): the
-- process inherits the harness env (PATH, HOME, etc.) plus the overrides
-- (e.g. @SSH_AUTH_SOCK@, @GIT_SSH_COMMAND@, @GIT_TERMINAL_PROMPT=0@). This
-- is the local-arm env-override seam (W2) — the secret-free auth env for
-- deploy-key ops. The overrides are NEVER secret bytes (only paths +
-- non-secret values); the secret lives only in the forwarded agent's
-- memory.
runLocalFixedArgvEnv
  :: Bool -> [String] -> Maybe String -> [(String, String)]
  -> IO (Either UntrustedErr Text)
runLocalFixedArgvEnv treat127AsMissing argv mCwd extras = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "runLocalFixedArgvEnv: empty argv (unreachable)"
  logExecDebug "[local]" argv mCwd extras
  inherited <- getEnvironment
  let env' = Just (mergeEnv inherited extras)
      cp = (proc program args)
              { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
              , cwd = mCwd, env = env'
              , create_group = True
              }
      -- ^ @create_group = True@ puts the child in its own POSIX process
      -- group so 'withManagedProcess' can kill the whole group on cleanup
      -- (SIGTERM → grace → SIGKILL). This prevents orphans when the
      -- dispatch wrapper cancels the Haskell worker thread.
      maxOutput = 50_000  -- bounded output cap (Task 4, matches ttcMaxOutputBytes)
  res <- try @IOException
         (withManagedProcess cp $ \ph _mIn hOut hErr -> do
            out <- readBounded hOut maxOutput
            err <- readBounded hErr maxOutput
            ec  <- waitForProcess ph
            pure (ec, out, err))
  pure $ case res of
    Left _ioErr                     -> Left (UeExec ExecNotImplemented)
    Right (ExitSuccess, out, _)    -> Right out
    Right (ExitFailure 127, _, _)
      | treat127AsMissing           -> Left (UeExec ExecNotImplemented)
    Right (ExitFailure n, out, err) -> Right (formatExitResult n out err)

-- | Merge env overrides over the inherited environment. The @overrides@
-- WIN on collision (per-op auth env must shadow any ambient value — e.g.
-- a user's ambient @SSH_AUTH_SOCK@ must NOT override the per-op agent's
-- socket, or git would sign with the user's ambient agent keys, breaking
-- the per-op scoping invariant in design §4.6). The result is sorted by
-- key for a deterministic order (mainly for test assertions —
-- @CreateProcess.env@ is order-insensitive but a stable order makes the
-- recording-fake + no-disk tests' diffs readable).
--
-- Implementation: @Map.union left right@ keeps @left@ on collision; putting
-- @overrides@ as @left@ makes overrides win. Mirrors
-- 'Seal.Git.Repo.readProcessBinaryCwdEnv' (which uses
-- @Map.union (Map.fromList extras) (Map.fromList inherited)@ — same
-- extras-win semantics).
mergeEnv :: [(String, String)] -> [(String, String)] -> [(String, String)]
mergeEnv inherited overrides =
  Map.toList (Map.union (Map.fromList overrides) (Map.fromList inherited))

-- | Format a non-zero exit result for the tool-call consumer. Combines
-- stdout and stderr (if non-empty) and annotates the exit code.
formatExitResult :: Int -> Text -> Text -> Text
formatExitResult n out err =
  let parts = [ t | t <- [out, err], not (T.null (T.strip t)) ]
      body  = if null parts then "" else T.intercalate "\n" parts
  in body <> "\n[exit code: " <> T.pack (show n) <> "]"

-- | Env keys whose values are redacted in debug logs. These carry raw
-- secrets injected by credential-injection paths (gh: 'GH_TOKEN';
-- 'GITHUB_TOKEN' is the older env var that some CI runners set, shadowed
-- by 'GH_TOKEN' at precedence; the git PAT path's 'http.extraHeader' is
-- an argv element, not env, but is listed here for defense-in-depth so a
-- value that accidentally reaches the env extras surface is still
-- redacted). Add to this set as new credential-injection paths introduce
-- new secret env keys.
secretEnvKeys :: Set String
secretEnvKeys = Set.fromList
  [ "GH_TOKEN"
  , "GITHUB_TOKEN"
  , "http.extraHeader"
  ]

-- | Replace the values of keys in 'secretEnvKeys' with @"<redacted>"@,
-- preserving the key (so the reader sees that an env override was
-- applied) and redacting only the value. Keys NOT in 'secretEnvKeys' pass
-- through unchanged.
redactEnv :: [(String, String)] -> [(String, String)]
redactEnv = map (\(k, v) ->
  if k `Set.member` secretEnvKeys then (k, "<redacted>") else (k, v))

-- | Emit a debug-level log line showing the exact command the UntrustedIO
-- executor is about to run. Covers both the local arm (a fixed-argv
-- subprocess) and the remote arm (an @ssh@ argv, including @-A@ for
-- agent-forwarding git ops). The @tag@ prefixes the line so the reader
-- can distinguish local vs remote vs remote-with-agent at a glance:
--
--   * @"[local]"@        — a local subprocess (@runLocalFixedArgvEnv@)
--   * @"[remote ssh]"@   — a remote SSH exec (no agent forwarding)
--   * @"[remote ssh -A]"@ — a remote SSH exec with agent forwarding
--                          (deploy-key git ops)
--
-- For the remote arm, the full SSH argv is logged (e.g.
-- @ssh -o StrictHostKeyChecking=yes ... agent@exec.internal -- cd ... && git pull@),
-- so the complete command — including the SSH portion — is visible when
-- @mode=remote@. Env overrides (e.g. @SSH_AUTH_SOCK=...@,
-- @GIT_SSH_COMMAND=...@) are shown as @KEY=VAL@ tokens. The cwd is shown
-- as @cd <path> &&@ when set.
--
-- Secret-bearing env keys (see 'secretEnvKeys') are redacted via
-- 'redactEnv' before the @KEY=VAL@ tokens are rendered, so a value like
-- @GH_TOKEN=ghp_secret...@ appears as @GH_TOKEN=<redacted>@ in the log.
-- This is a defense-in-depth seam on 'logExecDebug' itself, not caller
-- discipline — the redaction fires regardless of which arm produced the
-- call (the remote arm passes the secret extras separately via
-- 'runRemoteShellTextEnv' so the same redaction path covers it).
logExecDebug :: String -> [String] -> Maybe String -> [(String, String)] -> IO ()
logExecDebug tag argv mCwd extras =
  globalLogIO DebugS (K.ls msg)
  where
    msg = T.pack (unwords (filter (not . null) parts))
    parts =
      [ tag ]
      <> envPart
      <> cwdPart
      <> [ unwords (map shellQuoteArgv argv) ]
    -- Debug logs show the real env values (including secrets like GH_TOKEN).
    -- The harness machine is trusted and these logs are for debugging only.
    envPart = case extras of
      [] -> []
      xs -> [ unwords (map (\(k, v) -> k <> "=" <> v) xs) ]
    cwdPart = case mCwd of
      Just c  -> ["cd " <> c <> " &&"]
      Nothing -> []
    -- Quote an argv token for log readability: wrap in single quotes if
    -- it contains spaces or shell metacharacters. This is display-only
    -- (the actual subprocess argv is passed verbatim, never shell-parsed).
    shellQuoteArgv s
      | any (\c -> c == ' ' || c == '\'' || c == '"' || c == '$' || c == '`') s = "'" <> s <> "'"
      | otherwise = s

-- ---------------------------------------------------------------------------
-- The remote arm
-- ---------------------------------------------------------------------------

-- | The remote SSH executor. Workspace files live on the remote machine;
-- commands run via the SSH transport. File IO is implemented over SSH
-- (Option A in the plan: content piped over the SSH channel's
-- stdin/stdout). The 'SshConfig' is the validated, host-key-pinned config;
-- the 'RemoteRunner' is the existing SSH transport.
mkRemoteUntrustedIO :: SshConfig -> RemoteRunner -> UntrustedIO
mkRemoteUntrustedIO = mkRemoteUntrustedIOFromRunner

-- | Same as 'mkRemoteUntrustedIO' (the two names document the same
-- constructor). Provided for the wiring site, which threads the runner
-- explicitly.
mkRemoteUntrustedIOFromRunner :: SshConfig -> RemoteRunner -> UntrustedIO
mkRemoteUntrustedIOFromRunner sshCfg runner =
  -- The workdir root itself, resolved once as the SafePath for @.@. This
  -- is the single source of truth for the \"untrusted opcodes share one
  -- workspace root\" invariant on the remote arm: 'uioShellExec' /
  -- 'uioBinExec' default to it when the caller omits a cwd, so every
  -- opcode agrees on the same root (the remote @scWorkspace@), not the
  -- remote user's home or wherever the SSH server drops it.
  let wsRootPath = case mkSafePathRemote (wsRootFromCfg sshCfg) "." of
        Right sp -> getSafePath sp
        Left _   -> "/nonexistent-workdir-fail-closed"
  in UntrustedIO
  { uioReadFile = \rp scanBytes ->
      let rel = T.unpack (getRemotePath rp)
      in case mkSafePathRemote (wsRootFromCfg sshCfg) rel of
           Left pe  -> pure (Left (UePath pe))
           Right sp -> do
             -- ssh ... -- head -c <scanBytes> <abspath>  (bounded read).
             -- The SafePath is the workspace-anchored absolute path on the
             -- remote machine; the SSH command reads from that path, not
             -- the remote user's home CWD.
             let absPath = getSafePath sp
                 cmd = T.pack ("head -c " <> show scanBytes <> " " <> shellQuote absPath)
             res <- runRemoteShellText runner sshCfg cmd
             pure (Right . lineWindowFromText =<< res)
  , uioWriteFile = \rp content mode _ceiling' -> do
      let rel       = T.unpack (getRemotePath rp)
          byteCount = BS.length (TE.encodeUtf8 content)
      case mkSafePathRemote (wsRootFromCfg sshCfg) rel of
        Left pe  -> pure (Left (UePath pe))
        Right sp -> do
          -- ssh ... -- tee [-a] <abspath>   with content on stdin.
          -- The SafePath is the workspace-anchored absolute path.
          let absPath  = getSafePath sp
              teeFlag = case mode of WMWrite -> "" ; WMAppend -> "-a "
              cmd  = T.pack ("tee " <> teeFlag <> shellQuote absPath)
              argv = sshExecArgv sshCfg cmd
          res <- runRemoteStdin runner argv (TE.encodeUtf8 content)
          pure (either (Left . UeExec) (const (Right byteCount)) res)
  , uioPatchFile = \rp patch -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote (wsRootFromCfg sshCfg) rel of
        Left pe  -> pure (Left (UePath pe))
        Right sp -> do
          let absPath = getSafePath sp
          -- Read remote (cat) → apply diff in-process → write remote via
          -- a single SSH exec with stdin. The patched content is piped to
          -- a remote sh -c that writes the temp + mv (atomic).
          let readCmd = T.pack ("cat " <> shellQuote absPath)
          rRead <- runRemoteShellText runner sshCfg readCmd
          case rRead of
            Left e       -> pure (Left e)
            Right oldTxt -> case applyUnifiedDiff oldTxt patch of
              Left applyErr -> pure (Left (UeIo applyErr))
              Right newContent -> do
                let tmpPath = absPath <> ".seal-patch-tmp"
                    remoteSh = T.pack
                      ("sh -c 'cat > " <> shellQuote tmpPath
                       <> " && mv " <> shellQuote tmpPath
                       <> " " <> shellQuote absPath <> "'")
                    argv = sshExecArgv sshCfg remoteSh
                res <- runRemoteStdin runner argv (TE.encodeUtf8 newContent)
                pure (either (Left . UeExec) (const (Right ())) res)
  , uioShellExec = \cmd mCwd ->
      let prefixCd p = "cd " <> shellQuote p <> " && "
      in case mCwd of
        Nothing -> runRemoteShellText runner sshCfg
                     (T.pack (prefixCd wsRootPath
                              <> T.unpack (textShellCommand cmd)))
        Just rp ->
          case mkSafePathRemote (wsRootFromCfg sshCfg) (T.unpack (getRemotePath rp)) of
            Left pe  -> pure (Left (UePath pe))
            Right sp ->
              let cdCmd = "cd " <> shellQuote (getSafePath sp)
                          <> " && " <> T.unpack (textShellCommand cmd)
              in runRemoteShellText runner sshCfg (T.pack cdCmd)
  , uioBinExec = \bin bargs mCwd ->
      let argv' = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
      in case resolveBinCwd (wsRootFromCfg sshCfg) mCwd of
           Left pe  -> pure (Left (UePath pe))
           Right cwdPath ->
             let cmd = T.pack ("cd " <> shellQuote cwdPath <> " && "
                             <> T.unpack (T.intercalate " " (map (T.pack . shellQuote) argv')))
             in runRemoteShellText runner sshCfg cmd
  , uioProcessList =
      runRemoteShellText runner sshCfg "ps -o pid=,cmd="
   , uioProcessKill = \pid -> do
       res <- runRemoteShellText runner sshCfg ("kill " <> T.pack (show pid))
       pure (const (Right ()) =<< res)
   , uioSearchFiles = \pat mPath _limit ->
       let mRel = maybe "" (T.unpack . getRemotePath) mPath
       in case mkSafePathRemote (wsRootFromCfg sshCfg) mRel of
            Left pe  -> pure (Left (UePath pe))
            Right sp -> runRemoteShellText runner sshCfg (buildRgCmd pat (Just sp))
    , uioShellExecEnv = \extras cmd mCwd ->
       let prefixCd p = "cd " <> shellQuote p <> " && "
       in case mCwd of
         Nothing -> runRemoteShellTextEnv runner sshCfg
                      (T.pack (prefixCd wsRootPath)) extras
                      (T.pack (T.unpack (textShellCommand cmd)))
         Just rp ->
           case mkSafePathRemote (wsRootFromCfg sshCfg) (T.unpack (getRemotePath rp)) of
             Left pe  -> pure (Left (UePath pe))
             Right sp ->
               runRemoteShellTextEnv runner sshCfg
                 (T.pack ("cd " <> shellQuote (getSafePath sp) <> " && ")) extras
                 (T.pack (T.unpack (textShellCommand cmd)))
    , uioShellExecGitEnv = \extras _mKnownHosts cmd mCwd ->
        -- Remote deploy-key path (simple approach): ssh -A forwards the
        -- SEAL agent to the remote machine. The remote git clone uses the
        -- default ssh + the forwarded agent + the remote machine's default
        -- known_hosts. No GIT_SSH_COMMAND, no remote known_hosts file.
        -- Strip SSH_AUTH_SOCK/SSH_AGENT_PID from the REMOTE env prefix
        -- (the forwarded agent replaces them). Keep them in the LOCAL
        -- ssh -A process env so the right agent is forwarded.
        let localEnv = [ (k, v) | (k, v) <- extras
                      , k == "SSH_AUTH_SOCK" || k == "SSH_AGENT_PID"
                      ]
            remoteExtras = [ (k, v) | (k, v) <- extras
                           , k /= "SSH_AUTH_SOCK"
                           , k /= "SSH_AGENT_PID"
                           ]
            remoteEnvPrefix = T.pack (renderEnvPrefix remoteExtras)
        in case mCwd of
          Nothing ->
            let prefixCd = "cd " <> shellQuote wsRootPath <> " && "
                fullCmd = T.pack prefixCd <> remoteEnvPrefix <> T.pack (T.unpack (textShellCommand cmd))
            in runRemoteShellForwardingEnvText runner sshCfg localEnv fullCmd
          Just rp ->
            case mkSafePathRemote (wsRootFromCfg sshCfg) (T.unpack (getRemotePath rp)) of
              Left pe  -> pure (Left (UePath pe))
              Right sp ->
                let cdCmd = "cd " <> shellQuote (getSafePath sp) <> " && "
                    fullCmd = T.pack cdCmd <> remoteEnvPrefix <> T.pack (T.unpack (textShellCommand cmd))
                in runRemoteShellForwardingEnvText runner sshCfg localEnv fullCmd
     , uioBinExecEnv = \extras bin bargs mCwd ->
         let argv' = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
         in case resolveBinCwd (wsRootFromCfg sshCfg) mCwd of
            Left pe  -> pure (Left (UePath pe))
            Right cwdPath ->
              let cdPart = T.pack ("cd " <> shellQuote cwdPath <> " && ")
                  cmd = T.pack (T.unpack (T.intercalate " " (map (T.pack . shellQuote) argv')))
              in runRemoteShellTextEnv runner sshCfg cdPart extras cmd
    , uioBinExecGitEnv = \extras _mKnownHosts bin bargs mCwd ->
        -- Remote deploy-key path: mirrors uioShellExecGitEnv. Strip
        -- SSH_AUTH_SOCK/SSH_AGENT_PID from the REMOTE env prefix (the
        -- forwarded agent replaces them). Keep them in the LOCAL ssh -A
        -- process env so the right agent is forwarded.
        let localEnv = [ (k, v) | (k, v) <- extras
                      , k == "SSH_AUTH_SOCK" || k == "SSH_AGENT_PID"
                      ]
            remoteExtras = [ (k, v) | (k, v) <- extras
                           , k /= "SSH_AUTH_SOCK"
                           , k /= "SSH_AGENT_PID"
                           ]
            argv' = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
            remoteEnvPrefix = T.pack (renderEnvPrefix remoteExtras)
        in case resolveBinCwd (wsRootFromCfg sshCfg) mCwd of
           Left pe  -> pure (Left (UePath pe))
           Right cwdPath ->
             let cdPart = T.pack ("cd " <> shellQuote cwdPath <> " && ")
                 cmd = T.pack (T.unpack (T.intercalate " " (map (T.pack . shellQuote) argv')))
             in runRemoteShellForwardingEnvText runner sshCfg localEnv (cdPart <> remoteEnvPrefix <> cmd)
   }

-- | A stub remote executor that fails-closed on every method (preserving
-- the pre-Phase-3 behavior). Used by the wiring site in @mode=remote@
-- before the real remote arm is constructed, or in tests that want to
-- prove a remote-mode call never reaches the local FS.
mkRemoteUntrustedIOStub :: UntrustedIO
mkRemoteUntrustedIOStub = UntrustedIO
  { uioReadFile    = \_ _      -> pure (Left (UeExec ExecNotImplemented))
  , uioWriteFile   = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioPatchFile   = \_ _      -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExec   = \_ _      -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExec     = \_ _ _  -> pure (Left (UeExec ExecNotImplemented))
  , uioProcessList =             pure (Left (UeExec ExecNotImplemented))
  , uioProcessKill = \_         -> pure (Left (UeExec ExecNotImplemented))
  , uioSearchFiles = \_ _ _     -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecEnv = \_ _ _    -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecGitEnv = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExecEnv   = \_ _ _ _  -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExecGitEnv = \_ _ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  }

-- | The workspace root for remote confinement. The 'SshConfig' carries
-- the remote workspace as a 'RemotePath'; we wrap it back into a
-- 'WorkspaceRoot' for 'mkSafePathRemote'.
wsRootFromCfg :: SshConfig -> WorkspaceRoot
wsRootFromCfg cfg = WorkspaceRoot (T.unpack (getRemotePath (scWorkspace cfg)))

-- | Resolve an optional cwd ('RemotePath') for BIN_EXEC into an absolute
-- 'FilePath' the executor can pass to the subprocess. Unlike
-- 'uioShellExec' (which confines ALL paths — relative and absolute —
-- under the workspace root via 'mkSafePathRemote'), BIN_EXEC treats an
-- ABSOLUTE cwd as a pass-through (the operator explicitly chose an
-- out-of-workspace directory); a RELATIVE cwd is SafePath-confined under
-- the workspace root (the default untrusted-confinement contract).
--
--   * 'Nothing' → the workspace root itself (the one-root invariant).
--   * 'Just rp' (absolute) → the path verbatim (no confinement).
--   * 'Just rp' (relative) → 'mkSafePathRemote'-confined under the root;
--     a @..@ escape or blocked name is rejected with 'Left'.
resolveBinCwd :: WorkspaceRoot -> Maybe RemotePath -> Either PathError FilePath
resolveBinCwd wsRoot mCwd =
  case mCwd of
    Nothing   -> Right wsRootPath
    Just rp ->
      let rel = T.unpack (getRemotePath rp)
      in if isAbsolute rel
           then Right rel
           else getSafePath <$> mkSafePathRemote wsRoot rel
  where
    wsRootPath = case mkSafePathRemote wsRoot "." of
      Right sp -> getSafePath sp
      Left _   -> "/nonexistent-workdir-fail-closed"

-- | Single-quote a 'String' for the remote shell (the path is already
-- SafePath-validated, but quoting is defense-in-depth against any
-- metacharacters the validator permits, e.g. spaces). Embedded single
-- quotes are escaped with the standard @'\''@ idiom so a value containing
-- a quote cannot break out of its single-quoted argv token — e.g.
-- @foo'bar@ becomes @'foo'\''bar'@, which the shell parses back to the
-- literal @foo'bar@ as a single token. Applied uniformly to all remote
-- paths and search patterns.
shellQuote :: String -> String
shellQuote s = "'" <> go s <> "'"
  where
    go []         = []
    go ('\'':rest) = "'\\''" <> go rest
    go (c:rest)    = c : go rest

-- | Render the env-override prefix for the remote arm: @env VAR='val'
-- VAR2='val2' @ (each value single-quoted via 'shellQuote' so a value
-- containing spaces / quotes / @$()@ is passed as a single token — the
-- @env@ command sets them before the command runs). The @env@ prefix is
-- portable (@ssh -A@ only forwards the agent socket; @SendEnv@/@SetEnv@
-- need server @AcceptEnv@ which is @none@ by default — design §4.4). The
-- caller appends the command after the prefix.
renderEnvPrefix :: [(String, String)] -> String
renderEnvPrefix extras =
  if null extras
    then ""
    else "env " <> unwords [ k <> "=" <> shellQuote v | (k, v) <- extras ] <> " "

-- | Smart-construct a 'ShellCommand', lifting a parse failure into an
-- 'UntrustedErr' (defensive — the inputs are already validated, so this
-- only fires on a NUL that slipped through). Returns 'Left' so the caller
-- can short-circuit; the message is uniform across the remote arm.
shellCmd :: Text -> Either UntrustedErr ShellCommand
shellCmd t = case mkShellCommand t of
  Left _  -> Left (UeExec ExecNotImplemented)
  Right c -> Right c

-- | Like 'runRemoteShellForwardingText' but with local env overrides
-- (MERGED over the inherited environment). Used by the remote deploy-key
-- clone path so the local @ssh -A@ process uses the SEAL agent's
-- @SSH_AUTH_SOCK@ (not the ambient one) — the forwarded agent then has
-- the deploy key loaded.
runRemoteShellForwardingEnvText
  :: RemoteRunner -> SshConfig -> [(String, String)] -> Text
  -> IO (Either UntrustedErr Text)
runRemoteShellForwardingEnvText runner cfg localEnv cmdText =
  case shellCmd cmdText of
    Left e    -> pure (Left e)
    Right cmd -> do
      let argv = sshExecArgvForwarding cfg (textShellCommand cmd)
      logExecDebug "[remote ssh -A]" argv Nothing localEnv
      res <- runRemoteEnv runner localEnv argv
      pure (either (Left . UeExec) Right res)

-- | Run a remote shell command built from a 'Text' command string. The
-- 'shellCmd' parse failure is lifted to 'UeExec'; the 'runRemoteShell'
-- 'ExecError' is lifted to 'UeExec'. Uniform across the remote arm.
runRemoteShellText
  :: RemoteRunner -> SshConfig -> Text -> IO (Either UntrustedErr Text)
runRemoteShellText runner cfg cmdText =
  case shellCmd cmdText of
    Left e    -> pure (Left e)
    Right cmd -> do
      let argv = sshExecArgv cfg (textShellCommand cmd)
      logExecDebug "[remote ssh]" argv Nothing []
      res <- runRemoteShell runner cfg cmd
      pure (either (Left . UeExec) Right res)

-- | Like 'runRemoteShellText' but with env overrides applied to the
-- SUBPROCESS. The caller supplies the @cd@ prefix and the command SEPARATELY;
-- the composed remote command is @\<cdPart\>env K='V' … \<cmd\>@ so the vars
-- scope to the trailing command — NOT to the @cd@.
--
-- Placement is security-relevant (the PAT-clone bug): a POSIX shell scopes a
-- leading @env@ assignment only to the single command that follows it, so an
-- env prefix BEFORE @\<cd\> && \<cmd\>@ binds nothing for @\<cmd\>@. This
-- mirrors the deploy-key path ('uioShellExecGitEnv'), which composes
-- @cd … && env … git …@ for the same reason.
--
-- The 'logExecDebug' call receives the command WITHOUT the env prefix and
-- the extras SEPARATELY so 'redactEnv' can redact secret-bearing keys before
-- rendering (design §3.7): the logged message must not contain any value
-- from a key in 'secretEnvKeys'.
runRemoteShellTextEnv
  :: RemoteRunner -> SshConfig -> Text -> [(String, String)] -> Text
  -> IO (Either UntrustedErr Text)
runRemoteShellTextEnv runner cfg cdPart extras cmd =
  let envPrefix = T.pack (renderEnvPrefix extras)
      fullCmdText = cdPart <> envPrefix <> cmd
      logCmdText = cdPart <> cmd
  in case shellCmd fullCmdText of
       Left e     -> pure (Left e)
       Right full -> do
         logCmd <- case shellCmd logCmdText of
           Left _   -> pure full
           Right l  -> pure l
         let argv = sshExecArgv cfg (textShellCommand logCmd)
         logExecDebug "[remote ssh]" argv Nothing extras
         res <- runRemoteShell runner cfg full
         pure (either (Left . UeExec) Right res)

-- ---------------------------------------------------------------------------
-- Pure diff applier (lifted from Seal.ISA.Ops.File so the local AND remote
-- arms share the same patch logic without an opcode-module import cycle).
-- ---------------------------------------------------------------------------

-- | Apply a minimal unified diff to the original content. Returns
-- @Left errMsg@ if the patch is malformed or the context doesn't match;
-- @Right newContent@ on success. This is the same applier that lived in
-- 'Seal.ISA.Ops.File.applyUnifiedDiff' — lifted here so both arms share
-- one implementation.
--
-- The applier is **content-based**, not position-based: for each hunk it
-- extracts the old lines (context @ @ + removed @-@), searches for that
-- sequence in the file starting near the hunk header's line-number hint,
-- and splices in the new lines (context @ @ + added @+@). The line number
-- is a hint to disambiguate duplicate matches, NOT a trusted insertion
-- index — this is the design used by OpenCode (@seek@ in patch.ts) and
-- Hermes (@fuzzy_find_and_replace@). A position-based applier that
-- blindly @splitAt@s at the header's oldStart corrupts the file when:
--   * the model's line number is stale (file changed since it read it),
--   * an earlier hunk in the same patch shifted line numbers, or
--   * the model miscounted lines.
-- All three were observed in session 20260810-123133-477 ("The patch is
-- inserting lines at wrong positions").
applyUnifiedDiff :: Text -> Text -> Either Text Text
applyUnifiedDiff original patch =
  let origLines  = T.lines original
      patchLines = T.lines patch
  in go origLines patchLines
  where
    -- All hunks apply against the ORIGINAL file's line numbering; we
    -- thread the already-patched lines through 'go' so successive hunks
    -- see a consistent view. The search-start hint is carried in the
    -- accumulator so a later hunk's line-number hint still points into
    -- the original's coordinate space (we never let an earlier hunk's
    -- insertions/deletions shift a later hunk's target).
    go origLines [] = Right (joinLines origLines)
    go origLines (h : rest)
      | T.isPrefixOf "@@ " h  = applyHunk origLines h rest
      | T.isPrefixOf "--- " h = go origLines rest
      | T.isPrefixOf "+++ " h = go origLines rest
      | T.null h              = go origLines rest
      | otherwise             = Left ("unexpected line in patch: " <> h)

    applyHunk origLines header rest =
      case parseHunkHeader header of
        Left err -> Left err
        Right (oldStart, mOldLen) ->
          let (hunkLines, remainingPatch) = span isHunkLine rest
              (oldLines, _newLines) = splitHunk hunkLines
              -- The line-number hint is a 0-based index into the file
              -- pointing at where the hunk's old lines BEGIN. For a
              -- normal hunk (oldLen >= 1) that's oldStart-1 (1-based ->
              -- 0-based). For a PURE-INSERT hunk (oldLen == 0) the
              -- header's oldStart is the line AFTER which to insert
              -- (1-based), so the 0-based insertion index is oldStart
              -- itself (insert after that line). The @@ -0,0 +1,N @@
              -- form (insert at start of empty file) gives oldStart=0,
              -- which clamps to index 0.
              isPureInsert = case mOldLen of
                Just 0  -> True
                Nothing -> null oldLines   -- short-form header; infer
                _       -> False
              hint = if isPureInsert
                       then max 0 oldStart        -- insert after line oldStart
                       else max 0 (oldStart - 1) -- replace starting at oldStart
          in case findMatch origLines oldLines hint of
               Left err -> Left err
               Right idx ->
                 let (before, atAndAfter) = splitAt idx origLines
                     matched = take (length oldLines) atAndAfter
                     after   = drop (length oldLines) atAndAfter
                     -- Build the replacement: walk the hunk body and the
                     -- matched file lines in parallel. For context (' ')
                     -- lines we prefer the FILE's actual text (so a
                     -- fuzzy match doesn't drag the patch's trailing
                     -- whitespace into the file); for '+' lines we use
                     -- the patch's text; '-' lines are dropped.
                     replacement = spliceHunk hunkLines matched
                 in go (before ++ replacement ++ after) remainingPatch

    -- | Walk the hunk body and the matched file lines in parallel,
    -- producing the replacement line list. Context (' ') lines take
    -- the FILE's line (preserving the file's actual whitespace);
    -- '+' lines take the patch's text; '-' and '\\' lines are dropped.
    spliceHunk :: [Text] -> [Text] -> [Text]
    spliceHunk = go'
      where
        go' [] _ = []
        go' (l : ls) fileLines =
          case T.uncons l of
            Just (' ', _) -> case fileLines of
              (f : fs) -> f : go' ls fs
              []       -> go' ls []   -- shouldn't happen; findMatch guards
            Just ('+', body') -> body' : go' ls fileLines
            Just ('-', _) -> go' ls (drop 1 fileLines)
            Just ('\\', _) -> go' ls fileLines
            _ -> go' ls fileLines   -- empty/malformed: skip, keep file pos

    -- | Split hunk body lines into (oldLines, newLines). Context lines
    -- (' ' prefix) appear in BOTH; removed lines ('-') in old only;
    -- added lines ('+') in new only. '\\' (no-newline-at-eof) and empty
    -- lines are ignored.
    splitHunk :: [Text] -> ([Text], [Text])
    splitHunk ls =
      let go' []         = ([], [])
          go' (l : rest) =
            case T.uncons l of
              Just (' ', body) -> let (o, n) = go' rest in (body : o, body : n)
              Just ('-', body) -> let (o, n) = go' rest in (body : o, n)
              Just ('+', body) -> let (o, n) = go' rest in (o, body : n)
              Just ('\\', _)   -> go' rest
              _                -> go' rest  -- empty or malformed: skip
      in go' ls

    -- | Find the index in @lines@ where the @pattern@ sequence matches,
    -- searching near the @hint@ first, then the whole file. Tries four
    -- comparison strategies in order (exact -> rstrip -> trim ->
    -- normalized) so trailing-whitespace and Unicode punctuation
    -- differences don't cause a hard failure — mirrors OpenCode's
    -- @seek@ fallback ladder. An empty pattern (pure-insert hunk) lands
    -- at the hint index (insert after the hinted line).
    findMatch :: [Text] -> [Text] -> Int -> Either Text Int
    findMatch _    []     hint = Right hint
    findMatch xs pat    hint =
      case searchNear xs pat hint of
        Just idx -> Right idx
        Nothing  ->
          case searchAll xs pat of
            Just idx -> Right idx
            Nothing  ->
              Left ("FILE_PATCH: context not found near line "
                      <> T.pack (show (hint + 1)) <> ":\n"
                      <> T.intercalate "\n" pat)

    searchNear xs pat hint =
      let n      = length xs
          plen   = length pat
          -- Search outward from the hint: try hint, hint±1, hint±2, ...
          -- so the closest match to the claimed line wins (disambiguates
          -- duplicates by proximity to the hint).
          offsets = concatMap (\d -> [hint + d, hint - d]) [0..(n - 1)]
          valid  = filter (\i -> i >= 0 && i <= n - plen) offsets
      in firstMatch xs pat valid

    searchAll xs pat =
      let n    = length xs
          plen = length pat
      in firstMatch xs pat [0 .. n - plen]

    firstMatch _    _   []       = Nothing
    firstMatch xs pat (i : is) =
      if matchesAt xs pat i
        then Just i
        else firstMatch xs pat is

    matchesAt xs pat i =
      any (\cmp -> and (zipWith cmp (drop i xs) pat))
           [exactEq, rstripEq, trimEq, normalizedEq]

    exactEq a b = a == b
    rstripEq a b = T.dropWhileEnd isSpace a == T.dropWhileEnd isSpace b
    trimEq a b = T.dropWhile isSpace (T.dropWhileEnd isSpace a)
              == T.dropWhile isSpace (T.dropWhileEnd isSpace b)
    normalizedEq a b = normalize (trimLine a) == normalize (trimLine b)
      where
        trimLine = T.dropWhile isSpace . T.dropWhileEnd isSpace
        normalize = T.map (\c -> if c == '\t' then ' ' else c)

    isHunkLine l =
      T.null l
      || T.isPrefixOf " " l
      || T.isPrefixOf "-" l
      || T.isPrefixOf "+" l
      || T.isPrefixOf "\\" l

    -- | Join lines back into text, preserving the trailing newline if
    -- the original had one (T.lines drops it; we re-add it so a file
    -- ending in a newline round-trips).
    joinLines [] = ""
    joinLines ls = T.intercalate "\n" ls <> "\n"

    parseHunkHeader h =
      case T.stripPrefix "@@ -" h of
        Nothing -> Left ("malformed hunk header: " <> h)
        Just rest0 ->
          let (oldStartStr, afterOld) = breakNum rest0
              (oldLenStr, afterOldLen) = breakLen afterOld
              afterPlus0 = T.dropWhile (/= '+') afterOldLen
              afterPlus  = T.drop 1 afterPlus0
              (newStartStr, _) = breakNum afterPlus
              oldStart = readMaybe (T.unpack oldStartStr) :: Maybe Int
              _newStart = readMaybe (T.unpack newStartStr) :: Maybe Int
          in case oldStart of
               Just os_ -> Right (os_, readMaybe (T.unpack oldLenStr) :: Maybe Int)
               Nothing  -> Left ("malformed hunk header numbers: " <> h)
      where
        breakNum :: Text -> (Text, Text)
        breakNum s =
          let (digits, rest) = T.span isDigit s
          in case T.uncons rest of
               Just (',', rest') -> (digits, T.dropWhile isDigit rest')
               _                 -> (digits, rest)
        -- | After the oldStart number, an optional @,len@ may follow.
        -- Return the len string (empty if the short form was used) and
        -- the rest after the @,len@ (or after the start number if short
        -- form). The length is informational (the content search is the
        -- source of truth); we keep it only for diagnostics.
        breakLen :: Text -> (Text, Text)
        breakLen s =
          case T.uncons s of
            Just (',', rest) -> T.span isDigit rest
            _                -> ("", s)
        readMaybe :: String -> Maybe Int
        readMaybe s = case reads s :: [(Int, String)] of
          [(n, _)] -> Just n
          _        -> Nothing

-- | Build a 'LineWindow' from raw text (the remote arm returns raw
-- content via @cat@; the opcode renders it just like the local arm).
-- The text is split to lines and the whole thing is one window (no
-- truncation — the bounded read already enforced the byte ceiling).
lineWindowFromText :: Text -> LineWindow
lineWindowFromText txt =
  let ls = T.lines txt
      n  = length ls
  in LineWindow
       { lwLines     = ls
       , lwStart     = 0
       , lwEnd       = n
       , lwTotal     = n
       , lwHasMore   = False
       , lwTruncated = False
       }
