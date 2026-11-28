{-# LANGUAGE OverloadedStrings #-}
-- | The capability-scoping CI grep guard for 'WorkdirFs' / 'UIOEnv' (W6 DoD).
--
-- Mirrors the 'CapabilityScopingFail' compile-fail discipline, but for the
-- structural invariant that 'WorkdirFs' and 'UIOEnv' are NEVER reachable
-- from an opcode body. The 'WorkdirFs' handle (and the 'UIOEnv' record) are
-- capability-seam types: they live in 'SessionExec' (consumed at the
-- turn-entry wiring site) and in 'AgentEnv'/'dispatch' (which thread
-- 'UIOEnv' to the dispatcher), but they MUST NOT appear as fields of the
-- application environment ('Env' / AppEnv), the ISA registry, or any
-- opcode implementation module under @src/Seal/ISA/Ops/@.
--
-- This is a source-grep test: it reads the relevant source files and
-- asserts the absence of the forbidden imports / field declarations. If a
-- future change adds @wfs :: WorkdirFs@ to 'Env', or an opcode imports
-- 'Seal.Tools.Exec.WorkdirFs' / 'Seal.Tools.Exec.UIO.Internal', this test
-- fails — surfacing the regression before it ships.
module Seal.CapabilityScopingWorkdirFsFailSpec (spec) where

import Control.Exception (IOException, catch)
import Data.Either (isLeft)
import System.FilePath ((</>))
import Seal.Security.Path (WorkspaceRoot (..), mkSafePath)
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Capability scoping — WorkdirFs/UIOEnv grep guard (W6 DoD)" $ do

  it "Env (AppEnv) has no WorkdirFs field" $ do
    src <- readSrc "src/Seal/Types/Env.hs"
    hasFieldType src "WorkdirFs" `shouldBe` False

  it "Env (AppEnv) has no UIOEnv field" $ do
    src <- readSrc "src/Seal/Types/Env.hs"
    hasFieldType src "UIOEnv" `shouldBe` False

  it "ISA Registry has no WorkdirFs field" $ do
    src <- readSrc "src/Seal/ISA/Registry.hs"
    hasFieldType src "WorkdirFs" `shouldBe` False

  it "ISA Registry has no UIOEnv field" $ do
    src <- readSrc "src/Seal/ISA/Registry.hs"
    hasFieldType src "UIOEnv" `shouldBe` False

  it "no module under src/Seal/ISA/Ops/ imports Seal.Tools.Exec.WorkdirFs" $ do
    offenders <- collectOpModules
    bad <- filterM (moduleImports "Seal.Tools.Exec.WorkdirFs") offenders
    bad `shouldBe` []

  it "no module under src/Seal/ISA/Ops/ imports Seal.Tools.Exec.UIO.Internal" $ do
    offenders <- collectOpModules
    bad <- filterM (moduleImports "Seal.Tools.Exec.UIO.Internal") offenders
    bad `shouldBe` []

  it "no module under src/Seal/ISA/Ops/ declares a WorkdirFs field" $ do
    offenders <- collectOpModules
    bad <- filterM (\f -> hasFieldType <$> readSrc f <*> pure "WorkdirFs") offenders
    bad `shouldBe` []

  it "no module under src/Seal/ISA/Ops/ declares a UIOEnv field" $ do
    offenders <- collectOpModules
    bad <- filterM (\f -> hasFieldType <$> readSrc f <*> pure "UIOEnv") offenders
    bad `shouldBe` []

  -- -----------------------------------------------------------------------
  -- WU-14: the ~/.seal agent-immutability guard, extended to the machines
  -- feature's files. Rule 3: ~/.seal holds security-critical, agent-immutable
  -- state. 'blockedNames' already covers ".seal", so mkSafePath refuses these
  -- paths — these assertions pin that the NEW files inherit that refusal, and
  -- that no opcode module can reach the config machinery that reads them.
  -- -----------------------------------------------------------------------

  it "mkSafePath refuses ~/.seal/machines.toml" $ do
    -- A relative path whose segment list contains .seal is blocked before any
    -- filesystem access, so this is deterministic and needs no fixture file.
    res <- mkSafePath (WorkspaceRoot "/tmp/ws") ".seal/machines.toml"
    res `shouldSatisfy` isLeft

  it "mkSafePath refuses ~/.seal/exec-known-hosts" $ do
    res <- mkSafePath (WorkspaceRoot "/tmp/ws") ".seal/exec-known-hosts"
    res `shouldSatisfy` isLeft

  it "mkSafePath refuses an ABSOLUTE path into ~/.seal" $ do
    -- The AllowAbs variants canonicalise; the blocked-name check runs on the
    -- requested segments first, so an absolute spelling is refused too.
    res <- mkSafePath (WorkspaceRoot "/tmp/ws") "/home/someone/.seal/machines.toml"
    res `shouldSatisfy` isLeft

  it "no module under src/Seal/ISA/Ops/ imports Seal.Config.Machines" $ do
    offenders <- collectOpModules
    bad <- filterM (moduleImports "Seal.Config.Machines") offenders
    bad `shouldBe` []

  it "no module under src/Seal/ISA/Ops/ imports Seal.Config.Security" $ do
    offenders <- collectOpModules
    bad <- filterM (moduleImports "Seal.Config.Security") offenders
    bad `shouldBe` []

-- | Read a source file as Text. Fail-soft to @""@ when the file is absent
-- (mirroring 'Seal.Agent.Def.BackendNoDirectFsFailSpec.readWorkdirSource'):
-- the assertions below fire on a non-empty source, so a missing file yields
-- vacuous passes — which is the desired behaviour when the test CWD
-- (cabal's build dir) doesn't contain the @src/@ tree. CI runs from the
-- package root, where the files are present and the assertions are live.
readSrc :: FilePath -> IO Text
readSrc path = do
  exists <- doesFileExist path
  if not exists
    then pure ""
    else TIO.readFile path `catch` \(_ :: IOException) -> pure ""

-- | Does the source contain a record-field type annotation of the form
-- @:: <typeName>@ (allowing an optional leading @!@ strictness marker)?
-- This matches field declarations like
--
-- > , envFoo :: WorkdirFs
-- > , envBar :: !WorkdirFs
--
-- but NOT comments that merely mention the word @WorkdirFs@ without the
-- @:: @ prefix.
hasFieldType :: Text -> String -> Bool
hasFieldType src typeName =
  let needle = T.pack (":: " ++ typeName)
      needleStrict = T.pack (":: !" ++ typeName)
  in any (`T.isInfixOf` src) [needle, needleStrict]

-- | Does the module at @path@ import @modName@ (a whole-module import line
-- like @import Seal.Tools.Exec.WorkdirFs@ or
-- @import qualified Seal.Tools.Exec.WorkdirFs@)? Matches an @import@ line
-- whose module path starts with the given module name.
moduleImports :: Text -> FilePath -> IO Bool
moduleImports modName path = do
  src <- readSrc path
  pure (any lineImports (T.lines src))
  where
    lineImports line =
      let s = T.strip line
      in T.pack ("import " ++ T.unpack modName) `T.isPrefixOf` s
         || T.pack ("import qualified " ++ T.unpack modName) `T.isPrefixOf` s

-- | List all @.hs@ files under @src/Seal/ISA/Ops/@. Fail-soft to @[]@ when
-- the directory is absent (mirroring 'readSrc').
collectOpModules :: IO [FilePath]
collectOpModules = do
  let dir = "src/Seal/ISA/Ops"
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir `catch` \(_ :: IOException) -> pure []
      pure [ dir </> e | e <- entries, ".hs" `isSuffixOf` e ]

-- | A small filterM helper (avoids importing Control.Monad for one combinator).
filterM :: (a -> IO Bool) -> [a] -> IO [a]
filterM _ [] = pure []
filterM p (x:xs) = do
  keep <- p x
  rest <- filterM p xs
  pure (if keep then x : rest else rest)
