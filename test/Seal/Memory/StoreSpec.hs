{-# LANGUAGE OverloadedStrings #-}
module Seal.Memory.StoreSpec (spec) where

import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Memory.Path (MemoryPath, mkMemoryPath, memoryPathText)
import Seal.Memory.Store

-- | Helper: create a path from a string, failing the test if invalid.
path :: String -> MemoryPath
path s = case mkMemoryPath (T.pack s) of
  Right p -> p
  Left e  -> error ("invalid path: " <> show s <> " — " <> T.unpack e)

spec :: Spec
spec = describe "Seal.Memory.Store" $ do
  describe "fileMemoryStore" $ do
    describe "msWrite" $ do
      it "creates a file under active/ and content round-trips through msRead" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "preferences") "prefer concise answers"
          r <- msRead store (path "preferences")
          r `shouldBe` Right ("prefer concise answers", False)

      it "fails when the path already exists (write-once)" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "tz") "UTC-5"
          r <- msWrite store (path "tz") "UTC-8"
          r `shouldSatisfy` isLeft'

      it "creates parent directories for nested paths" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "projects/pureclaw/architecture") "microservices"
          doesFileExist (root </> "active" </> "projects" </> "pureclaw" </> "architecture.md")
            `shouldReturn` True

    describe "msRead" $ do
      it "returns Left for a non-existent path" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          r <- msRead store (path "nope")
          r `shouldSatisfy` isLeft'

      it "falls back to archived/ and returns (content, True)" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "old") "original"
          _ <- msArchive store (path "old")
          r <- msRead store (path "old")
          r `shouldBe` Right ("original", True)

    describe "msList" $ do
      it "returns paths matching a prefix" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "projects/a/arch") "a"
          _ <- msWrite store (path "projects/b/arch") "b"
          _ <- msWrite store (path "user/tz") "UTC"
          entries <- msList store (T.pack "projects/") False
          length entries `shouldBe` 2
          all (\p -> "projects/" `T.isPrefixOf` memoryPathText p) entries `shouldBe` True

      it "includes archived paths when includeArchived=True" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "active1") "a"
          _ <- msWrite store (path "active2") "b"
          _ <- msArchive store (path "active1")
          activeOnly <- msList store "" False
          length activeOnly `shouldBe` 1
          withArchived <- msList store "" True
          length withArchived `shouldBe` 2

    describe "msArchive" $ do
      it "moves the file from active/ to archived/ with a timestamp prefix" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "tz") "UTC-5"
          r <- msArchive store (path "tz")
          case r of
            Left e  -> expectationFailure ("archive failed: " <> T.unpack e)
            Right archivedPath -> do
              -- The file is no longer in active/
              doesFileExist (root </> "active" </> "tz.md") `shouldReturn` False
              -- The archived path contains the original filename with a timestamp
              let archivedText = memoryPathText archivedPath
              T.isInfixOf "tz" archivedText `shouldBe` True

      it "returns Left for a non-existent path" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          r <- msArchive store (path "nope")
          r `shouldSatisfy` isLeft'

      it "allows writing the same path after archiving (update pattern)" $
        withSystemTempDirectory "seal-mem" $ \root -> do
          store <- fileMemoryStore root
          _ <- msWrite store (path "tz") "UTC-5"
          _ <- msArchive store (path "tz")
          r <- msWrite store (path "tz") "UTC-8"
          r `shouldBe` Right ()
          -- The new content is readable
          readResult <- msRead store (path "tz")
          readResult `shouldBe` Right ("UTC-8", False)

  describe "noneMemoryStore" $ do
    it "write then read round-trips" $ do
      store <- noneMemoryStore
      _ <- msWrite store (path "m1") "hello"
      r <- msRead store (path "m1")
      r `shouldBe` Right ("hello", False)

    it "write fails on existing path (write-once)" $ do
      store <- noneMemoryStore
      _ <- msWrite store (path "m1") "old"
      r <- msWrite store (path "m1") "new"
      r `shouldSatisfy` isLeft'

    it "archive then read returns archived" $ do
      store <- noneMemoryStore
      _ <- msWrite store (path "m1") "content"
      _ <- msArchive store (path "m1")
      r <- msRead store (path "m1")
      r `shouldBe` Right ("content", True)

    it "archive then write same path succeeds" $ do
      store <- noneMemoryStore
      _ <- msWrite store (path "m1") "old"
      _ <- msArchive store (path "m1")
      r <- msWrite store (path "m1") "new"
      r `shouldBe` Right ()

    it "list returns active paths" $ do
      store <- noneMemoryStore
      _ <- msWrite store (path "a") "x"
      _ <- msWrite store (path "b") "y"
      entries <- msList store "" False
      length entries `shouldBe` 2

    it "list with includeArchived includes archived" $ do
      store <- noneMemoryStore
      _ <- msWrite store (path "a") "x"
      _ <- msWrite store (path "b") "y"
      _ <- msArchive store (path "a")
      active <- msList store "" False
      length active `shouldBe` 1
      withArch <- msList store "" True
      length withArch `shouldBe` 2

isLeft' :: Either a b -> Bool
isLeft' (Left _)  = True
isLeft' (Right _) = False
