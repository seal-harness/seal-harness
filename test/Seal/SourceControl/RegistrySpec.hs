{-# LANGUAGE OverloadedStrings #-}
module Seal.SourceControl.RegistrySpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.SourceControl.Repo
  ( RepoCredential (..), RepoId, SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.SourceControl.Registry

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

mkRepo :: Text -> Text -> VcsKind -> RepoCredential -> (RepoId, SourceRepo)
mkRepo rid url kind cred =
  case mkRepoId rid of
    Right i  -> (i, SourceRepo i url kind cred Nothing Nothing)
    Left err -> error ("bad fixed repo id in test: " <> T.unpack err)

patRepo :: (RepoId, SourceRepo)
patRepo = mkRepo "seal-harness"
  "git@github.com:seal-harness/seal-harness.git"
  VcsGitHub
  (CredPat "GITHUB_PAT_SEAL_HARNESS")

machineRepo :: (RepoId, SourceRepo)
machineRepo = mkRepo "acme-infra"
  "git@github.com:acme/infra.git"
  VcsGitHub
  (CredMachineUser "GITHUB_MACHINEUSER_ACME" "acme-bot")

-- | A two-repo registry covering a PAT + a MachineUser credential kind.
sampleRegistry :: RepoRegistry
sampleRegistry = RepoRegistry
  (Map.fromList [patRepo, machineRepo])

-- | Build a repo with an index-derived id, for the concurrency test.
aRepo :: Int -> SourceRepo
aRepo i = snd (mkRepo (T.pack ("repo-" <> show i))
                       (T.pack ("git@github.com:acme/repo-" <> show i <> ".git"))
                       VcsGitHub
                       (CredPat (T.pack ("VK_" <> show i))))

----------------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.SourceControl.Registry" $ do

  describe "loadRepoRegistry" $ do
    it "returns an empty registry when the file is absent" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        result <- loadRepoRegistry path
        result `shouldBe` Right (RepoRegistry Map.empty)

    it "returns Left with non-empty error text on a corrupt file" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        TIO.writeFile path "this is = [not valid toml"
        result <- loadRepoRegistry path
        case result of
          Left err -> T.length err `shouldSatisfy` (> 0)
          Right _  -> expectationFailure "expected Left for corrupt file but got Right"

  describe "saveRepoRegistry / loadRepoRegistry round-trip" $ do
    it "round-trips a two-repo registry (PAT + MachineUser)" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        saveRepoRegistry path sampleRegistry
        loaded <- loadRepoRegistry path
        loaded `shouldBe` Right sampleRegistry

    it "leaves no .tmp file after saving (atomic rename)" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        saveRepoRegistry path sampleRegistry
        leftover <- doesFileExist (path <> ".tmp")
        leftover `shouldBe` False

  describe "upsertRepo / removeRepo / lookupRepo" $ do
    it "upsertRepo adds a new repo to an empty registry" $ do
      let rr0  = RepoRegistry Map.empty
          (_ , r) = patRepo
          rr1 = upsertRepo r rr0
      rr1 `shouldBe` RepoRegistry (Map.fromList [patRepo])

    it "upsertRepo overwrites an existing repo by id" $ do
      let (k, r) = patRepo
          rr0 = RepoRegistry (Map.fromList [patRepo])
          r'  = r { srUrl = "git@github.com:seal-harness/seal-harness-RENAMED.git" }
          rr1 = upsertRepo r' rr0
      lookupRepo k rr1 `shouldBe` Just r'

    it "removeRepo deletes an existing repo" $ do
      let (k, _) = patRepo
          rr0 = RepoRegistry (Map.fromList [patRepo, machineRepo])
          rr1 = removeRepo k rr0
      lookupRepo k rr1 `shouldBe` Nothing
      Map.size (rrRepos rr1) `shouldBe` 1

    it "removeRepo is a no-op for a missing key" $ do
      let (k, _) = patRepo
          rr0 = RepoRegistry Map.empty
          rr1 = removeRepo k rr0
      rr1 `shouldBe` rr0

    it "lookupRepo finds a present repo and misses an absent one" $ do
      let (kPat, rPat) = patRepo
          (kMach, _) = machineRepo
          rr = RepoRegistry (Map.fromList [patRepo, machineRepo])
      lookupRepo kPat rr `shouldBe` Just rPat
      lookupRepo kMach rr `shouldBe` Just (snd machineRepo)
      lookupRepo (fst patRepo) (removeRepo (fst patRepo) rr) `shouldBe` Nothing

  describe "updateRepoRegistry (concurrency)" $ do
    it "serializes N concurrent upserts with no lost update" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
            n   = 10
        _ <- mapConcurrently
               (updateRepoRegistry path . upsertRepo . aRepo)
               [1 .. n]
        result <- loadRepoRegistry path
        case result of
          Left err -> expectationFailure ("load failed after concurrent upserts: " <> T.unpack err)
          Right rr -> Map.size (rrRepos rr) `shouldBe` n

    it "propagates a load error as Left without writing" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        TIO.writeFile path "this is = [not valid toml"
        res <- updateRepoRegistry path (upsertRepo (aRepo 1))
        res `shouldSatisfy` isLeft

  describe "RepoRegistryHandle" $ do
    it "fake wiring returns canned results" $ do
      let handle = RepoRegistryHandle
            { rrhList   = pure (Right [])
            , rrhMutate = \_ -> pure (Right ())
            }
      l <- rrhList handle
      m <- rrhMutate handle id
      l `shouldBe` Right ([] :: [SourceRepo])
      m `shouldBe` Right ()

    it "mkRepoRegistryHandle rrhList loads an absent file as an empty list" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        handle <- mkRepoRegistryHandle path
        l <- rrhList handle
        l `shouldBe` Right ([] :: [SourceRepo])

    it "mkRepoRegistryHandle rrhList surfaces a corrupt file as Left" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        TIO.writeFile path "this is = [not valid toml"
        handle <- mkRepoRegistryHandle path
        l <- rrhList handle
        l `shouldSatisfy` isLeft

    it "mkRepoRegistryHandle rrhMutate persists an upsert" $
      withSystemTempDirectory "seal-registry-test" $ \dir -> do
        let path = dir </> "repos.toml"
        handle <- mkRepoRegistryHandle path
        m <- rrhMutate handle (upsertRepo (aRepo 1))
        m `shouldSatisfy` isRight
        l <- rrhList handle
        case l of
          Left err -> expectationFailure ("list failed after mutate: " <> T.unpack err)
          Right rs -> length rs `shouldBe` 1