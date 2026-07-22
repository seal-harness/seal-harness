module Main (main) where

import Test.Hspec

import qualified Seal.Core.ChannelKindSpec
import qualified Seal.Core.MessageSourceSpec
import qualified Seal.Core.AllowListSpec
import qualified Seal.Core.TypesSpec
import qualified Seal.Core.PagingSpec
import qualified Seal.Gateway.ConfigSpec
import qualified Seal.Gateway.ApiSpec
import qualified Seal.Gateway.ServerSpec
import qualified Seal.Gateway.StreamBrokerSpec
import qualified Seal.Gateway.StreamSpec
import qualified Seal.Gateway.TranscriptSpec
import qualified Seal.AppMainSpec
import qualified Seal.Session.MetaSpec
import qualified Seal.Session.StoreSpec
import qualified Seal.Text.LineFileSpec
import qualified Seal.Tools.Exec.TypesSpec
import qualified Seal.Tools.Exec.UntrustedSpec
import qualified Seal.Tools.Exec.LocalSpec
import qualified Seal.Tools.Exec.RemoteSpec
import qualified Seal.Tools.ArgsSpec
import qualified Seal.Tools.Exec.CapabilityScopingFailSpec
import qualified Seal.Web.SearchSpec
import qualified Seal.Web.FetchSpec
import qualified Seal.Web.BrowserSpec
import qualified Seal.Media.ImageSpec
import qualified Seal.Media.TtsSpec
import qualified Seal.ConfigSpec
import qualified Seal.Config.PathsSpec
import qualified Seal.Security.CryptoSpec
import qualified Seal.Security.PathSpec
import qualified Seal.Security.SecretsSpec
import qualified Seal.Security.Vault.AgeSpec
import qualified Seal.Security.VaultSpec
import qualified Seal.Security.PolicySpec
import qualified Seal.Security.CommandSpec
import qualified Seal.Security.AdoptionSpec
import qualified Seal.Command.HelpSpec
import qualified Seal.Command.ModelSpec
import qualified Seal.Command.ParseSpec
import qualified Seal.Command.ProviderSpec
import qualified Seal.Command.SessionSpec
import qualified Seal.Command.ServeSpec
import qualified Seal.Command.SkillSpec
import qualified Seal.Command.AgentSpec
import qualified Seal.Command.BackgroundSpec
import qualified Seal.Command.CallSpec
import qualified Seal.Command.ChannelSpec
import qualified Seal.Command.SpecSpec
import qualified Seal.Command.TabSpec
import qualified Seal.Command.NewSpec
import qualified Seal.Config.FileSpec
import qualified Seal.Config.MigrateSpec
import qualified Seal.Config.SecuritySpec
import qualified Seal.Config.SecurityScopingFailSpec
import qualified Seal.Vault.BackendSpec
import qualified Seal.Vault.CommandsSpec
import qualified Seal.IngestSpec
import qualified Seal.Channel.CliSpec
import qualified Seal.Channel.WiringSpec
import qualified Seal.Channels.ClassSpec
import qualified Seal.Channels.LoopSpec
import qualified Seal.Channels.SignalSpec
import qualified Seal.Channels.Signal.EnvelopeSpec
import qualified Seal.Channels.Signal.RunSpec
import qualified Seal.Channels.Signal.TransportSpec
import qualified Seal.Channels.TelegramSpec
import qualified Seal.Channels.Telegram.CommandsSpec
import qualified Seal.Channels.Telegram.TransportSpec
import qualified Seal.Transcript.TypesSpec
import qualified Seal.Transcript.ConvSpec
import qualified Seal.Transcript.EntriesSpec
import qualified Seal.Transcript.ReconstructSpec
import qualified Seal.Handles.AskReplySpec
import qualified Seal.Handles.ChannelSpec
import qualified Seal.Handles.HarnessSpec
import qualified Seal.Handles.TabSpec
import qualified Seal.Handles.TranscriptSpec
import qualified Seal.Harness.IdSpec
import qualified Seal.Harness.RegistrySpec
import qualified Seal.Harness.ReconcileSpec
import qualified Seal.Harness.TmuxSpec
import qualified Seal.Harness.TmuxIOSpec
import qualified Seal.Harness.DiscoverySpec
import qualified Seal.Tabs.TypesSpec
import qualified Seal.TabsSpec
import qualified Seal.Tabs.RelaySpec
import qualified Seal.Tabs.WizardSpec
import qualified Seal.Routing.RouteSpec
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
import qualified Seal.ISA.Ops.RegistrySpec
import qualified Seal.Phase2aSpec
import qualified Seal.Phase2bSpec
import qualified Seal.Phase6aSpec
import qualified Seal.Phase6bSpec
import qualified Seal.Phase7aSpec
import qualified Seal.Phase5Spec
import qualified Seal.Phase4Spec
import qualified Seal.Signal.ConfigSpec
import qualified Seal.Telegram.ConfigSpec
import qualified Seal.Providers.AnthropicSpec
import qualified Seal.Providers.Anthropic.OAuthSpec
import qualified Seal.Providers.ClassSpec
import qualified Seal.Providers.OllamaSpec
import qualified Seal.Providers.RegistrySpec
import qualified Seal.Agent.LoopSpec
import qualified Seal.ISA.DispatchSpec
import qualified Seal.ISA.IntegrationSpec
import qualified Seal.ISA.Ops.HumanSpec
import qualified Seal.ISA.Ops.FileSpec
import qualified Seal.ISA.Ops.ShellSpec
import qualified Seal.ISA.Ops.ProcessSpec
import qualified Seal.ISA.Ops.BinSpec
import qualified Seal.ISA.Ops.SearchSpec
import qualified Seal.ISA.Ops.PatchSpec
import qualified Seal.ISA.Ops.SecretSpec
import qualified Seal.ISA.RegistrySpec

