{-# LANGUAGE OverloadedStrings #-}
-- | BIN_EXEC (Untrusted): run a named binary with a list of argv
-- arguments, via 'System.Process.proc' (RawCommand — no shell
-- interpreter) — on the local or remote backend, selected at wiring time
-- via the 'UntrustedIO' capability. The binary name and args are
-- validated 'BinName' / 'BinArg' (reject empty, NUL). An optional
-- operator-configured allow-list (a 'Set' of permitted binary names)
-- gates the binary; when the allow-list is 'Nothing' the binary is
-- permitted by the gate (the autonomy policy still applies). An optional
-- @cwd@ parameter selects the working directory: a relative path is
-- SafePath-confined to the workspace root (the session's workdir); an
-- absolute path is passed through verbatim. When omitted, the executor
-- defaults to the workspace root. All IO through the 'UntrustedIO' seam;
-- this module never imports 'System.Process'.
--
-- **Git credential injection:** when @binary == "git"@, the opcode
-- resolves the cwd's @remote.origin.url@ (via a pre-flight @git config
-- --get remote.origin.url@ — no auth needed, reads @.git/config@), looks
-- it up in the repo registry, and — if the URL matches a registered repo
-- with a credential — resolves the credential via 'resolveCloneTarget'
-- (deploy key: starts the per-repo ssh-agent + injects @SSH_AUTH_SOCK@ /
-- @GIT_SSH_COMMAND@; PAT: injects @GIT_TERMINAL_PROMPT=0@). The git
-- command then runs via 'uioBinExecGitEnv' (agent forwarding for remote
-- deploy keys) or 'uioBinExecEnv' (PAT) instead of 'uioBinExec', so
-- @git fetch@ / @git pull@ / @git push@ authenticate without the model
-- needing to know the credential mechanism. Unregistered repos and
-- non-git binaries fall through to the plain 'uioBinExec' path.
module Seal.ISA.Ops.Bin
  ( binExecOp
  , binExecSchema
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (isAbsolute)

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path
  ( PathError (..), WorkspaceRoot (..), mkSafePathRemote )
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.SourceControl.Clone (CloneEnv (..), renderCloneError)
import Seal.SourceControl.Repo (lookupRepoByUrl, RepoRegistry (..), SourceRepo (srId))
import Seal.Tools.Args (BinArg, BinName, mkBinName, mkBinArg, textBinName)
import Seal.Tools.Exec.UIO
  ( UIO, renderUntrustedErr, uioBinExec, uioBinExecEnv, uioBinExecGitEnv
  )
import Seal.Tools.Exec.UIOGit (uioCdRepoRegList, uioResolveClone, uioWithClone)
import Seal.Tools.Exec.Types (RemotePath, getRemotePath, mkRemotePath)

-- | BIN_EXEC opcode. Input: @{ binary: BinName, args: [BinArg, ...],
-- cwd?: Text }@. The @args@ field is optional (defaults to @[]@); the
-- @binary@ field is required; the @cwd@ field is optional (defaults to
-- the workspace root). When 'sbAllowList' is 'Nothing', any 'BinName'
-- passes the authorize gate (the autonomy policy still applies); when it
-- is @'Just' set@, the binary must be in @set@ or the gate returns
-- 'Denied'.
binExecOp
  :: WorkspaceRoot
  -> SecurityPolicy
  -> Maybe (Set Text)
  -> Opcode
binExecOp wsRoot policy mAllowList = UntrustedOpcode
  { uoName = OpName "BIN_EXEC"
  , uoDesc = "Run a named binary with argv args (no shell, optional allow-list). Git binary gets credential injection from registered repos."
  , uoInSchema = binExecSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case (binaryField v, argsField v) of
        (Nothing, _) -> Left "BIN_EXEC requires {binary:string, args:[string]}"
        (Just binText, mArgsText) ->
          case spAutonomy policy of
            Deny -> Left "BIN_EXEC denied by autonomy policy"
            _    -> case mAllowList of
              Just allowList
                | binText `Set.notMember` allowList ->
                  Left ("BIN_EXEC: binary \"" <> binText <> "\" not in the allow-list")
              _ -> case mkBinName binText of
                     Left _err -> Left "BIN_EXEC: invalid binary name"
                     Right _   -> case traverse mkBinArg <$> mArgsText of
                                    Just (Left _err) -> Left "BIN_EXEC: invalid arg"
                                    _                -> authorizeCwd wsRoot v
  , uoRun = \v -> do
      let mBin  = binaryField v
          mArgs = argsField v
          mCwd  = cwdField v
          recorded = object
            [ "binary" .= mBin
            , "arg_count" .= (fmap length mArgs :: Maybe Int)
            , "cwd" .= mCwd
            ]
      case mBin of
        Nothing -> pure (OpResult [TrpText "BIN_EXEC: missing binary"] True recorded)
        Just binText ->
          case mkBinName binText of
            Left err -> pure (OpResult [TrpText ("BIN_EXEC: invalid binary: " <> err)] True recorded)
            Right bin ->
              case traverse mkBinArg (fromMaybe [] mArgs) of
                   Left err -> pure (OpResult [TrpText ("BIN_EXEC: invalid arg: " <> err)] True recorded)
                   Right args ->
                     case resolveCwd wsRoot mCwd of
                       Left _err ->
                         pure (OpResult [TrpText "BIN_EXEC: invalid cwd"] True recorded)
                       Right mCwdPath -> do
                         if textBinName bin == "git"
                           then runGitWithCredentials bin args mCwdPath recorded
                           else do
                             res <- uioBinExec bin args mCwdPath
                             pure $ case res of
                               Left err   -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                               Right out -> OpResult [TrpText out] False recorded
  }

binExecSchema :: Value
binExecSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "binary" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The binary name (PATH lookup) or path. Must be in the operator allow-list when one is configured." :: Text)
            ]
        , "args" .= object
            [ "type" .= ("array" :: Text)
            , "items" .= object [ "type" .= ("string" :: Text) ]
            , "description" .= ("Argv tokens passed verbatim to the binary (no shell interpretation)." :: Text)
            ]
        , "cwd" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Optional working directory. A relative path is confined to the session workdir; an absolute path is used verbatim. Defaults to the session workdir." :: Text)
            ]
        , "timeout" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .= ("Per-call timeout in seconds; if the tool doesn't finish in this time, it's killed. Default 120, max 600." :: Text)
            ]
        ]
    , "required" .= (["binary"] :: [Text])
    ]

