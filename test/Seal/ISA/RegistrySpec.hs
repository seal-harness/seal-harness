{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.RegistrySpec (spec) where

import Data.Aeson (Value (..), object)
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class (ToolDefinition (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry

stubOp :: OpName -> TrustLevel -> Opcode
stubOp n tl = Opcode
  { opName = n, opTrust = tl, opDesc = "desc", opInSchema = object [], opOutSchema = object []
  , opAuthorize = const (Right ())
  , opRun = \_ _ -> pure (OpResult [] False Null) }

spec :: Spec
spec = describe "Seal.ISA.Registry" $ do
  let reg = mkRegistry [stubOp (OpName "A") Trusted, stubOp (OpName "B") Untrusted]
  it "looks up registered opcodes" $
    fmap opName (lookupOp reg (OpName "A")) `shouldBe` Just (OpName "A")
  it "misses unregistered" $
    fmap opName (lookupOp reg (OpName "Z")) `shouldBe` Nothing
  it "derives one ToolDefinition per opcode" $
    map tdName (registryToolDefs reg) `shouldMatchList` [OpName "A", OpName "B"]
