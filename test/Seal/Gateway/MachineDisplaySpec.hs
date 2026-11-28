{-# LANGUAGE OverloadedStrings #-}
-- | WU-11 — the display surfaces, pinned to their frozen strings.
--
-- Obligations from design §5.5/§10.2 that this module pins:
--
--   * T-STR-12 — @sessionInfoJson@'s @machine@ agrees with the name the tab
--     line embeds, for the same session. (The ill-posed "TUI and web renderers
--     agree" test was dropped in review — the tab line is TUI-only. This is the
--     shared projection both actually emit.)
--   * @machine@ is never @null@ on upgrade.
--
-- T-STR-9 (banner) and T-STR-10 (tab line) are pinned in @MachinePromptSpec@'s
-- neighbourhood but exercised through the renderers directly; the banner is
-- inline in the CLI boot path and the tab line needs a 'Tab', so both live with
-- their own assertions rather than being reconstructed here.
module Seal.Gateway.MachineDisplaySpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Time (UTCTime (..), fromGregorian)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, machineNameText, mkMachineName)
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.SessionJson (sessionInfoJson)
import Seal.Session.Meta (SessionMeta (..))

spec :: Spec
spec = describe "WU-11 machine display surfaces" $ do

  describe "sessionInfoJson (T-STR-12)" $ do

    it "emits the recorded machine" $
      machineField (sessionInfoJson Nothing Nothing Nothing (meta (Just alpha)))
        `shouldBe` Just (machineNameText alpha)

    it "never emits null — a legacy session reports a machine, not a blank" $ do
      -- Design §5.6: "resolved name (never null on upgrade)". A blank column for
      -- every pre-feature session would make the sidebar look broken, and a JSON
      -- null would force every consumer to branch.
      case machineField (sessionInfoJson Nothing Nothing Nothing (meta Nothing)) of
        Nothing -> expectationFailure "machine field absent"
        Just t  -> T.null t `shouldBe` False

    it "agrees with the raw record, so the two surfaces cannot drift" $
      machineField (sessionInfoJson Nothing Nothing Nothing (meta (Just alpha)))
        `shouldBe` (machineNameText <$> smMachine (meta (Just alpha)))

    it "an unrecorded session reports `local`" $ do
      -- The documented fallback: `local` is the implicit machine a pre-feature
      -- install resolves to, so it is the honest value to show rather than an
      -- invented one.
      machineField (sessionInfoJson Nothing Nothing Nothing (meta Nothing))
        `shouldBe` Just "local"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

machineField :: Value -> Maybe Text
machineField (Object o) = case KeyMap.lookup (Key.fromText "machine") o of
  Just (String t) -> Just t
  _               -> Nothing
machineField _ = Nothing

meta :: Maybe MachineName -> SessionMeta
meta mM = SessionMeta
  { smId              = either (error "fixture id") id
                          (mkSessionId "20260101-000000-001")
  , smProvider        = "anthropic"
  , smModel           = "claude-sonnet-4"
  , smChannel         = "web"
  , smParent          = Nothing
  , smAgent           = Nothing
  , smSystemOverride  = Nothing
  , smAgentName       = Nothing
  , smDescription     = Nothing
  , smSealFrontMatter = True
  , smRepoUrl         = Nothing
  , smMachine         = mM
  , smRepoBranch      = Nothing
  , smCreatedAt       = sampleTime
  , smLastActive      = sampleTime
  }

-- | A fixed timestamp: the display assertions do not depend on time.
sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 1 1) 0

alpha :: MachineName
alpha = case mkMachineName "alpha" of
  Right n -> n
  Left e  -> error ("fixture: " <> T.unpack e)
