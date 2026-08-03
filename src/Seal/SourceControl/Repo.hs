{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
-- | Source-control repository registry — the typed model + bidirectional
-- TOML codec + URL helpers for the seal-harness repo-clone seam (design
-- §4.1, §4.2).
--
-- Security invariants (enforced by construction):
--
-- * 'RepoId' is never used to construct a 'FilePath' — it is only a 'Map' key.
--   The charset predicate ('isValidRepoId') forbids @\/@, @\\@, @.@ and
--   whitespace, neutralizing path-traversal by construction.
--
-- * 'cUsername' is a public handle (a GitHub bot account name), NOT a secret.
--   It is stored in plaintext TOML and returned in API responses intentionally.
--   Secret /values/ live in the vault and are retrieved by 'cVaultKey' (a key
--   name) at clone time; this module never touches secret bytes.
module Seal.SourceControl.Repo
  ( VcsKind (..)
  , RepoCredential (..)
  , SourceRepo (..)
  , RepoRegistry (..)
  , RepoId (..)
  , mkRepoId
  , repoIdText
  , isValidRepoId
  , repoCodec
  , repoRegistryCodec
  , normalizeReposTable
  , normalizeRepoUrl
  , lookupRepoByUrl
  , parseRepoHost
  , hostAllowed
  , urlShapeValid
  , githubHosts
  , repoCredentialKindText
  , parseCredentialKind
  , vcsKindText
  , parseVcsKind
  ) where

import Control.Applicative ((<|>), empty)
import Control.Monad (void)
import Control.Monad.State (modify)
import Data.Aeson
  ( FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?) )
import Data.Aeson qualified as Aeson ((.=))
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.HashMap.Strict qualified as HashMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified
import Toml.Codec.BiMap (BiMap (..), TomlBiMap, TomlBiMapError (..))
import Toml.Codec.Error (TomlDecodeError (..))
import Toml.Codec.Types (Codec (..), TomlCodec, TomlState, eitherToTomlState)
import Toml.Parser (parseKey, unTomlParseError)
import Toml.Type.Key (Key, pattern (:||))
import Toml.Type.Printer (prettyKey)
import Toml.Type.TOML (TOML (..), insertKeyAnyVal)

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------

-- | The VCS kind of a 'SourceRepo'. @git@ is a plain Git server; @github@ is
-- GitHub (or a GitHub-protocol-compatible host). Used to pick the clone
-- strategy in W3's @planClone@.
data VcsKind = VcsGit | VcsGitHub
  deriving stock (Eq, Show)

-- | The credential bound to a 'SourceRepo'. Carries only vault key /names/ and
-- (for 'CredMachineUser') a public username — never secret bytes.
data RepoCredential
  = CredPat         { cVaultKey :: Text }
    -- ^ A personal access token (or fine-grained PAT); vault key → token bytes.
  | CredDeployKey   { cVaultKey :: Text }
    -- ^ An SSH deploy key; vault key → private key bytes.
  | CredMachineUser { cVaultKey :: Text, cUsername :: Text }
    -- ^ A machine-user HTTPS clone: vault key → token, plus a public bot handle.
    -- @cUsername@ is a public handle (a GitHub bot account name), NOT a secret.
  deriving stock (Eq, Show)

data SourceRepo = SourceRepo
  { srId         :: RepoId
  , srUrl        :: Text
  , srVcsKind    :: VcsKind
  , srCredential :: RepoCredential
  } deriving stock (Eq, Show)

-- | The source-control repo registry: a keyed-by-id map of 'SourceRepo's.
-- Defined here (in the pure type module) so 'lookupRepoByUrl' can consume it
-- without importing the IO-laden "Seal.SourceControl.Registry" (which would
-- create a cycle). "Seal.SourceControl.Registry" re-exports it.
newtype RepoRegistry = RepoRegistry { rrRepos :: Map RepoId SourceRepo }
  deriving stock (Eq, Show)

-- | Opaque repo key. Smart-constructed via 'mkRepoId'; the charset predicate
-- guards every Map position. 'RepoId' is never used to construct a 'FilePath'
-- — it is only a 'Map' key.
newtype RepoId = RepoId Text
  deriving stock (Eq, Ord, Show)

