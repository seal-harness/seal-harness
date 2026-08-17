{-# LANGUAGE OverloadedStrings #-}
-- | GIT_FETCH / GIT_PULL / GIT_PUSH opcodes (Untrusted) — design §4.2/§4.3
-- (rev 3). These execute git on the untrusted machine via 'UntrustedIO';
-- a Trusted opcode has no 'UntrustedIO' in scope per 'Seal.ISA.Opcode'.
--
-- Each opcode: resolve the workdir's origin URL via the SSH executor
-- (@git -C <workdir> config --get remote.origin.url@ — the single
-- no-trust-the-sandbox path); @lookupRepoByUrl@ → registry hit → resolve
-- credential (from the closed-over 'CloneDeps') → run
-- @git -C <workdir> fetch/pull/push <refspec>@ via 'uioShellExecEnv'
-- (deploy key: @SSH_AUTH_SOCK@ + @GIT_SSH_COMMAND@ env) or
-- 'uioBinExecEnv' (PAT: @http.extraHeader@ argv) with the resolved env.
-- Registry miss → error naming the origin URL. Vault-locked →
-- distinguishable ('CloneVaultError VaultLocked' surfaced in the result
-- text). Stays Untrusted; credential resolution via 'liftIO' in the
-- trusted plane. NO @runLocal@/@BackendExec@.
--
-- **GIT_PUSH audit** (rev 3 — NO 'TwoFileHandle' closed-over param):
-- @uoRun@ stashes @credential_kind@ + outcome in 'orRecorded' (secret-free).
-- The dispatcher's existing ACK-before-execute ('Dispatch.hs:66', fires
-- for ALL Untrusted opcodes) is the pre-run audit (\"records-then-runs\").
-- A 'Seal.ISA.Dispatch.recordGitPushResult' (mirrors
-- 'recordSetupRepoResult') is called at the 3 dispatch sites AFTER
-- @dispatch@ returns (where 'tHandle' IS in scope) — it reads
-- @credential_kind@ from 'orRecorded' + writes the result entry
-- (secret-free, carrying @credential_kind@ + outcome).
module Seal.ISA.Ops.Git
  ( gitFetchOp
  , gitPullOp
  , gitPushOp
  , resolveOriginUrl
  , runGitRemote
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Clone
  ( CloneDeps (..), CloneEnv (..), renderCloneError
  , resolveCloneTarget, withCloneTarget )
import Seal.SourceControl.Repo
  ( SourceRepo (..), lookupRepoByUrl
  , repoCredentialKindText, RepoRegistry (..) )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.Tools.Args (mkShellCommand, ShellCommand)
import Seal.Tools.Exec.UIO
  ( UIO, renderUntrustedErr, uioLiftIO, uioUntrustedIO )
import Seal.Tools.Exec.UntrustedIO (UntrustedErr, UntrustedIO)
import Seal.Tools.Exec.UntrustedIO qualified as UIORec
  (UntrustedIO (uioShellExec, uioShellExecGitEnv))
import Seal.Tools.Exec.Types (mkRemotePath)

----------------------------------------------------------------------------
-- Opcode constructors
----------------------------------------------------------------------------

-- | GIT_FETCH opcode. Input: @{workdir, remote?, ref?}@. Fetches from the
-- workdir's origin remote using the registered repo's credential (resolved
-- via 'CloneDeps'). Registry miss → error naming the origin URL.
gitFetchOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode
gitFetchOp deps wsRoot autonomy = mkGitOp deps wsRoot autonomy (OpName "GIT_FETCH") "fetch"

-- | GIT_PULL opcode. Input: @{workdir, remote?, ref?}@. Pulls from the
-- workdir's origin remote using the registered repo's credential.
gitPullOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode
gitPullOp deps wsRoot autonomy = mkGitOp deps wsRoot autonomy (OpName "GIT_PULL") "pull"

-- | GIT_PUSH opcode. Input: @{workdir, remote?, refspec?}@. Pushes to the
-- workdir's origin remote using the registered repo's credential. The
-- @uoRun@ stashes @credential_kind@ + outcome in 'orRecorded' (secret-free)
-- so 'Seal.ISA.Dispatch.recordGitPushResult' (called at the dispatch site)
-- can write the audit entry.
gitPushOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode
gitPushOp deps wsRoot autonomy = mkGitOp deps wsRoot autonomy (OpName "GIT_PUSH") "push"

-- | The shared constructor for the 3 git opcodes. The @gitVerb@ is
-- @fetch@/@pull@/@push@. The opcode resolves the workdir's origin URL,
-- looks it up in the registry, resolves the credential via 'CloneDeps',
-- runs @git -C <workdir> <verb> <refspec>@ with the resolved env, and
-- stashes @credential_kind@ + outcome in 'orRecorded' (secret-free).
mkGitOp
  :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> OpName -> Text -> Opcode
mkGitOp deps _wsRoot autonomy opNm gitVerb = UntrustedOpcode
  { uoName = opNm
  , uoDesc = gitOpDesc opNm
  , uoInSchema = gitSchema opNm
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case workdirField v of
        Nothing -> Left (opNameText opNm <> " requires {workdir:string}")
        Just _ -> case autonomy of
          Deny -> Left (opNameText opNm <> " denied by autonomy policy")
          _   -> Right ()
  , uoRun = \v -> do
      let mWorkdir = workdirField v
          mRefspec = refspecField v
          recorded = object
            [ "workdir" .= (mWorkdir :: Maybe Text)
            , "verb" .= gitVerb
            ]
      case mWorkdir of
        Nothing -> pure (OpResult
          [TrpText (opNameText opNm <> " requires {workdir:string}")] True recorded)
        Just workdir -> runGitRemote deps opNm gitVerb workdir mRefspec recorded
  }

opNameText :: OpName -> Text
opNameText (OpName n) = n

gitOpDesc :: OpName -> Text
gitOpDesc (OpName n)
  | n == "GIT_FETCH" = "Fetch from the workdir's origin remote (credential resolved via the repo registry)."
  | n == "GIT_PULL"  = "Pull from the workdir's origin remote (credential resolved via the repo registry)."
  | n == "GIT_PUSH"  = "Push to the workdir's origin remote (credential resolved via the repo registry; audited)."
  | otherwise        = "Git remote operation."

----------------------------------------------------------------------------
-- Schemas
----------------------------------------------------------------------------

gitSchema :: OpName -> Value
gitSchema _opNameNm =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "workdir" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The workspace-relative path to the repo (e.g. \"myrepo\"). The origin URL is read from <workdir>/.git/config." :: Text)
            ]
        , "refspec" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The refspec (e.g. \"main\" for fetch/pull, \"+main:main\" for push). Optional — defaults to the remote's default." :: Text)
            ]
        ]
    , "required" .= (["workdir"] :: [Text])
    ]

