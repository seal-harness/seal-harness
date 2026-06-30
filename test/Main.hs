module Main (main) where

import Test.Hspec

import qualified Seal.Core.TypesSpec
import qualified Seal.AppMainSpec
import qualified Seal.ConfigSpec
import qualified Seal.Config.PathsSpec
import qualified Seal.Security.CryptoSpec
import qualified Seal.Security.PathSpec
import qualified Seal.Security.SecretsSpec
import qualified Seal.Security.Vault.AgeSpec
import qualified Seal.Security.VaultSpec
import qualified Seal.Security.PolicySpec
import qualified Seal.Security.CommandSpec
import qualified Seal.Command.HelpSpec
import qualified Seal.Command.ParseSpec
import qualified Seal.Command.SpecSpec
import qualified Seal.Config.FileSpec
import qualified Seal.Vault.BackendSpec
import qualified Seal.Vault.CommandsSpec
import qualified Seal.IngestSpec
import qualified Seal.Channel.CliSpec
import qualified Seal.Transcript.TypesSpec
import qualified Seal.Handles.TranscriptSpec

main :: IO ()
main = hspec $ do
  Seal.Core.TypesSpec.spec
  Seal.AppMainSpec.spec
  Seal.ConfigSpec.spec
  Seal.Config.PathsSpec.spec
  Seal.Security.CryptoSpec.spec
  Seal.Security.PathSpec.spec
  Seal.Security.SecretsSpec.spec
  Seal.Security.Vault.AgeSpec.spec
  Seal.Security.VaultSpec.spec
  Seal.Security.PolicySpec.spec
  Seal.Security.CommandSpec.spec
  Seal.Command.HelpSpec.spec
  Seal.Command.ParseSpec.spec
  Seal.Command.SpecSpec.spec
  Seal.Config.FileSpec.spec
  Seal.Vault.BackendSpec.spec
  Seal.Vault.CommandsSpec.spec
  Seal.IngestSpec.spec
  Seal.Channel.CliSpec.spec
  Seal.Transcript.TypesSpec.spec
  Seal.Handles.TranscriptSpec.spec