-- | Run a @git@ binary with credential injection when the cwd is inside a
-- registered repo. Pre-flight: resolve the repo root + remote URL (no
-- auth needed — reads @.git/config@), look up the URL in the repo
-- registry, and — if found — resolve the credential via
-- 'resolveCloneTarget' and execute via 'uioBinExecGitEnv' (deploy key:
-- agent forwarding) or 'uioBinExecEnv' (PAT). If the URL is not registered
-- or no credential is resolved, fall through to 'uioBinExec'. Errors
-- from the pre-flight or credential resolution are surfaced (not
-- silently swallowed).
runGitWithCredentials
  :: BinName -> [BinArg] -> Maybe RemotePath -> Value -> UIO OpResult
runGitWithCredentials bin args mCwdPath recorded = do
  -- Pre-flight: resolve the remote URL from the cwd's .git/config.
  -- `git config --get remote.origin.url` reads local config only — no
  -- network, no auth needed.
  mRemoteUrl <- resolveRemoteUrl bin mCwdPath
  case mRemoteUrl of
    Left err -> pure (OpResult [TrpText err] True recorded)
    Right Nothing -> do
      -- Not a git repo (or no remote) — fall through to plain exec.
      res <- uioBinExec bin args mCwdPath
      pure $ case res of
        Left err   -> OpResult [TrpText (renderUntrustedErr err)] True recorded
        Right out -> OpResult [TrpText out] False recorded
    Right (Just remoteUrl) -> do
      -- Look up the URL in the repo registry.
      eRepos <- uioCdRepoRegList
      case eRepos of
        Left err -> pure (OpResult [TrpText ("BIN_EXEC: repo registry error: " <> err)] True recorded)
        Right repos -> do
          let registry = RepoRegistry (Map.fromList [(srId r, r) | r <- repos])
              mRepo = lookupRepoByUrl remoteUrl registry
          case mRepo of
            Nothing -> do
              -- URL not registered — fall through to plain exec (public repo).
              res <- uioBinExec bin args mCwdPath
              pure $ case res of
                Left err   -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                Right out -> OpResult [TrpText out] False recorded
            Just repo -> do
              -- Resolve the credential via the clone seam.
              eTarget <- uioResolveClone repo
              case eTarget of
                Left cloneErr ->
                  pure (OpResult [TrpText ("BIN_EXEC: credential resolution failed: " <> renderCloneError cloneErr)] True recorded)
                Right target ->
                  uioWithClone target $ \cloneEnv -> do
                    let envExtras = ceEnvExtras cloneEnv
                        mKnownHosts = ceKnownHostsContent cloneEnv
                        -- Deploy keys use uioBinExecGitEnv (agent forwarding);
                        -- PATs use uioBinExecEnv (no agent, just env overrides).
                        -- The distinction: deploy keys have SSH_AUTH_SOCK in
                        -- ceEnvExtras; PATs don't.
                        hasAgent = any (\(k, _) -> k == "SSH_AUTH_SOCK") envExtras
                    res <- if hasAgent
                             then uioBinExecGitEnv envExtras mKnownHosts bin args mCwdPath
                             else uioBinExecEnv envExtras bin args mCwdPath
                    pure $ case res of
                      Left err   -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                      Right out -> OpResult [TrpText out] False recorded