workdirField :: Value -> Maybe Text
workdirField = parseMaybe (withObject "in" (.: "workdir"))

refspecField :: Value -> Maybe Text
refspecField v = case parseMaybe (withObject "in" (.:? "refspec")) v of
  Just (Just r) -> Just r
  _             -> Nothing

----------------------------------------------------------------------------
-- runGitRemote — the shared credential-resolution + git-run logic
----------------------------------------------------------------------------

-- | Run a git remote operation (fetch/pull/push) on the workdir's origin
-- remote. Resolves the origin URL via the SSH executor, looks it up in the
-- registry, resolves the credential via 'CloneDeps', runs the git command
-- with the resolved env, and stashes @credential_kind@ + outcome in
-- 'orRecorded' (secret-free — for GIT_PUSH audit).
runGitRemote
  :: CloneDeps -> OpName -> Text -> Text -> Maybe Text -> Value
  -> UIO OpResult
runGitRemote deps opNm gitVerb workdir mRefspec recorded = do
  uio <- uioUntrustedIO
  -- 1. Resolve the origin URL via the SSH executor (the single
  --    no-trust-the-sandbox path).
  eOrigin <- uioLiftIO (resolveOriginUrl uio workdir)
  case eOrigin of
    Left err -> pure (mkErr opNm ("could not read origin URL: " <> err) recorded)
    Right originUrl -> do
      -- 2. Look up the origin URL in the registry.
      eRepos <- uioLiftIO (rrhList (cdRepoReg deps))
      let mRepo = case eRepos of
            Right repos -> lookupRepoByUrl originUrl
                               (RepoRegistry (Map.fromList [(srId r, r) | r <- repos]))
            Left _       -> Nothing
      case mRepo of
        Nothing -> pure (mkErr opNm
          ("no registered repo matches origin URL " <> originUrl
           <> " — register it first via /repo add or POST /api/repos")
          recorded)
        Just repo -> do
          -- 3. Resolve the credential via the no-disk seam.
          eTarget <- uioLiftIO (resolveCloneTarget deps repo)
          case eTarget of
            Left err -> pure (mkErr opNm (renderCloneError err) recorded)
            Right target -> do
              -- 4. Run the git command with the resolved env.
              let credKind = repoCredentialKindText (srCredential repo)
              eRes <- uioLiftIO (withCloneTarget target $ \env ->
                runGitCommand uio env gitVerb workdir mRefspec)
              case eRes of
                Left err -> pure (mkErr opNm (renderUntrustedErr err)
                                   (recordWithCred recorded credKind "failed"))
                Right out -> pure (OpResult
                  [TrpText (opNameText opNm <> " " <> gitVerb <> " succeeded: " <> T.strip (T.filter (/= '\n') out))]
                  False (recordWithCred recorded credKind "ok"))