-- | @[A-Za-z0-9_-]+@, non-empty, no leading @\.@. Mirrors
-- 'Seal.Skills.Types.isValidSkillId'.
isValidRepoId :: Text -> Bool
isValidRepoId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all (`elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

mkRepoId :: Text -> Either Text RepoId
mkRepoId t
  | isValidRepoId t = Right (RepoId t)
  | otherwise       = Left ("invalid repo id: " <> T.pack (show t))

repoIdText :: RepoId -> Text
repoIdText (RepoId t) = t

----------------------------------------------------------------------------
-- Enum text helpers
----------------------------------------------------------------------------

vcsKindText :: VcsKind -> Text
vcsKindText VcsGit    = "git"
vcsKindText VcsGitHub = "github"

parseVcsKind :: Text -> Either Text VcsKind
parseVcsKind "git"    = Right VcsGit
parseVcsKind "github" = Right VcsGitHub
parseVcsKind other    = Left ("unknown vcs_kind: " <> other)

repoCredentialKindText :: RepoCredential -> Text
repoCredentialKindText CredPat{}         = "pat"
repoCredentialKindText CredDeployKey{}   = "deploy_key"
repoCredentialKindText CredMachineUser{} = "machine_user"

-- | Build a 'RepoCredential' from a wire kind + a vault key name + an optional
-- username. Validates that @machine_user@ carries a non-empty username and
-- that the vault key is non-empty. Used by the REST API (W4) and slash UI (W5).
--
-- @account_key@ is a /reserved/ credential kind (a future constructor may add
-- it; until then it fails-closed so a repo registered with @account_key@
-- cannot decode — the registry MUST NOT silently accept an unknown kind).
parseCredentialKind :: Text -> Text -> Maybe Text -> Either Text RepoCredential
parseCredentialKind kind vaultKey mUsername
  | T.null vaultKey = Left "credential vault_key must be non-empty"
  | kind == "pat"          = Right (CredPat vaultKey)
  | kind == "deploy_key"   = Right (CredDeployKey vaultKey)
  | kind == "machine_user" =
      case mUsername of
        Just u | not (T.null u) -> Right (CredMachineUser vaultKey u)
        _                       -> Left "machine_user requires a non-empty username"
  | kind == "account_key" = Left "account_key credential kind is reserved (not yet supported)"
  | otherwise = Left ("unknown credential_kind: " <> kind)

----------------------------------------------------------------------------
-- Codec
----------------------------------------------------------------------------

-- | Bidirectional tomland codec for ONE @[repos.\<id\>]@ table. The @id@
-- comes from the enclosing 'Toml.tableMap' key (via 'repoRegistryCodec') and
-- is injected as the fixed 'RepoId'. Fail-closed on unknown @vcs_kind@ /
-- @credential_kind@, missing @vault_key@, and @machine_user@ without
-- @username@ (each is a decode 'Failure'). Extra/unknown fields are ignored
-- (tolmland default).
repoCodec :: RepoId -> TomlCodec SourceRepo
repoCodec srId = SourceRepo srId
  <$> Toml.text "url"                                       .= srUrl
  <*> validatedTextCodec "vcs_kind" parseVcsKind vcsKindText .= srVcsKind
  <*> credentialCodec                                       .= srCredential

-- | Bidirectional tomland codec for the whole @[repos]@ table — a keyed-by-id
-- map. Runs 'mkRepoId' on each decoded key (fail-closed: a bad key id → decode
-- 'Failure'). Returns an empty 'Map' when the @[repos]@ table is absent.
repoRegistryCodec :: TomlCodec (Map RepoId SourceRepo)
repoRegistryCodec = Toml.tableMap keyRepoBiMap repoCodecByKey "repos"

-- | Adapter the 'Toml.tableMap' value-codec slot requires (a @Key -> TomlCodec@
-- function). Converts the raw TOML 'Key' to a 'RepoId' (fail-closed via
-- 'mkRepoId') and nests 'repoCodec' under a sub-table named by the key —
-- mirroring @Toml.tableMap Toml._KeyText (Toml.table providerConfigCodec)
-- "providers"@ in "Seal.Config.File". The 'keyRepoBiMap' already validates
-- the key, so the 'Left' branch is unreachable in practice but kept for
-- totality.
repoCodecByKey :: Key -> TomlCodec SourceRepo
repoCodecByKey rawKey =
  case mkRepoId (prettyKey rawKey) of
    Left _    -> empty
    Right rid -> Toml.table (repoCodec rid) rawKey

-- | Bidirectional 'TomlBiMap' between TOML 'Key's and 'RepoId's. @forward@
-- (Key → RepoId) runs 'mkRepoId' on the rendered key text; a bad id is a
-- 'Failure' (fail-closed). @backward@ (RepoId → Key) re-parses the id text
-- (which is guaranteed valid by 'mkRepoId').
keyRepoBiMap :: TomlBiMap Key RepoId
keyRepoBiMap = BiMap
  { forward  = first (ArbitraryError . ("invalid repo id key: " <>) . T.pack . show)
                . mkRepoId . prettyKey
  , backward = first (ArbitraryError . unTomlParseError) . parseKey . repoIdText
  }

----------------------------------------------------------------------------
-- A codec for a validated text field (fail-closed on bad enum values)
----------------------------------------------------------------------------

-- | Codec for a required text field that is parsed/validated into a typed
-- value. On decode: looks up the key, decodes it as 'Text', runs the parser;
-- on @Left@ returns a 'Failure' (fail-closed). On encode: renders the value
-- back to 'Text' and writes it. A missing key is a 'KeyNotFound' 'Failure'.
validatedTextCodec :: forall a. Key -> (Text -> Either Text a) -> (a -> Text) -> TomlCodec a
validatedTextCodec key parse render = Codec input output
  where
    input :: TOML -> Validation [TomlDecodeError] a
    input toml = case HashMap.lookup key (tomlPairs toml) of
      Nothing -> Failure [KeyNotFound key]
      Just v  -> case backward Toml._Text v of
        Left err -> Failure [BiMapError key err]
        Right txt -> case parse txt of
          Left msg -> Failure [BiMapError key (ArbitraryError msg)]
          Right a  -> Success a

    output :: a -> TomlState a
    output a = do
      anyVal <- eitherToTomlState (forward Toml._Text (render a))
      a <$ modify (insertKeyAnyVal key anyVal)

----------------------------------------------------------------------------
-- Credential codec (fail-closed on unknown kind / missing username)
----------------------------------------------------------------------------

-- | Codec for the @credential_kind@ + @vault_key@ + optional @username@
-- fields, decoded into a 'RepoCredential'. Fail-closed on unknown
-- @credential_kind@, missing @vault_key@, and @machine_user@ without
-- @username@.
credentialCodec :: TomlCodec RepoCredential
credentialCodec = Codec input output
  where
    input :: TOML -> Validation [TomlDecodeError] RepoCredential
    input toml =
      let vKind  = fieldText          "credential_kind" toml
          vVault = fieldText          "vault_key"        toml
          vUser  = fieldOptionalText  "username"         toml
      in case (vKind, vVault, vUser) of
           (Success kind, Success vault, Success mUser) ->
             either (\msg -> Failure [BiMapError "credential_kind" (ArbitraryError msg)])
                    Success
                    (parseCredentialKind kind vault mUser)
           (e1, e2, e3) -> Failure (concatErrors e1 <> concatErrors e2 <> concatErrors e3)

    output :: RepoCredential -> TomlState RepoCredential
    output cred = do
      writeText "credential_kind" (repoCredentialKindText cred)
      writeText "vault_key"        (cVaultKey cred)
      case cred of
        CredMachineUser _ u -> writeText "username" u
        _                   -> pure ()
      pure cred

-- | Collect the error list from a 'Validation' branch (used to merge
-- fail-closed field errors in 'credentialCodec').
concatErrors :: Validation [e] a -> [e]
concatErrors (Failure es) = es
concatErrors (Success _)  = []

-- | Read a required text field from a 'TOML' (fail-closed on missing/typed
-- mismatch). Used inside the custom 'credentialCodec' read.
fieldText :: Key -> TOML -> Validation [TomlDecodeError] Text
fieldText key toml = case HashMap.lookup key (tomlPairs toml) of
  Nothing -> Failure [KeyNotFound key]
  Just v  -> case backward Toml._Text v of
    Left err -> Failure [BiMapError key err]
    Right t  -> Success t

-- | Read an optional text field from a 'TOML' (missing → 'Nothing').
fieldOptionalText :: Key -> TOML -> Validation [TomlDecodeError] (Maybe Text)
fieldOptionalText key toml = case HashMap.lookup key (tomlPairs toml) of
  Nothing -> Success Nothing
  Just v  -> case backward Toml._Text v of
    Left err -> Failure [BiMapError key err]
    Right t  -> Success (Just t)

-- | Write a text key/value into the encoded TOML state.
writeText :: Key -> Text -> TomlState ()
writeText key txt = do
  anyVal <- eitherToTomlState (forward Toml._Text txt)
  void (modify (insertKeyAnyVal key anyVal))

----------------------------------------------------------------------------
-- @repos@ table normalization
----------------------------------------------------------------------------

-- | tomland's 'Toml.tableMap' \/ 'Toml.table' combinators look up the @repos@
-- node by requiring it to carry an explicit value in the parsed AST. A TOML
-- file that declares only @[repos.\<id\>]@ sub-tables (the idiomatic style,
-- and the one every hand-written @repos.toml@ uses) never writes a bare
-- @[repos]@ header, so that node is /implicit/ in tomland's prefix tree and
-- the lookup silently returns an empty map instead of the sub-tables'
-- contents.
--
-- This walks the parsed AST once before decoding and makes that node explicit
-- — without disturbing anything else — so both styles decode correctly.
-- Round-tripped files (written by the encoder) already have an explicit node
-- and pass through unchanged. Direct sibling of 'normalizeProvidersTable'.
normalizeReposTable :: TOML -> TOML
normalizeReposTable t =
  t { tomlTables = HashMap.adjust explicitNode "repos" (tomlTables t) }
  where
    explicitNode :: Toml.PrefixTree TOML -> Toml.PrefixTree TOML
    explicitNode tree = case tree of
      Toml.Branch pref Nothing children ->
        Toml.Leaf pref (mempty { tomlTables = children })
      Toml.Branch _ (Just _) _ -> tree
      Toml.Leaf (_ :|| [])  _  -> tree
      Toml.Leaf (_ :|| (p : ps)) v ->
        Toml.Leaf ("repos" :|| []) (mempty { tomlTables = Toml.single (p :|| ps) v })

----------------------------------------------------------------------------
-- URL helpers (pure — used by planClone in W3 + REST/slash validation in W4/W5)
----------------------------------------------------------------------------

-- | The GitHub-first host allow-list. This pass restricts clones to
-- @github.com@; a per-credential @cHost@ may widen this in a follow-up.
githubHosts :: [Text]
githubHosts = ["github.com"]

-- | Is the parsed host in 'githubHosts'?
hostAllowed :: Text -> Bool
hostAllowed h = h `elem` githubHosts

-- | Parse the host from an SSH (@git@github.com:owner\/repo.git@) or HTTPS
-- (@https://github.com/owner/repo.git@) URL. Returns @Left@ with a clear
-- error on malformed URLs. Returns 'Either' 'Text' (NOT @Either CloneError@)
-- so this module does not depend on W3's 'CloneError'; W3's @planClone@ lifts
-- the error.
parseRepoHost :: Text -> Either Text Text
parseRepoHost url
  | T.null url = Left "empty repo URL"
  | "git@" `T.isPrefixOf` url = parseSsh
  | "https://" `T.isPrefixOf` url = parseHttps
  | "http://" `T.isPrefixOf` url = parseHttps
  | otherwise = Left "URL is neither SSH (git@<host>:...) nor HTTPS (https://<host>/...)"
  where
    parseSsh :: Either Text Text
    parseSsh =
      let afterAt = T.drop (T.length "git@") url
      in case T.breakOn ":" afterAt of
           (host, rest)
             | T.null rest -> Left "missing ':' in scp-form URL"
             | T.null host -> Left "empty host in scp-form URL"
             | otherwise   -> Right host

    parseHttps :: Either Text Text
    parseHttps =
      let rest = fromMaybe url (T.stripPrefix "https://" url <|> T.stripPrefix "http://" url)
          host = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') rest
      in if T.null host
           then Left "empty host in HTTPS URL"
           else Right host

-- | True iff the URL is non-empty AND matches one of the two supported shapes
-- (SSH @git\@\<host\>:...@ or HTTPS @https://\<host\>/...@).
urlShapeValid :: Text -> Bool
urlShapeValid url = not (T.null url) && (isSsh url || isHttps url)
  where
    isSsh u   = "git@" `T.isPrefixOf` u && T.isInfixOf ":" u
    isHttps u = "https://" `T.isPrefixOf` u || "http://" `T.isPrefixOf` u

----------------------------------------------------------------------------
-- URL normalization + registry lookup (W1 — shared with ISA.Ops.Repo)
----------------------------------------------------------------------------

-- | Normalize a repo URL to a canonical form for cross-scheme comparison.
-- The same repo reached via different schemes (e.g.
-- @git\@github.com:foo/bar.git@ vs @https://github.com/foo/bar.git@) should
-- compare equal so 'lookupRepoByUrl' matches across forms. Normalization:
--
--   * strip a scheme (@https://@, @http://@, @git://@, @ssh://@, @file://@);
--   * strip a leading @user\@@ (SCP-style);
--   * replace the SCP-style @:@ separator with @/@;
--   * strip a trailing @.git@;
--   * strip trailing slashes;
--   * lowercase (GitHub URLs are case-insensitive in host/path).
--
-- Returns the empty string only if the input is empty after trimming.
-- Idempotent: @normalizeRepoUrl (normalizeRepoUrl u) == normalizeRepoUrl u@.
normalizeRepoUrl :: Text -> Text
normalizeRepoUrl raw =
  let t1 = T.strip raw
      -- Strip a scheme.
      t2 = foldr (\s acc -> fromMaybe acc (T.stripPrefix s acc))
                 t1 [ "https://", "http://", "git://", "ssh://", "file://" ]
      -- Strip a leading user@ (SCP-style: git@host:path).
      t3 = case T.breakOn "@" t2 of
             (_, rest) | not (T.null rest) -> T.drop 1 rest
             _ -> t2
      -- Replace the SCP ':' separator with '/'. Only the FIRST ':'
      -- (after the host) is the separator; later ':' would be port-like,
      -- but a bare SCP url has exactly one ':'. If there's no '/', the
      -- first ':' is host/path; if there's a '/' before the ':', it's
      -- not SCP-style (e.g. ssh://host:port/path already had scheme
      -- stripped, so unlikely) — leave it.
      t4 = case T.breakOn ":" t3 of
             (host, rest) | not (T.null rest), not (T.any (== '/') host) ->
               host <> "/" <> T.drop 1 rest
             _ -> t3
      -- Strip trailing slashes, then a trailing .git, then any slash
      -- that the .git-strip might have exposed (e.g. ".../repo.git/"
      -- → ".../repo.git" → ".../repo"). Apply twice in case of a
      -- ".../repo.git/."-like edge; the composition is idempotent.
      stripTail t = T.dropWhileEnd (== '/') (fromMaybe t (T.stripSuffix ".git" (T.dropWhileEnd (== '/') t)))
      t5 = stripTail t4
  in T.toLower t5

-- | Look up a 'SourceRepo' in a 'RepoRegistry' by URL, matching across
-- scheme forms (SSH @git\@host:o/r.git@ ↔ HTTPS @https://host/o/r.git@ ↔
-- @https://host/o/r@). Both the query URL and each 'srUrl' are normalized
-- via 'normalizeRepoUrl' before comparison. Pure.
lookupRepoByUrl :: Text -> RepoRegistry -> Maybe SourceRepo
lookupRepoByUrl query (RepoRegistry repos) =
  let q = normalizeRepoUrl query
  in listToMaybe
       [ r | r <- Map.elems repos, normalizeRepoUrl (srUrl r) == q ]

----------------------------------------------------------------------------
-- JSON descriptor (for the REST API in W4)
----------------------------------------------------------------------------

instance ToJSON SourceRepo where
  toJSON r = object
    [ "id"          Aeson..= repoIdText (srId r)
    , "url"         Aeson..= srUrl r
    , "vcs_kind"    Aeson..= vcsKindText (srVcsKind r)
    , "credential"  Aeson..= credentialToObject (srCredential r)
    ]

instance FromJSON SourceRepo where
  parseJSON = withObject "SourceRepo" $ \o -> do
    rid  <- o .:  "id"
    url  <- o .:  "url"
    kind <- o .:  "vcs_kind"
    cred <- o .:  "credential"
    i  <- either (fail . T.unpack) pure (mkRepoId rid)
    vk <- either (fail . T.unpack) pure (parseVcsKind kind)
    SourceRepo i url vk <$> parseCredentialFromObject cred

credentialToObject :: RepoCredential -> Value
credentialToObject c = object $ case c of
  CredPat k ->
    [ "kind" Aeson..= ("pat" :: Text), "vault_key" Aeson..= k ]
  CredDeployKey k ->
    [ "kind" Aeson..= ("deploy_key" :: Text), "vault_key" Aeson..= k ]
  CredMachineUser k u ->
    [ "kind" Aeson..= ("machine_user" :: Text), "vault_key" Aeson..= k, "username" Aeson..= u ]

parseCredentialFromObject :: Value -> Parser RepoCredential
parseCredentialFromObject = withObject "RepoCredential" $ \o -> do
  kind  <- o .:  "kind"
  vault <- o .:  "vault_key"
  mUser <- o .:? "username"
  either (fail . T.unpack) pure (parseCredentialKind kind vault mUser)