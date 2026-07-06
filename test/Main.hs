module Main (main) where

import Test.Hspec

import qualified Seal.Core.ChannelKindSpec
import qualified Seal.Core.TypesSpec
import qualified Seal.Core.PagingSpec
import qualified Seal.AppMainSpec
import qualified Seal.Session.MetaSpec
import qualified Seal.Session.StoreSpec
import qualified Seal.Text.LineFileSpec
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
import qualified Seal.Command.ModelSpec
import qualified Seal.Command.ParseSpec
import qualified Seal.Command.ProviderSpec
import qualified Seal.Command.SessionSpec
import qualified Seal.Command.SkillSpec
import qualified Seal.Command.AgentSpec
import qualified Seal.Command.SpecSpec
import qualified Seal.Config.FileSpec
import qualified Seal.Vault.BackendSpec
import qualified Seal.Vault.CommandsSpec
import qualified Seal.IngestSpec
import qualified Seal.Channel.CliSpec
import qualified Seal.Channel.WiringSpec
import qualified Seal.Transcript.TypesSpec
import qualified Seal.Transcript.ConvSpec
import qualified Seal.Transcript.EntriesSpec
import qualified Seal.Transcript.ReconstructSpec
import qualified Seal.Handles.TranscriptSpec
import qualified Seal.Memory.TypesSpec
import qualified Seal.Memory.BackendSpec
import qualified Seal.Skills.TypesSpec
import qualified Seal.Skills.BackendSpec
import qualified Seal.Agent.Def.TypesSpec
import qualified Seal.Agent.Def.BackendSpec
import qualified Seal.Agent.Runtime.RegistrySpec
import qualified Seal.ISA.Ops.MemorySpec
import qualified Seal.ISA.Ops.SkillsSpec
import qualified Seal.ISA.Ops.AgentSpec
import qualified Seal.Phase5Spec
import qualified Seal.Providers.AnthropicSpec
import qualified Seal.Providers.Anthropic.OAuthSpec
import qualified Seal.Providers.ClassSpec
import qualified Seal.Providers.OllamaSpec
import qualified Seal.Providers.RegistrySpec
import qualified Seal.Agent.LoopSpec
import qualified Seal.ISA.DispatchSpec
import qualified Seal.ISA.Ops.HumanSpec
import qualified Seal.ISA.Ops.FileSpec
import qualified Seal.ISA.Ops.SecretSpec
import qualified Seal.ISA.RegistrySpec

main :: IO ()
main = hspec $ do
  Seal.Core.ChannelKindSpec.spec
  Seal.Core.TypesSpec.spec
  Seal.Core.PagingSpec.spec
  Seal.AppMainSpec.spec
  Seal.Session.MetaSpec.spec
  Seal.Session.StoreSpec.spec
  Seal.Text.LineFileSpec.spec
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
  Seal.Command.ModelSpec.spec
  Seal.Command.ParseSpec.spec
  Seal.Command.ProviderSpec.spec
  Seal.Command.SessionSpec.spec
  Seal.Command.SkillSpec.spec
  Seal.Command.AgentSpec.spec
  Seal.Command.SpecSpec.spec
  Seal.Config.FileSpec.spec
  Seal.Vault.BackendSpec.spec
  Seal.Vault.CommandsSpec.spec
  Seal.IngestSpec.spec
  Seal.Channel.CliSpec.spec
  Seal.Channel.WiringSpec.spec
  Seal.Transcript.TypesSpec.spec
  Seal.Transcript.ConvSpec.spec
  Seal.Transcript.EntriesSpec.spec
  Seal.Transcript.ReconstructSpec.spec
  Seal.Handles.TranscriptSpec.spec
  Seal.Memory.TypesSpec.spec
  Seal.Memory.BackendSpec.spec
  Seal.Skills.TypesSpec.spec
  Seal.Skills.BackendSpec.spec
  Seal.Agent.Def.TypesSpec.spec
  Seal.Agent.Def.BackendSpec.spec
  Seal.Agent.Runtime.RegistrySpec.spec
  Seal.ISA.Ops.MemorySpec.spec
  Seal.ISA.Ops.SkillsSpec.spec
  Seal.ISA.Ops.AgentSpec.spec
  Seal.Phase5Spec.spec
  Seal.Providers.AnthropicSpec.spec
  Seal.Providers.Anthropic.OAuthSpec.spec
  Seal.Providers.ClassSpec.spec
  Seal.Providers.OllamaSpec.spec
  Seal.Providers.RegistrySpec.spec
  Seal.Agent.LoopSpec.spec
  Seal.ISA.DispatchSpec.spec
  Seal.ISA.Ops.HumanSpec.spec
  Seal.ISA.Ops.FileSpec.spec
  Seal.ISA.Ops.SecretSpec.spec
  Seal.ISA.RegistrySpec.spec