-- | Resolve the origin URL of a workdir via @git -C <workdir> config --get
-- remote.origin.url@. This is the single no-trust-the-sandbox path: the
-- workdir path is a workspace-relative path (validated by 'SafePath' in the
-- 'uioShellExec' arm), and the URL is read from git's config, NOT from any
-- caller-supplied input. Returns 'Left' with an error message if the git
-- command fails.
resolveOriginUrl :: UntrustedIO -> Text -> IO (Either Text Text)
resolveOriginUrl uio workdir = do
  let mCwdPath = case mkRemotePath workdir of
        Right rp -> Just rp
        Left _   -> Nothing
      cmd = "git config --get remote.origin.url"
  res <- UIORec.uioShellExec uio (shellCmd cmd) mCwdPath
  pure $ case res of
    Left err -> Left (renderUntrustedErr err)
    Right out
      | T.null (T.strip out) -> Left "no remote.origin.url configured"
      | otherwise -> Right (T.strip (T.filter (/= '\n') out))

-- | Run @git -C <workdir> <verb> [refspec]@ with the resolved env (deploy
-- key: @SSH_AUTH_SOCK@ + @GIT_SSH_COMMAND@; PAT: @http.extraHeader@ argv).
-- The env is merged over the inherited environment by 'uioShellExecEnv'.
runGitCommand
  :: UntrustedIO -> CloneEnv -> Text -> Text -> Maybe Text
  -> IO (Either UntrustedErr Text)
runGitCommand uio env gitVerb workdir mRefspec = do
  let mCwdPath = case mkRemotePath workdir of
        Right rp -> Just rp
        Left _   -> Nothing
      gitConfigArgs = T.unwords (ceGitConfigArgs env)
      refspecArg = maybe "" (\r -> " " <> shellQ r) mRefspec
      cmd = T.strip ("git " <> gitConfigArgs <> " " <> gitVerb <> refspecArg)
  UIORec.uioShellExecGitEnv uio (ceEnvExtras env) (ceKnownHostsContent env) (shellCmd cmd) mCwdPath

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- | Build an error 'OpResult' (carries the error text + the recorded input;
-- no credential_kind — the credential wasn't resolved).
mkErr :: OpName -> Text -> Value -> OpResult
mkErr opNm msg =
  OpResult [TrpText (opNameText opNm <> ": " <> msg)] True

-- | Re-build the recorded object with @credential_kind@ + a status (for
-- GIT_PUSH audit — secret-free; the credential_kind is a public string like
-- @pat@ / @deploy_key@ / @machine_user@, NOT the secret itself). Merges
-- into the base recorded object (which carries @workdir@ + @verb@) so the
-- audit entry is complete: @{workdir, verb, credential_kind, status}@.
recordWithCred :: Value -> Text -> Text -> Value
recordWithCred base credKind status =
  case base of
    A.Object o -> A.Object
      ( KM.insert "credential_kind" (A.String credKind)
      ( KM.insert "status" (A.String status) o ) )
    _ -> object [ "credential_kind" .= credKind, "status" .= status ]

-- | Construct a 'ShellCommand', total on internally-built command strings.
shellCmd :: Text -> ShellCommand
shellCmd t = case mkShellCommand t of
  Right c  -> c
  Left _e  -> error "Git opcodes: internal: shell command rejected (NUL?) — unreachable"

-- | Single-quote a shell token (defense-in-depth).
shellQ :: Text -> Text
shellQ t = "'" <> T.concatMap (\c -> if c == '\'' then "'\\''" else T.singleton c) t <> "'"