# First-run gateway coordinates: `seal access-control configure`

<!-- status: revised (design review round 3) -->
<!-- date: 2026-11-09 -->

## Problem

A passkey is cryptographically bound to the WebAuthn relying-party id (`rp_id`,
a domain). Seal derives `origin`/`rp_id` from `[gateway] host`/`port` (or from
`[access_control] origin`). A fresh install ships `host = "localhost"`, so the
first passkey is enrolled for `localhost`. Changing the hostname afterwards
changes the resolved `rp_id`; every existing credential becomes `rp_mismatch`
and is unusable. That is correct WebAuthn behaviour, but it makes "enroll first,
point it at your domain later" impossible.

Secondary: `seal serve --server-host` / `--server-port` are parsed into
`ServerConfig` and copied into `Env`, but nothing reads them; the listener is
derived solely from `security.toml`. And there is no supported way to set the
final production coordinates *before* the first enrollment except hand-editing
`security.toml` between the first boot and the first passkey ceremony.

## Use cases

- **UC1 — fresh install, final domain.** Operator sets the public
  hostname/port/origin before anyone enrolls, so the first passkey is bound to
  the domain clients use. Before the first `seal serve`/enrollment.
- **UC2 — enrolled on localhost, now wants a domain.** Recovery is explicit:
  `reset --yes` (deletes every enrolled passkey) → re-run `configure` → `serve`
  → enroll. The refusal text states this.
- **UC3 — TLS reverse proxy.** Bind loopback, verify/allowlist the external
  `https://` origin. First run.
- **UC4 — direct TLS with a trusted cert/key.** Serve HTTPS itself; a
  certificate must already be trusted for WebAuthn (generated self-signed is
  not, until installed/trusted).
- **UC5 — wildcard/VPN bind.** `0.0.0.0` behind a firewall/VPN with a named
  origin.
- **UC6 — upgrading install.** Preserve a `[gateway]` still in `config.toml`.
- **UC7 — port-only change.** Move 8080 → 8443 on the same host; keep passkeys.

## Success criteria

- Following the documented first-run flow, an operator reaches a working
  domain-bound passkey with **zero hand edits** of `security.toml`.
- Zero first-enrollment `rp_mismatch` failures when the flow is followed.
- `configure --dry-run` output matches the subsequent real write, and the
  dry-run leaves `security.toml`, `config.toml`, `credentials.toml` and the
  audit log byte-identical.
- After `configure`, `serve` boots and the banner/`access-control status`
  report the intended origin/`rp_id`.
- A refused change leaves `security.toml` byte-identical.

## Goals

- Persist bind host/port, TLS settings, external origin, `rp_id` and
  generated-certificate names **before the first enrollment**, through a
  human-driven CLI.
- Validate that the written configuration can boot under the same rules
  `serve` applies, and that it cannot silently orphan credentials.
- Make the `serve` host/port flags real transient overrides, subject to the
  same pre-bind checks.
- Keep the security model: only human-driven CLI/admin paths write
  `~/.seal/security.toml`.

## Non-goals

- Migrating an existing passkey to a new `rp_id` (impossible; reset+re-enroll).
- Multiple `rp_id`s / multiple external origins.
- Wizard-written coordinates.
- Auto-clearing credentials (rejected: deletes the only factor).
- Issuing/trusting/validating certificate chains.
- Unsetting fields from the CLI (hand edit), except `--no-tls`.
- Changing `[access_control] mode`; it is preserved exactly, including absence.

## Setup-wizard gating is independent

The web wizard is **not** triggered by config-file presence:

- `AccessGate` uses `/api/auth/status`; `setup_required` is true when
  `acsMode == AccessUnconfigured` or credentials belong to another `rp_id`.
  `configure` never writes `mode`, so a fresh install stays `unconfigured`.
- `SetupGate` uses `GET /api/setup`; `required_complete` comes from
  `deriveSetupState`, which reads only the vault and provider steps.
- `seal access-control` already calls `ensureConfigTemplates` for every action,
  so a fresh home gets both templates from `status` alone.

**Regression test:** fresh home → `configure` → `deriveSetupState` still
reports vault+provider pending, and `bootPlan` still reports
`AccessUnconfigured`.

