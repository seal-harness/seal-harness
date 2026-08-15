{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.WorkdirFsSpec (spec) where

import Data.ByteString qualified as BS
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

import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath)
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