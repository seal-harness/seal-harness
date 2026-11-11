{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Tools.Exec.FileExplorerSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing, createFileLink
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Tools.Exec.FileExplorer
import Seal.Tools.Exec.Remote (RemoteRunner (..))
import Seal.Tools.Exec.Types
  ( ExecError (..), RemotePath, SshConfig (..), mkRemotePath, mkSshHost, mkSshUser
  )

spec :: Spec
spec = describe "Seal.Tools.Exec.FileExplorer" $ do

  --------------------------------------------------------------------------
  -- Fail-closed stub
  --------------------------------------------------------------------------

  describe "mkFailClosedFileExplorer" $ do
    let fe = mkFailClosedFileExplorer
    it "feListDirectory returns Left FeDisabled" $
      feListDirectory fe "/any/path" `shouldReturn` Left FeDisabled

    it "feReadFile returns Left FeDisabled" $
      feReadFile fe "/any/file" `shouldReturn` Left FeDisabled

    it "feReadFileBytes returns Left FeDisabled" $
      feReadFileBytes fe "/any/file" `shouldReturn` Left FeDisabled

    it "feResolveHome returns Left FeDisabled" $
      feResolveHome fe `shouldReturn` Left FeDisabled

  --------------------------------------------------------------------------
  -- Local arm
  --------------------------------------------------------------------------

  describe "mkLocalFileExplorer" $ do
    it "lists a directory with entries, types, sizes" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        createDirectoryIfMissing True (root </> "subdir")
        BS.writeFile (root </> "file.txt") "hello\n"
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe root
        case r of
          Left e -> expectationFailure ("expected Right, got " <> show e)
          Right listing -> do
            flPath listing `shouldBe` T.pack root
            flTruncated listing `shouldBe` False
            flWarning listing `shouldBe` Nothing
            let entries = flEntries listing
                names = map feName entries
            names `shouldContain` ["subdir"]
            names `shouldContain` ["file.txt"]
            -- Directories first
            case filter feIsDir entries of
              (d : _) -> feName d `shouldBe` "subdir"
              [] -> expectationFailure "expected a directory entry"
            case filter (not . feIsDir) entries of
              (f : _) -> do
                feName f `shouldBe` "file.txt"
                feIsDir f `shouldBe` False
                feIsSymlink f `shouldBe` False
                feSize f `shouldBe` Just 6
              [] -> expectationFailure "expected a file entry"

    it "returns FeNotFound for a missing path" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe (root </> "does-not-exist")
        r `shouldBe` Left FeNotFound

    it "returns FeNotADirectory when listing a file" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "file.txt") "hello\n"
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe (root </> "file.txt")
        r `shouldBe` Left FeNotADirectory

    it "returns FeIsDirectory when reading a directory" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        createDirectoryIfMissing True (root </> "subdir")
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFile fe (root </> "subdir")
        r `shouldBe` Left FeIsDirectory

    it "reads file content with correct line count" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "lines.txt") "line one\nline two\nline three\n"
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFile fe (root </> "lines.txt")
        case r of
          Left e -> expectationFailure ("expected Right, got " <> show e)
          Right content -> do
            fcContent content `shouldBe` "line one\nline two\nline three\n"
            fcLinesRead content `shouldBe` 3
            fcIsBinary content `shouldBe` False
            fcTruncated content `shouldBe` False

    it "counts lines correctly for content without trailing newline" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "nonl.txt") "a\nb"
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFile fe (root </> "nonl.txt")
        case r of
          Right content -> fcLinesRead content `shouldBe` 2
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "sets fcIsBinary when content has NUL bytes" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "binary.dat") (BS.pack [0x41, 0x00, 0x42])
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFile fe (root </> "binary.dat")
        case r of
          Right content -> do
            fcIsBinary content `shouldBe` True
            fcContent content `shouldBe` ""
            fcLinesRead content `shouldBe` 0
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "truncates content when file exceeds byte ceiling" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "big.txt") (BS.replicate 20 65)
        let fe = mkLocalFileExplorer 10
        r <- feReadFile fe (root </> "big.txt")
        case r of
          Right content -> do
            fcTruncated content `shouldBe` True
            fcContent content `shouldBe` "AAAAAAAAAA"
            fcLinesRead content `shouldBe` 1
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "reads raw bytes via feReadFileBytes (no UTF-8 decode)" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        let raw = BS.pack [0x41, 0x42, 0x43, 0x00, 0xFF]
        BS.writeFile (root </> "raw.bin") raw
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFileBytes fe (root </> "raw.bin")
        case r of
          Right (bs, truncated) -> do
            bs `shouldBe` raw
            truncated `shouldBe` False
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "feReadFileBytes truncates at byte ceiling" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "big.bin") (BS.replicate 20 65)
        let fe = mkLocalFileExplorer 10
        r <- feReadFileBytes fe (root </> "big.bin")
        case r of
          Right (bs, truncated) -> do
            BS.length bs `shouldBe` 10
            truncated `shouldBe` True
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "feReadFile returns FeNotFound for a missing file" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFile fe (root </> "ghost.txt")
        r `shouldBe` Left FeNotFound

    it "resolves home directory" $ do
      let fe = mkLocalFileExplorer 1048576
      r <- feResolveHome fe
      case r of
        Left e -> expectationFailure ("expected Right, got " <> show e)
        Right home -> home `shouldSatisfy` (not . null)

    it "applies lexicalCollapse to paths" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        createDirectoryIfMissing True (root </> "sub")
        BS.writeFile (root </> "sub" </> "file.txt") "content\n"
        let fe = mkLocalFileExplorer 1048576
        r <- feReadFile fe (root </> "sub" </> ".." </> "sub" </> "file.txt")
        case r of
          Right content -> fcContent content `shouldBe` "content\n"
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "sets flWarning when path is under sensitive dirs" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        createDirectoryIfMissing True (root </> ".ssh")
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe (root </> ".ssh")
        case r of
          Right listing -> flWarning listing `shouldBe` Just "This directory contains sensitive files"
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "does not set flWarning for normal directories" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        createDirectoryIfMissing True (root </> "src")
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe root
        case r of
          Right listing -> flWarning listing `shouldBe` Nothing
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "truncates listing at listingEntryLimit entries" $
      withSystemTempDirectory "seal-fe-trunc" $ \root -> do
        -- Create listingEntryLimit + 1 entries
        let extra = listingEntryLimit + 1
        mapM_ (\i -> BS.writeFile (root </> ("f" <> show i)) "") [1 .. extra]
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe root
        case r of
          Right listing -> do
            flTruncated listing `shouldBe` True
            length (flEntries listing) `shouldBe` listingEntryLimit
          Left e -> expectationFailure ("expected Right, got " <> show e)

    it "shows symlinks as symlink type (not followed)" $
      withSystemTempDirectory "seal-fe" $ \root -> do
        BS.writeFile (root </> "real.txt") "real\n"
        createFileLink (root </> "real.txt") (root </> "link.txt")
        let fe = mkLocalFileExplorer 1048576
        r <- feListDirectory fe root
        case r of
          Right listing -> do
            case filter feIsSymlink (flEntries listing) of
              (link : _) -> do
                feIsDir link `shouldBe` False
                feName link `shouldBe` "link.txt"
              [] -> expectationFailure "expected a symlink entry"
            length (filter feIsSymlink (flEntries listing)) `shouldBe` 1
          Left e -> expectationFailure ("expected Right, got " <> show e)

  --------------------------------------------------------------------------
  -- Remote arm
  --------------------------------------------------------------------------

  describe "mkRemoteFileExplorer" $ do
    it "lists directory via SSH (fake runner recording argv)" $ do
      calls <- newIORef []
      let out = T.unlines ["D|subdir", "F|file.txt|6|1700000000"]
      runner <- scriptedRunner calls [Right out]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/home/user/project"
      case r of
        Right listing -> do
          flPath listing `shouldBe` "/home/user/project"
          flTruncated listing `shouldBe` False
          let entries = flEntries listing
          length entries `shouldBe` 2
          -- Directory first
          feName (firstEntry entries) `shouldBe` "subdir"
          feIsDir (firstEntry entries) `shouldBe` True
          feName (entries !! 1) `shouldBe` "file.txt"
          feIsDir (entries !! 1) `shouldBe` False
          feSize (entries !! 1) `shouldBe` Just 6
        Left e -> expectationFailure ("expected Right, got " <> show e)
      recorded <- readIORef calls
      length recorded `shouldBe` 1

    it "parses S| symlink entries" $ do
      calls <- newIORef []
      let out = T.unlines ["S|alink", "D|adir", "F|afile|100|1700000000", "O|asocket"]
      runner <- scriptedRunner calls [Right out]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/test"
      case r of
        Right listing -> do
          let entries = flEntries listing
          length entries `shouldBe` 4
          -- Sorted: dirs first, then non-dirs alphabetically
          feIsDir (firstEntry entries) `shouldBe` True
          feName (firstEntry entries) `shouldBe` "adir"
          feName (entries !! 1) `shouldBe` "afile"
          feIsDir (entries !! 1) `shouldBe` False
          feSize (entries !! 1) `shouldBe` Just 100
          feIsSymlink (entries !! 2) `shouldBe` True
          feName (entries !! 2) `shouldBe` "alink"
          feName (entries !! 3) `shouldBe` "asocket"
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "returns FeNotFound when remote path does not exist" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "___SEAL_NOTFOUND___\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/nonexistent"
      r `shouldBe` Left FeNotFound

    it "returns FeNotADirectory when remote path is a file" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "___SEAL_NOTDIR___\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/some/file.txt"
      r `shouldBe` Left FeNotADirectory

    it "handles truncated SSH output (flTruncated)" $ do
      calls <- newIORef []
      let out = "D|a\n" <> truncationMarkerText <> " 50000 bytes — redirect to a file]"
      runner <- scriptedRunner calls [Right out]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/test"
      case r of
        Right listing -> do
          flTruncated listing `shouldBe` True
          length (flEntries listing) `shouldBe` 1
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "reads file content via SSH head -c" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "hello world\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFile fe "/home/user/file.txt"
      case r of
        Right content -> do
          fcContent content `shouldBe` "hello world\n"
          fcLinesRead content `shouldBe` 1
          fcIsBinary content `shouldBe` False
          fcTruncated content `shouldBe` False
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "returns FeNotFound when remote file does not exist" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "___SEAL_NOTFOUND___\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFile fe "/ghost.txt"
      r `shouldBe` Left FeNotFound

    it "returns FeIsDirectory when reading a remote directory" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "___SEAL_ISDIR___\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFile fe "/some/dir"
      r `shouldBe` Left FeIsDirectory

    it "resolves home via SSH echo $HOME" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "/home/agent\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feResolveHome fe
      r `shouldBe` Right "/home/agent"

    it "caches home directory resolution" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "/home/agent\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      _ <- feResolveHome fe
      _ <- feResolveHome fe
      _ <- feResolveHome fe
      recorded <- readIORef calls
      length recorded `shouldBe` 1

    it "uses -- separator in ls command" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right ""]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      _ <- feListDirectory fe "/test/path"
      recorded <- readIORef calls
      case recorded of
        (cmd : _) -> cmd `shouldSatisfy` T.isInfixOf "ls -1A --"
        [] -> expectationFailure "expected a recorded command"

    it "shell-quotes path in variable assignment (no single-quote leak)" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right ""]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      _ <- feListDirectory fe "/test/path"
      recorded <- readIORef calls
      case recorded of
        (cmd : _) -> do
          -- The path should be assigned via p='<path>' (shell-quoted)
          "p=" `T.isInfixOf` cmd `shouldBe` True
          -- The -- separator should be before "$p"
          "-- \"$p\"" `T.isInfixOf` cmd `shouldBe` True
        [] -> expectationFailure "expected a recorded command"

    it "reads raw bytes via feReadFileBytes (fake runner asserts head -c argv)" $ do
      calls <- newIORef []
      let content = "raw bytes here"
      runner <- scriptedRunner calls [Right content]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFileBytes fe "/home/user/file.bin"
      case r of
        Right (bs, truncated) -> do
          bs `shouldBe` TE.encodeUtf8 content
          truncated `shouldBe` False
        Left e -> expectationFailure ("expected Right, got " <> show e)
      recorded <- readIORef calls
      case recorded of
        (cmd : _) -> "head -c" `T.isInfixOf` cmd `shouldBe` True
        [] -> expectationFailure "expected a recorded command"

    it "feReadFileBytes returns raw non-UTF-8 bytes without corruption" $ do
      calls <- newIORef []
      -- Bytes 0xFF 0xFE are invalid UTF-8 — if the transport decodes
      -- to Text and re-encodes, these would be replaced with U+FFFD.
      -- With runRemoteBytes, the raw bytes should pass through intact.
      let rawBytes = BS.pack [0xFF, 0xFE, 0x00, 0x41, 0x42]
      runner <- scriptedRunnerBytes calls [Right rawBytes]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFileBytes fe "/home/user/binary.bin"
      case r of
        Right (bs, truncated) -> do
          bs `shouldBe` rawBytes
          truncated `shouldBe` False
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "feReadFileBytes returns FeNotFound for missing file" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right "___SEAL_NOTFOUND___\n"]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFileBytes fe "/ghost.bin"
      r `shouldBe` Left FeNotFound

    it "maps SSH exec failure to FeExec" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Left ExecRemoteUnreachable]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/test"
      r `shouldSatisfy` \case
        Left (FeExec _) -> True
        _ -> False

    it "maps ExecHostKeyUnknown to FeExec with ssh-keyscan instructions" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Left ExecHostKeyUnknown]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feResolveHome fe
      r `shouldSatisfy` \case
        Left (FeExec msg) -> "ssh-keyscan" `T.isInfixOf` msg
        _ -> False

    it "maps ExecHostKeyUnknown on feListDirectory with ssh-keyscan instructions" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Left ExecHostKeyUnknown]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/test"
      r `shouldSatisfy` \case
        Left (FeExec msg) -> "ssh-keyscan" `T.isInfixOf` msg
        _ -> False

    it "sets flWarning for sensitive path" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right ""]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feListDirectory fe "/home/user/.ssh"
      case r of
        Right listing -> flWarning listing `shouldBe` Just "This directory contains sensitive files"
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "applies lexicalCollapse to remote paths" $ do
      calls <- newIORef []
      runner <- scriptedRunner calls [Right ""]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      _ <- feListDirectory fe "/a/b/../c"
      recorded <- readIORef calls
      case recorded of
        (cmd : _) -> do
          -- The collapsed path should be /a/c (no ".." in the command)
          "../" `T.isInfixOf` cmd `shouldBe` False
          "/a/c" `T.isInfixOf` cmd `shouldBe` True
        [] -> expectationFailure "expected a recorded command"

    it "sets fcTruncated when remote content exceeds byte ceiling" $ do
      calls <- newIORef []
      let content = T.replicate 20 "A"
      runner <- scriptedRunner calls [Right content]
      fe <- mkRemoteFileExplorer sshCfg runner 10
      r <- feReadFile fe "/test/big.txt"
      case r of
        Right fc -> fcTruncated fc `shouldBe` True
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "detects binary content (NUL byte) in remote read" $ do
      calls <- newIORef []
      -- A NUL byte encoded as a single char — TE.decodeUtf8 in the
      -- RemoteRunner preserves it, and TE.encodeUtf8 round-trips it.
      let content = "abc" <> T.singleton (chr 0) <> "def"
      runner <- scriptedRunner calls [Right content]
      fe <- mkRemoteFileExplorer sshCfg runner 1048576
      r <- feReadFile fe "/test/bin.dat"
      case r of
        Right fc -> do
          fcIsBinary fc `shouldBe` True
          fcContent fc `shouldBe` ""
          fcLinesRead fc `shouldBe` 0
        Left e -> expectationFailure ("expected Right, got " <> show e)

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Safe head for test assertions: returns the first element, failing the
-- test with a clear message if the list is empty. Used instead of the
-- partial @head@ / @!! 0@ (which hlint flags). The caller has already
-- asserted the list's length, so this never actually fails.
firstEntry :: HasCallStack => [a] -> a
firstEntry []    = error "firstEntry: empty list (caller should have asserted length first)"
firstEntry (x:_) = x

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | A scripted fake 'RemoteRunner' that records every call's command
-- string (the text after the @--@ separator in the SSH argv) into a
-- recording 'IORef' and returns the next canned result from a mutable
-- queue. Runs out of results → returns @Right ""@. This lets multi-step
-- remote methods be tested under a single in-process runner (no live SSH).
scriptedRunner :: IORef [Text] -> [Either ExecError Text] -> IO RemoteRunner

