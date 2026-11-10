# First-run gateway coordinates — narrow implementation plan

<!-- date: 2026-11-09 -->
<!-- status: revised (plan review round 2) -->
<!-- design: docs/superpowers/specs/2026-11-09-first-run-gateway-coordinates-design.md -->

## Scope decision

Implement the **core**: a human-only `seal access-control configure` command
that persists final bind host/port, TLS settings, origin and `rp_id` before the
first passkey enrollment, plus removal of the dead
`--server-host`/`--server-port` surface.

Explicitly out of scope (operator-accepted residual risk):

- `--dry-run`.
- `serve` host/port overrides; the flags are removed instead.
- Global cross-process locking of every `security.toml` writer. `configure`
  acquires the existing serve lock (excluding a running daemon); a concurrent
  `tui`/`/vault setup` or another CLI writer can still cause a lost update.
  Corruption of the file itself is prevented by the unique-temp write in WU2.
- `bootPlan` hardening for non-loopback plain-http binds, and
  `--no-enrollment-token` loopback checks. Accepted by the operator.
- Audit event for coordinate changes.
- A global `resolveRpIdUnchecked` tightening; `configure` applies a strict
  check locally.
- Public-suffix detection, PEM content validation, certificate trust.

## User outcome

On a fresh `SEAL_HOME`, one command sets the final hostname/port/origin; then
`seal serve` → enroll → restart still works with the same passkey, with no
hand-edited `security.toml`. The setup wizard still runs because `configure`
never writes `access_control.mode`.

## PR mapping (one logical change per PR)

- **PR1 — WU1**: remove the dead server config surface. Independent, breaking
  cleanup; CHANGELOG/README note included.
- **PR2 — WU2**: security-file write safety (unique temp, atomic template
  creation). Independent of the command.
- **PR3 — WU3–WU6**: the `configure` command (types, planner, handler, docs).
  WU3–WU5 are one compile unit: adding `AcConfigure` makes the existing
  `runAccessControlWith` case non-exhaustive under `-Werror`. `make check` is
  green at the end of each PR, not after each WU.

## Work units

### WU1 — remove the dead server config surface (PR1)

Files: `src/Seal/Types/Config.hs`, `src/Seal/Types/Env.hs`,
`src/Seal/AppMain.hs`, `test/Seal/ConfigSpec.hs`, `test/Seal/AppMainSpec.hs`,
`test/Seal/Command/ServeSpec.hs`.

- Remove `ServerConfig`, `defaultServerConfig`, `pServerConfig`,
  `serverConfig_host`, `serverConfig_port`, `config_server`, `_config_server`,
  the `server` JSON key, and the `config_server` parser entry.
- Remove `envServerHost`/`envServerPort` and `mkEnv` wiring.
- `reorderGlobalArgs` keeps only `--log-level`; `--server-host`/`--server-port`
  are no longer hoisted and are rejected by the parser in either position.

Tests first:
- `ConfigSpec`: `--print-config` (encode `defaultConfig`) has no `server` key.
- `AppMainSpec`: `["serve","--log-level","debug","--server-host","0.0.0.0"]`
  reorders to `["--log-level","debug","serve","--server-host","0.0.0.0"]`
  (the flag stays after `serve`; the parser then rejects it).
- `ServeSpec`: `serve --server-host 0.0.0.0` and
  `--server-host 0.0.0.0 serve` both fail to parse; `serve` alone still parses.

### WU2 — security-file write safety (PR2)

Files: `src/Seal/Config/Security.hs`, `src/Seal/Config/Templates.hs`,
`test/Seal/Config/SecuritySpec.hs`,
`test/Seal/Config/TemplatesSpec.hs` (create if absent; wire into
`test/Main.hs` **and** the cabal test-suite `other-modules:`).

- Add one shared temp-file helper (in `Seal.Config.Security`): open a unique
  temp in the destination directory with `openBinaryTempFile` and immediately
  `setFileMode 0600`, returning the handle and path. `openBinaryTempFile` is
  `mkstemp`-style (`O_CREAT|O_EXCL`, mode 0600); `O_EXCL` makes a pre-created
  symlink or same name fail, so `O_NOFOLLOW` is redundant — record this in a
  comment.
- `saveSecurityConfig`: use that helper instead of the fixed
  `path <> ".tmp"`, write, close, `setFileMode 0600`, rename. Two concurrent
  writers to the **same** path target distinct temp files.
- `Templates.seedFile`: use that helper too, then install with `createLink`
  (hard link) so an existing destination makes the install fail with `EEXIST`;
  remove the temp either way. A file created after the existence check is never
  overwritten, and two concurrent seeders of the same path cannot corrupt the
  installed file.

