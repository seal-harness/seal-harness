{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The build-configuration guards for @-f remote-only-untrusted@ (WU-16).
--
-- Done-when 15 says @make check@ passes /including@ the hardened flag, and the
-- frozen requirement behind it is stronger than "it compiles": *"the
-- @-f remote-only-untrusted@ build still physically cannot run one locally"*.
-- Two separate things make that true, and this module asserts both, because
-- each has silently regressed once:
--
--   1. __The gate on the local wiring path.__ 'enforceRemoteOnly' refuses
--      @allow_localhost = true@ at boot, and 'Seal.Session.Workdir.mkLocalExec'
--      fail-closes under the flag so no wiring site can route around it. Both
--      have call sites; before this feature the check had none at all.
--
--   2. __The artifact boundary.__ The flag drops @Seal.Tools.Exec.Local@ from
--      @exposed-modules@, so any module that still imports it makes the
--      hardened build fail to link — which is what happened: @Remote.hs@,
--      @AgentMetaCache.hs@ and @UntrustedIO.hs@ each pulled in
--      @mkLocalExecHandle@ (through @Seal.Tools.Exec.Proc@, which every arm
--      needs for process-group killing and bounded reads) and the whole
--      library linked against a module that was not built.
--
-- The second is the interesting one and is why this spec exists. A test cannot
-- run the linker, so it asserts the /cause/: nothing outside the local arm may
-- import the module the flag removes. That is checkable in-process, and it is
-- the property that actually broke.
--
-- A real build with the flag is not asserted here — it cannot be, from inside
-- the unhardened test suite — and lives as a gate step instead (see the
-- @hardened@ Makefile target and the WU-16 note in the plan). This spec is the
-- guard that keeps that gate from failing for a reason nobody can see until
-- the last step of CI.
module Seal.Tools.Exec.HardenedBuildSpec (spec) where

import Control.Exception (IOException, catch)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec

import Seal.Config.Security
  ( SecurityConfig, defaultSecurityConfig, untrustedExecConfigFromSecurity )
import Seal.Tools.Exec.Untrusted
  ( UntrustedExecConfig (..), enforceRemoteOnly )

spec :: Spec
spec = describe "the hardened build (-f remote-only-untrusted)" $ do

  describe "the boot gate on the local wiring path" $ do
    it "the gate is CPP-gated to the hardened build, not run unconditionally" $ do
      -- A REGRESSION I introduced and CI caught. `enforceRemoteOnly` refuses
      -- `allow_localhost = true`, and the shipped `security.toml` leaves
      -- `[untrusted_execution]` absent — which defaults to `true`. Calling the
      -- check unconditionally therefore refused to start on EVERY FRESH
      -- INSTALL of a DEFAULT build, which has the local executor and honours
      -- the flag perfectly well.
      --
      -- Asserted at the CALL SITES, because that is where the gating lives. A
      -- pure-function test of `enforceRemoteOnly` cannot see this: the function
      -- was always correct, and calling it in the wrong build was the bug.
      serve <- readSrc "src/Seal/Command/Serve.hs"
      cli <- readSrc "src/Seal/Channel/Cli.hs"
      gatedIn "src/Seal/Command/Serve.hs" serve `shouldBe` True
      gatedIn "src/Seal/Channel/Cli.hs" cli `shouldBe` True

    it "refuses the absent-section default, which is allow_localhost = true" $ do
      -- Done-when 3 says an install with no [untrusted_execution] gets
      -- allow_localhost = true; a hardened binary must therefore refuse to
      -- start on such an install rather than start and fail every local call.
      -- This is the state the old Maybe-collapsed input could not express.
      let cfg = untrustedExecConfigFromSecurity' defaultSecurityConfig
      enforceRemoteOnly cfg `shouldSatisfy` \case
        Left _  -> True
        Right _ -> False

    it "accepts allow_localhost = false" $
      enforceRemoteOnly (UntrustedExecConfig False) `shouldBe` Right ()

    it "rejects allow_localhost = true" $
      enforceRemoteOnly (UntrustedExecConfig True) `shouldSatisfy` \case
        Left _  -> True
        Right _ -> False

    it "mkLocalExec fail-closes under the flag instead of building a handle" $ do
      -- The single local construction point. If this arm ever builds a handle
      -- under the flag, the gate is decorative: some wiring site will reach it.
      src <- readSrc "src/Seal/Session/Workdir.hs"
      T.isInfixOf "#if defined(REMOTE_ONLY_UNTRUSTED)\nmkLocalExec _ cloneDeps ="
        src
        `shouldBe` True

    it "no boot path can skip the gate: both call enforceRemoteOnly" $ do
      serve <- readSrc "src/Seal/Command/Serve.hs"
      cli <- readSrc "src/Seal/Channel/Cli.hs"
      T.isInfixOf "enforceRemoteOnly" serve `shouldBe` True
      T.isInfixOf "enforceRemoteOnly" cli `shouldBe` True

  describe "the artifact boundary the flag creates" $ do
    it "only the local arm imports Seal.Tools.Exec.Local" $ do
      -- The regression. `Seal.Tools.Exec.Local` is removed from
      -- exposed-modules under the flag, so every other importer is an
      -- undefined symbol at link time. Process helpers both arms need
      -- (process-group killing, bounded reads) live in Seal.Tools.Exec.Proc,
      -- which the flag does NOT remove.
      offenders <- filterM importsRemovedModule =<< collectHsFiles "src"
      offenders `shouldBe` []

    it "the shared process helpers live in a module the flag keeps" $ do
      -- Named, so the fix cannot be "move the helpers back later": the
      -- hardened build is what depends on this module surviving the flag.
      exists <- doesFileExist "src/Seal/Tools/Exec/Proc.hs"
      exists `shouldBe` True

    it "Seal.Tools.Exec.Local is the ONLY executor module the flag omits" $ do
      cabal <- readSrc "seal-harness.cabal"
      let omitted = omittedExecutorModules cabal
      omitted `shouldBe` ["Seal.Tools.Exec.Local"]

    it "LocalSpec is CPP-gated, so the hardened suite does not import a removed module" $ do
      src <- readSrc "test/Seal/Tools/Exec/LocalSpec.hs"
      T.isInfixOf "REMOTE_ONLY_UNTRUSTED" src `shouldBe` True

  describe "the gate is a real Makefile/CI step, not just a doc claim" $ do
    it "the Makefile has a hardened target that builds AND tests with the flag" $ do
      mk <- readSrc "Makefile"
      -- Both a build and a test, on the same flag: building proves it links,
      -- testing proves the suite still passes without the local executor.
      let commands = [ T.unwords (T.words ln)
                     | ln <- T.lines mk
                     , "remote-only-untrusted" `T.isInfixOf` ln ]
      any (T.isInfixOf "cabal build") commands `shouldBe` True
      any (T.isInfixOf "cabal test") commands `shouldBe` True

    it "CI runs the hardened gate" $ do
      ci <- readSrc ".github/workflows/ci.yml"
      gate <- readSrc ".github/workflows/gate.yml"
      let ran = any (T.isInfixOf "remote-only-untrusted") [ci, gate]
      ran `shouldBe` True

-- | Alias kept so the assertion below reads as a sentence rather than a
-- module-qualified call.
untrustedExecConfigFromSecurity'
  :: SecurityConfig -> UntrustedExecConfig
untrustedExecConfigFromSecurity' = untrustedExecConfigFromSecurity

-- | Read a source file as Text, fail-soft to @""@ when absent (cabal's build
-- dir has no @src/@ tree; CI runs from the package root, where the assertions
-- are live).
readSrc :: FilePath -> IO Text
readSrc path = do
  exists <- doesFileExist path
  if not exists
    then pure ""
    else TIO.readFile path `catch` \(_ :: IOException) -> pure ""

-- | Every @.hs@ file under a directory, recursively.
collectHsFiles :: FilePath -> IO [FilePath]
collectHsFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir `catch` \(_ :: IOException) -> pure []
      concat <$> mapM visit entries
  where
    visit e = do
      let path = dir </> e
      isDir <- doesDirectoryExist path
      if isDir
        then collectHsFiles path
        else pure [ path | ".hs" `isSuffixOf` e ]

-- | Does this module import @Seal.Tools.Exec.Local@?
--
-- The local arm itself is excluded: it IS the module. The test suite is not
-- walked (its specs sit outside @src@), and @LocalSpec@ is gated separately.
importsRemovedModule :: FilePath -> IO Bool
importsRemovedModule path
  | "Seal/Tools/Exec/Local.hs" `isSuffixOf` path = pure False
  | otherwise = do
      src <- readSrc path
      pure (any lineImports (T.lines src))
  where
    lineImports line =
      let s = T.strip line
          needle = "import Seal.Tools.Exec.Local"
          needleQ = "import qualified Seal.Tools.Exec.Local"
          -- Must be the module itself, not a longer sibling such as
          -- Seal.Tools.Exec.LocalFoo: the character after the name must not
          -- be an identifier character.
          bare p = p `isPrefixOf` T.unpack s
                   && case drop (length p) (T.unpack s) of
                        (c : _) -> not (isIdentChar c)
                        []      -> True
      in bare needle || bare needleQ
    isIdentChar c = c `elem` ("_.'" :: String)
                    || isAsciiLower c || isAsciiUpper c
                    || isDigit c

-- | The modules listed under a @if !flag(remote-only-untrusted)@
-- @exposed-modules:@ block. Read textually, because that is the shape the
-- .cabal file has and the point is that exactly one module is omitted.
omittedExecutorModules :: Text -> [Text]
omittedExecutorModules cabal =
  case dropWhile (not . T.isInfixOf "if !flag(remote-only-untrusted)")
                 (T.lines cabal) of
    [] -> []
    (_ : rest) ->
      -- Only the @exposed-modules:@ block, which is where the flag omits a
      -- module. The same clause also carries cpp-options/ghc-options and
      -- build-depends; a build-depends entry is not an executor.
      let block = takeWhile bodyLine rest
      in [ T.strip ln
         | ln <- drop 1 (dropWhile (not . isExposedHeader) block)
         , let s = T.strip ln, not (T.null s), not ("--" `T.isPrefixOf` s) ]
  where
    isExposedHeader ln = "exposed-modules:" `T.isPrefixOf` T.strip ln
    -- A stanza body line is indented (or blank); the next @if@ at the stanza's
    -- own indentation ends it.
    bodyLine ln =
      let s = T.strip ln
      in (T.null s || " " `T.isPrefixOf` ln || "\t" `T.isPrefixOf` ln)
         && not ("if " `T.isPrefixOf` s)

-- | A small filterM helper (avoids importing Control.Monad for one combinator).
-- | Does @path@ contain an @enforceRemoteOnly@ call inside a
-- @#if defined(REMOTE_ONLY_UNTRUSTED)@ block?
--
-- Textual, because the property IS the CPP structure: the gate has no runtime
-- representation to assert against. A call outside such a block is the bug.
gatedIn :: FilePath -> T.Text -> Bool
gatedIn _path src = go (T.lines src) False False
  where
    go [] _ _ = True   -- never saw an ungated call
    go (ln : rest) inFlag seen
      | "#if defined(REMOTE_ONLY_UNTRUSTED)" `T.isInfixOf` ln = go rest True seen
      | "#endif" `T.isPrefixOf` T.strip ln                     = go rest False seen
      | "enforceRemoteOnly" `T.isInfixOf` ln && not inFlag     = False
      | "enforceRemoteOnly" `T.isInfixOf` ln                   = go rest inFlag True
      | otherwise                                              = go rest inFlag seen

filterM :: (a -> IO Bool) -> [a] -> IO [a]
filterM _ [] = pure []
filterM p (x:xs) = do
  keep <- p x
  rest <- filterM p xs
  pure (if keep then x : rest else rest)
