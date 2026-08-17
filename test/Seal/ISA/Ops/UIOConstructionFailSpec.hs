{-# LANGUAGE OverloadedStrings #-}
-- | W-A2 compile-fail fixture: a module that tries to construct 'UIO' or
-- 'UIOEnv' directly (without the smart constructors) fails to compile
-- (constructor + 'unUIO' + 'UIOEnv' not exported from
-- 'Seal.Tools.Exec.UIO'). Mirrors the 'CapabilityScopingFailSpec' pattern.
module Seal.ISA.Ops.UIOConstructionFailSpec (spec) where

import Test.Hspec

import Seal.TestHelpers.CompileFail

spec :: Spec
spec = describe "UIO construction (W-A2 compile-fail fixture)" $ do

  it "constructing UIO directly fails (constructor not exported from UIO)" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Tools.Exec.UIO"
          , "bad :: UIO ()"
          , "bad = UIO (pure ())"
          ]
    assertCompileFail "uio_construct" "Not in scope: data constructor" src

  it "accessing unUIO fails (not exported from UIO)" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Tools.Exec.UIO"
          , "bad :: IO ()"
          , "bad = unUIO (pure ())"
          ]
    assertCompileFail "uio_unUIO" "Not in scope" src

  it "constructing UIOEnv directly fails (not exported from UIO)" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Tools.Exec.UIO"
          , "import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)"
          , "import Seal.SourceControl.Clone (CloneDeps)"
          , "bad :: IO ()"
          , "bad = pure ()"
          , "  where"
          , "    _env = UIOEnv mkRemoteUntrustedIOStub (undefined :: CloneDeps)"
          ]
    assertCompileFail "uio_env_construct" "Not in scope" src