-- | The unified slash-command registry builder. All channels (web, CLI,
-- Signal, Telegram) share the same core set of @\/@-commands, defined once
-- here. Only channel-specific specs (the terse @\/N@ tab-grammar, the
-- @\/channel@ channel-management command, the CLI's @\/bg@, and the
-- per-request @\/call@\/@\/skill@\/@\/stop@ rebuilds on the multi-session
-- web) stay at their wiring sites.
--
-- The carve-out for the web: the @\/N@ terse grammar (@\/1@ focus, @\/1
-- payload@ inject) is a tab-level operation the web frontend handles via
-- the sidebar, not via the send endpoint — 'Seal.Gateway.Send.handleSend'
-- short-circuits 'Focus'/'Inject'/'TabCommand' routes with a deferral
-- message before they reach the registry. The @terseGrammarSpec@ is still
-- included in the core list so @\/help@ displays the grammar; only its
-- execution is web-rejected.
module Seal.Command.Registry
  ( CoreCommandDeps (..)
  , coreCommandSpecs
  ) where

import Seal.Agent.Def.Backend (AgentDefBackend)
import Seal.Command.Agent (agentCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Provider (ProviderRuntime, providerCommandSpec)
import Seal.Command.Repo (RepoTestSeam, repoCommandSpec)
import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Spec (CommandSpec)
import Seal.Command.Stop (StopTranscriptWriter, stopCommandSpec)
import Seal.Command.Tab (TabCloseNotifier, tabCommandSpec, terseGrammarSpec)
import Seal.Config.Paths (SealPaths)
import Seal.Session.Store (SessionRuntime)
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.Tabs (TabsHandle)
import Seal.Tools.Exec.Abort (SessionAbortRegistry)
import Seal.Vault.Commands (VaultRuntime, vaultCommandSpec)

-- | The shared dependencies for the core slash-command specs. Built once
-- at startup by each wiring site (web 'Seal.Command.Serve', CLI
-- 'Seal.Tui', Signal/Telegram 'Seal.Channels.Signal.Run' /
-- 'Seal.Channels.Telegram.Run') and passed to 'coreCommandSpecs' to
-- produce the channel-agnostic slice of the 'Registry'.
--
-- The web's multi-session @\/stop@ (which must target the request's
-- session, not the process-global @srActive@) is handled by
-- 'Seal.Gateway.Send.replaceCallSkillSpecs' rebuilding the stop spec
-- per-request via 'Seal.Command.Stop.stopCommandSpecForSession'; the
-- @srActive@-reading spec produced here is the fallback for the
-- single-session channels.
data CoreCommandDeps = CoreCommandDeps
  { ccdVault       :: VaultRuntime
    -- ^ For @\/vault@ (status/unlock/lock/rekey).
  , ccdProvider    :: ProviderRuntime
    -- ^ For @\/provider@ (list/switch) + @\/model@.
  , ccdSession     :: SessionRuntime
    -- ^ For @\/session@, @\/model@, and the single-session @\/stop@.
  , ccdAgentDefs   :: AgentDefBackend
    -- ^ For @\/agent@ (list/edit/bind).
  , ccdCfgPath     :: FilePath
    -- ^ The config.toml path (for @\/agent@'s file edits).
  , ccdPaths       :: SealPaths
    -- ^ For @\/tab@ (session-meta lookups).
  , ccdTabs        :: TabsHandle
    -- ^ For @\/tab@ (list/new/close/focus/resume/rename).
  , ccdTabCloseNotifier :: TabCloseNotifier
    -- ^ Invoked after @\/tab close@ so attached channels are notified.
  , ccdAbortReg    :: SessionAbortRegistry
    -- ^ For @\/stop@ (the single-session variant; the web rebuilds
    -- per-request).
  , ccdStopWriter  :: StopTranscriptWriter
    -- ^ Writes the stop message to the session's transcript + broadcasts
    -- it so the stop appears cross-channel. Built at the wiring site from
    -- 'SealPaths' + the broker.
  , ccdRepoReg     :: RepoRegistryHandle
    -- ^ For @\/repo@ (list/add/remove/info/test).
  , ccdRepoSeam    :: Maybe RepoTestSeam
    -- ^ The @git ls-remote@ + vault-list seam for @\/repo test@ / @\/repo
    -- info@. 'Nothing' on channels that don't wire the seam yet
    -- (Signal/Telegram/TUI standalone); @\/repo@ is omitted from the
    -- registry in that case.
  }

-- | Build the core (channel-agnostic) slash-command specs. Each wiring
-- site passes its 'CoreCommandDeps' + any channel-specific specs to
-- 'mkRegistry':
--
-- @
-- 'mkRegistry' ('coreCommandSpecs' coreDeps <> [channelSpecificSpec, ...])
-- @
--
-- The web additionally rebuilds @\/call@, @\/skill@, and @\/stop@
-- per-request via 'Seal.Gateway.Send.replaceCallSkillSpecs' so those
-- commands target the request's explicit 'SessionId' (the web is
-- multi-session; @srActive@ is not authoritative there).
--
-- @\/new@ is deliberately NOT in the core list: on inbox channels
-- (Signal, Telegram) @\/new@ is handled at the loop level
-- ('Seal.Channels.Loop.handleNewSession') because the conversation key +
-- cursor aren't available to a registry 'CommandAction'. The CLI and web
-- add @newCommandSpec@ to their registries directly (closing over their
-- channel-specific @ndInsertTab@).
coreCommandSpecs :: CoreCommandDeps -> [CommandSpec]
coreCommandSpecs d =
  [ vaultCommandSpec (ccdVault d)
  , providerCommandSpec (ccdProvider d)
  , sessionCommandSpec (ccdSession d)
  , modelCommandSpec (ccdProvider d) (ccdSession d)
  , agentCommandSpec (ccdAgentDefs d) (ccdCfgPath d)
  , tabCommandSpec (ccdPaths d) (ccdTabs d) (ccdTabCloseNotifier d)
  , stopCommandSpec (ccdAbortReg d) (ccdSession d) (ccdStopWriter d)
  , terseGrammarSpec
  ]
  <> [ repoCommandSpec (ccdRepoReg d) seam | Just seam <- [ccdRepoSeam d] ]