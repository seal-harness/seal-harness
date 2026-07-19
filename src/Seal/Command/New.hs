{-# LANGUAGE OverloadedStrings #-}
-- | The @/new@ command: start a fresh session in the current tab.
--
-- @/new@ mints a new 'SessionMeta' from the config defaults (same path as
-- 'initSession'/'createConversationSession'/'handleTabNew') and rebinds the
-- current tab to the new session's id. The old session is kept on disk,
-- untouched — still listed in @/session list@, still resumable with
-- @/tab resume <id>@. No new tab is inserted, no tab is closed.
--
-- This is the user's "fresh conversation in the current window" affordance —
-- distinct from @/tab new@, which opens a new tab.
--
-- == Channel wiring
--
-- The command is registered as a 'CommandSpec' for the CLI and web-gateway
-- paths (both track "current" via an active-session ref + a 'TabsHandle').
-- The inbox channels (Signal, Telegram) handle @/new@ at the loop level
-- ('Seal.Channels.Loop') instead, because the per-conversation cursor +
-- conversation key aren't available to a registry 'CommandAction' — see the
-- design doc.
module Seal.Command.New
  ( NewDeps (..)
  , newCommandSpec
  , renderNewConfirmation
  , mintNewSession
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Options.Applicative (ParserInfo, info, helper, progDesc, header, (<**>))

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli (Backends (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File (FileConfig)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, newSession, resolveDefaultAgent )

-- | The deps a channel needs to run @/new@. Built once at startup; the
-- 'ndRebind' callback is the seam where each channel plugs in its "current
-- tab" mutation.
--
-- 'ndRebind' receives the freshly-minted 'SessionMeta' AND the old sid
-- (read by the closure from the channel's active-session ref BEFORE the
-- swap), plus the 'ChannelCaps' to send any per-channel diagnostic. It is
-- responsible for: (1) swapping the active-session ref to the new meta,
-- (2) rebinding the matching tab (if any) in the 'TabsHandle' to the new
-- sid, and (3) returning the old sid (so the caller can render the
-- confirmation line naming it). Returning the old sid from 'ndRebind'
-- avoids ordering ambiguity (architect review issue D): the closure reads
-- the old sid, swaps the ref, rebinds the tab, and hands back the old sid
-- in one callback.
data NewDeps = NewDeps
  { ndPaths        :: SealPaths
  , ndCfg          :: IO FileConfig
  , ndAgentDefs    :: Backends
  , ndChannelLabel :: Text
  , ndRebind        :: ChannelCaps -> SessionMeta -> IO SessionId
    -- ^ Swap active-session ref + rebind the current tab; return the old sid.
  }

-- | The @/new@ command spec. Grouped under Sessions in @/help@. Always
-- available (the operator typed it; no autonomy gate).
newCommandSpec :: NewDeps -> CommandSpec
newCommandSpec deps = CommandSpec
  { csName         = CommandName "new"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "Start a fresh session in the current tab (vs /tab new, which opens a new tab)"
  , csParserInfo   = newParserInfo deps
  , csAvailability = AlwaysAvailable
  }

newParserInfo :: NewDeps -> ParserInfo CommandAction
newParserInfo deps =
  info (pure (newCmd deps) <**> helper)
    (  progDesc "Start a fresh session in the current tab"
    <> header   "new — start a fresh session in the current tab (old session kept in /session list)"
    )

-- | The @/new@ action: mint a session from config defaults, call 'ndRebind'
-- (which swaps the active-session ref + rebinds the tab + returns the old
-- sid), and send the confirmation line.
newCmd :: NewDeps -> CommandAction
newCmd deps = CommandAction $ \caps -> do
  meta <- mintNewSession deps
  oldSid <- ndRebind deps caps meta
  ccSend caps (renderNewConfirmation meta oldSid)

-- | Mint a fresh 'SessionMeta' from the config defaults, persisted to disk
-- via 'newSession' (so @/session list@ picks it up). Shared by the
-- registry path (CLI/web) and the loop-level inbox path.
mintNewSession :: NewDeps -> IO SessionMeta
mintNewSession deps = do
  cfg <- ndCfg deps
  (mAgent, mProv, mModel) <- resolveDefaultAgent (bAgentDefs (ndAgentDefs deps)) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe cfgProv mProv
      model    = fromMaybe cfgModel mModel
  newSession (ndPaths deps) provider model (ndChannelLabel deps) mAgent

-- | Render the one-line confirmation. Names the old session + resume hint
-- so the safety net (old session kept on disk) is user-visible, per
-- PM/designer review.
renderNewConfirmation :: SessionMeta -> SessionId -> Text
renderNewConfirmation meta oldSid =
  "new session " <> sessionIdText (smId meta)
    <> " (" <> smProvider meta <> "/" <> smModel meta <> ")"
    <> " — prior session " <> sessionIdText oldSid
    <> " kept in /session list"