## Command surface

```
seal access-control configure
  [--host HOST] [--port PORT]
  [--tls | --no-tls]
  [--tls-cert PATH] [--tls-key PATH] [--tls-host NAME ...]
  [--origin URL] [--rp-id DOMAIN]
  [--dry-run]
```

- At least one coordinate option required; zero is usage (exit 2).
- `--host`/`--port` update `[gateway] host`/`port`.
- `--tls`/`--no-tls`: TLS semantics below.
- `--tls-cert`/`--tls-key`: must be given together, **must be absolute paths**,
  and must exist as readable regular files. They imply TLS.
- `--tls-host` (repeatable) **replaces** `tls_hosts`; names non-empty, no
  whitespace/control chars. Requires TLS to be on (else usage error).
- `--origin` updates `[access_control] origin`. Normalised to `scheme://host[:port]`
  with only `http`/`https`; userinfo, fragment, query, path, whitespace are
  rejected. It **replaces the previously managed origin** in `allowed_origins`
  (old managed entry removed, new inserted, hand-added entries preserved,
  duplicates dropped). When `--host`/`--port` change the derived bind origin,
  that old derived origin is also removed from `allowed_origins` so the
  allowlist does not grow.
- `--rp-id` updates `[access_control] rp_id`; validated with a **strict**
  direction: `rp_id == origin host`, or `rp_id` is a dot-suffix of the origin
  host (`(".", rp_id) isSuffixOf originHost`), and `rp_id` has at least two
  labels. The existing permissive `resolveRpIdUnchecked` direction
  (`rp_id` as a subdomain of the origin host) is tightened globally because it
  can boot an unusable gateway. Public-suffix rp_ids (e.g. `co.uk`) cannot be
  detected without a PSL; documented residual, and `rp_id == origin host` is
  recommended.
- `--dry-run`: runs every read-only check, prints the planned change, writes
  nothing, takes no locks.

### Why a dedicated command

A boot flag that mutates security-critical config implicitly is a footgun. The
dedicated command is explicit, testable without a socket, and CLI-only.
`serve` flags remain transient overrides.

## TLS semantics

`tlsEnabled = gcTls || (cert && key set)`.

- `--tls` without an explicit origin:
  - no persisted origin → derive `https://<effective host>[:port]` and write it
    (wildcard bind cannot derive → refuse, ask for `--origin`);
  - persisted origin is already `https` → keep it;
  - persisted origin is `http` → refuse, do not silently overwrite; tell the
    operator to pass `--origin https://...`.
- `--tls` with `--origin http://...` → refuse (`tlsOriginError`).
- `--tls` with no cert/key → `serve` generates a self-signed pair; output warns
  it is not trusted for WebAuthn until installed/trusted.
- `--tls-cert`/`--tls-key` alone imply TLS (matching `tlsEnabled`); validate
  existence/readability and absolute paths.
- `--no-tls` sets `tls = false` **and clears `tls_cert`, `tls_key`,
  `tls_hosts`** (otherwise the pair keeps TLS on). Usage error together with
  any TLS flag. Destroys the SAN list by design; documented.
- Always print the **effective** TLS state via `tlsEnabled`.

## Validation and exit codes

2 = malformed flags/usage; 1 = state/environment refusal; 0 = success.

Exact check order (mirrors `serve`): `tlsConfigError`, `gatewayHostError`,
`gatewayHostResolutionError`, `bootPlan` on prospective bytes, `tlsOriginError`.

### Usage errors (exit 2)

- no coordinate option; non-numeric/out-of-range port (`1..65535`);
- blank/whitespace/bracketed-IPv6 host, or URL/path-shaped host
  (`gatewayHostError`);
- origin not absolute `http`/`https`, or with userinfo/fragment/query/path/
  whitespace;
- `rp_id` empty/whitespace, IP literal, fewer than two labels, or not a
  parent-domain/equal suffix of the origin host;
- `--tls` + `--no-tls`; `--no-tls` + any TLS path/host flag; cert without key
  (or vice versa); relative cert/key path; `--tls-host` without TLS on;
- empty/whitespace `--tls-host`.

