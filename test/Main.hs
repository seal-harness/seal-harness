module Main (main) where

import Test.Hspec

import qualified Seal.ConfigSpec
import qualified Seal.Security.CryptoSpec
import qualified Seal.Security.SecretsSpec
import qualified Seal.Security.Vault.AgeSpec

main :: IO ()
main = hspec $ do
  Seal.ConfigSpec.spec
  Seal.Security.CryptoSpec.spec
  Seal.Security.SecretsSpec.spec
  Seal.Security.Vault.AgeSpec.spec
