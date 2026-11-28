{-# LANGUAGE OverloadedStrings #-}
-- | WU-11 — @buildMachinePrompt@, the TUI session-start picker (T-STR-8).
--
-- The requirements' frozen layout, with the two §0.2 amendments applied (no
-- platform labels — @machines.toml@ defines no @os@ field — and the annotation
-- column is @(default)@ / @(this machine)@ only):
--
-- @
--   execution machine [default: linux-builder]:
--     1. local          (this machine)
--     2. linux-builder  (default)
--     3. mac-mini
--   > 3
-- @
--
-- __Why the function takes @[Selectable]@ and not @[MachineName]@.__ @local@ is
-- not a constructible 'MachineName' — 'mkMachineName' refuses the reserved name
-- — so a @[MachineName]@ signature could not express it, and the renderer must
-- also SUPPRESS the @local@ row entirely when @allow_localhost = false@. Both
-- are properties of the selectable set, not of a name list. @Selectable@ is also
-- what @GET \/api\/machines@ returns, so the TUI and the web picker cannot
-- disagree about whether @local@ is offered.
module Seal.ISA.Ops.MachinePromptSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, Selectable (..), mkMachineName)
import Seal.ISA.Ops.Machine (buildMachinePrompt)

spec :: Spec
spec = describe "WU-11 buildMachinePrompt" $ do

  it "T-STR-8: renders the frozen layout exactly" $
    buildMachinePrompt threeMachines (Just (machine "linux-builder"))
      `shouldBe` T.unlines
        [ "execution machine [default: linux-builder]:"
        , "  1. local          (this machine)"
        , "  2. linux-builder  (default)"
        , "  3. mac-mini"
        , "> "
        ]

  it "omits the local row entirely when allow_localhost is false" $ do
    -- Not "greys it out": the requirements say `local` does not appear in the
    -- machine list at all, and neither the user nor the model can name it.
    let out = buildMachinePrompt noLocal (Just (machine "linux-builder"))
    out `shouldNotSatisfy` T.isInfixOf "local"
    out `shouldSatisfy` T.isInfixOf "1. linux-builder"
    out `shouldSatisfy` T.isInfixOf "2. mac-mini"

  it "renumbers when the local row is absent" $ do
    -- The numbering is positional, so a suppressed row must not leave a gap.
    buildMachinePrompt noLocal (Just (machine "linux-builder"))
      `shouldBe` T.unlines
        [ "execution machine [default: linux-builder]:"
        , "  1. linux-builder  (default)"
        , "  2. mac-mini"
        , "> "
        ]

  it "names the default in the header" $
    buildMachinePrompt threeMachines (Just (machine "mac-mini"))
      `shouldSatisfy` T.isInfixOf "execution machine [default: mac-mini]:"

  it "marks `local` as this machine and never as default" $ do
    -- `local` cannot BE the configured default: `default` in machines.toml
    -- names a file entry, and `local` is implicit. Asserted so a future
    -- "mark the default" loop cannot double-annotate the local row.
    let out = buildMachinePrompt threeMachines Nothing
    out `shouldSatisfy` T.isInfixOf "(this machine)"
    out `shouldNotSatisfy` T.isInfixOf "(this machine)  (default)"

  it "renders no annotation column width padding after a bare machine" $ do
    -- Only the two annotated rows carry padding; an unannotated row is just
    -- the name. Trailing whitespace would be invisible in a terminal and would
    -- make exact-output assertions (and terminal wrapping) disagree.
    -- The trailing prompt line "> " is excluded: its space is the input cursor
    -- position, not padding.
    let out = buildMachinePrompt threeMachines (Just (machine "linux-builder"))
        rows = filter (`notElem` ["> ", ">"]) (T.lines out)
    [ r | r <- rows, T.isSuffixOf " " r ] `shouldBe` []

  it "with no default the header says so rather than omitting the bracket" $
    buildMachinePrompt threeMachines Nothing
      `shouldSatisfy` T.isInfixOf "execution machine:"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

threeMachines :: [Selectable]
threeMachines =
  [ SelLocal
  , SelMachine (machine "linux-builder")
  , SelMachine (machine "mac-mini") ]

noLocal :: [Selectable]
noLocal =
  [ SelMachine (machine "linux-builder")
  , SelMachine (machine "mac-mini") ]

machine :: Text -> MachineName
machine t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("fixture: " <> T.unpack e)
