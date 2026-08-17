{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.NewSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Seal.Command.Help (renderHelpIndex)
import Seal.Command.New
  ( NewDeps (..), newCommandSpec, renderNewConfirmation
  , NewArgs (..), parseNewArgs, emptyNewArgs, resolveRepoUrl )
import Seal.Command.Parse (ParseOutcome (..), parseSlash)
import Seal.Command.Spec (mkRegistry)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.SourceControl.Repo
  ( SourceRepo (..), RepoCredential (CredPat), VcsKind (VcsGitHub)
  , mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

-- | A stub repo for testing.
mkTestRepo :: Text -> Text -> SourceRepo
mkTestRepo rid url = SourceRepo
  { srId = case mkRepoId rid of Right r -> r; Left e -> error (T.unpack e)
  , srUrl = url
  , srVcsKind = VcsGitHub
  , srCredential = CredPat "test-key"
  , srDeployKeyPublic = Nothing
  , srKeyfilePath = Nothing
  }

-- | A stub RepoRegistryHandle that returns a fixed list of repos.
stubRepoReg :: [SourceRepo] -> RepoRegistryHandle
stubRepoReg repos = RepoRegistryHandle
  { rrhList = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

-- | A stub NewDeps. ndInsertTab returns a canned old sid; the disk-touching
-- mint + the actual tab insert are exercised at the CLI/integration level,
-- not here.
stubDeps :: NewDeps
stubDeps =
  NewDeps
    { ndPaths = error "ndPaths: unused"
    , ndCfg = error "ndCfg: unused"
    , ndAgentDefs = error "ndAgentDefs: unused"
    , ndChannelLabel = "test"
    , ndOldMeta = error "ndOldMeta: unused by parse/render tests"
    , ndInsertTab = \_caps _newMeta -> pure (mkSid "20260701-000000-000")
    , ndSetupRepo = Nothing
    , ndRepoReg = Nothing
    }

spec :: Spec
spec = describe "Seal.Command.New" $ do
  describe "renderNewConfirmation" $ do
    let newMeta = SessionMeta
          { smId = mkSid "20260719-120000-001"
          , smProvider = "anthropic"
          , smModel = "claude-sonnet-4-20250514"
          , smChannel = "cli"
          , smAgent = Nothing
          , smSystemOverride = Nothing
          , smAgentName = Nothing
          , smDescription = Nothing
          , smCreatedAt = error "unused"
          , smLastActive = error "unused"
          }
        oldSid = mkSid "20260701-000000-000"
        line = renderNewConfirmation newMeta oldSid
    it "names the new session id" $
      T.unpack line `shouldContain` "new session 20260719-120000-001"
    it "names the provider/model" $
      T.unpack line `shouldContain` "anthropic/claude-sonnet-4-20250514"
    it "names the prior session + resume hint" $ do
      T.unpack line `shouldContain` "prior session 20260701-000000-000"
      T.unpack line `shouldContain` "/session list"

  describe "parseNewArgs" $ do
    it "empty string yields emptyNewArgs" $
      parseNewArgs "" `shouldBe` emptyNewArgs
    it "parses -p provider" $
      parseNewArgs "-p anthropic" `shouldBe`
        emptyNewArgs { naProvider = Just "anthropic" }
    it "parses --provider provider" $
      parseNewArgs "--provider ollama" `shouldBe`
        emptyNewArgs { naProvider = Just "ollama" }
    it "parses -m model" $
      parseNewArgs "-m claude-sonnet-4" `shouldBe`
        emptyNewArgs { naModel = Just "claude-sonnet-4" }
    it "parses --model model" $
      parseNewArgs "--model llama3" `shouldBe`
        emptyNewArgs { naModel = Just "llama3" }
    it "parses -r repo" $
      parseNewArgs "-r https://github.com/foo/bar.git" `shouldBe`
        emptyNewArgs { naRepo = Just "https://github.com/foo/bar.git" }
    it "parses --repo repo" $
      parseNewArgs "--repo git@github.com:foo/bar.git" `shouldBe`
        emptyNewArgs { naRepo = Just "git@github.com:foo/bar.git" }
    it "parses all three flags" $
      parseNewArgs "-p anthropic -m claude-sonnet-4 -r https://github.com/foo/bar.git"
        `shouldBe` NewArgs
          { naProvider = Just "anthropic"
          , naModel = Just "claude-sonnet-4"
          , naRepo = Just "https://github.com/foo/bar.git"
          }
    it "parses long-form all three" $
      parseNewArgs "--provider anthropic --model claude-sonnet-4 --repo https://github.com/foo/bar.git"
        `shouldBe` NewArgs
          { naProvider = Just "anthropic"
          , naModel = Just "claude-sonnet-4"
          , naRepo = Just "https://github.com/foo/bar.git"
          }
    it "ignores unknown flags" $
      parseNewArgs "--unknown foo -p anthropic" `shouldBe`
        emptyNewArgs { naProvider = Just "anthropic" }

  describe "resolveRepoUrl" $ do
    let repos =
          [ mkTestRepo "seal-test-repo" "https://github.com/seal-harness/seal-harness.git"
          , mkTestRepo "other-repo" "git@github.com:foo/bar.git"
          ]
        regH = stubRepoReg repos

    it "resolves a registered repo ID to its URL" $ do
      url <- resolveRepoUrl regH "seal-test-repo"
      url `shouldBe` "https://github.com/seal-harness/seal-harness.git"

    it "resolves a different registered repo ID to its URL" $ do
      url <- resolveRepoUrl regH "other-repo"
      url `shouldBe` "git@github.com:foo/bar.git"

    it "falls back to the raw value when the ID is not registered" $ do
      url <- resolveRepoUrl regH "https://github.com/unknown/repo.git"
      url `shouldBe` "https://github.com/unknown/repo.git"

    it "falls back to the raw value when the registry is empty" $ do
      let emptyReg = stubRepoReg []
      url <- resolveRepoUrl emptyReg "some-repo-id"
      url `shouldBe` "some-repo-id"

    it "falls back to the raw value when the registry returns an error" $ do
      let errReg = RepoRegistryHandle
            { rrhList = pure (Left "corrupt toml")
            , rrhMutate = \_ -> pure (Right ())
            }
      url <- resolveRepoUrl errReg "some-repo-id"
      url `shouldBe` "some-repo-id"

  describe "newCommandSpec" $ do
    it "parses /new with no args" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -p anthropic" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -p anthropic" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -p anthropic -m claude-sonnet-4" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -p anthropic -m claude-sonnet-4" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -r https://github.com/foo/bar.git" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -r https://github.com/foo/bar.git" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -r seal-test-repo" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -r seal-test-repo" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new --provider anthropic --model claude-sonnet-4 --repo https://github.com/foo/bar.git" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new --provider anthropic --model claude-sonnet-4 --repo https://github.com/foo/bar.git" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/help index includes /new" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
          help = renderHelpIndex reg
      T.unpack help `shouldContain` "/new"

showPO :: ParseOutcome -> String
showPO (ParsedAction _)   = "ParsedAction"
showPO (ParseHelp Nothing) = "ParseHelp nothing"
showPO (ParseHelp (Just _)) = "ParseHelp just"
showPO (ParseFailure _)   = "ParseFailure"
