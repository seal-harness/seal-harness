{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.RegistrySpec (spec) where

import Data.Set qualified as Set
import Data.Aeson (Value (..), object)
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class (ToolDefinition (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry

stubTrustedOp :: OpName -> Opcode
stubTrustedOp n = TrustedOpcode
  { toName = n, toTrust = Trusted, toDesc = "desc", toInSchema = object [], toOutSchema = object []
  , toAuthorize = const (Right ())
  , toBlocking = False
  , toRun = \_ _ -> pure (OpResult [] False Null) }

stubUntrustedOp :: OpName -> Opcode
stubUntrustedOp n = UntrustedOpcode
  { uoName = n, uoDesc = "desc", uoInSchema = object [], uoOutSchema = object []
  , uoAuthorize = const (Right ())
  , uoRun = \_ -> pure (OpResult [] False Null) }

spec :: Spec
spec = describe "Seal.ISA.Registry" $ do
  let reg = mkRegistry [stubTrustedOp (OpName "A"), stubUntrustedOp (OpName "B")]
  it "looks up registered opcodes" $
    fmap opName (lookupOp reg (OpName "A")) `shouldBe` Just (OpName "A")
  it "misses unregistered" $
    fmap opName (lookupOp reg (OpName "Z")) `shouldBe` Nothing
  it "derives one ToolDefinition per opcode" $
    map tdName (registryToolDefs reg) `shouldMatchList` [OpName "A", OpName "B"]
  it "emits tool definitions in registration order (not alphabetical)" $ do
    let regOrdered = mkRegistry
          [ stubTrustedOp (OpName "Z")
          , stubTrustedOp (OpName "A")
          , stubTrustedOp (OpName "M")
          ]
    map tdName (registryToolDefs regOrdered) `shouldBe` [OpName "Z", OpName "A", OpName "M"]
  it "emits at most one ToolDefinition per opcode name when the input list has duplicates" $ do
    let regDup = mkRegistry
          [ stubTrustedOp (OpName "A")
          , stubTrustedOp (OpName "A")
          , stubUntrustedOp (OpName "B")
          ]
    map tdName (registryToolDefs regDup) `shouldBe` [OpName "A", OpName "B"]

  describe "hideOpcodes" $ do
    let hideReg = mkRegistry
          [ stubTrustedOp (OpName "MANAGE_OP")
          , stubTrustedOp (OpName "LEGACY_OP")
          ]
        hidden = Set.fromList [OpName "LEGACY_OP"]
        reg' = hideOpcodes hidden hideReg

    it "omits hidden opcodes from tool definitions" $
      map tdName (registryToolDefs reg') `shouldBe` [OpName "MANAGE_OP"]

    it "still dispatches hidden opcodes via lookupOp" $
      fmap opName (lookupOp reg' (OpName "LEGACY_OP")) `shouldBe` Just (OpName "LEGACY_OP")

    it "does not affect non-hidden opcodes" $
      fmap opName (lookupOp reg' (OpName "MANAGE_OP")) `shouldBe` Just (OpName "MANAGE_OP")

    it "hideOpcodes with empty set is a no-op for tool definitions" $
      map tdName (registryToolDefs (hideOpcodes Set.empty hideReg))
        `shouldMatchList` [OpName "MANAGE_OP", OpName "LEGACY_OP"]
