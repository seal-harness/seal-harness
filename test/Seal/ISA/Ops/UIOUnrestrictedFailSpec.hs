{-# LANGUAGE OverloadedStrings #-}
-- | W-A2 compile-fail fixture: an opcode body typed 'UIO OpResult' that
-- calls 'liftIO'\/'ask'\/'throwM' fails to compile (no 'MonadIO'\/
-- 'MonadReader'\/'MonadThrow' instance). Mirrors the
-- 'CapabilityScopingFailSpec' pattern (build-source-string +
-- 'assertCompileFail').
module Seal.ISA.Ops.UIOUnrestrictedFailSpec (spec) where

import Test.Hspec

import Seal.TestHelpers.CompileFail

spec :: Spec
spec = describe "UIO restriction (W-A2 compile-fail fixture)" $ do

  it "a UIO body that calls liftIO fails to compile (no MonadIO instance)" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Control.Monad.IO.Class (liftIO)"
          , "import Seal.Tools.Exec.UIO"
          , "bad :: UIO ()"
          , "bad = liftIO (putStrLn \"escaped\")"
          ]
    assertCompileFail "uio_liftIO" "No instance for" src

  it "a UIO body that calls ask fails to compile (no MonadReader instance)" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Control.Monad.Reader (ask)"
          , "import Seal.Tools.Exec.UIO"
          , "import Seal.Tools.Exec.UIO.Internal (UIOEnv(..))"
          , "bad :: UIO ()"
          , "bad = do"
          , "  _env <- ask"
          , "  pure ()"
          ]
    assertCompileFail "uio_ask" "No instance for" src