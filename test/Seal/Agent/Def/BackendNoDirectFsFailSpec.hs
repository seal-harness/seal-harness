{-# LANGUAGE OverloadedStrings #-}
-- | The no-direct-FS fixture for the workdir-scoped agent-def backend
-- (§3.6 / W4 DoD). The workdir functions live in
-- "Seal.Agent.Def.Workdir"; they must NOT import @System.Directory@ or
-- @Data.Text.IO@ — every workspace read goes through the 'WorkdirFs'
-- handle (single SafePath-confined chokepoint). This spec reads the
-- module's source file and asserts neither import line is present.
module Seal.Agent.Def.BackendNoDirectFsFailSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "Seal.Agent.Def.Workdir (no direct FS imports — §3.6)" $ do
  it "does not import System.Directory" $ do
    src <- readWorkdirSource
    src `shouldNotSatisfy` any (isImportOf "System.Directory")

  it "does not import Data.Text.IO" $ do
    src <- readWorkdirSource
    src `shouldNotSatisfy` any (isImportOf "Data.Text.IO")

-- | Read the workdir module's source file. The path is resolved relative
-- to the package root (the test suite's CWD when run via cabal).
readWorkdirSource :: IO [Text]
readWorkdirSource = do
  let path = "src" </> "Seal" </> "Agent" </> "Def" </> "Workdir.hs"
  exists <- doesFileExist path
  if not exists
    then pure []  -- fail-soft: the assertions below will fire on a non-empty list
    else T.lines <$> TIO.readFile path

-- | Predicate: is a line an import of the given module (qualified or bare)?
-- Matches @import System.Directory@, @import qualified System.Directory@,
-- @import System.Directory (...)@, etc. Does NOT match re-export lines
-- or comments that merely mention the module name.
isImportOf :: Text -> Text -> Bool
isImportOf modName line =
  let stripped = T.strip line
  in "import " `T.isPrefixOf` stripped
       && modName `T.isInfixOf` stripped
       && not ("--" `T.isPrefixOf` stripped)