Tests first:
- `SecuritySpec`: two concurrent `saveSecurityConfig` calls on the **same
  path** with different valid snapshots; the final file decodes to one complete
  snapshot (not a truncation/mix); no temp file remains in the directory; a
  writer produces mode 0600.
- `TemplatesSpec`: two concurrent `ensureConfigTemplates` calls on the same
  home create each file once and never replace a file written between the check
  and install; an existing file is returned as `Nothing` (not created); no temp
  file remains.

### WU3 — command surface (PR3)

Files: `src/Seal/Types/Command.hs`, `test/Seal/Command/ServeSpec.hs`
(extend; do not add a new spec or touch `test/Main.hs`/cabal).

- `AccessControlAction` gains `AcConfigure !ConfigureOptions` (derive
  `Eq, Show`).
- `ConfigureOptions` (strict fields):
  `coHost :: Maybe Text`, `coPort :: Maybe Text` (raw decimal, validated in the
  command with a total parser), `coTls :: Bool`, `coNoTls :: Bool`,
  `coTlsCert :: Maybe Text`, `coTlsKey :: Maybe Text`,
  `coTlsHosts :: [Text]`, `coOrigin :: Maybe Text`, `coRpId :: Maybe Text`.
- `pAccessControl` adds `configure` with `--host`, `--port`, `--tls`,
  `--no-tls`, `--tls-cert`, `--tls-key`, `--tls-host` (repeatable),
  `--origin`, `--rp-id`, and a `progDesc`.

Tests first: each flag parses; `--tls`/`--no-tls` both parse; `--help` mentions
`configure` and every flag name.

### WU4 — pure planner and validation (PR3)

Files: `src/Seal/Command/AccessControl.hs`.
Tests: `test/Seal/Command/AccessControlSpec.hs`.

Export `ConfigureError(..)`, `PlannedConfigure(..)`, `planConfigure`,
`configureExit`, and (WU5) `runAccessControlWithOutput` from
`Seal.Command.AccessControl` so the specs can import them. `ConfigureOptions`
is exported from `Seal.Types.Command`.

Types:

```haskell
data ConfigureError = ConfigureUsage Text | ConfigureRefusal Text
  deriving stock (Eq, Show)
configureExit :: ConfigureError -> ExitCode   -- Usage -> 2, Refusal -> 1

data PlannedConfigure = PlannedConfigure
  { plConfig   :: SecurityConfig
  , plResolved :: (Maybe Text, Maybe Text)   -- (origin, rp_id)
  }

planConfigure
  :: SecurityConfig -> CredentialsPresence -> ConfigureOptions
  -> Either ConfigureError PlannedConfigure
```

`planConfigure` is pure and:

- rejects zero coordinate options (`ConfigureUsage`);
- parses `coPort` with `readMaybe` into `1..65535` (`ConfigureUsage` on
  non-numeric/out-of-range);
- rejects `--tls` + `--no-tls`, `--no-tls` with any TLS flag, cert without key
  (or key without cert), relative cert/key paths (`ConfigureUsage`), and
  empty/whitespace `--tls-host` (`ConfigureUsage`); `--tls-host` requires TLS
  to be effectively on (after `--tls`/cert+key/`--no-tls`), else
  `ConfigureUsage`;
- strict origin parse on the **raw** text: reject whitespace, `@`, `?`, `#`,
  `\`, a trailing path, and any scheme other than `http`/`https`, then run
  `normalizeOrigin` and keep the normalised value (`ConfigureUsage`);
- `gatewayHostError` failures are `ConfigureUsage` (a bad `--host` flag value),
  with test cases for empty, whitespace, bracketed IPv6, and URL/path-shaped
  values;
- strict `rp_id`: lower-case and trim it first, then require `rp_id ==
  originHost`, or `("." <> rp_id) isSuffixOf originHost` with at least two
  labels; `localhost` is allowed by equality; IP literals rejected
  (`ConfigureUsage`). This runs **before** `bootPlan`, because
  `resolveRpIdUnchecked` is still permissive;
- applies deltas to the existing `PartialGatewayConfig` /
  `AccessControlFileConfig` (`fromMaybe` empty section), preserving
  `static_dir`, `mode` (including absence), and unrelated fields;
- `--tls` with no `--origin`: keep an existing `https` origin; refuse an
  existing `http` origin (`ConfigureRefusal`); otherwise derive
  `https://<canonical host>[:port]` only when the bind host is loopback
  (canonicalised to `localhost`) or a non-IP domain. Wildcard, non-loopback IP
  literal, and IPv6 hosts without an origin are `ConfigureRefusal`. The derived
  origin omits the port when it is the scheme default (443) and includes it
  otherwise;