-- | Construct a 'RemotePath', crashing on invalid input (test fixtures only).
rp :: Text -> RemotePath
rp t = case mkRemotePath t of
  Right r -> r
  Left err ->
    error ("FileExplorerSpec: bad remote path: " <> T.unpack err <> ": " <> T.unpack t)

-- | Extract the command text (after the @--@ separator) from an SSH argv.
-- Shared by 'scriptedRunner' and 'scriptedRunnerBytes'.
extractCmd :: [String] -> Text
extractCmd argv = case dropWhile (/= "--") argv of
  (_sep : rest) -> T.pack (unwords rest)
  _             -> T.pack (unwords argv)

-- | Record a command text and pop the next canned result from the queue.
-- Shared by 'scriptedRunner'.
recordAndPop :: IORef [Text] -> IORef [Either ExecError Text] -> Text
             -> IO (Either ExecError Text)
recordAndPop recRef' qRef cmdText = do
  modifyIORef' recRef' (++ [cmdText])
  atomicModifyIORef' qRef $ \case
    (y : ys) -> (ys, y)
    []       -> ([], Right "")
scriptedRunner recRef canned0 = do
  qRef <- newIORef canned0
  pure RemoteRunner
    { runRemote = recordAndPop recRef qRef . extractCmd
    , runRemoteStdin = \argv _stdin -> recordAndPop recRef qRef (extractCmd argv)
    , runRemoteEnv = \_env argv -> recordAndPop recRef qRef (extractCmd argv)
    , runRemoteBytes = \argv -> do
        modifyIORef' recRef (++ [extractCmd argv])
        atomicModifyIORef' qRef $ \case
          (y : ys) -> (ys, case y of
            Left e  -> Left e
            Right t -> Right (TE.encodeUtf8 t, False))
          []       -> ([], Right ("", False))
    }

-- | Like 'scriptedRunner' but the canned results for 'runRemoteBytes'
-- are raw 'ByteString' (not encoded from 'Text'). Used for the
-- non-UTF-8 binary test where 'TE.encodeUtf8' would corrupt the bytes.
scriptedRunnerBytes :: IORef [Text] -> [Either ExecError ByteString] -> IO RemoteRunner
scriptedRunnerBytes recRef canned0 = do
  qRef <- newIORef canned0
  pure RemoteRunner
    { runRemote = \_argv -> pure (Right "")
    , runRemoteStdin = \_argv _stdin -> pure (Right "")
    , runRemoteEnv = \_env _argv -> pure (Right "")
    , runRemoteBytes = \argv -> do
        modifyIORef' recRef (++ [extractCmd argv])
        atomicModifyIORef' qRef $ \case
          (y : ys) -> (ys, case y of
            Left e  -> Left e
            Right bs -> Right (bs, False))
          []       -> ([], Right (BS.empty, False))
    }

-- | SSH config fixture for tests.
sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = rp "/srv/agent-workspace"
  }

-- | The truncation marker prefix used by 'readBounded' in the RemoteRunner.
truncationMarkerText :: Text
truncationMarkerText = "\n[output truncated at"
