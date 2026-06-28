module Main (main) where

import Test.Hspec

import qualified Seal.ConfigSpec

main :: IO ()
main = hspec Seal.ConfigSpec.spec