### State/environment refusals (exit 1)

- `seal serve` running (serve lock unavailable) or another config write holding
  `security.toml.lock`;
- `security.toml` unparseable, still in legacy credential layout, or a write
  fails;
- `credentials.toml` invalid/empty/future version/legacy layout;
- any enrolled credential's `rp_id` would differ from the prospective `bpRpId`;
- a non-loopback bind with a non-https origin **unless** `mode = none` (the
  explicit waiver);
- unresolvable host;
- TLS pair incomplete, or TLS enabled with an http origin;
- prospective `bootPlan` refusal;
- explicit cert/key path missing/unreadable;
- after `migrateSecurityConfig`, `config.toml` still carries legacy security
  fields (migration failed or is undecidable) — refuse rather than create a
  `security.toml` that would make the next boot drop them.

### Credential rule

Use `BootPlan.bpCreds`/`bpRpId` (one derivation). Refuse when the map is
non-empty and **any** `cred_rp_id /= bpRpId`. Deliberately conservative: a
mixed store must be reset, not half-preserved. `bpRpId == Nothing` with any
credential is a refusal. A port-only change keeps `bpRpId`, so credentials
survive. `mode = none` does not exempt credentials.

Refusal copy names the destructive recovery exactly:
`seal access-control reset --yes` (deletes every enrolled passkey) →
`seal access-control configure ...` → `seal serve` → enroll.

## Write safety, upgrade window, and `--dry-run`

The command lives in `Seal.Command.AccessControl`; **no broad
`SecurityConfig -> SecurityConfig` writer is added to
`Seal.Config.Security`**.

Ordered steps:

0. `--dry-run` short-circuits: no `ensureSealDirs`, no templates, no migration,
   no locks, no audit; read the current security/legacy-gateway values
   read-only (as `access-control status` does), plan and print.
1. `ensureSealDirs` (the state directory must exist before a lock file can be
   created; a truly fresh home otherwise fails at step 2).
2. Acquire the **serve lock** (fcntl; non-blocking) and the **config write
   lock** (`security.toml.lock`, the same `O_CREAT|O_EXCL` lock vault setup
   uses) for the whole read-modify-write. Both are non-blocking; either failing
   is a refusal. This serializes configure against `serve`, other `configure`
   runs, and `tui`/`/vault setup` (which already uses `security.toml.lock`).
   Extract the generic O_EXCL lock helper out of `Provision.withSetupLock` into
   a shared home (`Seal.Security.DaemonLock`) and make `withSetupLock` delegate,
   so both paths use one mechanism.
3. Run `migrateSecurityConfig` **and verify it**: re-read `config.toml`; if
   `configHasLegacySecurityFields` is still true, refuse (exit 1) with
   "run `seal serve` once to migrate, then retry". Then `ensureConfigTemplates`.
   This closes the fail-open migration window: configure never writes a
   `security.toml` that would cause the next boot's "security.toml wins" branch
   to strip un-migrated vault/`[untrusted_execution]` settings.
4. Load and refuse an unparseable `security.toml`.
5. Apply only the requested deltas to the existing decoded
   `PartialGatewayConfig`/`AccessControlFileConfig` (never rebuild from resolved
   defaults), preserving `static_dir`, TLS paths, origins, `mode`, and
   absent-vs-explicit distinctions.
6. Encode the prospective document, decode it again, and compare the whole
   `SecurityConfig` for equality with the intended value.
7. Run `preflight` (current on-disk legacy-layout check + credentials presence),
   then `bootPlan` on `BootInputs` built from the **prospective encoded text**
   and `scAccessControl`; then the TLS/host checks in the order above.
8. Write under the config lock via `saveSecurityConfig`. Its temp file becomes
   **unique per call**, created with `O_CREAT|O_EXCL|O_NOFOLLOW` at mode 0600
   (not `openBinaryTempFile` + chmod).
9. Append `CoordinatesChanged` to the audit log (new values only; a failed
   append logs a warning but does not fail the command, matching existing
   audit semantics).

`Templates.seedFile` is changed from fixed-`.tmp`+rename (which can overwrite a
file created after its existence check) to: write a unique 0600 temp, then
`createLink` it into place (fails with `EEXIST`), then unlink the temp. A
concurrent writer can never clobber a just-created template.

