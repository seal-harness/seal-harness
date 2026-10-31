{-# LANGUAGE OverloadedStrings #-}
-- | Deciding whether the gateway may start, and in what state — the design §10
-- table as two functions.
--
-- The split matters for testability: 'preflight' does the I/O (read
-- @security.toml@ as text, read @credentials.toml@) and 'bootPlan' is pure, so
-- every refusal is reachable in a unit test without a filesystem, a socket, or
-- a running server.
--
-- Two properties this module exists to guarantee:
--
-- * /Totality./ Every combination of (section present?, mode?, credentials
--   present?, credential version, coordinates, bind address) lands on exactly
--   one row. There is no "fall through to something reasonable" arm — a state
--   the table does not describe is a refusal to boot, not a guess.
-- * /One place./ The mode defaulting that used to live in
--   'Seal.Security.AccessControl.resolveAccessControl' — "no mode line means
--   passkey if credentials exist" — is here, so a caller cannot independently
--   decide what an absent @mode@ means and drift from it. In particular the
--   rule that guards the whole feature: absence never means @none@.
module Seal.Config.BootPlan
  ( BindCoordinates (..)
  , BootInputs (..)
  , CredentialsPresence (..)
  , BootRefusal (..)
  , bootRefusalMessage
  , BootPlan (..)
  , preflight
  , bootPlan
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)

import Seal.Config.Credentials
  ( CredentialsFile (..), credentialsVersion, loadCredentials )
import Seal.Config.Paths
  ( SealPaths, credentialsFilePath, securityFilePath )
import Seal.Config.Security
  ( AccessControlFileConfig (..), SecurityConfig (..), decodeSecurityConfig
  , CredentialFileConfig, hasLegacyLayout )
import Seal.Security.AccessControl
  ( CredentialAvailability (..), credentialAvailability, credentialFromFile
  , isLoopbackHost, resolveCoordinates )
import Seal.Security.EnrollmentGrant (GrantSource (..))
import Seal.Security.WebAuthn.Types (AccessMode (..), Credential, parseAccessMode)

-- | The address the gateway would bind, which decides whether credentials can
-- be resolved to a usable origin and whether a session cookie could travel in
-- the clear.
data BindCoordinates = BindCoordinates
  { bcHost :: !Text
  , bcPort :: !Int
  } deriving stock (Eq, Show)

-- | Everything 'bootPlan' needs, gathered by 'preflight'.
data BootInputs = BootInputs
  { biSecurityRaw :: !Text
    -- ^ The @security.toml@ bytes as they are on disk. Kept because the
    -- legacy-layout check has to see the document, not a decoded summary of
    -- it: decoding is what loses a table the codec does not know.
  , biSection     :: !(Maybe AccessControlFileConfig)
    -- ^ 'Nothing' when the file is absent or has no @[access_control]@.
  , biCredentials :: !CredentialsPresence
  } deriving stock (Eq, Show)

-- | What @credentials.toml@ turned out to be. Three states, because boot treats
-- them differently: absent is normal (nothing enrolled yet), invalid is a
-- refusal, and present-but-empty is a corruption signal — the store's writers
-- cannot produce it (design §9.2), so seeing it means something else did.
data CredentialsPresence
  = CredentialsAbsent
  | CredentialsPresent !Int !(Map Text CredentialFileConfig)
  | CredentialsInvalid Text
  deriving stock (Eq, Show)

-- | Why the gateway will not start. Every constructor names the thing the
-- operator has to change; none of them is a catch-all.
data BootRefusal
  = BrSecurityUnparseable Text
  | BrLegacyLayout
  | BrCredentialsInvalid Text
  | BrCredentialsEmpty
  | BrCredentialsVersion !Int
  | BrModeInvalid Text
  | BrCoordinatesInvalid Text
  | BrUnsafeBind Text
  | BrPublicBindWithLoopbackOrigin
  deriving stock (Eq, Show)

-- | The operator-facing text for a refusal. Each message names the command or
-- the edit that fixes it — a refusal that only says "no" leaves the operator
-- with a gateway that will not start and no way forward.
bootRefusalMessage :: BootRefusal -> Text
bootRefusalMessage refusal = case refusal of
  BrSecurityUnparseable err ->
    "security.toml could not be read: " <> err
      <> "\n  Fix ~/.seal/security.toml by hand; `seal serve` will not start until it parses."
  BrLegacyLayout ->
    "security.toml still holds the pre-split [access_control.credentials] tables.\n"
      <> "  Run `seal access-control migrate-credentials` to move them to credentials.toml."
  BrCredentialsInvalid err ->
    "credentials.toml could not be read: " <> err
      <> "\n  Run `seal access-control reset --yes` (with the daemon stopped) and enroll again."
  BrCredentialsEmpty ->
    "credentials.toml exists but holds no credentials.\n"
      <> "  The store is never written empty on purpose; treat this as corruption.\n"
      <> "  Run `seal access-control reset --yes` (with the daemon stopped) and enroll again."
  BrCredentialsVersion version ->
    "credentials.toml has format version " <> tshow version
      <> ", which this build does not understand.\n"
      <> "  Upgrade seal, or restore a backup of ~/.seal/credentials.toml."
  BrModeInvalid raw ->
    "access_control.mode is \"" <> raw <> "\", which is not a valid mode.\n"
      <> "  Use \"passkey\" (the default) or \"none\"."
  BrCoordinatesInvalid err ->
    "[access_control] origin/rp_id are unusable: " <> err
      <> "\n  Set origin to an absolute URL (or unset it for a loopback bind)."
  BrUnsafeBind reason ->
    "refusing to serve passkey-protected access with an unusable origin: " <> reason
      <> "\n  Bind a loopback address, or run behind a TLS reverse proxy and set "
      <> "[access_control] origin to its https:// URL."
  BrPublicBindWithLoopbackOrigin ->
    "the gateway binds a non-loopback address but [access_control] origin is a "
      <> "loopback URL.\n"
      <> "  Browsers reaching it from another machine cannot use a localhost "
      <> "origin, and the setup window would be reachable from the network.\n"
      <> "  Set origin to the address clients actually use."

-- | Everything the runtime needs, already decided. The handle built from this
-- never reads @credentials.toml@ again, which is what makes a mid-flight edit
-- of the store unable to change the running gateway's behaviour.
data BootPlan = BootPlan
  { bpMode      :: !AccessMode
  , bpOrigin    :: !(Maybe Text)
  , bpRpId      :: !(Maybe Text)
  , bpCreds     :: !(Map Text Credential)
  , bpMintGrant :: !(Maybe GrantSource)
    -- ^ 'Just' when boot should mint an enrollment grant: nothing enrolled,
    -- nothing usable, or access control is off. Never minted when a usable
    -- credential exists — there is already an authority.
  } deriving stock (Eq, Show)

-- | Read the two files and hand 'bootPlan' what it needs.
--
-- Reads @security.toml@ as text /and/ decodes it: the raw document is what the
-- legacy check needs, and the decoded section is what the table needs.
preflight :: SealPaths -> IO (Either BootRefusal BootInputs)
preflight paths = do
  securityExists <- doesFileExist (securityFilePath paths)
  raw <- if securityExists then TIO.readFile (securityFilePath paths) else pure ""
  creds <- credentialsPresence paths
  -- A document that does not decode leaves the section absent here; 'bootPlan'
  -- refuses it with the decoder's own message. Deciding it in one place keeps
  -- the refusals testable without files, and keeps the two copies from
  -- disagreeing about which condition wins.
  pure (Right BootInputs
    { biSecurityRaw = raw
    , biSection     = either (const Nothing) scAccessControl (decodeSecurityConfig raw)
    , biCredentials = creds })

credentialsPresence :: SealPaths -> IO CredentialsPresence
credentialsPresence paths = do
  loaded <- loadCredentials (credentialsFilePath paths)
  pure $ case loaded of
    Left err               -> CredentialsInvalid err
    Right Nothing          -> CredentialsAbsent
    Right (Just file)      -> CredentialsPresent (crdVersion file) (crdCredentials file)

-- | The design §10 table.
bootPlan :: BindCoordinates -> BootInputs -> Either BootRefusal BootPlan
bootPlan coords inputs = do
  -- The two document-level refusals. Both live here rather than in 'preflight'
  -- because 'BootInputs' carries the raw text precisely so the decision stays
  -- pure. Order matters: a document that does not even parse is refused first,
  -- since 'hasLegacyLayout' answers False for it and would otherwise let a
  -- corrupt file through as "no legacy layout".
  case decodeSecurityConfig (biSecurityRaw inputs) of
    Left err -> Left (BrSecurityUnparseable err)
    Right _  -> Right ()
  -- Legacy before anything about the store: a pre-split install has no
  -- credentials.toml at all, so reporting the missing store would send the
  -- operator to `reset --yes` when the answer is `migrate-credentials`.
  if hasLegacyLayout (biSecurityRaw inputs) then Left BrLegacyLayout else Right ()
  creds <- plannedCredentials (biCredentials inputs)
  mode <- plannedMode inputs creds
  (origin, rpId) <- case resolveCoordinates (bcHost coords) (bcPort coords)
                                            (biSection inputs) mode of
    Left err -> Left (BrCoordinatesInvalid err)
    Right resolved -> Right resolved
  checkBind coords mode origin rpId
  pure BootPlan
    { bpMode      = mode
    , bpOrigin    = origin
    , bpRpId      = rpId
    , bpCreds     = creds
    , bpMintGrant = mintFor mode rpId creds
    }

-- | The credential map, or a refusal. The version is checked before anything
-- else: a future format must not be read with this build's assumptions.
plannedCredentials :: CredentialsPresence -> Either BootRefusal (Map Text Credential)
plannedCredentials presence = case presence of
  CredentialsAbsent        -> Right Map.empty
  CredentialsInvalid err   -> Left (BrCredentialsInvalid err)
  CredentialsPresent v raw
    | v /= credentialsVersion -> Left (BrCredentialsVersion v)
    | Map.null raw            -> Left BrCredentialsEmpty
    | otherwise               -> case traverse credentialFromFile (Map.toList raw) of
        Left err -> Left (BrCredentialsInvalid err)
        Right ok -> Right (Map.fromList ok)

-- | Mode, including the one defaulting rule: no @mode@ line means passkey when
-- credentials exist and unconfigured otherwise. @none@ is never inferred.
plannedMode :: BootInputs -> Map Text Credential -> Either BootRefusal AccessMode
plannedMode inputs creds = case biSection inputs >>= acfcMode of
  Nothing
    | Map.null creds -> Right AccessUnconfigured
    | otherwise      -> Right AccessPasskey
  Just raw -> case parseAccessMode raw of
    Left err  -> Left (BrModeInvalid err)
    Right mode -> Right mode

-- | The two bind checks, kept as separate constructors so a failure tells the
-- operator which of the two distinct problems they have.
checkBind
  :: BindCoordinates -> AccessMode -> Maybe Text -> Maybe Text
  -> Either BootRefusal ()
checkBind coords mode origin rpId
  -- Most specific first: a public bind pointed at a loopback origin is that
  -- mistake, not the broader "not https" one, and the two need different fixes.
  | not loopbackBind && maybe False isLoopbackHost rpId =
      Left BrPublicBindWithLoopbackOrigin
  | mode == AccessPasskey && not loopbackBind && not originIsHttps =
      Left (BrUnsafeBind "the bind address is not loopback and the origin is not https")
  | otherwise = Right ()
  where
    loopbackBind = isLoopbackHost (bcHost coords)
    originIsHttps = maybe False ("https://" `T.isPrefixOf`) origin

-- | Which boot states mint an enrollment grant (design §11).
--
-- A usable credential means an assertion is available, so nothing is minted. In
-- @open@ mode the grant is what stops a network client enrolling its own
-- credential and flipping a public gateway into one locked with a key the
-- operator does not hold.
mintFor :: AccessMode -> Maybe Text -> Map Text Credential -> Maybe GrantSource
mintFor mode rpId creds = case mode of
  AccessUnconfigured -> Just CliToken
  AccessOpen         -> Just CliToken
  AccessPasskey      -> case credentialAvailability rpId creds of
    Usable       -> Nothing
    NoCredentials -> Just CliToken
    UnusableOnly -> Just CliToken
tshow :: Show a => a -> Text
tshow = T.pack . show
