module Seal.Types.Command
  ( Command(..)
  , AccessControlAction(..)
  , EnrollOptions(..)
  , ConfigureOptions(..)
  , pCommand
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Security.Policy (AutonomyLevel (..))

-- | The subcommand selected on the command line. 'CommandNoOp' is the
-- harmless placeholder carried by 'defaultConfig'; it is not exposed as a
-- subcommand (the subcommands are @tui@ and @serve@) and is excluded from
-- the config-file 'FromJSON'/'ToJSON' instances.
-- Each subcommand carries the autonomy level selected via @--yolo@
-- ('Full' — bypass the human-confirmation gate) vs the default
-- ('Supervised' — prompt before running any Untrusted opcode).
data Command
  = CommandNoOp
  | CommandTui AutonomyLevel
  | CommandServe AutonomyLevel (Maybe FilePath) Bool
  | CommandAccessControl AccessControlAction
  | CommandGenOpenApi
  deriving (Eq, Show)

-- | The @seal access-control@ subcommands. All of them are human-driven admin
-- actions against @~\/.seal@; none is an opcode.
--
-- @enroll@ mints the one-time authority that adds a credential, @disable@ is
-- the only way to turn access control off (there is no HTTP path that can),
-- @reset@ is the lost-every-device escape hatch, and @migrate-credentials@
-- finishes the pre-split → @credentials.toml@ move. @configure@ persists the
-- gateway coordinates before the first passkey is enrolled.
data AccessControlAction
  = AcStatus
  | AcEnroll !EnrollOptions
  | AcConfigure !ConfigureOptions
  | AcDisable !Bool
    -- ^ @--yes@: disabling hands the gateway to anyone who can reach it, so it
    -- is never implicit. Kept as a field rather than a parse-time requirement so
    -- a missing @--yes@ is a usage error (exit 2) the command can report.
  | AcReset
  | AcMigrateCredentials !Bool
    -- ^ @--force@: re-run the table removal even though @credentials.toml@
    -- exists. Never overwrites the store itself.
  deriving (Eq, Show)

-- | The @configure@ flag set. Every field is optional (except that at least
-- one must be present, which the command enforces): the operator changes the
-- coordinates they name and nothing else. @coPort@ is raw text so a bad value
-- is a usage error (exit 2) the command reports, not an optparse failure.
data ConfigureOptions = ConfigureOptions
  { coHost     :: !(Maybe Text)
  , coPort     :: !(Maybe Text)
  , coTls      :: !Bool
  , coNoTls    :: !Bool
  , coTlsCert  :: !(Maybe FilePath)
  , coTlsKey   :: !(Maybe FilePath)
  , coTlsHosts :: ![Text]
  , coOrigin   :: !(Maybe Text)
  , coRpId     :: !(Maybe Text)
  } deriving (Eq, Show)


-- | The @enroll@ flag matrix. Validation lives in the command, not the parser,
-- so every illegal combination is reachable and testable as a usage error.
data EnrollOptions = EnrollOptions
  { eoTtl     :: !(Maybe String)
    -- ^ @--ttl N[s|m|h]@, unparsed: the command clamps and rejects.
  , eoNoToken :: !Bool
    -- ^ @--no-token@: mint a loopback-confined window grant instead of a token.
  , eoForce   :: !Bool
    -- ^ @--force@: replace an outstanding grant.
  , eoCancel  :: !Bool
    -- ^ @--cancel@: drop the outstanding grant, its claims and its token.
  } deriving (Eq, Show)

pCommand :: Parser Command
pCommand = hsubparser
  $  command "tui" (info (CommandTui <$> pAutonomy)
                         (progDesc "Start the interactive terminal UI (TUI)"))
  <> command "serve" (info (CommandServe <$> pAutonomy <*> pStaticDir <*> pNoEnrollmentToken)
                            (progDesc "Run the web gateway server"))
  <> command "access-control"
       (info (pAccessControl <**> helper)
             (progDesc "Manage passkey access control (security.toml, credentials.toml)"))
  <> command "gen-openapi" (info (pure CommandGenOpenApi)
                                  (progDesc "Print the OpenAPI 3.1 spec (JSON) to stdout"))

-- | @access-control status | enroll | disable | reset | migrate-credentials@.
pAccessControl :: Parser Command
pAccessControl = CommandAccessControl <$> hsubparser
  (  command "status"
       (info (pure AcStatus)
             (progDesc "Print the access-control mode, origin and enrolled credentials"))
  <> command "enroll"
       (info (AcEnroll <$> pEnroll)
             (progDesc "Mint a one-time enrollment grant (token on stdout, hints on stderr)"))
  <> command "configure"
       (info (AcConfigure <$> pConfigure)
             (progDesc "Set the gateway bind host/port, TLS and passkey origin before first enrollment"))
  <> command "disable"
       (info (AcDisable <$> pDisableConfirm)
             (progDesc "Turn access control off, keeping credentials (requires --yes)"))
  <> command "reset"
       (info (AcReset <$ pResetConfirm)
             (progDesc "Remove the credentials and the section so you can re-enroll (requires --yes)"))
  <> command "migrate-credentials"
       (info (AcMigrateCredentials <$> pMigrateForce <* pMigrateConfirm)
             (progDesc "Move passkeys out of security.toml into credentials.toml (requires --yes)"))
  )

-- | The @enroll@ flags. Mutually exclusive combinations are rejected by the
-- command with exit code 2.
pEnroll :: Parser EnrollOptions
pEnroll = EnrollOptions
  <$> optional (strOption
        ( long "ttl"
       <> metavar "N[s|m|h]"
       <> help "Grant lifetime, e.g. 90s, 10m, 1h (default 10m, window 5m; 30s-24h)"
       ))
  <*> switch
        ( long "no-token"
       <> help "Mint a loopback-only enrollment window instead of a token (bootstrap only)"
        )
  <*> switch
        ( long "force"
       <> help "Replace an outstanding grant instead of refusing"
        )
  <*> switch
        ( long "cancel"
       <> help "Drop the outstanding grant, its claims and its token file"
        )

-- | The @configure@ flags. All optional; the command requires at least one and
-- validates combinations (exit 2) before touching the filesystem.
pConfigure :: Parser ConfigureOptions
pConfigure = ConfigureOptions
  <$> optionalText "host" "HOST" "Bind host (a name, an address, or 0.0.0.0 for every interface)"
  <*> optionalText "port" "PORT"
        "Bind port (1-65535); must match the port clients use"
  <*> switch
        ( long "tls"
       <> help "Serve HTTPS (with --tls-cert/--tls-key, or a generated self-signed pair)"
        )
  <*> switch
        ( long "no-tls"
       <> help "Serve HTTP; clears tls_cert, tls_key and tls_hosts"
        )
  <*> optionalFilePath "tls-cert" "PATH" "PEM certificate chain (implies TLS)"
  <*> optionalFilePath "tls-key" "PATH" "PEM private key (implies TLS)"
  <*> many (T.pack <$> strOption
        ( long "tls-host"
       <> metavar "NAME"
       <> help "Replace the generated certificate's SAN names (repeatable; requires TLS)"
        ))
  <*> optionalText "origin" "URL"
        "External origin clients use (https://name[:port]); also allowlisted for the WebSocket"
  <*> optionalText "rp-id" "DOMAIN"
        "WebAuthn relying-party id (defaults to the origin host)"
  where
    optionalText longName meta desc =
      (T.pack <$>) <$> optional (strOption
        ( long longName <> metavar meta <> help desc ))
    optionalFilePath longName meta desc =
      optional (strOption
        ( long longName <> metavar meta <> help desc ))

-- | @--force@ re-runs the table removal. It never overwrites @credentials.toml@.
pMigrateForce :: Parser Bool
pMigrateForce = switch
  ( long "force"
 <> help "Drop the stale tables even if credentials.toml already exists (the store is never overwritten)"
  )

-- | @--yes@ is mandatory: a migration rewrites the file the next boot depends on.
pMigrateConfirm :: Parser ()
pMigrateConfirm = flag' ()
  ( long "yes"
 <> help "Confirm rewriting security.toml"
  )

-- | @--yes@ is mandatory: resetting access control hands the gateway to anyone
-- who can reach it until setup completes again.
pResetConfirm :: Parser AccessControlAction
pResetConfirm = flag' AcReset
  ( long "yes"
 <> help "Confirm removing the access_control section (anyone who can reach the gateway can re-enroll)"
  )

-- | @--yes@ is mandatory: with access control off, anyone who can reach the
-- gateway has full control.
pDisableConfirm :: Parser Bool
pDisableConfirm = switch
  ( long "yes"
 <> help "Confirm turning access control off (anyone who can reach the gateway gets full control)"
  )

-- | @--yolo@ sets 'Full' autonomy (bypass the untrusted-opcode approval
-- gate); absent defaults to 'Supervised'.
pAutonomy :: Parser AutonomyLevel
pAutonomy = flag Supervised Full
  ( long "yolo"
  <> help "Bypass the approval gate so untrusted opcodes run without prompting (ACK audit still recorded)"
  )

-- | @--static-dir DIR@ overrides the @[gateway] static_dir@ in
-- @~\/.seal\/security.toml@, serving UI assets from DIR instead of the embedded
-- bundle (dev mode). Absent = @Nothing@ (use the security config or the
-- embedded default).
pStaticDir :: Parser (Maybe FilePath)
pStaticDir = optional (strOption
  ( long "static-dir"
  <> metavar "DIR"
  <> help "Serve static UI assets from DIR instead of the embedded bundle (dev mode)"
  ))

-- | @--no-enrollment-token@ mints a 'CliWindow' grant at boot instead of a
-- 'CliToken' grant: the browser can enroll a passkey without pasting a token.
-- The operator asserts the network is secured (firewall/VPN) — the token's
-- purpose is to prevent a remote attacker from enrolling first.
pNoEnrollmentToken :: Parser Bool
pNoEnrollmentToken = switch
  ( long "no-enrollment-token"
  <> help "Skip the enrollment token on first run (for a gateway behind a firewall/VPN)"
  )
