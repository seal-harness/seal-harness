{-# LANGUAGE OverloadedStrings #-}
-- | SETUP_REPO (Untrusted): clone a remote repository into the session's
-- workspace so the model can work with its code and discover any skills it
-- ships. The opcode is VCS-agnostic in name and result shape (\"cloned at
-- \<path\>\") but git-only in implementation for now; a future @vcs@ arg or
-- URL-scheme dispatch can add others without changing the contract.
--
-- Untrusted because upstream repo content is untrusted — a clone is a
-- filesystem mutation of untrusted-origin data, so it goes through the
-- sandboxed 'UntrustedIO' + the 'Autonomy' confirmation gate, not a
-- trusted shell. This is strictly safer than the prior pattern of the
-- model running @git clone@ via 'SHELL_EXEC' and hoping.
--
-- Semantics:
--
--   * Shallow clone (@git clone --depth 1@) to keep large repos cheap.
--   * Multiple repos are supported: each clones into
--     @\<workdir\>\/\<sanitized-repo-name\>\/@.
--   * Idempotent: if the target dir already holds a clone of the same
--     remote URL, the call is a no-op (\"Repo already exists — no-op\").
--     If the dir exists but its remote differs, the call errors (\"a
--     different repo already occupies that path\") rather than silently
--     clobbering.
--   * The clone runs in the workspace root (cwd = workdir) via
--     'uioShellExec'; the URL is validated to a safe charset so it cannot
--     inject shell metacharacters into the @\/bin\/sh -c@ single-arg
--     boundary.
--
-- Credential resolution (W3 — design §4.2/§4.3, rev 3): 'setupRepoOp' takes
-- a 'CloneDeps' closed-over param (mirrors @secretGetOp (cdVault deps)@).
-- 'cloneRepoIO' does @lookupRepoByUrl@ against the registry
-- (@cdRepoReg@) → if the URL matches a registered repo, resolve the
-- credential via the no-disk seam ('Seal.SourceControl.Clone.resolveCloneTarget'
-- using @cdVault@/@cdSshAgent@/@cdPinnedKnownHosts@/@cdKeyfilesDir@) and
-- run @git clone@ via 'uioShellExecEnv' (deploy key: @SSH_AUTH_SOCK@ +
-- @GIT_SSH_COMMAND@) or 'uioBinExecEnv' (PAT: @http.extraHeader@ argv) with
-- the resolved env. If the URL is NOT registered, fall through to a
-- bare-URL clone (public repos, backward-compat). Stays Untrusted;
-- credential resolution via 'liftIO' in the trusted plane. NO
-- @runLocal@/@BackendExec@.
module Seal.ISA.Ops.Repo
  ( setupRepoOp
  , validateRepoUrl
  , sanitizeRepoName
  , normalizeRepoUrl
  , isShellMetachar
  , CloneResult (..)
  , cloneRepoIO
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Char (isAlphaNum)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Clone
  ( CloneDeps (..), CloneEnv (..), renderCloneError, resolveCloneTarget
  , withCloneTarget )
import Seal.SourceControl.Repo (normalizeRepoUrl, lookupRepoByUrl, SourceRepo (..), RepoRegistry (..))
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.Tools.Args (mkShellCommand, ShellCommand)
import Seal.Tools.Exec.UIO
  ( UIO, renderUntrustedErr, uioLiftIO, uioUntrustedIO )
import Seal.Tools.Exec.UntrustedIO (UntrustedIO)
import Seal.Tools.Exec.UntrustedIO qualified as UIORec
  (UntrustedIO (uioShellExec, uioShellExecGitEnv))
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath)

-- | SETUP_REPO opcode. Input: @{url: Text}@. Authorize: autonomy must not
-- be 'Deny' and the URL must validate ('validateRepoUrl'). Run: a shallow
-- @git clone@ into @\<workdir\>\/\<sanitized-repo-name\>@ via
-- 'uioShellExec', after an idempotency check (read the existing remote).
-- 'orRecorded': the url + target path + status (secret-free).
setupRepoOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode
setupRepoOp deps _wsRoot autonomy = UntrustedOpcode
  { uoName = OpName "SETUP_REPO"
  , uoDesc = "Clone a remote repository into the session workspace (shallow, idempotent). Discover any skills it ships via the available-skills catalog on the next turn."
  , uoInSchema = setupRepoSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case urlField v of
        Nothing -> Left "SETUP_REPO requires {url:string}"
        Just url -> case validateRepoUrl url of
          Left err -> Left ("SETUP_REPO: invalid url: " <> err)
          Right _ -> case autonomy of
            Deny -> Left "SETUP_REPO denied by autonomy policy"
            _   -> Right ()
  , uoRun = \v -> do
      let mUrl = urlField v
          recorded = object [ "url" .= (mUrl :: Maybe Text) ]
      case mUrl of
        Nothing -> pure (OpResult [TrpText "SETUP_REPO requires {url:string}"] True recorded)
        Just url -> case validateRepoUrl url of
          Left err -> pure (OpResult [TrpText ("SETUP_REPO: invalid url: " <> err)] True recorded)
          Right url' -> runSetupRepo deps url' recorded
  }

setupRepoSchema :: Value
setupRepoSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "url" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The repository URL to clone (https://, git://, ssh://, or git@host:path). Cloned shallowly into <workdir>/<repo-name>." :: Text)
            ]
        ]
    , "required" .= (["url"] :: [Text])
    ]

urlField :: Value -> Maybe Text
urlField = parseMaybe (withObject "in" (.: "url"))

-- | Validate a repo URL. Accepts @https://@, @http://@, @git://@,
-- @ssh://@, and the @git\@host:path@ SCP-style form. Rejects any URL
-- containing shell metacharacters that could break out of the
-- @\/bin\/sh -c@ single-arg boundary (the @uioShellExec@ contract).
-- Returns the trimmed URL on success, or an error message.
validateRepoUrl :: Text -> Either Text Text
validateRepoUrl raw =
  let url = T.strip raw
  in if T.null url
       then Left "url is empty"
       else if not (hasAcceptableScheme url)
              then Left "url must use https://, http://, git://, ssh://, or git@host:path"
              else if T.any isShellMetachar url
                     then Left "url contains forbidden shell metacharacters"
                     else Right url

-- | True if the URL begins with an acceptable scheme or is SCP-style
-- (@git\@host:path@, more generally @user\@host:path@).
hasAcceptableScheme :: Text -> Bool
hasAcceptableScheme url =
  any (`T.isPrefixOf` url)
      [ "https://", "http://", "git://", "ssh://" ]
  || isScpStyle url

-- | Heuristic for @user\@host:path@ (SCP-style). Has an @\@ before the
-- first @/@ (if any), and a @:@ after the host, and no scheme prefix.
isScpStyle :: Text -> Bool
isScpStyle url =
  case T.breakOn "@" url of
    (user, rest) | not (T.null user), not (T.null rest) ->
      let afterAt = T.drop 1 rest
      in T.any (== ':') afterAt
             && not (":" `T.isPrefixOf` afterAt)   -- not ':host:path' (no user)
             && not ("/" `T.isPrefixOf` user)      -- not a path with an '@'
    _ -> False

-- | Shell metacharacters forbidden in a repo URL (the @\/bin\/sh -c@
-- single-arg boundary treats these specially). A legit git URL never
-- contains them; their presence signals an injection attempt.
isShellMetachar :: Char -> Bool
isShellMetachar c = c `elem` (";`$\\\"'|\n\r&<>(){}*?[]#!~" :: String)

-- | 'normalizeRepoUrl' is the shared normalizer in "Seal.SourceControl.Repo"
-- (W1 moved it there so both 'ISA.Ops.Repo' and 'lookupRepoByUrl' use the SAME
-- normalizer). Re-exported here for backward compatibility with existing
-- callers (e.g. 'runSetupRepo's idempotency check below).

sanitizeRepoName :: Text -> Text
sanitizeRepoName url =
  -- Strip trailing slashes first so a trailing slash doesn't yield an
  -- empty last segment. Then take the last '/' segment; fall back to the
  -- ':' split for SCP-style (git@host:path); then the whole url.
  let trimmed = T.dropWhileEnd (== '/') url
      lastSeg = case T.breakOnEnd "/" trimmed of
        (_, seg) | not (T.null seg) -> seg
        _ -> case T.breakOnEnd ":" trimmed of
               (_, seg) | not (T.null seg) -> seg
               _ -> trimmed
      withoutGit = fromMaybe lastSeg (T.stripSuffix ".git" lastSeg)
      sanitized = T.map (\c -> if isAlphaNum c || c == '_' || c == '-' then c else '-') withoutGit
      trimmedName = T.dropWhile (== '-') (T.dropWhileEnd (== '-') sanitized)
  in if T.null trimmedName then "repo" else trimmedName

-- | The outcome of a clone attempt. Shared by the opcode (model-invoked)
-- and the @POST /api/sessions/:id/setup-repo@ endpoint (web combo box).
data CloneResult
  = CloneCloned Text    -- ^ cloned into <repo-name> (shallow)
  | CloneNoop Text      -- ^ repo already exists at <repo-name>
  | CloneConflict Text Text  -- ^ a different repo occupies <repo-name> (existing url)
  | CloneFailed Text    -- ^ clone or idempotency check failed (<error>)
  deriving stock (Eq, Show)

-- | Run the clone (or no-op) via an 'UntrustedIO' capability and return a
-- structured 'CloneResult'. This is the shared seam between the
-- model-invoked 'SETUP_REPO' opcode and the web combo box's
-- @POST /api/sessions/:id/setup-repo@ endpoint — both build the same
-- 'UntrustedIO' (sandboxed to the session workdir) and call this.
--
-- Credential resolution (W3): @lookupRepoByUrl@ against the registry
-- (@cdRepoReg@) → if the URL matches a registered repo, resolve the
-- credential via the no-disk seam ('resolveCloneTarget' using @cdVault@/
-- @cdSshAgent@/@cdPinnedKnownHosts@/@cdKeyfilesDir@) and run @git clone@
-- via 'uioShellExecEnv' (deploy key: @SSH_AUTH_SOCK@ + @GIT_SSH_COMMAND@
-- env) or 'uioBinExecEnv' (PAT: @http.extraHeader@ argv) with the resolved
-- env. If the URL is NOT registered, fall through to a bare-URL clone
-- (public repos, backward-compat).
cloneRepoIO :: CloneDeps -> UntrustedIO -> Text -> IO CloneResult
cloneRepoIO deps uio url = do
  let repoName = sanitizeRepoName url
      mCwdPath = case mkRemotePath "." of
        Right rp -> Just rp
        Left _   -> Nothing
      checkCmd = "if [ -d " <> shellQ repoName <> "/.git ]; then git -C "
                 <> shellQ repoName <> " config --get remote.origin.url; else rm -rf "
                 <> shellQ repoName <> "; echo __NONE__; fi"
  checkRes <- UIORec.uioShellExec uio (shellCmd checkCmd) mCwdPath
  case checkRes of
    Left err -> pure (CloneFailed ("idempotency check failed: " <> renderUntrustedErr err))
    Right existing -> do
      let existingUrl = T.strip (T.filter (/= '\n') existing)
          cleanUrl = T.strip url
      if existingUrl /= "__NONE__"
        then if normalizeRepoUrl existingUrl == normalizeRepoUrl cleanUrl
               then pure (CloneNoop repoName)
               else pure (CloneConflict repoName existingUrl)
        else do
          -- Look up the URL in the repo registry. If registered, resolve
          -- the credential via the no-disk seam; else fall through to a
          -- bare-URL clone (public repos).
          eRepos <- rrhList (cdRepoReg deps)
          let mRepo = case eRepos of
                Right repos -> lookupRepoByUrl cleanUrl (RepoRegistry (Map.fromList [(srId r, r) | r <- repos]))
                Left _       -> Nothing
          case mRepo of
            Just repo -> cloneWithCredential deps uio repo repoName mCwdPath
            Nothing   -> cloneBareUrl uio cleanUrl repoName mCwdPath

-- | Clone a registered repo via the no-disk seam (deploy key or PAT).
-- Resolves the credential via 'resolveCloneTarget' + runs @git clone@ with
-- the resolved env (deploy key: 'uioShellExecEnv'; PAT: 'uioBinExecEnv' —
-- both merge the auth env over the inherited env).
cloneWithCredential
  :: CloneDeps -> UntrustedIO -> SourceRepo -> Text -> Maybe RemotePath
  -> IO CloneResult
cloneWithCredential deps uio repo repoName mCwdPath = do
  eTarget <- resolveCloneTarget deps repo
  case eTarget of
    Left err -> pure (CloneFailed ("credential resolution failed: " <> renderCloneError err))
    Right target -> withCloneTarget target $ \env -> do
      let gitConfigArgs = map T.unpack (ceGitConfigArgs env)
          cloneCmd = "git " <> T.unwords (map T.pack gitConfigArgs)
                     <> " clone --depth 1 -- " <> shellQ (ceUrl env) <> " " <> shellQ repoName
      cloneRes <- UIORec.uioShellExecGitEnv uio (ceEnvExtras env) (ceKnownHostsContent env) (shellCmd cloneCmd) mCwdPath
      case cloneRes of
        Left err -> pure (CloneFailed ("clone failed: " <> renderUntrustedErr err))
        Right _out -> verifyClone uio repoName _out mCwdPath

-- | Clone a bare URL (no credential — public repo, backward-compat).
cloneBareUrl :: UntrustedIO -> Text -> Text -> Maybe RemotePath -> IO CloneResult
cloneBareUrl uio cleanUrl repoName mCwdPath = do
  let cloneCmd = "git clone --depth 1 -- " <> shellQ cleanUrl <> " " <> shellQ repoName
  cloneRes <- UIORec.uioShellExec uio (shellCmd cloneCmd) mCwdPath
  case cloneRes of
    Left err -> pure (CloneFailed ("clone failed: " <> renderUntrustedErr err))
    Right _out -> verifyClone uio repoName _out mCwdPath

-- | Verify a clone actually landed by checking for @<repoName>/.git@.
-- 'uioShellExec' returns 'Right' even on non-zero exit (it surfaces
-- stderr to the model for SHELL_EXEC), so the exit code is unreliable
-- for distinguishing success from failure. The filesystem is the source
-- of truth. Returns 'CloneCloned' on success, 'CloneFailed' (with the
-- clone's output text so the user sees /why/) on failure.
verifyClone :: UntrustedIO -> Text -> Text -> Maybe RemotePath -> IO CloneResult
verifyClone uio repoName cloneOut mCwdPath = do
  let verifyCmd = "test -d " <> shellQ repoName <> "/.git && echo __OK__ || echo __MISSING__"
  vRes <- UIORec.uioShellExec uio (shellCmd verifyCmd) mCwdPath
  case vRes of
    Left err -> pure (CloneFailed ("clone verify failed: " <> renderUntrustedErr err))
    Right vOut
      | "__OK__" `T.isInfixOf` vOut -> pure (CloneCloned repoName)
      | otherwise -> pure (CloneFailed
                            ("clone did not land — git output: "
                             <> T.strip (T.filter (/= '\n') cloneOut)))

-- | Run the clone (or no-op) and build the 'OpResult' (opcode path; wraps
-- 'cloneRepoIO' with the audit 'orRecorded' payload).
runSetupRepo :: CloneDeps -> Text -> Value -> UIO OpResult
runSetupRepo deps url recorded = do
  uio <- uioUntrustedIO
  res <- uioLiftIO (cloneRepoIO deps uio url)
  pure $ case res of
    CloneCloned repoName ->
      OpResult [TrpText ("Cloned " <> T.strip url <> " into " <> repoName <> " (shallow).")]
               False (recordWith recorded repoName "cloned")
    CloneNoop repoName ->
      OpResult [TrpText ("Repo already exists — no-op (" <> repoName <> ").")]
               False (recordWith recorded repoName "noop")
    CloneConflict repoName existing ->
      OpResult [TrpText ("A different repo already occupies " <> repoName <> " (existing: " <> existing <> ").")]
               True (recordWith recorded repoName "conflict")
    CloneFailed err ->
      OpResult [TrpText ("SETUP_REPO: " <> err)] True (recordWith recorded "" "failed")

-- | Construct a 'ShellCommand', total on our internally-built command
-- strings (they contain no NULs). 'mkShellCommand' only fails on NUL, so
-- this never triggers the error branch in practice.
shellCmd :: Text -> ShellCommand
shellCmd t = case mkShellCommand t of
  Right c  -> c
  Left _e  -> error "SETUP_REPO: internal: shell command rejected (NUL?) — unreachable"

-- | Re-build the recorded object with the target repo name + a status.
recordWith :: Value -> Text -> Text -> Value
recordWith _ target status =
  object [ "target" .= target, "status" .= status ]

-- | Single-quote a shell token (the safe way to embed a literal in a
-- @\/bin\/sh -c@ single-arg command). Any embedded @'@ becomes @'\''@.
-- The URL has already been validated to contain no shell metacharacters,
-- but quoting is defense-in-depth.
shellQ :: Text -> Text
shellQ t = "'" <> T.concatMap (\c -> if c == '\'' then "'\\''" else T.singleton c) t <> "'"