- `--no-tls` clears `tls`, `tls_cert`, `tls_key`, `tls_hosts`. It leaves an
  existing `https` origin alone: that is the valid reverse-proxy shape (TLS
  terminated in front, gateway plain-http on loopback);
- `--port` with an explicit persisted origin: rewrite the managed origin's port
  when it matches the old derived bind origin; otherwise `ConfigureRefusal`
  asking for `--origin`;
- merge `allowed_origins`: remove the old managed origin (`old acfcOrigin`) and
  the old derived bind origin, insert the new normalised origin, dedupe; if the
  result is empty, use the new derived origin so `withGatewayDefaults` cannot
  substitute the localhost default;
- resolve effective bind coordinates as `BindCoordinates (gcHost effective)
  (gcPort effective)` where `effective = withGatewayDefaults newCfg`
  (mirroring `access-control status`), then build
  `prospectiveRaw = Toml.encode securityConfigCodec newCfg`,
  `BootInputs prospectiveRaw (scAccessControl newCfg) creds`, call `bootPlan`,
  and use `bpCreds`/`bpRpId` for the credential rule: refuse
  (`ConfigureRefusal`) if the map is non-empty and any `credRpId /= bpRpId`, or
  if `bpRpId == Nothing` with credentials;
- builds `GatewayConfig` with `withGatewayDefaults` for validation only and
  checks `gatewayHostError`, `tlsConfigError`, `tlsOriginError`;
- refuses non-loopback + non-https origin unless `bpMode == AccessOpen`
  (`ConfigureRefusal`);
- verifies the encoded document decodes back equal to `newCfg`
  (`ConfigureRefusal` on mismatch).

Tests first (all named in `AccessControlSpec`):
zero options; ports `"0"`, `"70000"`, `"abc"`, `"-1"`; `--tls`+`--no-tls`;
`--no-tls` with each TLS flag; cert-only/key-only; relative cert/key; empty
`--tls-host`; `--tls-host` without TLS on; host rejects empty, whitespace,
bracketed IPv6, and URL/path-shaped values (all `ConfigureUsage`); origin
rejects `ftp://`, `https://u@h`, `https://h?q`, `https://h#f`, `https://h/p`,
`" https://h "`, `https://h\\x`; rp_id equality, uppercase input normalised,
dot-suffix parent, `localhost`, IP literal, one-label (`com`), subdomain-wrong
direction; allowed_origins merge replaces managed and derived entries, dedupes,
and never becomes empty; `--tls` derives `https://localhost` for
`127.0.0.1`/`::1`, derives for a domain host (omitting `:443`), refuses
wildcard/IPv6-non-loopback; `--no-tls` clears the pair/hosts and leaves an
existing `https` origin; `--port` rewrites a managed origin and refuses an
external one; credential orphan (mismatch and `Nothing`); non-loopback+http
refused unless `mode=none`; encode/decode equality.

Property tests (QuickCheck, bounded):
- normalising an already-normalised origin is idempotent;
- the new origin is always in the resulting `allowed_origins` and the list has
  no duplicates;
- for accepted `rp_id`/origin pairs, `rp_id` is equal to or a parent suffix of
  the origin host.

### WU5 — configure handler and output (PR3)

Files: `src/Seal/Command/AccessControl.hs`,
`test/Seal/Command/AccessControlSpec.hs`.

- Add an output seam:
  `runAccessControlWithOutput :: (Text -> IO ()) -> (Text -> IO ()) -> SealPaths
  -> AccessControlAction -> IO ExitCode`; `runAccessControlWith` delegates with
  real `TIO.putStrLn`/`hPutStrLn stderr`. Tests capture into `IORef`s.
- `AcConfigure opts -> configure paths opts`:
  1. `ensureSealDirs`.
  2. Acquire the serve lock (`acquireServeLock`), release in a bracket; held
     → `ConfigureRefusal` (1).
  3. Refuse when `config.toml` exists and `configHasLegacySecurityFields` is
     true: "run `seal serve` once to migrate, then retry" (1). This avoids the
     fail-open migration data-loss window without changing migration code.
     `configure` never migrates itself; this is documented.
  4. Load `security.toml` (1 if unparseable); `preflight` for
     `CredentialsPresence`.
  5. `planConfigure`; then the resolver check
     (`gatewayHostResolutionError hostResolves`) and cert/key absolute +
     existing + readable checks (1 if missing/unreadable). The resolver is
     passed as a parameter to a small `configureWith` seam so tests use a
     deterministic function; production passes `hostResolves`.
  6. Write with `updateSecurityConfig (securityFilePath paths) (const (plConfig
     plan))` (WU2 makes the write corruption-safe). Document the accepted
     lost-update semantics.
  7. stdout: one `key: old -> new` line per changed key (multi-valued keys
     comma-separated, absent old value `(none)`), then `bind_host:`,
     `bind_port:`, `tls: on|off` (effective via `tlsEnabled`), `origin:`,
     `rp_id:` (`(none)` when unresolved). stderr: warnings (self-signed cert
     trust, `mode=none` non-loopback plain-http) and next steps (`seal serve`,
     `seal access-control status`).
