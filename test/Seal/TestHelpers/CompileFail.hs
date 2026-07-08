{-# LANGUAGE OverloadedStrings #-}
-- | A test helper that asserts a Haskell source string FAILS to compile
-- with an expected error substring. Used by the capability-scoping
-- compile-fail fixture (spec §8 line 226-228): a Trusted opcode that
-- tries to use an 'ExecBackend' must fail to type-check (it has no
-- 'ExecBackend' in scope — the GADT 'TrustedOpcode' has no 'uoRun' field).
module Seal.TestHelpers.CompileFail
  ( assertCompileFail
  ) where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- | @assertCompileFail label expectedErr src@ writes @src@ to a temp
-- file, invokes @ghc -fno-code -e <src>@ (or @ghc -c@), and asserts the
-- compilation FAILS and the stderr contains @expectedErr@. Raises a
-- hspec 'pendingWith' (not a hard failure) if @ghc@ is not on PATH, so
-- the test is skipped in environments without GHC (CI without the
-- compiler on PATH — though the Nix dev shell always has it).
assertCompileFail :: String -> Text -> String -> IO ()
assertCompileFail label expectedErr src =
  withSystemTempDirectory ("seal-cf-" <> label) $ \dir -> do
    let path = dir </> "Probe.hs"
    writeFile path src
    ghcRes <- try @IOError (readProcessWithExitCode "ghc" ["-fno-code", "-i" <> dir, path] "")
    case ghcRes of
      Left _ -> error "assertCompileFail: ghc not on PATH (unexpected in the Nix dev shell)"
      Right (ec, _out, err) ->
        case ec of
          ExitSuccess -> error ("assertCompileFail: " <> label <> " compiled but should have failed")
          ExitFailure _ -> case T.breakOn expectedErr (T.pack err) of
            (T.Empty, _) -> error ("assertCompileFail: " <> label <> " failed but stderr did not contain: " <> show expectedErr <> "\nstderr:\n" <> err)
            _ -> pure ()