-- | Pre-flight: resolve the @remote.origin.url@ from the cwd's git
-- config. Runs @git config --get remote.origin.url@ via 'uioBinExec'
-- (no auth needed — reads @.git/config@). Returns:
--
--   * @Left err@ — the pre-flight git call itself failed (surfacable error).
--   * @Right Nothing@ — the cwd is not inside a git repo, or the repo
--     has no @remote.origin.url@ (fall through to plain exec).
--   * @Right (Just url)@ — the remote URL, trimmed.
resolveRemoteUrl :: BinName -> Maybe RemotePath -> UIO (Either Text (Maybe Text))
resolveRemoteUrl bin mCwdPath = do
  let arg t = case mkBinArg t of
        Right a -> a
        Left _  -> error "unreachable: mkBinArg rejected a literal"
  res <- uioBinExec bin [arg "config", arg "--get", arg "remote.origin.url"] mCwdPath
  pure $ case res of
    Left err -> Left ("BIN_EXEC: pre-flight git config failed: " <> renderUntrustedErr err)
    Right out ->
      let trimmed = T.strip (T.filter (/= '\n') out)
      in if T.null trimmed
           then Right Nothing
           else Right (Just trimmed)

binaryField :: Value -> Maybe Text
binaryField = parseMaybe (withObject "in" (.: "binary"))

-- | Extract the optional @args@ array. Returns 'Nothing' when the field
-- is absent; returns @'Just' []@ when present-but-empty.
argsField :: Value -> Maybe [Text]
argsField = parseMaybe (withObject "in" (.: "args"))

-- | Extract the optional @cwd@ string. Returns 'Nothing' when the field
-- is absent.
cwdField :: Value -> Maybe Text
cwdField v = case parseMaybe (withObject "in" (.:? "cwd")) v :: Maybe (Maybe Text) of
  Just (Just t) -> Just t
  _             -> Nothing

-- | Validate the @cwd@ at the authorize gate. A relative path is
-- SafePath-confined (rejects @..@ escapes + blocked names); an absolute
-- path is accepted verbatim (the operator explicitly chose an
-- out-of-workspace directory). 'mkRemotePath' defends against
-- option-injection (leading dash) + control chars for both kinds.
authorizeCwd :: WorkspaceRoot -> Value -> Either Text ()
authorizeCwd wsRoot v =
  case cwdField v of
    Nothing -> Right ()
    Just cwdText ->
      case mkRemotePath cwdText of
        Left _err -> Left "BIN_EXEC: cwd must not start with '-'"
        Right rp ->
          let rel = T.unpack (getRemotePath rp)
          in if isAbsolute rel
               then Right ()
               else case mkSafePathRemote wsRoot rel of
                      Left pe  -> Left (cwdEscapeErr pe)
                      Right _  -> Right ()

-- | Resolve the @cwd@ to a 'Maybe RemotePath' for the executor. 'Nothing'
-- means the caller omitted @cwd@ → the executor defaults to the workspace
-- root. @'Just' rp@ carries the validated 'RemotePath' (the arm applies
-- SafePath confinement for relative paths, pass-through for absolute).
resolveCwd :: WorkspaceRoot -> Maybe Text -> Either Text (Maybe RemotePath)
resolveCwd _ Nothing = Right Nothing
resolveCwd wsRoot (Just cwdText) =
  case mkRemotePath cwdText of
    Left _err -> Left "BIN_EXEC: cwd must not start with '-'"
    Right rp ->
      let rel = T.unpack (getRemotePath rp)
      in if isAbsolute rel
           then Right (Just rp)
           else case mkSafePathRemote wsRoot rel of
                  Left pe  -> Left (cwdEscapeErr pe)
                  Right _  -> Right (Just rp)

-- | Render a 'PathError' from cwd validation as a user-facing 'Text'.
-- Maps the two confinement failures to stable messages the authorize
-- gate returns (so the test suite can assert on them).
cwdEscapeErr :: PathError -> Text
cwdEscapeErr (PathEscapesWorkspace _) = "BIN_EXEC: cwd escapes the workspace"
cwdEscapeErr (PathIsBlocked _)        = "BIN_EXEC: cwd touches a blocked location"
cwdEscapeErr (PathDoesNotExist _)     = "BIN_EXEC: cwd does not exist"
cwdEscapeErr (PathInsecureMode _)     = "BIN_EXEC: cwd has insecure mode"
