{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.RegistrySpec (spec) where

import Data.Aeson (object, (.=))
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Test.Hspec

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode
import Seal.ISA.Ops.Registry
import Seal.ISA.Registry
import Seal.Providers.Class (ToolDefinition (..), ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A trivial trusted opcode with a recognizable schema, so the describe
-- opcode has something concrete to render.
sampleOp :: Opcode
sampleOp = TrustedOpcode
  { toName = OpName "SAMPLE_OP"
  , toTrust = Trusted
  , toDesc = "A sample opcode for testing."
  , toInSchema = object
      [ "type" .= ("object" :: T.Text)
      , "properties" .= object
          [ "x" .= object [ "type" .= ("integer" :: T.Text) ] ]
      ]
  , toOutSchema = object ["type" .= ("object" :: T.Text)]
  , toAuthorize = const (Right ())
  , toRun = \_ _ -> pure (OpResult [TrpText "ok"] False (object []))
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Registry" $ do

  describe "OPCODE_DESCRIBE" $ do
    let reg = mkRegistry [ sampleOp ]

    it "renders the opcode's name, description, and schemas" $ do
      let op = opcodeDescribeOp reg
      r <- runTestApp (opRun op localBackend (object ["name" .= ("SAMPLE_OP" :: T.Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> do
          "SAMPLE_OP"      `T.isInfixOf` t `shouldBe` True
          "A sample opcode" `T.isInfixOf` t `shouldBe` True
          "input_schema"   `T.isInfixOf` t `shouldBe` True
          "output_schema"  `T.isInfixOf` t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

    it "returns an error for an unknown opcode name" $ do
      let op = opcodeDescribeOp reg
      r <- runTestApp (opRun op localBackend (object ["name" .= ("NOPE" :: T.Text)]))
      orIsError r `shouldBe` True
      case orParts r of
        [TrpText t] -> "not found" `T.isInfixOf` t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "rejects input missing the name field" $ do
      let op = opcodeDescribeOp reg
      r <- runTestApp (opRun op localBackend (object []))
      orIsError r `shouldBe` True

    it "can describe itself (recursive knot includes the describe op)" $ do
      let reg' = mkRegistry [ sampleOp, opcodeDescribeOp reg', opcodeListOp reg' ]
          op = opcodeDescribeOp reg'
      r <- runTestApp (opRun op localBackend (object ["name" .= ("OPCODE_DESCRIBE" :: T.Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> "OPCODE_DESCRIBE" `T.isInfixOf` t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

  describe "OPCODE_LIST" $ do
    it "lists every opcode name + description" $ do
      let reg = mkRegistry [ sampleOp ]
          op = opcodeListOp reg
      r <- runTestApp (opRun op localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> do
          "SAMPLE_OP"          `T.isInfixOf` t `shouldBe` True
          "A sample opcode"    `T.isInfixOf` t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

    it "reports when no opcodes are registered" $ do
      let reg = mkRegistry []
          op = opcodeListOp reg
      r <- runTestApp (opRun op localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> "no opcodes" `T.isInfixOf` t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

  describe "registryToolDefs' (stub schemas)" $ do
    it "emits the real schema when useStub is False" $ do
      let reg = mkRegistry [ sampleOp ]
      case listToMaybe (registryToolDefs' False reg) of
        Nothing -> expectationFailure "expected at least one tool definition"
        Just td -> do
          tdName td `shouldBe` OpName "SAMPLE_OP"
          tdInputSchema td `shouldBe` toInSchema sampleOp

    it "emits the stub schema when useStub is True (name + description preserved)" $ do
      let reg = mkRegistry [ sampleOp ]
      case listToMaybe (registryToolDefs' True reg) of
        Nothing -> expectationFailure "expected at least one tool definition"
        Just td -> do
          tdName td        `shouldBe` OpName "SAMPLE_OP"
          tdDescription td `shouldBe` "A sample opcode for testing."
          tdInputSchema td `shouldBe` stubSchema