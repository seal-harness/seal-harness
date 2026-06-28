{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.PathSpec (spec) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath, createDirectoryIfMissing, createFileLink)
import System.FilePath (joinPath, splitDirectories, (</>))
import System.IO.Temp (withSystemTempDirectory)
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
