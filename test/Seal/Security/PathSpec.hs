{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.PathSpec (spec) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath, createDirectoryIfMissing, createFileLink)
import System.FilePath (joinPath, splitDirectories, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes, setFileMode)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (elements, forAll, ioProperty, listOf, resize)

import Seal.Security.Path

spec :: Spec
spec = describe "Seal.Security.Path" $ do

  it "accepts a file inside the workspace" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "ok.txt") "hi"
      r <- mkSafePath (WorkspaceRoot root) "ok.txt"
      fmap getSafePath r `shouldSatisfy` either (const False) (const True)

  it "accepts a nested path within the workspace" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      createDirectoryIfMissing True (root </> "subdir")
      BS.writeFile (root </> "subdir" </> "nested.txt") "data"
      r <- mkSafePath (WorkspaceRoot root) ("subdir" </> "nested.txt")
      r `shouldSatisfy` isOk

  it "rejects parent traversal" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      r <- mkSafePath (WorkspaceRoot root) "../escape.txt"
      r `shouldSatisfy` isEscape

  it "rejects an absolute path outside the workspace" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      r <- mkSafePath (WorkspaceRoot root) "/etc/passwd"
      r `shouldSatisfy` isEscape

  it "rejects blocked .env" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      r <- mkSafePath (WorkspaceRoot root) ".env"
      r `shouldSatisfy` isBlocked

  it "rejects blocked .ssh dotfiles" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      createDirectoryIfMissing True (root </> ".ssh")
      BS.writeFile (root </> ".ssh" </> "id_rsa") "k"
      r <- mkSafePath (WorkspaceRoot root) (".ssh" </> "id_rsa")
      r `shouldSatisfy` isBlocked

  it "rejects blocked .seal dotfiles" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      createDirectoryIfMissing True (root </> ".seal")
      BS.writeFile (root </> ".seal" </> "config") "cfg"
      r <- mkSafePath (WorkspaceRoot root) (".seal" </> "config")
      r `shouldSatisfy` isBlocked

  it "rejects a missing file with PathDoesNotExist" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      r <- mkSafePath (WorkspaceRoot root) "no-such-file.txt"
      r `shouldSatisfy` isMissing

  it "symlink inside workspace resolving outside is rejected" $
    withSystemTempDirectory "seal-ws" $ \root ->
      withSystemTempDirectory "seal-outside" $ \outside -> do
        let outsideTarget = outside </> "secret.txt"
        BS.writeFile outsideTarget "top-secret"
        createFileLink outsideTarget (root </> "evil")
        r <- mkSafePath (WorkspaceRoot root) "evil"
        r `shouldSatisfy` isEscape

  -- Segments are drawn from a small fixed safe set and the list is bounded
  -- (resize 4 + listOf), so paths are short, valid directory names — never
  -- "..", absolute, blocked, or pathologically large. We create the directory
  -- first so the Right branch is genuinely exercised; the test stays fast and
  -- deterministic. (An earlier version used arbitrary strings and hung on
  -- pathological generated input.)
  prop "no relative input ever yields a path outside the root" $
    forAll (resize 4 (listOf (elements ["a", "b", "sub", "x"]))) $ \segs ->
      ioProperty $
        withSystemTempDirectory "seal-ws" $ \root -> do
          let rel = joinPath segs
          unless (null segs) $ createDirectoryIfMissing True (root </> rel)
          r <- mkSafePath (WorkspaceRoot root) rel
          canonRoot <- canonicalizePath root
          pure $ case r of
            Right sp ->
              splitDirectories canonRoot `isPrefixOf` splitDirectories (getSafePath sp)
            Left _ -> True

  describe "KeysRoot and mkSafeKeyPath" $ do

    it "ensureKeysRoot creates the directory with mode 0700" $
      withSystemTempDirectory "seal-keys" $ \tmp -> do
        let keysDir = tmp </> "keys"
        kr <- ensureKeysRoot keysDir
        status <- getFileStatus keysDir
        (fileMode status `intersectFileModes` 0o777) `shouldBe` 0o700
        kr `shouldBe` KeysRoot keysDir

    it "accepts a not-yet-existing path under the root" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        r  <- mkSafeKeyPath kr "future.identity"
        r `shouldSatisfy` isOk

    it "accepts an existing file with mode 0600" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        let target = root </> "key.identity"
        BS.writeFile target "key-material"
        setFileMode target 0o600
        r <- mkSafeKeyPath kr "key.identity"
        r `shouldSatisfy` isOk

    it "accepts an existing file with mode 0400" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        let target = root </> "ro.identity"
        BS.writeFile target "key-material"
        setFileMode target 0o400
        r <- mkSafeKeyPath kr "ro.identity"
        r `shouldSatisfy` isOk

    it "rejects an existing file with mode 0644 (PathInsecureMode)" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        let target = root </> "loose.identity"
        BS.writeFile target "key-material"
        setFileMode target 0o644
        r <- mkSafeKeyPath kr "loose.identity"
        r `shouldSatisfy` isInsecureMode

    it "rejects a .. escape attempt" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        r  <- mkSafeKeyPath kr "../escape"
        r `shouldSatisfy` isEscape

    it "rejects an absolute path outside the root" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        r  <- mkSafeKeyPath kr "/etc/passwd"
        r `shouldSatisfy` isEscape

    it "rejects a symlink that resolves outside the root" $
      withSystemTempDirectory "seal-keys" $ \root ->
        withSystemTempDirectory "seal-outside" $ \outside -> do
          let outsideTarget = outside </> "secret.key"
          BS.writeFile outsideTarget "top-secret"
          createFileLink outsideTarget (root </> "evil-link")
          kr <- ensureKeysRoot root
          r  <- mkSafeKeyPath kr "evil-link"
          r `shouldSatisfy` isEscape

    it "getSafeKeyPath returns a path under the root" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        r  <- mkSafeKeyPath kr "future.identity"
        case r of
          Left e  -> expectationFailure ("expected Right, got: " <> show e)
          Right p -> getSafeKeyPath p `shouldContain` "future.identity"

    it "show SafeKeyPath does not reveal the path" $
      withSystemTempDirectory "seal-keys" $ \root -> do
        kr <- ensureKeysRoot root
        let target = root </> "secret.identity"
        BS.writeFile target "key"
        setFileMode target 0o600
        r <- mkSafeKeyPath kr "secret.identity"
        case r of
          Left e  -> expectationFailure ("expected Right, got: " <> show e)
          Right p -> show p `shouldNotContain` "secret.identity"

  where
    isOk     = either (const False) (const True)
    isEscape = either isEsc (const False)
    isEsc (PathEscapesWorkspace _) = True
    isEsc _ = False
    isBlocked = either isBlk (const False)
    isBlk (PathIsBlocked _) = True
    isBlk _ = False
    isMissing = either isMiss (const False)
    isMiss (PathDoesNotExist _) = True
    isMiss _ = False
    isInsecureMode = either isIM (const False)
    isIM (PathInsecureMode _) = True
    isIM _ = False
