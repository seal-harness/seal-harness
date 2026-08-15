{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Tools.Exec.WorkdirFsSpec (spec) where

import Data.ByteString qualified as BS
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing, createFileLink, setCurrentDirectory
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Security.Path (WorkspaceRoot (..), mkSafePathRemote, getSafePath)
import Seal.TestHelpers.FixtureRepo (stubCloneDeps)
import Seal.Tools.Exec.Remote (RemoteRunner (..))
import Seal.Tools.Exec.Types
  ( ExecError (..), RemotePath, SshConfig (..), getRemotePath, mkRemotePath
  , mkSshHost, mkSshUser
  )
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIO, shellQuote)
import Seal.Tools.Exec.WorkdirFs

spec :: Spec
spec = describe "Seal.Tools.Exec.WorkdirFs" $ do

  --------------------------------------------------------------------------
  -- Local arm
  --------------------------------------------------------------------------

  describe "local arm (mkLocalWorkdirFs)" $ do
    it "wfsReadFile reads a workspace file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        let path = root </> "hello.txt"
        BS.writeFile path "hello world\n"
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        r <- wfsReadFile fs (rp "hello.txt")
        r `shouldBe` Right "hello world"

    it "wfsDoesFileExist returns True for an existing file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "a.txt") "x"
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsDoesFileExist fs (rp "a.txt") `shouldReturn` True

    it "wfsDoesFileExist returns False for a missing file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsDoesFileExist fs (rp "nope.txt") `shouldReturn` False

    it "wfsDoesDirectoryExist returns True for an existing dir" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        createDirectoryIfMissing True (root </> "sub")
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsDoesDirectoryExist fs (rp "sub") `shouldReturn` True

    it "wfsListDirectory returns the children of a dir" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        createDirectoryIfMissing True (root </> "d")
        BS.writeFile (root </> "d" </> "a.txt") "a"
        BS.writeFile (root </> "d" </> "b.txt") "b"
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        r <- wfsListDirectory fs (rp "d")
        sort <$> r `shouldBe` Right ["a.txt", "b.txt"]

    it "wfsListDirectory returns Right [] on a missing dir" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsListDirectory fs (rp "nonexistent") `shouldReturn` Right []

    it "wfsFileSize returns the byte size of a file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "sized.txt") "12345"
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsFileSize fs (rp "sized.txt") `shouldReturn` Right 5

    it "wfsModificationTime returns a UTCTime for a file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "mt.txt") "x"
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        r <- wfsModificationTime fs (rp "mt.txt")
        r `shouldSatisfy` either (const False) (const True)

    it "rejects a symlink escaping the workdir" $
      withSystemTempDirectory "seal-wfs" $ \root ->
        withSystemTempDirectory "seal-escape" $ \outside -> do
          let outsideTarget = outside </> "secret.txt"
          BS.writeFile outsideTarget "top-secret"
          createFileLink outsideTarget (root </> "evil.txt")
          let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
          r <- wfsReadFile fs (rp "evil.txt")
          r `shouldSatisfy` isWfsPath

    it "allows a within-workdir symlink" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "real.txt") "real content\n"
        createFileLink (root </> "real.txt") (root </> "link.txt")
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        r <- wfsReadFile fs (rp "link.txt")
        r `shouldBe` Right "real content"

    it "rejects an oversize file with WfsOversize" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "big.txt") (BS.replicate 10 65)
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 5
        r <- wfsReadFile fs (rp "big.txt")
        r `shouldSatisfy` isWfsOversize

    it "wfsReadFile returns WfsNotFound for a missing file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        r <- wfsReadFile fs (rp "ghost.txt")
        r `shouldBe` Left WfsNotFound

    it "rejects a .. path" $
      withSystemTempDirectory "seal-wfs" $ \root ->
        withSystemTempDirectory "seal-other" $ \outside -> do
          let target = outside </> "passwd"
          BS.writeFile target "root:x:0:0\n"
          let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
          r <- wfsReadFile fs (rp "../passwd")
          r `shouldSatisfy` isWfsPath

  --------------------------------------------------------------------------
  -- In-memory stub arm
  --------------------------------------------------------------------------

  describe "in-memory stub (mkInMemWorkdirFs)" $ do
    it "wfsReadFile reads a FileContent entry" $ do
      let seed = Map.fromList
            [ (rp "agents.md", FileContent "hello agents\n")
            ]
          fs = mkInMemWorkdirFs seed
      wfsReadFile fs (rp "agents.md") `shouldReturn` Right "hello agents"

    it "wfsDoesFileExist returns True for a FileContent entry" $ do
      let seed = Map.fromList [(rp "f.txt", FileContent "x")]
          fs = mkInMemWorkdirFs seed
      wfsDoesFileExist fs (rp "f.txt") `shouldReturn` True

    it "wfsDoesFileExist returns False for a Missing entry" $ do
      let seed = Map.fromList [(rp "f.txt", Missing)]
          fs = mkInMemWorkdirFs seed
      wfsDoesFileExist fs (rp "f.txt") `shouldReturn` False

    it "wfsDoesDirectoryExist returns True for a Directory entry" $ do
      let seed = Map.fromList [(rp "d", Directory ["a.txt", "b.txt"])]
          fs = mkInMemWorkdirFs seed
      wfsDoesDirectoryExist fs (rp "d") `shouldReturn` True

    it "wfsListDirectory returns the Directory's children" $ do
      let seed = Map.fromList
            [ (rp "d", Directory ["a.txt", "b.txt"])
            ]
          fs = mkInMemWorkdirFs seed
      r <- wfsListDirectory fs (rp "d")
      sort <$> r `shouldBe` Right ["a.txt", "b.txt"]

    it "wfsListDirectory returns Right [] on a missing dir" $ do
      let seed = Map.fromList [(rp "f.txt", FileContent "x")]
          fs = mkInMemWorkdirFs seed
      wfsListDirectory fs (rp "nope") `shouldReturn` Right []

    it "wfsFileSize returns the content length" $ do
      let seed = Map.fromList [(rp "f.txt", FileContent "hello")]
          fs = mkInMemWorkdirFs seed
      wfsFileSize fs (rp "f.txt") `shouldReturn` Right 5

    it "rejects a SymlinkTarget escaping the workspace" $ do
      let seed = Map.fromList
            [ (rp "evil.md", SymlinkTarget (rp "/etc/shadow"))
            , (rp "agents.md", FileContent "safe\n")
            ]
          fs = mkInMemWorkdirFs seed
      r <- wfsReadFile fs (rp "evil.md")
      r `shouldSatisfy` isWfsPath

    it "allows a within-workdir SymlinkTarget chain" $ do
      let seed = Map.fromList
            [ (rp "link.md", SymlinkTarget (rp "real.md"))
            , (rp "real.md", FileContent "real content\n")
            ]
          fs = mkInMemWorkdirFs seed
      wfsReadFile fs (rp "link.md") `shouldReturn` Right "real content"

    it "rejects a symlink loop with WfsIo" $ do
      let seed = Map.fromList
            [ (rp "a.md", SymlinkTarget (rp "b.md"))
            , (rp "b.md", SymlinkTarget (rp "a.md"))
            ]
          fs = mkInMemWorkdirFs seed
      r <- wfsReadFile fs (rp "a.md")
      r `shouldSatisfy` isWfsIo

    it "wfsReadFile returns WfsNotFound for a missing key" $ do
      let seed = Map.fromList [(rp "f.txt", FileContent "x")]
          fs = mkInMemWorkdirFs seed
      wfsReadFile fs (rp "ghost.txt") `shouldReturn` Left WfsNotFound

  --------------------------------------------------------------------------
  -- Fail-closed stub
  --------------------------------------------------------------------------

  describe "fail-closed stub (mkWorkdirFsStub)" $ do
    it "wfsReadFile returns Left WfsStub" $
      wfsReadFile mkWorkdirFsStub (rp "any.txt") `shouldReturn` Left WfsStub

    it "wfsDoesFileExist returns False" $
      wfsDoesFileExist mkWorkdirFsStub (rp "any.txt") `shouldReturn` False

    it "wfsDoesDirectoryExist returns False" $
      wfsDoesDirectoryExist mkWorkdirFsStub (rp "any") `shouldReturn` False

    it "wfsListDirectory returns Right []" $
      wfsListDirectory mkWorkdirFsStub (rp "any") `shouldReturn` Right []

    it "wfsFileSize returns Left WfsStub" $
      wfsFileSize mkWorkdirFsStub (rp "any.txt") `shouldReturn` Left WfsStub

    it "wfsModificationTime returns Left WfsStub" $
      wfsModificationTime mkWorkdirFsStub (rp "any.txt") `shouldReturn` Left WfsStub

  --------------------------------------------------------------------------
  -- wfsListDirectory missing dir → [] on the local arm
  --------------------------------------------------------------------------

  describe "wfsListDirectory missing dir" $ do
    it "returns Right [] (local arm)" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsListDirectory fs (rp "does-not-exist") `shouldReturn` Right []

    it "returns Right [] (in-memory stub)" $ do
      let fs = mkInMemWorkdirFs Map.empty
      wfsListDirectory fs (rp "does-not-exist") `shouldReturn` Right []

  --------------------------------------------------------------------------
  -- doesFileExist / symlink interaction on local arm
  --------------------------------------------------------------------------

  describe "local arm symlink existence" $ do
    it "wfsDoesFileExist follows a within-workdir symlink" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "real.txt") "x"
        createFileLink (root </> "real.txt") (root </> "link.txt")
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        wfsDoesFileExist fs (rp "link.txt") `shouldReturn` True

    it "wfsDoesFileExist returns False for an escaping symlink" $
      withSystemTempDirectory "seal-wfs" $ \root ->
        withSystemTempDirectory "seal-escape" $ \outside -> do
          let outsideTarget = outside </> "secret.txt"
          BS.writeFile outsideTarget "top-secret"
          createFileLink outsideTarget (root </> "evil.txt")
          let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
          wfsDoesFileExist fs (rp "evil.txt") `shouldReturn` False

  --------------------------------------------------------------------------
  -- Oversize on local arm with default ceiling
  --------------------------------------------------------------------------

  describe "local arm oversize with default ceiling" $ do
    it "rejects a file exceeding maxBootstrapFileBytes" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        let bigSize = 1024 * 1024 + 1
        BS.writeFile (root </> "big.txt") (BS.replicate bigSize 65)
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) (1024 * 1024)
        r <- wfsReadFile fs (rp "big.txt")
        r `shouldSatisfy` isWfsOversize

  --------------------------------------------------------------------------
  -- Empty / whitespace-only file
  --------------------------------------------------------------------------

  describe "local arm empty file" $ do
    it "wfsReadFile returns WfsNotFound for a whitespace-only file" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "empty.txt") "   \n  "
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        r <- wfsReadFile fs (rp "empty.txt")
        r `shouldBe` Left WfsNotFound

  --------------------------------------------------------------------------
  -- setCurrentDirectory independence (mkSafePath is absolute-anchored)
  --------------------------------------------------------------------------

  describe "local arm CWD independence" $ do
    it "wfsReadFile works regardless of the process CWD" $
      withSystemTempDirectory "seal-wfs" $ \root -> do
        BS.writeFile (root </> "cwd.txt") "ok\n"
        let fs = mkLocalWorkdirFs (WorkspaceRoot root) 1048576
        withSystemTempDirectory "seal-elsewhere" $ \elsewhere -> do
          setCurrentDirectory elsewhere
          r <- wfsReadFile fs (rp "cwd.txt")
          r `shouldBe` Right "ok"

  --------------------------------------------------------------------------
  -- Remote arm (mkRemoteWorkdirFs)
  --------------------------------------------------------------------------

  describe "remote arm (mkRemoteWorkdirFs)" $ do

    it "rejects a .. path BEFORE any SSH call (IORef empty)" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [] 1048576
      r <- wfsReadFile fs (rp "../etc/passwd")
      r `shouldSatisfy` isWfsPath
      readIORef calls `shouldReturn` ([] :: [Text])

    it "rejects an absolute escape path BEFORE any SSH call" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [] 1048576
      r <- wfsReadFile fs (rp "/etc/shadow")
      r `shouldSatisfy` isWfsPath
      readIORef calls `shouldReturn` ([] :: [Text])

    it "wfsReadFile reads a workspace file (realpath → stat → head)" $ do
      calls <- newIORef []
      let absPath = "/srv/agent-workspace/agents.md"
      fs <- mkRemoteFs calls
        [ Right (T.pack absPath)
        , Right "12"
        , Right "hello agents\n"
        ] 1048576
      r <- wfsReadFile fs (rp "agents.md")
      r `shouldBe` Right "hello agents"
      n <- length <$> readIORef calls
      n `shouldBe` 3

    it "wfsReadFile rejects a realpath-resolved symlink escape" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right "/etc/shadow"] 1048576
      r <- wfsReadFile fs (rp "evil.md")
      r `shouldSatisfy` isWfsPath
      n <- length <$> readIORef calls
      n `shouldBe` 1

    it "wfsReadFile returns WfsNotFound when realpath reports missing" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right ""] 1048576
      r <- wfsReadFile fs (rp "ghost.md")
      r `shouldBe` Left WfsNotFound

    it "wfsReadFile rejects an oversize file (stat-first)" $ do
      calls <- newIORef []
      let absPath = "/srv/agent-workspace/big.txt"
      fs <- mkRemoteFs calls [Right (T.pack absPath), Right "100"] 5
      r <- wfsReadFile fs (rp "big.txt")
      r `shouldSatisfy` isWfsOversize
      n <- length <$> readIORef calls
      n `shouldBe` 2

    it "wfsDoesFileExist returns True (test -f echo y)" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right "y\n"] 1048576
      wfsDoesFileExist fs (rp "agents.md") `shouldReturn` True
      n <- length <$> readIORef calls
      n `shouldBe` 1

    it "wfsDoesFileExist returns False on empty stdout" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right ""] 1048576
      wfsDoesFileExist fs (rp "ghost.md") `shouldReturn` False

    it "wfsDoesDirectoryExist returns True (test -d echo y)" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right "y"] 1048576
      wfsDoesDirectoryExist fs (rp "sub") `shouldReturn` True

    it "wfsListDirectory returns the dir's children (realpath → ls -1)" $ do
      calls <- newIORef []
      let absPath = "/srv/agent-workspace/d"
      fs <- mkRemoteFs calls [Right (T.pack absPath), Right "a.txt\nb.txt\n"] 1048576
      r <- wfsListDirectory fs (rp "d")
      sort <$> r `shouldBe` Right ["a.txt", "b.txt"]
      n <- length <$> readIORef calls
      n `shouldBe` 2

    it "wfsListDirectory returns Right [] on a missing dir (realpath empty)" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right ""] 1048576
      wfsListDirectory fs (rp "nope") `shouldReturn` Right []
      n <- length <$> readIORef calls
      n `shouldBe` 1

    it "wfsListDirectory rejects a realpath-resolved symlink escape" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right "/etc"] 1048576
      r <- wfsListDirectory fs (rp "evil-dir")
      r `shouldSatisfy` isWfsPath
      n <- length <$> readIORef calls
      n `shouldBe` 1

    it "wfsFileSize returns the byte size (realpath → stat -c %s)" $ do
      calls <- newIORef []
      let absPath = "/srv/agent-workspace/sized.txt"
      fs <- mkRemoteFs calls [Right (T.pack absPath), Right "42"] 1048576
      wfsFileSize fs (rp "sized.txt") `shouldReturn` Right 42

    it "wfsFileSize rejects a realpath-resolved symlink escape" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right "/etc/passwd"] 1048576
      r <- wfsFileSize fs (rp "evil.txt")
      r `shouldSatisfy` isWfsPath

    it "wfsModificationTime returns a UTCTime (realpath → stat -c %Y)" $ do
      calls <- newIORef []
      let absPath = "/srv/agent-workspace/mt.txt"
      fs <- mkRemoteFs calls [Right (T.pack absPath), Right "1700000000"] 1048576
      r <- wfsModificationTime fs (rp "mt.txt")
      r `shouldSatisfy` either (const False) (const True)

    it "wfsModificationTime rejects a realpath-resolved symlink escape" $ do
      calls <- newIORef []
      fs <- mkRemoteFs calls [Right "/etc/passwd"] 1048576
      r <- wfsModificationTime fs (rp "evil.txt")
      r `shouldSatisfy` isWfsPath

  --------------------------------------------------------------------------
  -- QuickCheck: shellQuote has no unescaped shell metacharacters for
  -- every path that passes mkSafePathRemote.
  --------------------------------------------------------------------------

  describe "shellQuote property (mkSafePathRemote-validated paths)" $ do
    prop "contains no unescaped shell metacharacter" $
      forAll genValidRemotePathText $ \pathTxt ->
        let wsR = WorkspaceRoot "/srv/agent-workspace"
        in case mkSafePathRemote wsR (T.unpack pathTxt) of
             Right sp ->
               let quoted = shellQuote (getSafePath sp)
               in noUnescapedMeta quoted
             Left _ -> True

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Construct a 'RemotePath', crashing on invalid input (test fixtures only).
rp :: Text -> RemotePath
rp t = case mkRemotePath t of
  Right r -> r
  Left err ->
    error ("WorkdirFsSpec: bad remote path: " <> T.unpack err <> ": " <> T.unpack t)

