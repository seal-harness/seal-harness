{-# LANGUAGE OverloadedStrings #-}
module Seal.Memory.BackendSpec (spec) where

import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Core.Types (SessionId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo, gitHasCommits)
import Seal.Memory.Backend
import Seal.Memory.Types (MemoryEntry (..), MemoryId (..), mkMemoryId, memoryIdText)
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleMemoryId :: MemoryId
sampleMemoryId = case mkMemoryId "m1" of
  Right mid -> mid
  Left _    -> MemoryId "fallback"

mkEntry :: Text -> MemoryEntry
mkEntry content = MemoryEntry
  { meId = sampleMemoryId
  , meContent = content
  , meTags = ["greeting", "demo"]
  , meCreatedAt = sampleTime
  , meUpdatedAt = sampleTime
  , meSession = SessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Memory.Backend" $ do
  describe "encodeMemory / decodeMemory" $ do
    it "round-trips an entry with tags" $ do
      let e = mkEntry "hello world"
      decodeMemory (encodeMemory e) `shouldBe` Just e

    it "round-trips an entry with empty tags" $ do
      let e = (mkEntry "x") { meTags = [] }
      decodeMemory (encodeMemory e) `shouldBe` Just e

    it "round-trips an entry with no system (empty body)" $ do
      let e = (mkEntry "") { meTags = [] }
      decodeMemory (encodeMemory e) `shouldBe` Just e

  describe "noneBackend" $ do
    it "store then recall round-trips" $ do
      backend <- noneBackend
      mbStore backend (mkEntry "hello")
      mbRecall backend sampleMemoryId `shouldReturn` Just (mkEntry "hello")

    it "delete removes the entry" $ do
      backend <- noneBackend
      mbStore backend (mkEntry "hello")
      mbDelete backend sampleMemoryId
      mbRecall backend sampleMemoryId `shouldReturn` Nothing

    it "list returns all entries" $ do
      backend <- noneBackend
      mbStore backend (mkEntry "a")
      mbList backend `shouldReturn` [mkEntry "a"]

  describe "markdownMemoryBackend" $ do
    it "store writes a file and recall reads it back" $
      withSystemTempDirectory "seal-mem" $ \root -> do
        let cfgRoot = root </> "config"
            memDir  = cfgRoot </> "memory"
        ensureConfigRepo cfgRoot
        backend <- markdownMemoryBackend memDir (openConfigRepo cfgRoot)
        mbStore backend (mkEntry "from-disk")
        doesFileExist (memDir </> "m1.md") `shouldReturn` True
        m <- mbRecall backend sampleMemoryId
        case m of
          Just e  -> meContent e `shouldBe` "from-disk"
          Nothing -> expectationFailure "memory not read back"

    it "store auto-commits to the git repo" $
      withSystemTempDirectory "seal-mem" $ \root -> do
        let cfgRoot = root </> "config"
            memDir  = cfgRoot </> "memory"
        ensureConfigRepo cfgRoot
        backend <- markdownMemoryBackend memDir (openConfigRepo cfgRoot)
        mbStore backend (mkEntry "committed")
        gitHasCommits (openConfigRepo cfgRoot) `shouldReturn` True

    it "list enumerates the directory sorted by id" $
      withSystemTempDirectory "seal-mem" $ \root -> do
        let cfgRoot = root </> "config"
            memDir  = cfgRoot </> "memory"
        ensureConfigRepo cfgRoot
        backend <- markdownMemoryBackend memDir (openConfigRepo cfgRoot)
        mbStore backend ((mkEntry "a") { meId = case mkMemoryId "zeta" of Right i -> i; Left _ -> sampleMemoryId })
        mbStore backend ((mkEntry "b") { meId = case mkMemoryId "alpha" of Right i -> i; Left _ -> sampleMemoryId })
        entries <- mbList backend
        map (memoryIdText . meId) entries `shouldBe` ["alpha", "zeta"]

    it "delete removes the file" $
      withSystemTempDirectory "seal-mem" $ \root -> do
        let cfgRoot = root </> "config"
            memDir  = cfgRoot </> "memory"
        ensureConfigRepo cfgRoot
        backend <- markdownMemoryBackend memDir (openConfigRepo cfgRoot)
        mbStore backend (mkEntry "x")
        mbDelete backend sampleMemoryId
        doesFileExist (memDir </> "m1.md") `shouldReturn` False
        mbRecall backend sampleMemoryId `shouldReturn` Nothing