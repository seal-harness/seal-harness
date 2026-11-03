{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.ConvRepairSpec (spec) where

import Data.Aeson (object)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Test.Hspec
import Test.QuickCheck

import Seal.Agent.ConvRepair (repairDanglingToolUse)
import Seal.Core.Types (OpName (..), ToolCallId (..))
import Seal.Providers.Class
  ( ContentBlock (..)
  , Message (..)
  , Role (..)
  , ToolResultPart (..)
  )

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

asst :: [ContentBlock] -> Message
asst = Message Assistant

usr :: [ContentBlock] -> Message
usr = Message User

toolUse :: Text -> ContentBlock
toolUse i = CbToolUse (ToolCallId i) (OpName "FILE_READ") (object [])

toolResult :: Text -> ContentBlock
toolResult i = CbToolResult (ToolCallId i) [TrpText "ok"] False

spec :: Spec
spec = describe "Seal.Agent.ConvRepair.repairDanglingToolUse" $ do
  it "leaves a complete tail untouched" $ do
    let conv = [usr [CbText "hi"], asst [CbText "reading"], asst [toolUse "c1"], usr [toolResult "c1"]]
    repairDanglingToolUse conv `shouldBe` ([], conv)

  it "leaves an empty conversation untouched" $
    repairDanglingToolUse [] `shouldBe` ([], [])

  it "appends one synthetic error result for a dangling tool_use" $ do
    let conv = [asst [toolUse "c1"]]
        (findings, out) = repairDanglingToolUse conv
    findings `shouldBe` []
    length out `shouldBe` length conv + 1
    case reverse out of
      (Message User [CbToolResult cid _ isErr]) : _ -> do
        cid `shouldBe` ToolCallId "c1"
        isErr `shouldBe` True
      other -> expectationFailure ("unexpected tail: " <> show other)

  it "repairs exactly the unmatched ids in a partial tail" $ do
    let conv = [asst [toolUse "c1", toolUse "c2"], usr [toolResult "c1"]]
        (findings, out) = repairDanglingToolUse conv
    findings `shouldBe` []
    case reverse out of
      (Message User results) : _ -> do
        length results `shouldBe` 1
        case results of
          [CbToolResult cid _ _] -> cid `shouldBe` ToolCallId "c2"
          _ -> expectationFailure "expected exactly one synthetic result"
      other -> expectationFailure ("unexpected tail: " <> show other)

  it "reports (and does not repair) a mid-history dangling id" $ do
    let conv = [asst [toolUse "c1"], usr [CbText "later"], asst [CbText "done"]]
        (findings, out) = repairDanglingToolUse conv
    findings `shouldBe` ["c1"]
    out `shouldBe` conv

  it "is idempotent" $
    property $ \(Conv conv) ->
      let (_, firstPass)  = repairDanglingToolUse conv
          (_, secondPass) = repairDanglingToolUse firstPass
      in secondPass === firstPass

  it "only ever appends (input is a prefix of output)" $
    property $ \(Conv conv) ->
      let (_, out) = repairDanglingToolUse conv
      in conv `isPrefixOf` out

  it "never reports findings for a conversation whose tail is complete" $
    property $ \(CompleteConv conv) ->
      let (findings, out) = repairDanglingToolUse conv
      in (findings, out) === ([], conv)

-- ---------------------------------------------------------------------------
-- Generators (bounded)
-- ---------------------------------------------------------------------------

newtype Conv = Conv [Message]
  deriving stock (Show)

newtype CompleteConv = CompleteConv [Message]
  deriving stock (Show)

-- | Arbitrary small conversations (any shape, including dangling tool_use).
instance Arbitrary Conv where
  arbitrary = do
    n <- choose (1 :: Int, 3)
    Conv <$> vectorOf n genMessage

-- | Conversations whose tool_use turns are always answered: the tail is
-- complete, so the repair must be a no-op.
instance Arbitrary CompleteConv where
  arbitrary = do
    n <- choose (0 :: Int, 3)
    CompleteConv . concat <$> vectorOf n genTurn

genTurn :: Gen [Message]
genTurn = do
  r <- choose (0 :: Int, 2)
  pure $ case r of
    0 -> [usr [CbText "u"]]
    1 -> [asst [CbText "a"]]
    _ -> [asst [toolUse "c1"], usr [toolResult "c1"]]

genMessage :: Gen Message
genMessage = do
  role <- elements [User, Assistant]
  Message role <$> resize 3 (listOf genBlock)

genBlock :: Gen ContentBlock
genBlock = do
  i <- elements ["c1", "c2", "c3"]
  oneof
    [ pure (CbText "t")
    , pure (toolUse i)
    , pure (toolResult i)
    ]
