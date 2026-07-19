{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.NewSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Seal.Command.Help (renderHelpIndex)
import Seal.Command.New (NewDeps (..), newCommandSpec, renderNewConfirmation)
import Seal.Command.Parse (ParseOutcome (..), parseSlash)
import Seal.Command.Spec (mkRegistry)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Session.Meta (SessionMeta (..))

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

-- | A stub NewDeps. ndRebind returns a canned old sid; the disk-touching
-- mint + the actual rebind are exercised at the CLI/integration level,
-- not here.
stubDeps :: NewDeps
stubDeps =
  NewDeps
    { ndPaths = error "ndPaths: unused"
    , ndCfg = error "ndCfg: unused"
    , ndAgentDefs = error "ndAgentDefs: unused"
    , ndChannelLabel = "test"
    , ndRebind = \_caps _newMeta -> pure (mkSid "20260701-000000-000")
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

  describe "newCommandSpec" $ do
    it "parses /new with no args" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/help index includes /new with the contrast-vs-/tab new synopsis" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
          help = renderHelpIndex reg
      T.unpack help `shouldContain` "/new"
      T.unpack help `shouldContain` "/tab new"

showPO :: ParseOutcome -> String
showPO (ParsedAction _)   = "ParsedAction"
showPO (ParseHelp Nothing) = "ParseHelp nothing"
showPO (ParseHelp (Just _)) = "ParseHelp just"
showPO (ParseFailure _)   = "ParseFailure"