- Existing `runAccessControl` keeps its `ensureConfigTemplates` preamble; the
  handler updates the just-seeded files. (No dry-run, so no restructuring.)

Tests first (using `withHome` and the output seam; `runAccessControlWith` skips
the preamble, so also call `ensureConfigTemplates` in the relevant setup or add
one test through `runAccessControl`):
- success writes all keys and `AcStatus` reports the new origin/rp_id;
- each planner rejection yields exit 2 (usage) or 1 (refusal) with the message
  on stderr and `security.toml` **byte-identical**;
- serve lock held by a child → exit 1, file untouched;
- legacy markers in `config.toml` → exit 1, no `security.toml` created/changed;
- credential orphan → exit 1, file untouched;
- port-only change with a matching credential succeeds and keeps the
  credential;
- `--tls` derivation and `--no-tls` clearing are reflected in the file;
- missing/unreadable cert/key → exit 1;
- output lines match the specified shape (captured);
- fresh-home flow: `ensureConfigTemplates` + `configure`, then
  `deriveSetupState` is still incomplete and `bootPlan` still reports
  `AccessUnconfigured` (wizard-gating regression).

### WU6 — docs, messages, and release notes (PR3)

Files: `README.md`, `config/templates/security.toml`, `CHANGELOG.md`,
`src/Seal/Config/BootPlan.hs`, `src/Seal/Command/AccessControl.hs`,
`test/Seal/Config/BootPlanSpec.hs`, `test/Seal/Command/AccessControlSpec.hs`.

- README first-run flow gains step 0: `seal access-control configure` before
  the first `seal serve`/enrollment, with a reverse-proxy example and a
  direct-TLS example.
- Template comments mention `configure` next to `[gateway]`/`[access_control]`
  and the reset -> configure -> serve -> enroll recovery. Keep the template
  prose ASCII (`TemplatesSpec` asserts it): use `->`, not a Unicode arrow.
- CHANGELOG (PR1 and PR3): removed `--server-host`/`--server-port` and
  `[server]`; new command; accepted residual risks (concurrent-writer
  lost-update, non-loopback plain-http first run unless `mode=none`,
  `--no-enrollment-token` exposure, self-signed TLS trust).
- `bootRefusalMessage`, `access-control status` and `reset` output name the
  configure step and `reset --yes` deleting all passkeys; the credential-orphan
  refusal in `configure` uses the same reset -> configure -> serve -> enroll
  wording.
- Tests: `BootPlanSpec` pins the new refusal text;
  `AccessControlSpec` pins the `status`/`reset`/orphan-refusal copy.

## TDD order

1. PR1: update specs → RED → remove code → GREEN → `make check`.
2. PR2: write-safety specs → RED → implement → GREEN → `make check`.
3. PR3: parser spec → RED → types/parser → planner spec → RED → planner →
   handler spec → RED → handler → docs → `make check`.

Per-PR DoD: branch from `main`; verify a human-filed GitHub issue exists for the
PR (issues are human-authored; if none exists, stop and ask a human), then draft
PR with `Closes #NN`; rebase on `main`; `make check` green (build + test +
hlint); no `--no-verify`; no force push; run `self-reflect` and commit the
knowledge-base updates before opening the PR.

## Accepted risks (explicit)

- A concurrent `tui /vault setup`, `disable`, `reset` or
  `migrate-credentials` can cause a lost update between configure's load and
  write. WU2 prevents file corruption and truncation; it does not prevent the
  semantic lost update. The serve lock excludes a running daemon.
- A non-loopback plain-http first run remains allowed by `bootPlan`, and
  `configure` refuses to create one unless `mode=none`; operators who already
  have one can still boot it. Operator accepted.
- `--no-enrollment-token` still mints a no-secret window without a loopback
  check. Operator accepted.
- Generated self-signed TLS is not trusted for WebAuthn until installed.
- Public-suffix `rp_id` cannot be detected without a PSL; `rp_id == origin host`
  is recommended.
- `updateSecurityConfig` writes the planned snapshot; fields are preserved
  relative to the snapshot configure loaded, not relative to a concurrent
  writer's changes.
