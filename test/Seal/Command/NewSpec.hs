{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.NewSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Seal.Command.Help (renderHelpIndex)
import Seal.Command.New
  ( NewDeps (..), newCommandSpec, renderNewConfirmation
  , NewArgs (..), parseNewArgs, emptyNewArgs )
import Seal.Command.Parse (ParseOutcome (..), parseSlash)
import Seal.Command.Spec (mkRegistry)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Session.Meta (SessionMeta (..))

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

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
