{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The security-critical, boot-only configuration that lives in
-- @~\/.seal\/security.toml@ — a separate file from @config.toml@ (which holds
-- the agent/operator-tunable 'RuntimeConfig'). No opcode can reach this module.
--
-- It is re-read in one narrow case only: 'updateAccessControlSection', which
-- rewrites the @[access_control]@ table when the operator enrolls a passkey,
-- waives the requirement, or manages credentials from the authenticated web
-- UI. That writer's callback sees only 'AccessControlFileConfig', so it
-- physically cannot express a change to any other section — the type split
-- (design §4 Approach E) keeps its guarantee.
--
-- Moving @untrusted_execution@ and the vault settings here means a future
-- @CONFIG_UPDATE@ opcode (which operates on 'RuntimeConfig') and the Gateway's
-- @updateRuntimeConfig@ caller physically cannot express a change to these
-- fields — the type split makes it a compile error (design §4 Approach E).
--
-- Every field is optional; a missing key decodes as 'Nothing' and a
-- 'Nothing' value is omitted from the encoded output.
module Seal.Config.Security
  ( SecurityConfig (..)
  , UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..)
  , AccessControlFileConfig (..)
  , CredentialFileConfig (..)
  , accessControlCodec
  , credentialCodec
  , normalizeAccessControlTable
  , fixNode
  , hasLegacyLayout
  , tomlKeyPaths
  , WriteMode (..)
  , updateAccessControlSection
  , clearAccessControlSection
  , writeSecretFile
  , securityWriteLock
  , defaultSecurityConfig
  , securityConfigCodec
  , loadSecurityConfig
  , decodeSecurityConfig
  , saveSecurityConfig
  , updateSecurityConfig
  , untrustedExecConfigFromSecurity
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (bracketOnError)
import Data.HashMap.Strict qualified as HashMap
import Data.Functor ((<&>))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import System.IO.Unsafe (unsafePerformIO)
import System.IO (hClose)
import System.Posix.Files (setFileMode)
import System.Posix.IO
  ( OpenFileFlags (creat, nofollow, trunc), OpenMode (WriteOnly), closeFd
  , defaultFileFlags, fdToHandle, openFd )
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified

import Seal.Tools.Exec.Types
  ( SshConfig (..), mkSshHost, mkSshUser, mkRemotePath )
import Seal.Tools.Exec.Untrusted
  ( UntrustedExecConfig (..), UntrustedExecMode (..) )

-- | The boot-only, agent-immutable security configuration. Carries the
-- @untrusted_execution@ section (remote-only enforcement) and the vault
-- settings. Loaded once at boot from @security.toml@; never passed to any
-- opcode or the Gateway.
data SecurityConfig = SecurityConfig
  { scVaultPath :: Maybe Text
    -- ^ Absolute path to the vault file (default: @~\/.seal\/config\/vault\/vault.age@).
  , scVaultRecipient :: Maybe Text
    -- ^ age public key: @age1…@ or @age1yubikey1…@.
  , scVaultIdentity :: Maybe Text
    -- ^ Path to the identity file under @keys\/@, or a user-supplied path.
  , scVaultUnlock :: Maybe Text
    -- ^ @\"startup\"@ | @\"on_demand\"@ | @\"per_access\"@.
  , scVaultKeyType :: Maybe Text
    -- ^ Display label: @\"x25519\"@ | @\"yubikey\"@ | @\"user\"@.
  , scUntrustedExec :: Maybe UntrustedExecFileConfig
    -- ^ Optional @[untrusted_execution]@ section (remote-only untrusted
    -- execution). Absent means @mode=local@ (default). @mode=remote@
    -- fail-closes at call time when the remote block is absent or
    -- unreachable (boot still succeeds).
  , scAccessControl :: Maybe AccessControlFileConfig
    -- ^ Optional @[access_control]@ section. Absent means *unconfigured*: the
    -- gateway serves only the setup screen until the operator enrolls a
    -- passkey or explicitly waives (design §4). This is the ONE section the
    -- gateway may write, via 'updateAccessControlSection'.
  } deriving stock (Eq, Show)

-- | The @[untrusted_execution]@ section (spec §3 Layer A). @mode@ is
-- @\"local\"@ (default) or @\"remote\"@ (fail-closed). The optional
-- @[untrusted_execution.remote]@ sub-table carries the SSH coordinates;
-- absent under @mode=local@ (no remote needed), and @mode=remote@ parses
-- OK without it (fail-closed is at call time, not parse time — spec §7
-- row 1).
data UntrustedExecFileConfig = UntrustedExecFileConfig
  { uefcMode   :: Text
    -- ^ @\"local\"@ | @\"remote\"@
  , uefcRemote :: Maybe UntrustedExecRemoteFileConfig
  } deriving stock (Eq, Show)

-- | The @[untrusted_execution.remote]@ sub-table (spec §5). Every field is
-- optional at the TOML layer; the call site validates that the required
-- fields (@host@/@user@/@known_hosts@/@workspace@) are present when
-- @mode=remote@ (absent ⇒ fail-closed at call time).
data UntrustedExecRemoteFileConfig = UntrustedExecRemoteFileConfig
  { uerfcHost       :: Maybe Text
  , uerfcUser       :: Maybe Text
  , uerfcPort       :: Maybe Int
  , uerfcIdentity   :: Maybe FilePath
  , uerfcKnownHosts :: Maybe FilePath
  , uerfcWorkspace  :: Maybe Text
  } deriving stock (Eq, Show)

-- | The @[access_control]@ section (design §4). @mode@ is @\"passkey\"@ or
-- @\"none\"@; the section being absent means *unconfigured*, which is not the
-- same as @none@ — unconfigured closes the API and shows the setup screen,
-- whereas @none@ is the operator's explicit waiver.
--
-- @origin@/@rp_id@ are only needed when the browser reaches the gateway
-- through a TLS reverse proxy; otherwise the origin is derived from
-- @[gateway]@ at boot ('Seal.Security.AccessControl.resolveAccessControl').
data AccessControlFileConfig = AccessControlFileConfig
  { acfcMode        :: Maybe Text
    -- ^ Optional. Absent means "passkey" when credentials are present and
    -- "unconfigured" otherwise. Only @\"none\"@ can open the gateway, and it
    -- has to be written out — an open gateway is never inferred.
  , acfcOrigin      :: Maybe Text
  , acfcRpId        :: Maybe Text
  } deriving stock (Eq, Show)

-- | One @[access_control.credentials.\<id\>]@ table.
data CredentialFileConfig = CredentialFileConfig
  { cfcPublicKey :: Text
    -- ^ Base64url of the 64-byte uncompressed @x || y@ P-256 point.
  , cfcSignCount :: Int
  , cfcLabel     :: Text
  , cfcCreatedAt :: Text
    -- ^ ISO-8601. Kept as text here and parsed on resolution, so a malformed
    -- value is a boot-time error rather than a decode-time surprise.
  , cfcRpId      :: Text
  , cfcAddedVia  :: Maybe Text
    -- ^ How the credential was enrolled: @\"cli_token\"@ | @\"cli_window\"@ |
    -- @\"assertion\"@ | @\"legacy\"@. Shares its vocabulary with the grant's
    -- @minted_via@ plus @legacy@. Absent or unrecognised reads as
    -- @\"legacy\"@ — the safe label, since it claims nothing about the
    -- authority that created the credential.
  } deriving stock (Eq, Show)

-- | Bidirectional codec for the @[access_control]@ section.
accessControlCodec :: Toml.TomlCodec AccessControlFileConfig
accessControlCodec = AccessControlFileConfig
  <$> Toml.dioptional (Toml.text "mode") .= acfcMode
  <*> Toml.dioptional (Toml.text "origin") .= acfcOrigin
  <*> Toml.dioptional (Toml.text "rp_id") .= acfcRpId

-- | Codec for one credential table.
credentialCodec :: Toml.TomlCodec CredentialFileConfig
credentialCodec = CredentialFileConfig
  <$> Toml.text "public_key" .= cfcPublicKey
  <*> Toml.int "sign_count" .= cfcSignCount
  <*> Toml.text "label" .= cfcLabel
  <*> Toml.text "created_at" .= cfcCreatedAt
  <*> Toml.text "rp_id" .= cfcRpId
  <*> Toml.dioptional (Toml.text "added_via") .= cfcAddedVia

-- | Every /value-bearing/ key path in a parsed document, as a list of pieces.
--
-- Table nodes are deliberately not emitted on their own. A table is a prefix
-- of the paths underneath it, and whether it appears as a node or as a prefix
-- depends only on spelling — a header or a dotted key. Emitting both would
-- make "the document's data" mean two different things, and a rewrite that
-- normalises a dotted key into a header would look like damage.
--
-- The three shapes tomland produces all have to be walked, or a path
-- comparison silently misses one of them:
--
-- * an explicit table header — a prefix-tree 'Toml.Branch' whose prefix /is/
--   the path;
-- * a table's own keys — a 'Toml.TOML' payload reached through a
--   'Toml.Branch' or 'Toml.Leaf';
-- * a /dotted key/ — which tomland does NOT expand into nested tables. It
--   keeps the whole path in one 'Toml.tomlPairs' key, so
--   @credentials.\<id\>.public_key@ under @[access_control]@ arrives as the
--   single pair key @(\"credentials\" :| [\"\<id\>\",\"public_key\"])@ and no
--   prefix tree ever holds a @credentials@ node. This is why the check below
--   cannot be a codec.
tomlKeyPaths :: Toml.TOML -> [[Toml.Piece]]
tomlKeyPaths = go []
  where
    go prefix toml =
         [ prefix <> keyPieces key
         | key <- HashMap.keys (Toml.tomlPairs toml) ]
      <> concatMap nodePaths (HashMap.elems (Toml.tomlTables toml))

    -- A node's own prefix is the authoritative absolute path: an implicit
    -- table header arrives as one multi-piece prefix under a single-piece
    -- map key, so the map key alone loses path segments.
    nodePaths tree = case tree of
      Toml.Branch pref mValue children ->
           maybe [] (go (keyPieces pref)) mValue
        <> concatMap nodePaths (HashMap.elems children)
      Toml.Leaf pref value -> go (keyPieces pref) value

keyPieces :: Toml.Key -> [Toml.Piece]
keyPieces = NonEmpty.toList . Toml.unKey

-- | Expand dotted keys into nested tables.
--
-- tomland keeps a dotted key as one flat pair whose key carries the whole
-- path: @untrusted_execution.mode = \"local\"@ becomes
-- @(\"untrusted_execution\" :| [\"mode\"], …)@ in 'Toml.tomlPairs', and no
-- @untrusted_execution@ node exists anywhere in the prefix tree. A codec looks
-- up tables, so it finds nothing, decodes the section as absent — and the next
-- write drops it. Silently: the document still parses, so nothing reports it.
--
-- Expanding first makes the document look the way the codec expects, so both
-- spellings decode and re-encode identically. (tomland's own
-- 'Toml.Type.TOML.insertKeyAnyVal' does not help: it stores the value at the
-- full multi-piece key, which is exactly where it already was. The nesting has
-- to be built.)
expandDottedKeys :: Toml.TOML -> Toml.TOML
expandDottedKeys toml = foldl' insert base dottedPaths
  where
    pairs       = HashMap.toList (Toml.tomlPairs toml)
    dottedPaths = [(keyPieces key, value) | (key, value) <- pairs, isDotted key]
    base = toml
      { Toml.tomlPairs  = HashMap.fromList
          [(key, value) | (key, value) <- pairs, not (isDotted key)]
      , Toml.tomlTables = fmap expandNode (Toml.tomlTables toml)
      }
    insert acc (pieces, value) = insertDotted pieces value acc
    isDotted key = case keyPieces key of
      _ : _ : _ -> True
      _         -> False

    expandNode node = case node of
      Toml.Branch pref mValue children ->
        Toml.Branch pref (fmap expandDottedKeys mValue) (fmap expandNode children)
      Toml.Leaf pref value -> Toml.Leaf pref (expandDottedKeys value)

    -- Insert the value at the dotted path, creating the intermediate tables as
    -- explicit 'Toml.Leaf' nodes — the form 'Toml.table' and 'Toml.tableMap'
    -- look up. The payload type is tomland's GADT-indexed 'Toml.Value', so it
    -- is inferred rather than named.
    insertDotted [] _ target = target
    insertDotted (piece : rest) value target = case rest of
      [] -> target { Toml.tomlPairs = HashMap.insert (piece Toml.:|| []) value
                                            (Toml.tomlPairs target) }
      _  -> target
        { Toml.tomlTables = HashMap.insert piece
            (Toml.Leaf (piece Toml.:|| []) (insertDotted rest value (nodeValue existing)))
            (Toml.tomlTables target) }
      where
        existing = HashMap.lookupDefault (Toml.Leaf (piece Toml.:|| []) mempty) piece
                     (Toml.tomlTables target)

    -- A node's own payload with any child nodes folded into it: the canonical
    -- explicit form, and the one 'fixNode' produces.
    nodeValue node = case node of
      Toml.Leaf _ value -> value
      Toml.Branch _ mValue children ->
        maybe mempty (\value -> value { Toml.tomlTables = children }) mValue

-- | Everything 'loadSecurityConfig' does to a parsed document before decoding.
normalizeSecurityToml :: Toml.TOML -> Toml.TOML
normalizeSecurityToml = normalizeAccessControlTable . expandDottedKeys

-- | Does this raw @security.toml@ still carry the pre-split credential tables?
--
-- Once the store moved to @credentials.toml@, a write that rewrites
-- @security.toml@ without noticing the old tables would drop every credential —
-- silently, on a document whose next boot then reads as unconfigured.
--
-- Detection walks the parsed key paths, it does not grep the text. A substring
-- scan for @[access_control.credentials.@ misses the dotted-key spelling of the
-- same document (@[access_control]@ plus @credentials.\<id\>.public_key = …@),
-- and — as 'tomlKeyPaths' explains — so does anything that goes through the
-- prefix tree, which is why this is not a codec either.
--
-- An unparseable document answers 'False': it is refused earlier, as
-- @BrSecurityUnparseable@, so it can never reach the writer this guard protects.
--
-- Detection is not reading. Decoding the credentials back out for
-- @migrate-credentials@ is a separate concern, and it must handle the
-- dotted-key spelling too: 'normalizeAccessControlTable' only makes
-- /prefix-tree/ nodes explicit, so a dotted-key file currently decodes to an
-- empty credential map. A migration that reads through the codec alone would
-- therefore move nothing and then report success.
hasLegacyLayout :: Text -> Bool
hasLegacyLayout raw = case Toml.parse raw of
  Left _     -> False
  Right toml -> any isCredentialPath (tomlKeyPaths toml)
  where
    isCredentialPath (p1 : p2 : _) = p1 == "access_control" && p2 == "credentials"
    isCredentialPath _             = False

-- | Make the implicit @access_control@ node explicit before decoding.
--
-- tomland's 'Toml.tableMap' looks the section up under its @[access_control]@
-- header, so an idiomatic hand-written file containing only
-- @[access_control.credentials.\<id\>]@ sub-tables decodes as an EMPTY map
-- (learnings 2026-08-02 §4). Mirrors
-- 'Seal.SourceControl.Repo.normalizeReposTable'.
normalizeAccessControlTable :: Toml.TOML -> Toml.TOML
normalizeAccessControlTable t =
  t { Toml.tomlTables = HashMap.adjust fixAccessControl "access_control" (Toml.tomlTables t) }
  where
    -- Two levels are implicit in an idiomatic file: `access_control` and the
    -- `credentials` table beneath it. Both must be made explicit, or the
    -- nested `Toml.tableMap` lookup silently yields an empty map and the
    -- operator's passkeys disappear.
    fixAccessControl tree = fixChildIn "credentials" (fixNode "access_control" tree)

    fixChildIn child tree = case tree of
      Toml.Branch pref mv children ->
        Toml.Branch pref mv (HashMap.adjust (fixNode child) child children)
      Toml.Leaf pref v ->
        Toml.Leaf pref v { Toml.tomlTables =
                             HashMap.adjust (fixNode child) child (Toml.tomlTables v) }

-- | Collapse whatever implicit path the parser produced under @root@ into a
-- single explicit table node named @root@.
fixNode :: Toml.Piece -> Toml.PrefixTree Toml.TOML -> Toml.PrefixTree Toml.TOML
fixNode root tree = case tree of
  Toml.Branch pref Nothing children ->
    Toml.Leaf pref (mempty { Toml.tomlTables = children })
  Toml.Branch _ (Just _) _ -> tree
  Toml.Leaf (_ Toml.:|| []) _ -> tree
  Toml.Leaf (_ Toml.:|| (p : ps)) v ->
    Toml.Leaf (root Toml.:|| [])
      (mempty { Toml.tomlTables = Toml.single (p Toml.:|| ps) v })

-- | Starting state: all fields absent.
defaultSecurityConfig :: SecurityConfig
defaultSecurityConfig = SecurityConfig
  { scVaultPath      = Nothing
  , scVaultRecipient = Nothing
  , scVaultIdentity  = Nothing
  , scVaultUnlock    = Nothing
  , scVaultKeyType   = Nothing
  , scUntrustedExec  = Nothing
  , scAccessControl  = Nothing
  }

-- ---------------------------------------------------------------------------
-- Codec
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for 'SecurityConfig'.
securityConfigCodec :: Toml.TomlCodec SecurityConfig
securityConfigCodec = SecurityConfig
  <$> Toml.dioptional (Toml.text "vault_path")     .= scVaultPath
  <*> Toml.dioptional (Toml.text "vault_recipient") .= scVaultRecipient
  <*> Toml.dioptional (Toml.text "vault_identity")  .= scVaultIdentity
  <*> Toml.dioptional (Toml.text "vault_unlock")    .= scVaultUnlock
  <*> Toml.dioptional (Toml.text "vault_key_type")  .= scVaultKeyType
  <*> Toml.dioptional (Toml.table untrustedExecConfigCodec "untrusted_execution") .= scUntrustedExec
  <*> Toml.dioptional (Toml.table accessControlCodec "access_control")
        .= scAccessControl

-- | Bidirectional tomland codec for the @[untrusted_execution]@ section.
untrustedExecConfigCodec :: Toml.TomlCodec UntrustedExecFileConfig
untrustedExecConfigCodec = UntrustedExecFileConfig
  <$> Toml.text "mode" .= uefcMode
  <*> Toml.dioptional (Toml.table untrustedExecRemoteConfigCodec "remote") .= uefcRemote

-- | Bidirectional tomland codec for the @[untrusted_execution.remote]@
-- sub-table. Every field is optional at the TOML layer.
untrustedExecRemoteConfigCodec :: Toml.TomlCodec UntrustedExecRemoteFileConfig
untrustedExecRemoteConfigCodec = UntrustedExecRemoteFileConfig
  <$> Toml.dioptional (Toml.text "host")        .= uerfcHost
  <*> Toml.dioptional (Toml.text "user")        .= uerfcUser
  <*> Toml.dioptional (Toml.int "port")         .= uerfcPort
  <*> Toml.dioptional (Toml.string "identity")  .= uerfcIdentity
  <*> Toml.dioptional (Toml.string "known_hosts") .= uerfcKnownHosts
  <*> Toml.dioptional (Toml.text "workspace")   .= uerfcWorkspace

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | Load the security config file at @path@.
--
-- * File absent  → @Right 'defaultSecurityConfig'@
-- * Parse error  → @Left@ with the rendered tomland diagnostics
loadSecurityConfig :: FilePath -> IO (Either Text SecurityConfig)
loadSecurityConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right defaultSecurityConfig)
    else TIO.readFile path <&> decodeSecurityConfig

-- | Decode @security.toml@ from its text.
--
-- The I/O-free half of 'loadSecurityConfig', exported because the boot
-- preflight needs the document as text (for the legacy-layout check) /and/ the
-- decoded section at the same time, and reading the file twice could see two
-- different documents.
decodeSecurityConfig :: Text -> Either Text SecurityConfig
decodeSecurityConfig contents = case Toml.parse contents of
  Left err   -> Left (Toml.unTomlParseError err)
  Right toml -> case Toml.runTomlCodec securityConfigCodec
                     (normalizeSecurityToml toml) of
    Success cfg  -> Right cfg
    Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | Whether a write is allowed to discard the pre-split credential tables.
--
-- A credential table in @security.toml@ is only ever a leftover from the
-- layout before credentials moved to @credentials.toml@, and rewriting the
-- document without migrating it first destroys it: the next boot then reads as
-- unconfigured and every enrolled passkey is gone. So the exemption is a
-- value, not a convention — the two callers that may pass 'DropCredentials'
-- are @migrate-credentials@ and @reset --yes@, both CLI-only and both
-- @--yes@-gated.
data WriteMode = PreserveCredentials | DropCredentials
  deriving stock (Eq, Show)

-- | Save @cfg@ to @path@ atomically.
--
-- The temp file is created with mode @0600@ at creation time (not chmod'ed
-- afterwards), so there is never a window in which the vault recipient or a
-- passkey public key is world-readable. It is then renamed over @path@, which
-- is atomic on every filesystem this project supports.
--
-- Every writer funnels through here, so this is where the credential-preserving
-- refusal lives. It reads the document /as it is on disk/, not the value being
-- written: the caller has already decoded it, and decoding is exactly what
-- loses a legacy table it does not understand.
saveSecurityConfig :: FilePath -> SecurityConfig -> WriteMode -> IO (Either Text ())
saveSecurityConfig path cfg mode = do
  refusal <- legacyCredentialRefusal path mode
  case refusal of
    Just err -> pure (Left err)
    Nothing  -> do
      let encoded = Toml.encode securityConfigCodec cfg
          tmp     = path <> ".tmp"
      writeSecretFile tmp encoded
      renameFile tmp path
      pure (Right ())

legacyCredentialRefusal :: FilePath -> WriteMode -> IO (Maybe Text)
legacyCredentialRefusal _    DropCredentials   = pure Nothing
legacyCredentialRefusal path PreserveCredentials = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      raw <- TIO.readFile path
      pure $ if hasLegacyLayout raw
        then Just ("refusing to rewrite " <> T.pack path <> ": it still holds the "
                    <> "pre-split [access_control.credentials] tables. Run "
                    <> "`seal access-control migrate-credentials` first.")
        else Nothing

-- | Write a text file whose permissions are restricted from the moment it
-- exists: @0600@ is applied at creation (via @openFd@'s @creat@ mode) and again
-- afterwards to defeat a permissive umask, so there is never a window in which
-- the contents are world-readable. Used for @security.toml@ and for the
-- per-boot setup code.
writeSecretFile :: FilePath -> Text -> IO ()
writeSecretFile path contents =
  bracketOnError
    (openFd path WriteOnly defaultFileFlags
       { trunc = True, creat = Just 0o600, nofollow = True })
    closeFd
                 (\fd -> do
                     h <- fdToHandle fd
                     TIO.hPutStr h contents
                     hClose h
                     setFileMode path 0o600)

-- | Process-wide lock serializing security config writes (design V7).
--
-- Exported because the credential store shares it: a credential write and a
-- @security.toml@ write must not interleave (an enrollment raises the mode and
-- writes a credential as one operation — design §6.1). It is
-- /non-reentrant/: a caller that already holds it must use the unlocked
-- primitives, never a writer that takes it. 'Seal.Config.Credentials'\\'s
-- writers take it; nothing else may call them from inside it.
{-# NOINLINE securityWriteLock #-}
securityWriteLock :: MVar ()
securityWriteLock = unsafePerformIO (newMVar ())

-- | Load the security config at @path@, apply @f@, save. Propagates any load
-- error as @Left Text@ without writing. This is the admin/boot path (e.g.
-- @\/vault setup@); it is NEVER called by an opcode or the HTTP Gateway
-- (those operate on 'RuntimeConfig' and physically cannot reach
-- 'SecurityConfig' — design §4 E). Serialized behind 'securityWriteLock'
-- to prevent lost-update races (design V7).
updateSecurityConfig :: FilePath -> (SecurityConfig -> SecurityConfig) -> IO (Either Text ())
updateSecurityConfig path f = withMVar securityWriteLock $ \_ -> do
  result <- loadSecurityConfig path
  case result of
    Left err  -> pure (Left err)
    Right cfg -> saveSecurityConfig path (f cfg) PreserveCredentials

-- | The ONLY writer of @security.toml@ reachable from the gateway.
--
-- It loads the file, applies @f@ to the @[access_control]@ section alone, and
-- re-encodes. The callback's type is @AccessControlFileConfig ->
-- AccessControlFileConfig@, so no value the gateway can build will ever name a
-- vault or @untrusted_execution@ field: rewriting those is a compile error,
-- exactly as the 'RuntimeConfig' split intends.
--
-- The write is verified before it is committed: the freshly encoded document
-- is decoded again and compared with the intended section, so a codec change
-- that silently drops a field surfaces as @Left@ instead of as data loss.
-- Serialized behind 'securityWriteLock' (the same lock the vault commands use
-- for lost-update protection).
updateAccessControlSection
  :: FilePath
  -> (AccessControlFileConfig -> AccessControlFileConfig)
  -> IO (Either Text AccessControlFileConfig)
updateAccessControlSection path f = withMVar securityWriteLock $ \_ -> do
  loaded <- loadSecurityConfig path
  case loaded of
    Left err -> pure (Left err)
    Right cfg -> do
      let updated = f (fromMaybe emptyAccessControl (scAccessControl cfg))
          newCfg = cfg { scAccessControl = Just updated }
          encoded = Toml.encode securityConfigCodec newCfg
      case reDecode encoded of
        Just roundTripped
          | scAccessControl roundTripped == Just updated ->
              -- The section writer never discards credentials: enrollment
              -- moves them out, it does not drop them.
              fmap (>> Right updated)
                (saveSecurityConfig path newCfg PreserveCredentials)
        _ -> pure (Left "refusing to write security.toml: the encoded document does not round-trip the new [access_control] section")
  where
    reDecode encoded = case Toml.parse encoded of
      Left _     -> Nothing
      Right toml -> case Toml.runTomlCodec securityConfigCodec toml of
        Success c -> Just c
        Failure _ -> Nothing

-- | Remove the @[access_control]@ table entirely, returning the gateway to the
-- unconfigured state. Reachable only from the @seal access-control reset@ CLI
-- command (the human-driven path); no opcode and no HTTP route can call it.
clearAccessControlSection :: FilePath -> WriteMode -> IO (Either Text ())
clearAccessControlSection path mode = withMVar securityWriteLock $ \_ -> do
  loaded <- loadSecurityConfig path
  case loaded of
    Left err  -> pure (Left err)
    Right cfg -> saveSecurityConfig path (cfg { scAccessControl = Nothing }) mode

-- | The section a first write starts from when the file has none.
--
-- 'acfcMode' is deliberately 'Nothing', not @Just \"none\"@. Any write to a
-- section-less file would otherwise record an /implicit/ waiver, and invariant
-- 1 says absence never means off: an open gateway has to be written out by a
-- human. With 'Nothing', the write leaves the mode unstated, and boot resolves
-- it from whether credentials exist — @passkey@ if they do, @unconfigured@ if
-- they do not.
emptyAccessControl :: AccessControlFileConfig
emptyAccessControl = AccessControlFileConfig
  { acfcMode = Nothing
  , acfcOrigin = Nothing
  , acfcRpId = Nothing
  }

-- | Resolve the 'SecurityConfig'\'s @[untrusted_execution]@ section to the
-- typed 'UntrustedExecConfig' the dispatcher consumes. Returns
-- 'Nothing' when the section is absent OR @mode=local@ (the default —
-- no remote needed, the local executor is wired by the call site).
-- Returns @Just (UemRemote, ...remote...)@ when @mode=remote@,
-- with the remote 'SshConfig' if the remote block is fully present
-- (host/user/known_hosts/workspace all set). A @mode=remote@ with a
-- missing/incomplete remote block returns @Just (UemRemote, Nothing)@
-- — fail-closed is at call time (spec §7 row 1), not at config resolution.
untrustedExecConfigFromSecurity :: SecurityConfig -> Maybe UntrustedExecConfig
untrustedExecConfigFromSecurity cfg =
  resolveByMode =<< scUntrustedExec cfg

resolveByMode :: UntrustedExecFileConfig -> Maybe UntrustedExecConfig
resolveByMode uec =
  let mode = if uefcMode uec == "remote" then UemRemote else UemLocal
  in case mode of
       UemRemote -> Just (UntrustedExecConfig UemRemote (resolveRemoteSsh uec))
       UemLocal  -> localModeResult uec

-- | Resolve the [untrusted_execution.remote] sub-table to an 'SshConfig'.
-- Shared by both the UemRemote branch and the hardened-build localModeResult.
resolveRemoteSsh :: UntrustedExecFileConfig -> Maybe SshConfig
resolveRemoteSsh uec = uefcRemote uec >>= \r ->
  uerfcHost r >>= \host ->
  uerfcUser r >>= \user ->
  uerfcKnownHosts r >>= \knownHosts ->
  uerfcWorkspace r >>= \workspace ->
  let port = fromMaybe 22 (uerfcPort r)
      identity = uerfcIdentity r
  in case ( mkSshHost host
          , mkSshUser user
          , mkRemotePath workspace
          ) of
       (Right h, Right u, Right w) -> Just SshConfig
         { scHost       = h
         , scUser       = u
         , scPort       = port
         , scIdentity   = identity
         , scKnownHosts = knownHosts
         , scWorkspace  = w
         }
       _ -> Nothing

#if defined(REMOTE_ONLY_UNTRUSTED)
localModeResult :: UntrustedExecFileConfig -> Maybe UntrustedExecConfig
localModeResult uec =
  Just (UntrustedExecConfig UemRemote (resolveRemoteSsh uec))
#else
localModeResult :: UntrustedExecFileConfig -> Maybe UntrustedExecConfig
localModeResult _ = Nothing
#endif
