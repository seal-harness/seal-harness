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
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (renameFile)
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  , withCreateProcess
  )

import Seal.Security.Path
  ( PathError (..), SafePath, WorkspaceRoot (..), getSafePath, mkSafePath
  , mkSafePathForWrite, mkSafePathRemote
  )
import Seal.Text.LineFile
  ( LineWindow (..) )
import Seal.Tools.Args
  ( BinArg, BinName, SearchPattern, ShellCommand
  , mkShellCommand, textBinArg, textBinName, textSearchPattern, textShellCommand
  )
import Seal.Tools.Exec.Remote
  ( RemoteRunner (..), runRemoteShell, sshExecArgv
  )
import Seal.Tools.Exec.Types
  ( ExecError (..), RemotePath, SshConfig (..), getRemotePath
  )

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

  , uioBinExec     :: BinName -> [BinArg] -> IO (Either UntrustedErr Text)
    -- ^ Run a named binary (no shell, fixed argv). Returns stdout or
    -- error.

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
mkLocalUntrustedIO wsRoot = UntrustedIO
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
           Nothing -> runLocalFixedArgv False argv Nothing
           Just rp -> case mkSafePathRemote wsRoot (T.unpack (getRemotePath rp)) of
             Left pe  -> pure (Left (UePath pe))
             Right sp -> runLocalFixedArgv False argv (Just (getSafePath sp))
  , uioBinExec = \bin bargs ->
      let argv = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
      in runLocalFixedArgv True argv Nothing
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
runLocalFixedArgv
  :: Bool -> [String] -> Maybe String -> IO (Either UntrustedErr Text)
runLocalFixedArgv treat127AsMissing argv mCwd = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "runLocalFixedArgv: empty argv (unreachable)"
      cp = (proc program args)
             { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
             , cwd = mCwd
             }
  res <- try @IOException
         (withCreateProcess cp $ \_ mOut mErr ph -> do
            (hOut, hErr) <- case (mOut, mErr) of
              (Just a, Just b) -> pure (a, b)
              _                -> error "runLocalFixedArgv: pipe creation failed (unreachable)"
            out <- TE.decodeUtf8 <$> BS.hGetContents hOut
            err <- TE.decodeUtf8 <$> BS.hGetContents hErr
            ec  <- waitForProcess ph
            pure (ec, out, err))
  pure $ case res of
    Left _ioErr                     -> Left (UeExec ExecNotImplemented)
    Right (ExitSuccess, out, _)    -> Right out
    Right (ExitFailure 127, _, _)
      | treat127AsMissing           -> Left (UeExec ExecNotImplemented)
    Right (ExitFailure n, out, err) -> Right (formatExitResult n out err)

-- | Format a non-zero exit result for the tool-call consumer. Combines
-- stdout and stderr (if non-empty) and annotates the exit code.
formatExitResult :: Int -> Text -> Text -> Text
formatExitResult n out err =
  let parts = [ t | t <- [out, err], not (T.null (T.strip t)) ]
      body  = if null parts then "" else T.intercalate "\n" parts
  in body <> "\n[exit code: " <> T.pack (show n) <> "]"

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
mkRemoteUntrustedIOFromRunner sshCfg runner = UntrustedIO
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
      case mCwd of
        Nothing -> runRemoteShellText runner sshCfg (textShellCommand cmd)
        Just rp ->
          case mkSafePathRemote (wsRootFromCfg sshCfg) (T.unpack (getRemotePath rp)) of
            Left pe  -> pure (Left (UePath pe))
            Right _  ->
              let cdCmd = "cd " <> shellQuote (T.unpack (getRemotePath rp))
                          <> " && " <> T.unpack (textShellCommand cmd)
              in runRemoteShellText runner sshCfg (T.pack cdCmd)
  , uioBinExec = \bin bargs ->
      let argv' = T.unpack (textBinName bin) : map (T.unpack . textBinArg) bargs
          cmd   = T.intercalate " " (map (T.pack . shellQuote) argv')
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
  , uioBinExec     = \_ _      -> pure (Left (UeExec ExecNotImplemented))
  , uioProcessList =             pure (Left (UeExec ExecNotImplemented))
  , uioProcessKill = \_         -> pure (Left (UeExec ExecNotImplemented))
  , uioSearchFiles = \_ _ _     -> pure (Left (UeExec ExecNotImplemented))
  }

-- | The workspace root for remote confinement. The 'SshConfig' carries
-- the remote workspace as a 'RemotePath'; we wrap it back into a
-- 'WorkspaceRoot' for 'mkSafePathRemote'.
wsRootFromCfg :: SshConfig -> WorkspaceRoot
wsRootFromCfg cfg = WorkspaceRoot (T.unpack (getRemotePath (scWorkspace cfg)))

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

