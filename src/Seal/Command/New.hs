{-# LANGUAGE OverloadedStrings #-}
-- | The @/new@ command: start a fresh session in a new tab.
--
-- @/new@ mints a new 'SessionMeta' from the config defaults (or from
-- optional @-p@\/@-m@ overrides) and inserts a new tab into the
-- 'TabsHandle' — the same action the web frontend's "Start a new tab"
-- form performs. The old session (if any) is kept on disk, untouched —
-- still listed in @\/session list@, still resumable with @\/tab resume
-- \<id\>@. When @-r@\/@--repo@ is given, the repo is cloned into the
-- new session's workdir via SETUP_REPO before the first turn (same as
-- the web form's "Set up repo" field).
--
-- The @-r@\/@--repo@ argument accepts either a registered repo ID (looked
-- up in the repo registry @repos.toml@) or a raw git URL. When a registered
-- ID is found, the registered URL is used for the clone. When no ID
-- matches, the value is treated as a raw URL.
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
  , NewArgs (..)
  , parseNewArgs
  , emptyNewArgs
  , resolveRepoUrl
  ) where

import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
  ( Parser, ParserInfo, info, helper, progDesc, header, optional, short, long
  , strOption, metavar, help, (<**>) )

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli (Backends (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File (RuntimeConfig)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, newSession, resolveDefaultAgent, updateSessionRepoUrl )
import Seal.SourceControl.Repo (SourceRepo (..), mkRepoId, srUrl)
import Seal.SourceControl.Registry (RepoRegistryHandle (..))

-- | Optional arguments for @/new@. All fields are 'Maybe' — 'Nothing' means
-- "use the config default" (for provider/model) or "no repo" (for repo).
data NewArgs = NewArgs
  { naProvider :: Maybe Text
  , naModel    :: Maybe Text
  , naRepo     :: Maybe Text
  } deriving stock (Eq, Show)

-- | The empty 'NewArgs' — no overrides, use all config defaults.
emptyNewArgs :: NewArgs
emptyNewArgs = NewArgs { naProvider = Nothing, naModel = Nothing, naRepo = Nothing }

-- | Parse the raw argument text from the routing layer into 'NewArgs'.
-- This is a simple manual parse used by the inbox-channel loop path
-- ('Seal.Channels.Loop.handleNewSession'), which doesn't go through
-- optparse-applicative. Supports @-p@\/@--provider@, @-m@\/@--model@, and
-- @-r@\/@--repo@ with a single value each. Unknown flags are ignored.
parseNewArgs :: Text -> NewArgs
parseNewArgs raw =
  go (splitArgs raw) emptyNewArgs
  where
    go [] acc = acc
    go (flag : val : rest) acc
      | flag `elem` ["-p", "--provider"] = go rest acc { naProvider = Just val }
      | flag `elem` ["-m", "--model"]    = go rest acc { naModel    = Just val }
      | flag `elem` ["-r", "--repo"]     = go rest acc { naRepo     = Just val }
      | otherwise                        = go (val : rest) acc
    go (_flag : rest) acc = go rest acc

    -- Split on whitespace, preserving non-empty tokens.
    splitArgs t = case T.words t of
      [] -> []
      ws -> ws

-- | Resolve the @-r@\/@--repo@ value to a git URL. First tries the value
-- as a registered repo ID (looked up via 'RepoRegistryHandle'); if found,
-- returns the registered 'srUrl'. If no ID matches, falls back to treating
-- the value as a raw git URL. This lets the user type @\/new -r myrepo@
-- (a registered id) or @\/new -r https:\/\/github.com\/foo\/bar.git@ (a raw
-- URL) interchangeably.
resolveRepoUrl :: RepoRegistryHandle -> Text -> IO Text
resolveRepoUrl regH raw = do
  eRepos <- rrhList regH
  case eRepos of
    Right repos | Just repo <- matchById repos -> pure (srUrl repo)
    _ -> pure raw
  where
    matchById repos = do
      rid <- either (const Nothing) Just (mkRepoId (T.strip raw))
      listToMaybe [ r | r <- repos, srId r == rid ]

-- | The deps a channel needs to run @/new@. Built once at startup.
--
-- 'ndInsertTab' is the seam where each channel plugs in its tab-insertion
-- + active-session-swap logic. It receives the freshly-minted
-- 'SessionMeta' and the 'ChannelCaps', inserts a new tab bound to the new
-- session, swaps the active-session ref to the new meta, and returns the
-- old sid (so the caller can render the confirmation line naming it).
data NewDeps = NewDeps
  { ndPaths        :: SealPaths
  , ndCfg          :: IO RuntimeConfig
  , ndAgentDefs    :: Backends
  , ndChannelLabel :: Text
  , ndOldMeta      :: IO SessionMeta
    -- ^ Read the current (pre-swap) active session. Used to (a) determine
    -- the old sid for the confirmation line, and (b) as the source of
    -- default provider/model when no overrides are given.
  , ndInsertTab     :: ChannelCaps -> SessionMeta -> IO SessionId
    -- ^ Insert a new tab bound to the new session, swap the active-session
    -- ref, and return the old sid.
  , ndSetupRepo    :: Maybe (SessionId -> Text -> IO (Either Text Text))
    -- ^ Optional repo-setup seam. When 'Just', the @/new@ command calls it
    -- with the new session id + repo URL to clone a repo into the session
    -- workdir (dispatching SETUP_REPO). 'Nothing' in contexts without a
    -- dispatcher (standalone CLI, tests).
  , ndRepoReg      :: Maybe RepoRegistryHandle
    -- ^ Optional repo-registry handle for resolving @-r@ repo IDs to URLs.
    -- 'Nothing' in contexts without a registry (tests); the @-r@ value is
    -- then treated as a raw URL.
  }

-- | The @/new@ command spec. Grouped under Sessions in @/help@. Always
-- available (the operator typed it; no autonomy gate).
newCommandSpec :: NewDeps -> CommandSpec
newCommandSpec deps = CommandSpec
  { csName         = CommandName "new"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "Start a new tab with a fresh session (optional -p/-m/-r overrides)"
  , csParserInfo   = newParserInfo deps
  , csAvailability = AlwaysAvailable
  }

newParserInfo :: NewDeps -> ParserInfo CommandAction
newParserInfo deps =
  info (newCmd deps <$> optional providerOpt <*> optional modelOpt <*> optional repoOpt <**> helper)
    (  progDesc "Start a new tab with a fresh session"
    <> header   "new — start a new tab with a fresh session (old session kept in /session list)"
    )

providerOpt :: Parser Text
providerOpt = strOption
  (  long "provider"
  <> short 'p'
  <> metavar "PROVIDER"
  <> help "Provider override (default: config default)"
  )

modelOpt :: Parser Text
modelOpt = strOption
  (  long "model"
  <> short 'm'
  <> metavar "MODEL"
  <> help "Model override (default: config default)"
  )

repoOpt :: Parser Text
repoOpt = strOption
  (  long "repo"
  <> short 'r'
  <> metavar "REPO"
  <> help "Repo ID (from /repo list) or git URL to clone into the session (default: none)"
  )

-- | The @/new@ action: read the old session, mint a fresh session using
-- the given args (or config defaults when not specified), insert a new
-- tab, optionally clone a repo, and send the confirmation line.
newCmd :: NewDeps -> Maybe Text -> Maybe Text -> Maybe Text -> CommandAction
newCmd deps mProvider mModel mRepo = CommandAction $ \caps -> do
  oldMeta <- ndOldMeta deps
  let args = NewArgs { naProvider = mProvider, naModel = mModel, naRepo = mRepo }
  meta <- mintNewSessionWith args oldMeta deps
  oldSid <- ndInsertTab deps caps meta
  case (naRepo args, ndSetupRepo deps) of
    (Just repoVal, Just setupFn) -> do
      repoUrl <- resolveRepoUrlMaybe deps repoVal
      eRes <- setupFn (smId meta) repoUrl
      case eRes of
        Left err -> ccSend caps ("repo setup failed: " <> err)
        Right _ -> do
          -- Record the repo URL on the session meta so the frontend can
          -- display the repo ID in the sidebar.
          _ <- updateSessionRepoUrl (ndPaths deps) (smId meta) (Just repoUrl)
          pure ()
    _ -> pure ()
  ccSend caps (renderNewConfirmation meta oldSid)

-- | Resolve the @-r@ value to a URL using the repo registry (if wired),
-- falling back to the raw value.
resolveRepoUrlMaybe :: NewDeps -> Text -> IO Text
resolveRepoUrlMaybe deps raw =
  case ndRepoReg deps of
    Just regH -> resolveRepoUrl regH raw
    Nothing   -> pure raw

-- | Mint a fresh 'SessionMeta' using the given args, falling back to the
-- old session's provider/model when no override is given (so mid-session
-- @\/model use@ changes survive @\/new@), and ultimately to config
-- defaults. Persisted to disk via 'newSession' so @/session list@ picks it
-- up. Shared by the registry path (CLI/web) and the loop-level inbox path.
mintNewSessionWith :: NewArgs -> SessionMeta -> NewDeps -> IO SessionMeta
mintNewSessionWith args oldMeta deps =
  newSession (ndPaths deps) provider model (ndChannelLabel deps) (smAgent oldMeta)
  where
    provider = fromMaybe (smProvider oldMeta) (naProvider args)
    model    = fromMaybe (smModel oldMeta) (naModel args)

-- | Mint a fresh 'SessionMeta' from the config defaults (or the given
-- overrides). Used when there is no "old session" to inherit from (e.g.
-- the loop-level path on first conversation message).
mintNewSession :: NewArgs -> NewDeps -> IO SessionMeta
mintNewSession args deps = do
  cfg <- ndCfg deps
  (mAgent, mProv, mModel) <- resolveDefaultAgent (bAgentDefs (ndAgentDefs deps)) cfg
  let (cfgProv, cfgModel) = defaultSessionSelection cfg
      provider = fromMaybe (fromMaybe cfgProv mProv) (naProvider args)
      model    = fromMaybe (fromMaybe cfgModel mModel) (naModel args)
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
