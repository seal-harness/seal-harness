{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.RegistrySpec (spec) where

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
  , toRun = \_ _ -> pure (OpResult [] False Null) }

stubUntrustedOp :: OpName -> Opcode
stubUntrustedOp n = UntrustedOpcode
  { uoName = n, uoDesc = "desc", uoInSchema = object [], uoOutSchema = object []
  , uoAuthorize = const (Right ())
  , uoRun = \_ _ _ -> pure (OpResult [] False Null) }

spec :: Spec
spec = describe "Seal.ISA.Registry" $ do
  let reg = mkRegistry [stubTrustedOp (OpName "A"), stubUntrustedOp (OpName "B")]
  it "looks up registered opcodes" $
    fmap opName (lookupOp reg (OpName "A")) `shouldBe` Just (OpName "A")
  it "misses unregistered" $
    fmap opName (lookupOp reg (OpName "Z")) `shouldBe` Nothing
  it "derives one ToolDefinition per opcode" $
    map tdName (registryToolDefs reg) `shouldMatchList` [OpName "A", OpName "B"]
