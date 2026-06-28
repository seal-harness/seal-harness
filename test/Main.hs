module Main (main) where

import Test.Hspec

import qualified Seal.ConfigSpec
import qualified Seal.Security.SecretsSpec

main :: IO ()
main = hspec $ do
  Seal.ConfigSpec.spec
  Seal.Security.SecretsSpec.spec