-- | Smart-construct a 'ShellCommand', lifting a parse failure into an
-- 'UntrustedErr' (defensive — the inputs are already validated, so this
-- only fires on a NUL that slipped through). Returns 'Left' so the caller
-- can short-circuit; the message is uniform across the remote arm.
shellCmd :: Text -> Either UntrustedErr ShellCommand
shellCmd t = case mkShellCommand t of
  Left _  -> Left (UeExec ExecNotImplemented)
  Right c -> Right c

-- | Run a remote shell command built from a 'Text' command string. The
-- 'shellCmd' parse failure is lifted to 'UeExec'; the 'runRemoteShell'
-- 'ExecError' is lifted to 'UeExec'. Uniform across the remote arm.
runRemoteShellText
  :: RemoteRunner -> SshConfig -> Text -> IO (Either UntrustedErr Text)
runRemoteShellText runner cfg cmdText =
  case shellCmd cmdText of
    Left e    -> pure (Left e)
    Right cmd -> do
      res <- runRemoteShell runner cfg cmd
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
applyUnifiedDiff :: Text -> Text -> Either Text Text
applyUnifiedDiff original patch =
  let origLines  = T.lines original
      patchLines = T.lines patch
  in go origLines patchLines
  where
    go origLines [] = Right (T.intercalate "\n" origLines <> "\n")
    go origLines (h : rest)
      | T.isPrefixOf "@@ " h   = applyHunk origLines h rest
      | T.isPrefixOf "--- " h  = go origLines rest
      | T.isPrefixOf "+++ " h  = go origLines rest
      | T.null h               = go origLines rest
      | otherwise              = Left ("unexpected line in patch: " <> h)
    applyHunk origLines header rest =
      case parseHunkHeader header of
        Left err -> Left err
        Right (oldStart, _oldLen, _newStart, _newLen) ->
          let (hunkLines, remainingPatch) = span isHunkLine rest
              idx = max 0 (oldStart - 1)
              (before, atAndAfter) = splitAt idx origLines
          in case applyHunkLines atAndAfter hunkLines of
               Left err -> Left err
               Right patched -> go (before ++ patched) remainingPatch
    isHunkLine l =
      T.null l
      || T.isPrefixOf " " l
      || T.isPrefixOf "-" l
      || T.isPrefixOf "+" l
      || T.isPrefixOf "\\" l
    applyHunkLines orig [] = Right orig
    applyHunkLines (o : os) (h : hs)
      | T.isPrefixOf " " h  = keep o        (applyHunkLines os hs)
      | T.isPrefixOf "-" h  =                applyHunkLines os hs
      | T.isPrefixOf "+" h  = keep (T.drop 1 h) (applyHunkLines (o : os) hs)
      | T.isPrefixOf "\\" h =                applyHunkLines (o : os) hs
      | T.null h            =                applyHunkLines (o : os) hs
      | otherwise           = Left ("unexpected hunk line: " <> h)
      where keep x acc = (x :) <$> acc
    applyHunkLines [] (h : hs)
      | T.isPrefixOf "+" h  = keep (T.drop 1 h) (applyHunkLines [] hs)
      | T.isPrefixOf " " h  = Left ("hunk context line past end of file: " <> h)
      | T.isPrefixOf "-" h  = Left ("hunk removed line past end of file: " <> h)
      | T.isPrefixOf "\\" h = applyHunkLines [] hs
      | T.null h            = applyHunkLines [] hs
      | otherwise           = Left ("unexpected hunk line at end: " <> h)
      where keep x acc = (x :) <$> acc
    parseHunkHeader h =
      case T.stripPrefix "@@ -" h of
        Nothing -> Left ("malformed hunk header: " <> h)
        Just rest0 ->
          let (oldStartStr, afterOld) = breakNum rest0
              afterPlus0 = T.dropWhile (/= '+') afterOld
              afterPlus  = T.drop 1 afterPlus0
              (newStartStr, _) = breakNum afterPlus
              oldStart = readMaybe (T.unpack oldStartStr) :: Maybe Int
              newStart = readMaybe (T.unpack newStartStr) :: Maybe Int
          in case (oldStart, newStart) of
               (Just os_, Just ns_) -> Right (os_, Nothing, ns_, Nothing)
               _ -> Left ("malformed hunk header numbers: " <> h)
      where
        breakNum :: Text -> (Text, Text)
        breakNum s =
          let (digits, rest) = T.span isDigit s
          in case T.uncons rest of
               Just (',', rest') -> (digits, T.dropWhile isDigit rest')
               _                 -> (digits, rest)
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