main :: IO ()
main = hspec $ do
  Seal.Core.ChannelKindSpec.spec
  Seal.Core.MessageSourceSpec.spec
  Seal.Core.AllowListSpec.spec
  Seal.Core.TypesSpec.spec
  Seal.Core.PagingSpec.spec
  Seal.Gateway.ConfigSpec.spec
  Seal.Gateway.ApiSpec.spec
  Seal.Gateway.ServerSpec.spec
  Seal.Gateway.StreamBrokerSpec.spec
  Seal.Gateway.StreamSpec.spec
  Seal.Gateway.TranscriptSpec.spec
  Seal.AppMainSpec.spec
  Seal.Session.MetaSpec.spec
  Seal.Session.StoreSpec.spec
  Seal.Text.LineFileSpec.spec
  Seal.Tools.Exec.TypesSpec.spec
  Seal.Tools.Exec.UntrustedSpec.spec
  Seal.Tools.Exec.LocalSpec.spec
  Seal.Tools.Exec.RemoteSpec.spec
  Seal.Tools.ArgsSpec.spec
  Seal.Tools.Exec.CapabilityScopingFailSpec.spec
  Seal.Web.SearchSpec.spec
  Seal.Web.FetchSpec.spec
  Seal.Web.BrowserSpec.spec
  Seal.Media.ImageSpec.spec
  Seal.Media.TtsSpec.spec
  Seal.ConfigSpec.spec
  Seal.Config.PathsSpec.spec
  Seal.Security.CryptoSpec.spec
  Seal.Security.PathSpec.spec
  Seal.Security.SecretsSpec.spec
  Seal.Security.Vault.AgeSpec.spec
  Seal.Security.VaultSpec.spec
  Seal.Security.PolicySpec.spec
  Seal.Security.CommandSpec.spec
  Seal.Security.AdoptionSpec.spec
  Seal.Command.HelpSpec.spec
  Seal.Command.ModelSpec.spec
  Seal.Command.ParseSpec.spec
  Seal.Command.ProviderSpec.spec
  Seal.Command.SessionSpec.spec
  Seal.Command.ServeSpec.spec
  Seal.Command.SkillSpec.spec
  Seal.Command.AgentSpec.spec
  Seal.Command.BackgroundSpec.spec
  Seal.Command.CallSpec.spec
  Seal.Command.ChannelSpec.spec
  Seal.Command.SpecSpec.spec
  Seal.Command.TabSpec.spec
  Seal.Command.NewSpec.spec
  Seal.Config.FileSpec.spec
  Seal.Config.MigrateSpec.spec
  Seal.Config.SecuritySpec.spec
  Seal.Config.SecurityScopingFailSpec.spec
  Seal.Vault.BackendSpec.spec
  Seal.Vault.CommandsSpec.spec
  Seal.IngestSpec.spec
  Seal.Channel.CliSpec.spec
  Seal.Channel.WiringSpec.spec
  Seal.Channels.ClassSpec.spec
  Seal.Channels.LoopSpec.spec
  Seal.Channels.SignalSpec.spec
  Seal.Channels.TelegramSpec.spec
  Seal.Channels.Telegram.CommandsSpec.spec
  Seal.Channels.Telegram.TransportSpec.spec
  Seal.Channels.Signal.EnvelopeSpec.spec
  Seal.Channels.Signal.RunSpec.spec
  Seal.Channels.Signal.TransportSpec.spec
  Seal.Transcript.TypesSpec.spec
  Seal.Transcript.ConvSpec.spec
  Seal.Transcript.EntriesSpec.spec
  Seal.Transcript.ReconstructSpec.spec
  Seal.Handles.AskReplySpec.spec
  Seal.Handles.ChannelSpec.spec
  Seal.Handles.HarnessSpec.spec
  Seal.Handles.TabSpec.spec
  Seal.Handles.TranscriptSpec.spec
  Seal.Harness.IdSpec.spec
  Seal.Harness.RegistrySpec.spec
  Seal.Harness.ReconcileSpec.spec
  Seal.Harness.TmuxSpec.spec
  Seal.Harness.TmuxIOSpec.spec
  Seal.Harness.DiscoverySpec.spec
  Seal.Tabs.TypesSpec.spec
  Seal.TabsSpec.spec
  Seal.Tabs.RelaySpec.spec
  Seal.Tabs.WizardSpec.spec
  Seal.Routing.RouteSpec.spec
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
  Seal.ISA.Ops.RegistrySpec.spec
  Seal.Phase2aSpec.spec
  Seal.Phase2bSpec.spec
  Seal.Phase6aSpec.spec
  Seal.Phase6bSpec.spec
  Seal.Phase7aSpec.spec
  Seal.Phase5Spec.spec
  Seal.Phase4Spec.spec
  Seal.Signal.ConfigSpec.spec
  Seal.Telegram.ConfigSpec.spec
  Seal.Providers.AnthropicSpec.spec
  Seal.Providers.Anthropic.OAuthSpec.spec
  Seal.Providers.ClassSpec.spec
  Seal.Providers.OllamaSpec.spec
  Seal.Providers.RegistrySpec.spec
  Seal.Agent.LoopSpec.spec
  Seal.ISA.DispatchSpec.spec
  Seal.ISA.IntegrationSpec.spec
  Seal.ISA.Ops.HumanSpec.spec
  Seal.ISA.Ops.FileSpec.spec
  Seal.ISA.Ops.ShellSpec.spec
  Seal.ISA.Ops.ProcessSpec.spec
  Seal.ISA.Ops.BinSpec.spec
  Seal.ISA.Ops.SearchSpec.spec
  Seal.ISA.Ops.PatchSpec.spec
  Seal.ISA.Ops.SecretSpec.spec
  Seal.ISA.RegistrySpec.spec
