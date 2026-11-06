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
--   * Optional @branch@ (@{url, branch}@): a fresh clone checks that branch
--     (or tag — a tag yields a detached HEAD) out via a single
--     @--branch=\<ref\>@ argv token. The value reaches a subprocess argv, so
--     it is carried by the validated 'Seal.Tools.Args.BranchName' newtype,
--     never raw 'Text'.
--   * Idempotent: if the target dir already holds a clone of the same
--     remote URL and the requested branch is already checked out, the call
--     is a no-op (\"Repo already exists — no-op\"). A differing / unknown /
--     detached current branch is SWITCHED ('switchBranch': fetch the branch
--     ref at depth 1, then check it out) — never a re-clone, and the
--     directory is never deleted.
--     If the dir exists but its remote differs, the call errors (\"a
--     different repo already occupies that path\") rather than silently
--     clobbering.
--   * The clone runs in the workspace root (cwd = workdir) via
--     'uioShellExec'; the URL is validated to a safe charset so it cannot
--     inject shell metacharacters into the @\/bin\/sh -c@ single-arg
--     boundary.
--
-- Credential resolution (W3 — design §4.2/§4.3, rev 3): 'setupRepoOp' takes
-- a 'CloneDeps' closed-over param (mirrors @secretManageOp (cdVault deps)@).
-- 'cloneRepoIO' does @lookupRepoByUrl@ against the registry
-- (@cdRepoReg@) → if the URL matches a registered repo, resolve the
-- credential via the no-disk seam ('Seal.SourceControl.Clone.resolveCloneTarget'
-- using @cdVault@/@cdSshAgent@/@cdPinnedKnownHosts@/@cdKeyfilesDir@) and
-- clones via @gh repo clone@ with @GH_TOKEN@ (PAT/MachineUser: the raw
-- token from 'ceRawToken' injected as @GH_TOKEN@ env) or @git clone@ via
-- 'uioShellExecGitEnv' (deploy key: @SSH_AUTH_SOCK@ + @GIT_SSH_COMMAND@).
-- If the URL is NOT registered, fall through to a bare-URL clone (public
-- repos, backward-compat). Stays Untrusted; credential resolution via
-- 'liftIO' in the trusted plane. NO @runLocal@/@BackendExec@.
module Seal.ISA.Ops.Repo
  ( setupRepoOp
  , runSetupRepo
  , parseSetupRepoInput
  , parseRepoProbe
  , renderCloneResult
  , SwitchTransport (..)
  , switchTransport
  , validateRepoUrl
  , sanitizeRepoName
  , normalizeRepoUrl
  , isShellMetachar
  , CloneResult (..)
  , cloneRepoIO
  , tryCodegraphInit
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.Char (isAlphaNum)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.SourceControl.Clone
  ( CloneDeps (..), CloneEnv (..), renderCloneError, resolveCloneTarget
  , withCloneTarget )
import Seal.SourceControl.Repo (normalizeRepoUrl, lookupRepoByUrl, SourceRepo (..), RepoRegistry (..))
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.Tools.Args
  ( BranchName, branchNameText, mkBranchName, mkShellCommand, ShellCommand )
import Seal.Tools.Exec.UIO
  ( UIO, renderUntrustedErr, uioLiftIO, uioUntrustedIO )
import Seal.Tools.Exec.UntrustedIO (UntrustedIO)
import Seal.Tools.Exec.UntrustedIO qualified as UIORec
  (UntrustedIO (uioShellExec, uioShellExecEnv, uioShellExecGitEnv))
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath)

-- | SETUP_REPO opcode. Input: @{url: Text, branch?: Text}@. Authorize:
-- autonomy must not be 'Deny' and the input must parse + validate
-- ('parseSetupRepoInput'). Run: a shallow @git clone@ into
-- @\<workdir\>\/\<sanitized-repo-name\>@ via 'uioShellExec', after a
-- branch-aware idempotency check (read the existing remote + the branch it
-- has checked out). 'orRecorded': the target path + status (secret-free).
--
-- No 'WorkspaceRoot' argument: the clone's root is the 'UIOEnv' the
-- dispatcher supplies (the per-session workdir), so the opcode never needs
-- one — and the delegation worker (which has no workspace root in scope but
-- does have the child's 'UIOEnv') can build this op for a handoff session's
-- pre-turn checkout.
setupRepoOp :: CloneDeps -> AutonomyLevel -> Opcode
setupRepoOp deps autonomy = UntrustedOpcode
  { uoName = OpName "SETUP_REPO"
  , uoDesc = "Clone a remote repository into the session workspace (shallow, idempotent; an optional branch or tag is checked out). Discover any skills it ships via the available-skills catalog on the next turn."
  , uoInSchema = setupRepoSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case parseSetupRepoInput v of
        Left err -> Left err
        Right _ -> case autonomy of
          Deny -> Left "SETUP_REPO denied by autonomy policy"
          _    -> Right ()
  , uoRun = \v ->
      let recorded = object [ "url" .= (urlField v :: Maybe Text) ]
      in case parseSetupRepoInput v of
           Left err -> pure (OpResult [TrpText err] True recorded)
           Right (url, mBranch) -> runSetupRepo deps url mBranch recorded
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
        , "branch" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The branch or tag to check out. Omit to use the remote's default branch." :: Text)
            ]
        ]
    , "required" .= (["url"] :: [Text])
    ]

urlField :: Value -> Maybe Text
urlField = parseMaybe (withObject "in" (.: "url"))

-- | The optional @branch@ field. An absent field, @null@, or a non-string
-- value is treated as absent (the remote's default branch).
branchField :: Value -> Maybe Text
branchField v = case parseMaybe (withObject "in" (.:? "branch")) v of
  Just (Just b) -> Just b
  _             -> Nothing

-- | Parse + validate the SETUP_REPO input into the cloned URL and the
-- optional 'BranchName'. Shared by 'uoAuthorize' and 'uoRun' so the two
-- cannot disagree about what a valid input is. An absent, empty, or
-- whitespace-only @branch@ is 'Nothing'. The 'Left' arm is the
-- user-facing message (the callers render it verbatim).
parseSetupRepoInput :: Value -> Either Text (Text, Maybe BranchName)
parseSetupRepoInput v = do
  rawUrl <- case urlField v of
    Just u  -> Right u
    Nothing -> Left "SETUP_REPO requires {url:string}"
  url <- case validateRepoUrl rawUrl of
    Right u  -> Right u
    Left err -> Left ("SETUP_REPO: invalid url: " <> err)
  mBranch <- case branchField v of
    Nothing -> Right Nothing
    Just raw
      | T.null (T.strip raw) -> Right Nothing
      | otherwise -> case mkBranchName raw of
          Right b  -> Right (Just b)
          Left err -> Left ("SETUP_REPO: invalid branch: " <> err)
  pure (url, mBranch)

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
  | CloneNoop Text      -- ^ repo already exists at <repo-name> (branch matches)
  | CloneConflict Text Text  -- ^ a different repo occupies <repo-name> (existing url)
  | CloneSwitched Text Text  -- ^ switched an existing clone to <branch> (<repo-name>)
  | CloneFailed Text    -- ^ clone, switch, or idempotency check failed (<error>)
  deriving stock (Eq, Show)

-- | Which executor arm a branch SWITCH uses, chosen from the resolved
-- credential kind (mirrors 'cloneWithCredential''s dispatch).
--
-- A PAT / machine-user credential is delivered as
-- @GIT_CONFIG_PARAMETERS='http.extraHeader=Authorization: Basic …'@ inside
-- 'ceEnvExtras'. @GIT_CONFIG_PARAMETERS@ is a member of
-- 'Seal.Tools.Exec.UntrustedIO.secretEnvKeys', so the remote arm of
-- 'uioShellExecEnv' pipes it over SSH **stdin** instead of rendering it into
-- the remote command string. @uioShellExecGitEnv@'s remote arm instead
-- renders the extras into the remote command prefix — using it for a PAT
-- switch would put the @Authorization@ header on the remote argv. Hence:
-- secret-bearing credential → 'SwitchViaShellEnv'; deploy key (agent
-- forwarding, no secret in the env) → 'SwitchViaGitEnv'.
data SwitchTransport
  = SwitchViaShellEnv  -- ^ PAT / machine user (@ceRawToken@ is 'Just')
  | SwitchViaGitEnv    -- ^ deploy key (@ceRawToken@ is 'Nothing')
  deriving stock (Eq, Show)

-- | Pick the switch executor arm from the resolved credential: a raw token
-- means a PAT/machine-user credential (see 'SwitchTransport'); no token
-- means a deploy key.
switchTransport :: Maybe ByteString -> SwitchTransport
switchTransport (Just _rawToken) = SwitchViaShellEnv
switchTransport Nothing          = SwitchViaGitEnv

-- | The @--branch=\<ref\>@ argv token for a requested branch — a SINGLE
-- token (@--branch='x'@, never @--branch x@), so the value can never be
-- read as a separate option. Empty when no branch was requested, so the
-- emitted clone command is byte-identical to the pre-branch one.
branchFlag :: Maybe BranchName -> Text
branchFlag Nothing  = ""
branchFlag (Just b) = " --branch=" <> shellQ (branchNameText b)

-- | Parse the idempotency-probe output: the existing clone's origin URL,
-- then (second line) the branch @git@ currently has checked out
-- (@git rev-parse --abbrev-ref HEAD@ — the literal @HEAD@ for a detached
-- checkout). A one-line response is tolerated: the current branch is then
-- unknown ('Nothing'), which is what the remote test fixture's
-- @\"__NONE__\\n\"@ reply produces. A @\"__NONE__\"@ URL means "no clone
-- here".
parseRepoProbe :: Text -> (Text, Maybe Text)
parseRepoProbe out = case T.lines out of
  []             -> ("", Nothing)
  (urlLine : ls) -> (T.strip urlLine, firstNonBlank ls)

-- | The first non-blank line of a (possibly empty) list of lines.
firstNonBlank :: [Text] -> Maybe Text
firstNonBlank [] = Nothing
firstNonBlank (l : ls)
  | T.null (T.strip l) = firstNonBlank ls
  | otherwise          = Just (T.strip l)

-- | The first line of a command's output, trimmed (reads
-- @rev-parse --abbrev-ref HEAD@).
firstLine :: Text -> Text
firstLine t = case T.lines t of
  (l : _) -> T.strip l
  []      -> ""

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
--
-- With @mBranch@: a fresh clone checks that branch out ('branchFlag'); an
-- existing clone of the same repo is switched when the branch differs
-- ('switchBranch'), and a no-op when it already matches.
cloneRepoIO :: CloneDeps -> UntrustedIO -> Text -> Maybe BranchName -> IO CloneResult
cloneRepoIO deps uio url mBranch = do
  let repoName = sanitizeRepoName url
      cleanUrl = T.strip url
      mCwdPath = case mkRemotePath "." of
        Right rp -> Just rp
        Left _   -> Nothing
      -- Idempotency probe: the existing origin URL, then the branch git
      -- currently has checked out (a second line — see 'parseRepoProbe').
      checkCmd = "if [ -d " <> shellQ repoName <> "/.git ]; then git -C "
                 <> shellQ repoName <> " config --get remote.origin.url; git -C "
                 <> shellQ repoName <> " rev-parse --abbrev-ref HEAD; else rm -rf "
                 <> shellQ repoName <> "; echo __NONE__; fi"
      -- No clone yet: look the URL up in the repo registry. If registered,
      -- resolve the credential via the no-disk seam; else fall through to a
      -- bare-URL clone (public repos).
      cloneFresh = do
        eRepos <- rrhList (cdRepoReg deps)
        let mRepo = case eRepos of
              Right repos -> lookupRepoByUrl cleanUrl
                               (RepoRegistry (Map.fromList [(srId r, r) | r <- repos]))
              Left _      -> Nothing
        case mRepo of
          Just repo -> cloneWithCredential deps uio repo repoName mBranch mCwdPath
          Nothing   -> cloneBareUrl uio cleanUrl repoName mBranch mCwdPath
  checkRes <- UIORec.uioShellExec uio (shellCmd checkCmd) mCwdPath
  case checkRes of
    Left err -> pure (CloneFailed ("idempotency check failed: " <> renderUntrustedErr err))
    Right out -> case parseRepoProbe out of
      (existingUrl, mCurrent)
        | existingUrl == "__NONE__" -> cloneFresh
        | normalizeRepoUrl existingUrl /= normalizeRepoUrl cleanUrl ->
            pure (CloneConflict repoName existingUrl)
        | otherwise -> case mBranch of
            -- No branch requested: same repo ⇒ no-op (unchanged behavior).
            Nothing -> pure (CloneNoop repoName)
            -- Requested branch already checked out ⇒ no-op. A differing,
            -- unknown, or detached ("HEAD") current branch ⇒ switch.
            Just b
              | mCurrent == Just (branchNameText b) -> pure (CloneNoop repoName)
              | otherwise -> switchBranch deps uio cleanUrl repoName b mCwdPath

-- | Clone a registered repo via the no-disk seam. Resolves the credential
-- via 'resolveCloneTarget', then branches on the credential kind:
--
--   * **PAT/MachineUser** ('ceRawToken' is 'Just'): clones via
--     @gh repo clone <url> <dest> -- --depth 1@ with @GH_TOKEN@ injected
--     into the process env. This mirrors the BIN_EXEC @gh@ path
--     ('runGhWithCredentials' in "Seal.ISA.Ops.Bin") — the raw token
--     bytes (from 'ceRawToken') go to @GH_TOKEN@, never to argv or disk.
--     @gh@ authenticates via the token, not via @http.extraHeader@.
--
--   * **Deploy key** ('ceRawToken' is 'Nothing'): clones via
--     @git clone@ with the agent-forwarding env (@SSH_AUTH_SOCK@ /
--     @GIT_SSH_COMMAND@) — @gh@ cannot use an SSH agent.
cloneWithCredential
  :: CloneDeps -> UntrustedIO -> SourceRepo -> Text -> Maybe BranchName
  -> Maybe RemotePath -> IO CloneResult
cloneWithCredential deps uio repo repoName mBranch mCwdPath = do
  eTarget <- resolveCloneTarget deps repo
  case eTarget of
    Left err -> pure (CloneFailed ("credential resolution failed: " <> renderCloneError err))
    Right target -> withCloneTarget target $ \env -> do
      case ceRawToken env of
        Just tokenBytes -> do
          let token = map (toEnum . fromIntegral) (BS.unpack tokenBytes)
              envExtras = ("GH_TOKEN", token) : ceEnvExtras env
              ghCmd = "gh repo clone " <> shellQ (ceUrl env) <> " "
                      <> shellQ repoName <> " -- --depth 1" <> branchFlag mBranch
          cloneRes <- UIORec.uioShellExecEnv uio envExtras (shellCmd ghCmd) mCwdPath
          case cloneRes of
            Left err -> pure (CloneFailed ("clone failed (transport): " <> renderUntrustedErr err))
            Right _out -> verifyClone uio repoName _out mCwdPath
        Nothing -> do
          let gitConfigArgs = map T.unpack (ceGitConfigArgs env)
              cloneCmd = "git " <> T.unwords (map T.pack gitConfigArgs)
                         <> " clone --depth 1" <> branchFlag mBranch
                         <> " -- " <> shellQ (ceUrl env) <> " " <> shellQ repoName
          cloneRes <- UIORec.uioShellExecGitEnv uio (ceEnvExtras env) (ceKnownHostsContent env) (shellCmd cloneCmd) mCwdPath
          case cloneRes of
            Left err -> pure (CloneFailed ("clone failed (transport): " <> renderUntrustedErr err))
            Right _out -> verifyClone uio repoName _out mCwdPath

-- | Clone a bare URL (no credential — public repo, backward-compat).
cloneBareUrl
  :: UntrustedIO -> Text -> Text -> Maybe BranchName -> Maybe RemotePath
  -> IO CloneResult
cloneBareUrl uio cleanUrl repoName mBranch mCwdPath = do
  let cloneCmd = "git clone --depth 1" <> branchFlag mBranch
                 <> " -- " <> shellQ cleanUrl <> " " <> shellQ repoName
  cloneRes <- UIORec.uioShellExec uio (shellCmd cloneCmd) mCwdPath
  case cloneRes of
    Left err -> pure (CloneFailed ("clone failed (transport): " <> renderUntrustedErr err))
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
      | "__OK__" `T.isInfixOf` vOut -> do
          _ <- tryCodegraphInit uio repoName mCwdPath
          pure (CloneCloned repoName)
      | otherwise -> pure (CloneFailed
                            ("clone did not land — git output:\n"
                             <> T.strip cloneOut))

-- | Switch an EXISTING clone to @branch@ (the idempotent second call with a
-- different branch) without re-cloning. The credential is resolved exactly
-- like 'cloneRepoIO' does (registry lookup → 'resolveCloneTarget' →
-- 'withCloneTarget'), then ONE shell command runs: check the branch out if
-- it already exists locally, else fetch its ref at depth 1 and check it
-- out. The fetch refspec is fully qualified (@refs\/heads\/\<b\>@), so a tag
-- name fails loudly instead of DWIM-ing to the tag. The result is verified
-- with @rev-parse --abbrev-ref HEAD@; on a mismatch 'CloneFailed' carries
-- git's output and the directory (plus any work in it) is left intact —
-- never deleted. On success 'tryCodegraphInit' re-runs (the graph would
-- otherwise describe the old branch) and the result is 'CloneSwitched'.
switchBranch
  :: CloneDeps -> UntrustedIO -> Text -> Text -> BranchName -> Maybe RemotePath
  -> IO CloneResult
switchBranch deps uio cleanUrl repoName branch mCwdPath = do
  eRepos <- rrhList (cdRepoReg deps)
  let mRepo = case eRepos of
        Right repos -> lookupRepoByUrl cleanUrl
                         (RepoRegistry (Map.fromList [(srId r, r) | r <- repos]))
        Left _      -> Nothing
  case mRepo of
    -- Unregistered (public) repo: no credential to resolve.
    Nothing -> runSwitch (UIORec.uioShellExec uio) (shellCmd (switchCmd repoName b))
    Just repo -> do
      eTarget <- resolveCloneTarget deps repo
      case eTarget of
        Left err -> pure (CloneFailed ("credential resolution failed: " <> renderCloneError err))
        Right target -> withCloneTarget target $ \env ->
          runSwitch (switchExec env) (shellCmd (switchCmd repoName b))
  where
    b = branchNameText branch
    -- Dispatch on the credential kind (see 'SwitchTransport'): a PAT must
    -- ride 'uioShellExecEnv' (secret extras over stdin on the remote arm).
    switchExec env = case switchTransport (ceRawToken env) of
      SwitchViaShellEnv -> UIORec.uioShellExecEnv uio (ceEnvExtras env)
      SwitchViaGitEnv ->
        UIORec.uioShellExecGitEnv uio (ceEnvExtras env) (ceKnownHostsContent env)
    runSwitch exec cmd = do
      res <- exec cmd mCwdPath
      case res of
        Left err -> pure (CloneFailed ("switch failed (transport): " <> renderUntrustedErr err))
        Right out -> verifySwitch exec out
    verifySwitch exec switchOut = do
      let verifyCmd = "git -C " <> shellQ repoName <> " rev-parse --abbrev-ref HEAD"
      vRes <- exec (shellCmd verifyCmd) mCwdPath
      case vRes of
        Left err -> pure (CloneFailed ("switch verify failed: " <> renderUntrustedErr err))
        Right vOut
          | firstLine vOut == b -> do
              _ <- tryCodegraphInit uio repoName mCwdPath
              pure (CloneSwitched repoName b)
          | otherwise -> pure (CloneFailed
              ("switch to " <> b <> " did not take — git output:\n"
               <> T.strip switchOut <> "\n" <> T.strip vOut))

-- | The one shell command that moves an existing clone onto @branch@:
-- check it out directly when the local branch ref exists, otherwise fetch
-- that branch's ref (at depth 1) into a local branch ref and check it out.
-- Every interpolated value is shell-quoted.
switchCmd :: Text -> Text -> Text
switchCmd repoName b =
  "if git -C " <> qr <> " rev-parse --verify --quiet " <> shellQ ("refs/heads/" <> b)
    <> " >/dev/null\n"
  <> "then git -C " <> qr <> " checkout " <> shellQ b <> "\n"
  <> "else git -C " <> qr <> " fetch --depth 1 origin "
    <> shellQ ("refs/heads/" <> b <> ":refs/heads/" <> b)
    <> " && git -C " <> qr <> " checkout " <> shellQ b <> "\n"
  <> "fi"
  where
    qr = shellQ repoName

-- | Render a 'CloneResult' as the user-facing text. @url@ is the requested
-- URL and @mBranch@ the requested branch (if any) — 'CloneCloned' and
-- 'CloneNoop' carry only the repo name, so the branch is passed in.
renderCloneResult :: Text -> Maybe Text -> CloneResult -> Text
renderCloneResult url mBranch res = case res of
  CloneCloned name ->
    "Cloned " <> T.strip url <> " into " <> name <> " (shallow"
      <> branchNote mBranch <> ")."
  CloneNoop name ->
    "Repo already exists — no-op (" <> name <> branchNote mBranch <> ")."
  CloneConflict name existing ->
    "A different repo already occupies " <> name <> " (existing: " <> existing <> ")."
  CloneSwitched name b ->
    "Repo already exists — switched to branch " <> b <> " (" <> name <> ")."
  CloneFailed err ->
    "SETUP_REPO failed — could not clone " <> T.strip url <> ":\n" <> err
  where
    branchNote = maybe "" (", branch " <>)

-- | Run the clone (or no-op / switch) and build the 'OpResult' (opcode
-- path; wraps 'cloneRepoIO' with the audit 'orRecorded' payload). A
-- 'CloneSwitched' is a NON-error result (the clone is usable on the
-- requested branch — the turn engine's post-repo hooks must still run).
runSetupRepo :: CloneDeps -> Text -> Maybe BranchName -> Value -> UIO OpResult
runSetupRepo deps url mBranch recorded = do
  uio <- uioUntrustedIO
  res <- uioLiftIO (cloneRepoIO deps uio url mBranch)
  let (target, status, isErr) = case res of
        CloneCloned name      -> (name, "cloned", False)
        CloneNoop name        -> (name, "noop", False)
        CloneConflict name _  -> (name, "conflict", True)
        CloneSwitched name _  -> (name, "switched", False)
        CloneFailed _         -> ("", "failed", True)
  pure (OpResult [TrpText (renderCloneResult url (branchNameText <$> mBranch) res)]
                 isErr (recordWith recorded target status))

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

-- | Best-effort: run @codegraph init@ in the freshly cloned repo directory
-- so the agent has a pre-built knowledge graph on the next turn. This is
-- a soft-failure operation — if @codegraph@ is not installed (exit 127) or
-- fails for any reason (unsupported language, large repo, etc.), the
-- clone result is unaffected. The @codegraph@ binary is looked up via
-- @command -v@ first so we don't spawn a process we know will fail; if
-- not found, we skip silently.
--
-- Security: this runs on the untrusted plane via 'uioShellExec', which is
-- correct — @codegraph init@ parses untrusted repo content (tree-sitter on
-- upstream code). No new attack surface is introduced.
tryCodegraphInit :: UntrustedIO -> Text -> Maybe RemotePath -> IO ()
tryCodegraphInit uio repoName mCwdPath = do
  -- Check if codegraph is installed (command -v returns 0 if found).
  let checkCmd = "command -v codegraph >/dev/null 2>&1"
  checkRes <- UIORec.uioShellExec uio (shellCmd checkCmd) mCwdPath
  case checkRes of
    Left _ -> pure ()   -- uioShellExec failed entirely — skip
    Right _ -> do
      -- codegraph exists; run init with the repo directory as cwd.
      -- @codegraph init@ (no path arg) initializes the project in the
      -- current directory. The @|| true@ ensures best-effort: any failure
      -- (unsupported language, etc.) is swallowed.
      let repoPath = case mkRemotePath repoName of
            Right rp -> Just rp
            Left _   -> Nothing
      let initCmd = "codegraph init 2>&1 || true"
      _ <- UIORec.uioShellExec uio (shellCmd initCmd) repoPath
      pure ()
