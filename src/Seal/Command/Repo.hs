{-# LANGUAGE OverloadedStrings #-}
-- | The @/repo@ command group: list, add, remove, inspect, or test the
-- source-control repos registered in @config\/repos.toml@ (design §4.6).
-- Mirrors 'Seal.Command.Skill' (hsubparser with @list@/@info@ subcommands,
-- 'InteractiveOnly' availability, plain-language renderers). Mutations
-- (@add@\/@remove@) go through 'RepoRegistryHandle' (the service layer over
-- @repos.toml@); the credential /value/ is NEVER read by this command (only
-- the vault key /name/) — secret bytes live in the vault and are fetched at
-- clone time by W3's 'Seal.SourceControl.Clone.resolveCloneTarget'.
--
-- /repo test runs @git ls-remote@ through the injected 'RepoTestSeam' (the
-- real seam is 'lsRemoteRepo'; tests inject a stub) so the command is fully
-- testable without running real git. The /repo test error-message mapping
-- (AC6) reconciles the W3 'renderCloneError' wording for the slash surface:
-- @git failed (exit N)@ becomes @git ls-remote failed (exit N)@ here, since
-- the only git invocation /repo test performs is @git ls-remote@.
module Seal.Command.Repo
  ( repoCommandSpec
  , renderRepoLine
  , renderRepoInfo
  , credentialKindLabel
  , RepoTestSeam (..)
  ) where

import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Security.Vault.Age (VaultError (..))
import Seal.SourceControl.Clone (CloneError (..))
import Seal.SourceControl.Repo
  ( RepoCredential (..), RepoId, SourceRepo (..)
  , hostAllowed, mkRepoId, parseCredentialKind, parseRepoHost, parseVcsKind
  , repoIdText, urlShapeValid, vcsKindText )
import Seal.SourceControl.Registry
  ( RepoRegistryHandle (..), removeRepo, upsertRepo )

----------------------------------------------------------------------------
-- Test seam
----------------------------------------------------------------------------

-- | The /repo command depends on the live vault + @repoCloneStateDir@ for
-- @/repo test@, and on the vault's key list for the @/repo info@ non-blocking
-- advisory. To keep the command testable without running real git, the
-- ls-remote seam is injected. Production wiring (in 'Seal.Command.Serve')
-- passes a real seam built from 'Seal.SourceControl.Clone.lsRemoteRepo' and
-- 'Seal.Security.Vault.vhList'; tests pass a stub.
data RepoTestSeam = RepoTestSeam
  { rtsLsRemote  :: SourceRepo -> IO (Either CloneError Text)
    -- ^ The @git ls-remote@ seam (production: 'lsRemoteRepo').
  , rtsVaultList :: IO (Either VaultError [Text])
    -- ^ The vault key list (production: 'vhList') for the /repo info advisory.
  }

----------------------------------------------------------------------------
-- Command spec
----------------------------------------------------------------------------

-- | The @/repo@ command spec. Closes over the 'RepoRegistryHandle' (for
-- list/add/remove/info) and a 'RepoTestSeam' (for /repo test + /repo info
-- advisory). 'InteractiveOnly' (mirrors /skill) so it dispatches only on the
-- channel the operator is typing on — not reachable by the agent's tool
-- surface.
repoCommandSpec :: RepoRegistryHandle -> RepoTestSeam -> CommandSpec
repoCommandSpec regH seam = CommandSpec
  { csName         = CommandName "repo"
  , csAliases      = []
  , csGroup        = GroupRepos
  , csSynopsis     = "List, add, remove, inspect, or test source-control repos"
  , csParserInfo   = repoParserInfo regH seam
  , csAvailability = InteractiveOnly
  }

repoParserInfo :: RepoRegistryHandle -> RepoTestSeam -> ParserInfo CommandAction
repoParserInfo regH seam =
  info (repoParser regH seam <**> helper)
    (  progDesc "List, add, remove, inspect, or test source-control repos"
    <> header   "repo — manage the source-control repo registry"
    )

repoParser :: RepoRegistryHandle -> RepoTestSeam -> Parser CommandAction
repoParser regH seam = hsubparser
  (  command "list"
       (info (pure (listCmd regH))
             (progDesc "List all registered repos (id, url, credential kind)"))
  <> command "add"
       (info (addCmd regH <$> idArg <*> urlArg <*> vcsOpt <*> credOpt
                      <*> vaultKeyOpt <*> usernameOpt)
             (progDesc "Add or replace a source-control repo"))
  <> command "remove"
       (info (removeCmd regH <$> idArg)
             (progDesc "Remove a source-control repo by id"))
  <> command "info"
       (info (infoCmd regH seam <$> idArg)
             (progDesc "Show a repo's descriptor + a vault-key advisory"))
  <> command "test"
       (info (testCmd regH seam <$> idArg)
             (progDesc "Run git ls-remote to verify the credential resolves"))
  <> metavar "COMMAND"
  )

----------------------------------------------------------------------------
-- Arguments / options
----------------------------------------------------------------------------

-- | Required repo-id argument.
idArg :: Parser Text
idArg = T.pack <$> strArgument (metavar "ID" <> help "Repo id (e.g. myrepo)")

-- | Required repo URL argument.
urlArg :: Parser Text
urlArg = T.pack <$> strArgument (metavar "URL" <> help "Repo URL (git@github.com:owner/repo.git, ssh://host/path, or https://github.com/owner/repo.git)")

-- | @--vcs@ option (default @github@).
vcsOpt :: Parser Text
vcsOpt = T.pack <$> strOption
  (  long "vcs"
  <> metavar "KIND"
  <> value "github"
  <> showDefault
  <> help "VCS kind: git or github (default github)"
  )

-- | @--cred@ option (default @pat@). The help text enumerates each kind with
-- a plain-language description so the operator understands what each stores
-- before adding a repo.
credOpt :: Parser Text
credOpt = T.pack <$> strOption
  (  long "cred"
  <> metavar "KIND"
  <> value "pat"
  <> showDefault
  <> help ( "Credential kind: pat (Personal Access Token: a token stored in "
         <> "the vault, used to clone over HTTPS — token never in URL or "
         <> "process list; note: deploy_key is preferred for lower exposure); "
         <> "deploy_key (SSH deploy key: an encrypted keyfile on the harness "
         <> "disk + a passphrase in the vault — preferred, lowest exposure); "
         <> "machine_user (bot account: a username + token stored in the vault, "
         <> "used to clone over HTTPS as the bot user — requires --username)"
         )
  )

-- | @--vault-key@ option (required). The vault key NAME (the secret value
-- is NEVER read by this command — only at clone time).
vaultKeyOpt :: Parser Text
vaultKeyOpt = T.pack <$> strOption
  (  long "vault-key"
  <> metavar "KEY"
  <> help "Vault key name under which the credential value is stored"
  )

-- | @--username@ option (optional; required iff @--cred machine_user@).
usernameOpt :: Parser (Maybe Text)
usernameOpt = optional (T.pack <$> strOption
  (  long "username"
  <> metavar "USER"
  <> help "Public bot account handle (required iff --cred machine_user)"
  ))

----------------------------------------------------------------------------
-- list
----------------------------------------------------------------------------

listCmd :: RepoRegistryHandle -> CommandAction
listCmd regH = CommandAction $ \caps -> do
  eRepos <- rrhList regH
  case eRepos of
    Left err      -> ccSend caps err
    Right []      -> ccSend caps "no repos registered"
    Right repos   -> mapM_ (ccSend caps . renderRepoLine) repos

----------------------------------------------------------------------------
-- add
----------------------------------------------------------------------------

-- | @/repo add <id> <url> --vcs --cred --vault-key [--username]@. Validates
-- the id, URL shape, host allow-list, VCS kind, and credential kind before
-- mutating. The credential /value/ is NEVER read (only the vault key name).
-- On a successful mutation, echoes @added repo \<id\>@.
addCmd
  :: RepoRegistryHandle
  -> Text   -- ^ raw id
  -> Text   -- ^ url
  -> Text   -- ^ vcs kind (text)
  -> Text   -- ^ credential kind (text)
  -> Text   -- ^ vault key name
  -> Maybe Text  -- ^ optional username (machine_user only)
  -> CommandAction
addCmd regH rawId url rawVcs rawCred vaultKey mUsername =
  CommandAction $ \caps -> do
    case validateAdd rawId url rawVcs rawCred vaultKey mUsername of
      Left err -> ccSend caps err
      Right repo -> do
        res <- rrhMutate regH (upsertRepo repo)
        case res of
          Left e  -> ccSend caps e
          Right _ -> ccSend caps ("added repo " <> repoIdText (srId repo))

-- | Pure validation for @/repo add@. Runs every write-time check from the
-- security table (§Security): id charset, URL shape, host allow-list, VCS
-- kind, credential kind (with the machine_user username requirement).
validateAdd
  :: Text -> Text -> Text -> Text -> Text -> Maybe Text
  -> Either Text SourceRepo
validateAdd rawId url rawVcs rawCred vaultKey mUsername = do
  rid       <- mkRepoId rawId
  vcs       <- parseVcsKind rawVcs
  -- URL shape (defense in depth on top of host allow-list).
  if not (urlShapeValid url)
    then Left "URL is neither SSH (git@<host>:... or ssh://<host>/...) nor HTTPS (https://<host>/...)"
    else do
      host <- parseRepoHost url
      if not (hostAllowed vcs host)
        then Left ("host " <> host <> " not supported (github repos must use github.com; git repos allow any host)")
        else do
          cred <- parseCredentialKind rawCred vaultKey mUsername
          Right SourceRepo
            { srId               = rid
            , srUrl              = url
            , srVcsKind          = vcs
            , srCredential       = cred
            , srDeployKeyPublic  = Nothing
            , srKeyfilePath      = Nothing
            }

----------------------------------------------------------------------------
-- remove
----------------------------------------------------------------------------

-- | @/repo remove <id>@. Idempotent (204 semantics mirror the REST API): a
-- missing id is still reported as @removed@.
removeCmd :: RepoRegistryHandle -> Text -> CommandAction
removeCmd regH raw = CommandAction $ \caps ->
  case mkRepoId raw of
    Left err -> ccSend caps err
    Right rid -> do
      res <- rrhMutate regH (removeRepo rid)
      case res of
        Left e  -> ccSend caps e
        Right _ -> ccSend caps ("removed repo " <> repoIdText rid)

----------------------------------------------------------------------------
-- info
----------------------------------------------------------------------------

-- | @/repo info <id>@. Renders the descriptor and appends a NON-BLOCKING
-- vault-key advisory: if the vault lists its keys and the repo's
-- @cVaultKey@ is not among them, the operator gets immediate feedback
-- (@vault key \<name\> not found — clone will fail until it is added@) —
-- without failing the command. Lazy-verify is preserved (the vault key is
-- not actually fetched here; only its name is cross-checked against the
-- vault's key list). A locked vault surfaces @vault locked — run /vault
-- unlock to check@; any other vault error skips the advisory silently.
infoCmd :: RepoRegistryHandle -> RepoTestSeam -> Text -> CommandAction
infoCmd regH seam raw = CommandAction $ \caps ->
  case mkRepoId raw of
    Left err -> ccSend caps err
    Right rid -> do
      eRepos <- rrhList regH
      case eRepos of
        Left e -> ccSend caps e
        Right repos -> case findRepo rid repos of
          Nothing  -> ccSend caps ("repo not found: " <> repoIdText rid)
          Just r  -> do
            mapM_ (ccSend caps) (renderRepoInfo r)
            advisory <- vaultKeyAdvisory seam (srCredential r)
            for_ advisory (ccSend caps)

-- | Find a repo by id in a list (helper to avoid a Map.fromList round-trip).
findRepo :: RepoId -> [SourceRepo] -> Maybe SourceRepo
findRepo rid = go
  where
    go []       = Nothing
    go (r : rs) = if srId r == rid then Just r else go rs

-- | Compute the non-blocking vault-key advisory for /repo info. Returns
-- 'Nothing' when no advisory applies (the vault key is present, or a
-- non-lock vault error occurred — silent skip).
vaultKeyAdvisory :: RepoTestSeam -> RepoCredential -> IO (Maybe Text)
vaultKeyAdvisory seam cred = do
  eKeys <- rtsVaultList seam
  let vaultKey = cVaultKey cred
  pure $ case eKeys of
    Left VaultLocked -> Just "vault locked — run /vault unlock to check"
    Left _           -> Nothing  -- other vault error: skip the advisory
    Right keys ->
      if vaultKey `elem` keys
        then Nothing  -- key present: no advisory
        else Just ("vault key " <> vaultKey <> " not found — clone will fail until it is added")

----------------------------------------------------------------------------
-- test
----------------------------------------------------------------------------

-- | @/repo test <id>@. Resolves the repo, runs @git ls-remote@ via the
-- injected seam, and echoes the head sha on success
-- (@credential verified — \<sha\>@). On failure, renders the 'CloneError'
-- via the /repo test-specific mapping (AC6): notably @CloneGitFailed n@
-- becomes @git ls-remote failed (exit n)@ (NOT W3's @git failed (exit n)@),
-- since the only git invocation /repo test performs is @git ls-remote@.
testCmd :: RepoRegistryHandle -> RepoTestSeam -> Text -> CommandAction
testCmd regH seam raw = CommandAction $ \caps ->
  case mkRepoId raw of
    Left err -> ccSend caps err
    Right rid -> do
      eRepos <- rrhList regH
      case eRepos of
        Left e -> ccSend caps e
        Right repos -> case findRepo rid repos of
          Nothing  -> ccSend caps ("repo not found: " <> repoIdText rid)
          Just r   -> do
            res <- rtsLsRemote seam r
            case res of
              Left e  -> ccSend caps (renderRepoTestError e)
              Right s -> ccSend caps ("credential verified — " <> s)

-- | /repo test error-message mapping (AC6). Mirrors W3's 'renderCloneError'
-- EXCEPT for @CloneGitFailed@, which is reconciled to @git ls-remote failed@
-- per the W3 reviewer's non-blocking note (the slash surface invokes
-- @git ls-remote@, not @git@; the W3 wording was generic and is sharpened
-- here for the operator-facing message).
renderRepoTestError :: CloneError -> Text
renderRepoTestError = \case
  CloneVaultError VaultLocked ->
    "vault locked — run /vault unlock"
  CloneVaultError (VaultKeyNotFound k) ->
    "vault key " <> k <> " not found"
  CloneVaultError _ ->
    "vault error"
  CloneNoCredentialForUrl u ->
    "no credential resolvable for " <> u
  CloneUnsupportedVcs v ->
    "unsupported VCS: " <> vcsKindText v
  CloneHostNotSupported h ->
    "host " <> h <> " not supported (github repos must use github.com; git repos allow any host)"
  CloneGitFailed n ->
    "git ls-remote failed (exit " <> T.pack (show n) <> ")"
  CloneAgentError msg ->
    "ssh-agent error: " <> msg

----------------------------------------------------------------------------
-- Renderers
----------------------------------------------------------------------------

-- | One line per repo for @/repo list@: @id  url  <human-credential-label>@.
renderRepoLine :: SourceRepo -> Text
renderRepoLine r =
  repoIdText (srId r) <> "  " <> srUrl r <> "  " <> credentialKindLabel (srCredential r)

-- | Multi-line detail for @/repo info@. The @username@ line is emitted ONLY
-- for 'CredMachineUser' (a public bot handle); PAT/DeployKey have no
-- username.
renderRepoInfo :: SourceRepo -> [Text]
renderRepoInfo r =
  baseLines <> usernameLine
  where
    baseLines =
      [ "id:          " <> repoIdText (srId r)
      , "url:         " <> srUrl r
      , "vcs:         " <> vcsKindText (srVcsKind r)
      , "credential:  " <> credentialKindLabel (srCredential r)
      , "vault key:   " <> cVaultKey (srCredential r)
      ]
    usernameLine = case srCredential r of
      CredMachineUser _ u -> ["username:    " <> u]
      _                   -> []

-- | Human-readable label for a 'RepoCredential' (the @credential_kind@ wire
-- string is @pat@\/@deploy_key@\/@machine_user@; this is the long form for
-- @/repo list@ + @/repo info@).
credentialKindLabel :: RepoCredential -> Text
credentialKindLabel = \case
  CredPat _         -> "Personal Access Token"
  CredDeployKey _   -> "SSH Deploy Key"
  CredMachineUser {} -> "Bot Account"