## Serve overrides

`CommandServe` gains `ServeOverrides { soHost :: Maybe Text, soPort :: Maybe
String }`; `AppMain.dispatch` validates the port as `1..65535` (stderr + exit 2)
before `runServeMain`. The parser keeps raw text so a bad value is exit 2, not
an optparse exit 1.

Overrides are applied at the **first** `GatewayConfig` binding, immediately
after `gatewayConfigFromSecurity` (`gwCfgForAccess`), **before**
`tlsConfigError`, host checks, `preflight`/`bootPlan`, `tlsOriginError`,
`newAccessControlHandle`, the banner, `sanInputsFor` and the WS allowlist. An
override cannot bypass a refusal.

Additional guards:

- A **host** override is refused if it would change the resolved `rp_id` while
  credentials are enrolled (compare prospective rp_id to the enrolled
  credentials' `cred_rp_id`), because a passkey enrolled under the override
  would be orphaned on restart. `127.0.0.1`→`localhost` canonicalisation and an
  explicit `[access_control] origin` leave `rp_id` unchanged and are allowed.
- A port-only override changes the origin's port but not `rp_id`; allowed.
- A non-loopback plain-http bind is refused when the mode is not `none`
  (including `unconfigured`), so the pre-auth setup screen cannot be exposed by
  an override. This hardening is added to `bootPlan` too, so a persisted config
  gets the same rule.
- `--no-enrollment-token` (a `CliWindow` grant) is refused unless the effective
  bind/origin is loopback, matching the CLI `enroll --no-token` rule. Otherwise
  a no-secret enrollment window could sit on a public interface.

Startup warnings (stderr), split by effect and naming the persist command:

- host override that changes the origin/rp_id: "this boot uses HOST (rp_id X);
  persist with `seal access-control configure --host HOST [--port PORT]`";
- host override that leaves rp_id unchanged: listener-only warning, same hint;
- port override: "this boot listens on PORT; rp_id is unchanged; persist with
  `seal access-control configure --port PORT`";
- both: the hint carries both flags.

### Removing the legacy `ServerConfig`

Remove `ServerConfig`, `defaultServerConfig`, `pServerConfig`,
`serverConfig_host`, `serverConfig_port`, `config_server`, `_config_server`,
the `[server]` config-file decoding and `Config` JSON/default/parser entries,
`Env.envServerHost`/`envServerPort`, and the `--server-host`/`--server-port`
entries in `reorderGlobalArgs`.

Breaking changes documented in `CHANGELOG.md`/README:

- `seal --server-host X serve` (flag before subcommand) is a parse error; use
  `seal serve --server-host X`;
- `--print-config` no longer emits `server`;
- a `[server]` table in `config.toml` is ignored (it was never read).

## Output

stdout (stable, scriptable): one `key: old -> new` line per changed key, then
separate `bind_host:`, `bind_port:`, `tls: on|off` (effective), `origin:` and
`rp_id:` lines. `--dry-run` prefixes the block with `dry_run: true`.
Multi-valued keys print as comma-separated normalised values; an absent old
value prints `(none)`. stderr carries hints, warnings, refusals, usage, and the
next steps (`seal serve`, then `seal access-control status`). Never print key
material or vault values.

## Discovery updates

- `bootRefusalMessage`, `access-control status` and `reset` output point at
  `configure`; `reset` explicitly says it **deletes all enrolled passkeys** and
  gives the reset → configure → serve → enroll order.
- README first-run flow gains step 0 (configure coordinates before first serve).
- `security.toml` template `[gateway]`/`[access_control]` comments mention
  `configure`.
- `CHANGELOG.md` entry for the new command and removed legacy surface.

## Work units

- **WU1 — pure planner + strict validation.** Deltas, http/https origin,
  strict rp_id rule (including tightening `resolveRpIdUnchecked`), port range,
  TLS combinations, prospective `bootPlan`, credential rule, exit-code map.
- **WU2 — locking + write safety.** Extract generic O_EXCL lock to
  `DaemonLock`, make `Provision.withSetupLock` delegate, unique-temp
  `saveSecurityConfig`, atomic create-if-absent `Templates.seedFile`, tests.
- **WU3 — configure handler.** Fresh-home dirs, locks, checked migration,
  load/apply/encode/decode/equality, validation, write, audit, dry-run, output,
  help.
- **WU4 — serve overrides + boot hardening.** Overrides before checks, rp_id
  guard, non-loopback/http bootPlan hardening, `--no-enrollment-token`
  loopback check, split warnings, port validation.
- **WU5 — legacy removal.** Remove `ServerConfig`/`Env` fields, reorder, JSON,
  parser; tests and CHANGELOG/README notes.
- **WU6 — docs/messages.** README step 0, templates, `bootRefusalMessage`,
  `status`, `reset` copy.

Each is independently verifiable and its own logical change.

## TDD outline (concrete)

No new module; existing specs gain cases.

`Command/AccessControlSpec`:
fresh home + full configure writes all keys and `status` reports them;
`--origin` replaces the old managed/derived `allowed_origins` entries; `--tls`
derives https origin; `--tls` + persisted http origin refuses; `--tls` +
`--origin http://` refuses; `--no-tls` clears tls/cert/key/hosts and conflicts
are exit 2; ports `0`/`70000`/`abc` exit 2; blank/bracketed/URL-host exit 2;
unresolvable host exit 1 (injected resolver); ftp/userinfo/fragment/query origin
exit 2; IP/short/subdomain-wrong rp_id exit 2, parent rp_id allowed, public
suffix documented; non-loopback+http exit 1 unless `mode=none`; daemon lock held
→ exit 1; config lock held → exit 1; mismatched credential → exit 1, file
byte-identical; port-only change with matching credential succeeds; invalid/
empty/future credentials exit 1; legacy `[gateway]` migrates and is preserved;
legacy migration failure (config.toml still marked) → exit 1, no security.toml;
`--host` only preserves static_dir/tls_cert/tls_key/tls_hosts/allowed_origins/
mode; successful write is 0600 and round-trips; `--dry-run` leaves
security.toml/config.toml/credentials.toml/audit log byte-identical and matches
the real write's output; fresh-home configure leaves setup incomplete and mode
`AccessUnconfigured`; audit has `event=coordinates_changed` with bind/tls/origin/
rp_id and no secrets.

`Config/SecuritySpec`: unique-temp writes do not collide; legacy-credential
refusal holds; `resolveRpIdUnchecked` rejects the subdomain-wrong direction.

`Security/DaemonLockSpec`: generic O_EXCL lock: concurrent acquire fails,
release allows, stale reclaim; `withSetupLock` still behaves.

`Config/TemplatesSpec`: two concurrent `ensureConfigTemplates` calls create the
file once and never replace a file created after the existence check.

`Gateway/ConfigSpec`/`Command/ServeSpec`: `applyServeOverrides` sets host/port
and preserves the rest; host override changing rp_id with credentials is
refused; effective `bootPlan`/TLS/host checks see the override; non-loopback+
http unconfigured is refused by `bootPlan`; `--no-enrollment-token` on
non-loopback refuses.

`AppMainSpec`: `--server-host` after `serve` is not hoisted; `--log-level` is;
`--server-port abc` exits 2.

`ConfigSpec`: drop the legacy `ServerConfig` assertion; `--print-config` has no
`server` key.

DoD: `make check` green; README/template/help updated; CHANGELOG entry; design
status updated; draft PR with `Closes #NN`; rebase; self-reflect; no
`--no-verify`, no force push.

## Risks

- Generated self-signed TLS is not trusted for WebAuthn until installed.
- Public-suffix `rp_id` cannot be detected without a PSL; recommend equality.
- Wildcard binds make the WS guard accept any Origin (existing); configure
  warns. Fixing that is a separate change.
- Removing `[server]` and the global flags is a documented breaking change.
- `hostResolves` is a typo guard, not a security boundary.

## Alternatives considered

- Persist from `serve` flags: implicit security-config mutation; rejected.
- Auto-clear credentials: deletes the only factor; rejected.
- Wizard-set coordinates: enlarges the pre-auth attack surface; rejected.
