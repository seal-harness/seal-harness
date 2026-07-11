{-# LANGUAGE OverloadedStrings #-}
-- | The capability-scoping compile-fail fixture (spec §8 line 226-228).
-- A 'TrustedOpcode' that tries to reference an 'ExecBackend' (i.e. shells
-- out) must FAIL TO COMPILE: the GADT 'TrustedOpcode' has no 'uoRun'
-- field, and no 'ExecBackend' is in scope in 'toRun' (its signature is
-- @BackendExec -> Value -> App OpResult@). This test asserts that
-- guarantee by feeding the compiler a source string that attempts it and
-- asserting the failure.
module Seal.Tools.Exec.CapabilityScopingFailSpec (spec) where

import Test.Hspec
import Test.QuickCheck ()  -- instances

import Seal.TestHelpers.CompileFail

spec :: Spec
spec = describe "Capability scoping (spec §8 compile-fail fixture)" $ do

  it "a Trusted opcode whose toRun tries to use an ExecBackend fails to compile" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.ISA.Opcode"
          , "import Seal.Tools.Exec.Types (ExecBackend)"
          , "import Data.Aeson (Value (..))"
          , "bad :: Opcode"
          , "bad = TrustedOpcode"
          , "  { toName = \"X\""
          , "  , toTrust = Trusted"
          , "  , toDesc = \"\""
          , "  , toInSchema = Null"
          , "  , toOutSchema = Null"
          , "  , toAuthorize = const (Right ())"
          , "  , toRun = \\backend v -> case backend of"
          , "      _ -> error \"this opcode tries to use an ExecBackend\""
          , "  }"
          ]
        -- The expected error: 'TrustedOpcode' doesn't have a 'toRun' that
        -- can pattern-match on an 'ExecBackend' (it only gets a
        -- 'BackendExec'). The mismatch surfaces as a type error.
    assertCompileFail "trusted_shells_out" "Couldn't match" src