-- | Assert the 'Either' is a 'Left' carrying a 'WfsPath' constructor.
isWfsPath :: Either WorkdirFsErr a -> Bool
isWfsPath = \case
  Left (WfsPath _) -> True
  _ -> False

-- | Assert the 'Either' is a 'Left' carrying 'WfsOversize'.
isWfsOversize :: Either WorkdirFsErr a -> Bool
isWfsOversize = \case
  Left WfsOversize -> True
  _ -> False

-- | Assert the 'Either' is a 'Left' carrying a 'WfsIo' constructor.
isWfsIo :: Either WorkdirFsErr a -> Bool
isWfsIo = \case
  Left (WfsIo _) -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Remote-arm test fixtures
-- ---------------------------------------------------------------------------

sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = rp "/srv/agent-workspace"
  }

wsRootOf :: SshConfig -> WorkspaceRoot
wsRootOf cfg = WorkspaceRoot (T.unpack (getRemotePath (scWorkspace cfg)))

-- | A scripted fake 'RemoteRunner' that records every call's command string
-- (the text after the @--@ separator in the SSH argv) into a recording
-- 'IORef' and returns the next canned result from a separate mutable queue
-- 'IORef'. Runs out of results → returns @Right ""@. This lets the
-- multi-step remote methods (realpath → stat → head) be tested under a
-- single in-process runner (no live SSH).
scriptedRunner :: IORef [Text] -> [Either ExecError Text] -> IO RemoteRunner
scriptedRunner recRef canned0 = do
  qRef <- newIORef canned0
  pure RemoteRunner
    { runRemote = recordAndPop recRef qRef . extractCmd
    , runRemoteStdin = \argv _stdin -> recordAndPop recRef qRef (extractCmd argv)
    , runRemoteEnv = \_env argv -> recordAndPop recRef qRef (extractCmd argv)
    }
  where
    recordAndPop :: IORef [Text] -> IORef [Either ExecError Text] -> Text
                 -> IO (Either ExecError Text)
    recordAndPop recRef' qRef cmdText = do
      modifyIORef' recRef' (++ [cmdText])
      atomicModifyIORef' qRef $ \case
        (y:ys) -> (ys, y)
        []     -> ([], Right "")
    extractCmd :: [String] -> Text
    extractCmd argv = case dropWhile (/= "--") argv of
      (_sep : rest) -> T.pack (unwords rest)
      _             -> T.pack (unwords argv)

-- | Build a remote 'WorkdirFs' wired to a scripted runner backed by the
-- recording 'IORef'. The canned results are consumed in order across the
-- method's sequential SSH calls.
mkRemoteFs :: IORef [Text] -> [Either ExecError Text] -> Int -> IO WorkdirFs
mkRemoteFs recRef canned ceilingBytes = do
  deps <- stubCloneDeps
  runner <- scriptedRunner recRef canned
  let uio = mkRemoteUntrustedIO sshCfg runner
      env = mkTestUIOEnv uio deps
  pure (mkRemoteWorkdirFs env sshCfg (wsRootOf sshCfg) ceilingBytes)

-- ---------------------------------------------------------------------------
-- QuickCheck: shellQuote metacharacter property
-- ---------------------------------------------------------------------------

-- | Bounded generator over text that 'mkRemotePath' accepts (no leading
-- dash, no control chars) AND that lexically stays under the workspace root
-- (no @..@ escape). Generates relative path components from a safe alphabet.
genValidRemotePathText :: Gen Text
genValidRemotePathText = do
  n <- chooseInt (1, 4)
  comps <- vectorOf n genPathComponent
  pure (T.intercalate "/" comps)
  where
    genPathComponent =
      T.pack <$> listOf1 (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "-_."))

-- | Assert that a shell-quoted string contains no UNescaped shell
-- metacharacter. 'shellQuote' wraps the value in single quotes and escapes
-- embedded single quotes with @'\\''@. Inside single quotes, the shell
-- interprets NO metacharacters — the only way to break out is an unescaped
-- @'@. So the property reduces to: between the outer quotes, every @'@ is
-- part of the @'\\''@ escape sequence (there is no bare @'@ that closes the
-- quoting). We also assert the result starts and ends with @'@.
noUnescapedMeta :: String -> Bool
noUnescapedMeta s =
  case s of
    ('\'':rest) -> maybe False noBareQuote (breakLastQuote rest)
    _ -> False
  where
    breakLastQuote xs =
      if not (null xs) && last xs == '\''
        then Just (init xs)
        else Nothing
    noBareQuote [] = True
    noBareQuote ('\'':'\\':'\'':'\'':rest) = noBareQuote rest
    noBareQuote ('\'':_) = False
    noBareQuote (_:rest) = noBareQuote rest