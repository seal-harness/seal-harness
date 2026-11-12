# Plan: move `[gateway]` into `~/.seal/security.toml`

**Status:** draft, revision 4 — awaiting operator decision on one open item (§8)
**Date:** 2026-11-09
**Author:** agent (implementation plan)
**Origin:** operator request — "the `gateway` config section configures the Seal
gateway server. I think that config section needs to be moved into
`~/.seal/security.toml` because things such as the host and port that the server
is listening on are security sensitive and should not be controllable by the
LLM."
**Approved scope (operator):** the **whole `[gateway]` table** moves, including
`static_dir`.

---

## 1. Why

`Seal.Config.Security` exists so that a boot-only, agent-immutable setting lives
in a file whose *codec no agent-reachable writer touches* (`Config/Security.hs`
module header; design §4 Approach B + E in
`docs/superpowers/specs/2026-07-22-remote-enforcement-tamper-proof-design.md`).
`[gateway]` breaks that rule today:

| Reachable from | Path | Can express a `[gateway]` change? |
|---|---|---|
| Opcode file tools | `SafePath` blocks the `.seal` segment (`Security/Path.hs:51`) | No |
| Any `CONFIG_UPDATE` opcode (future) | typed on `RuntimeConfig` | **Yes** — `rcGateway :: Maybe PartialGatewayConfig` (`Config/File.hs:107`, codec `:475`) |
| HTTP gateway writers | `updateRuntimeConfig` (`Gateway/API.hs:1545,1560,2573,2623,2655,2790,2850,2906,2943`) / `saveRuntimeConfig` re-encode the whole file | **Yes** |

Security-relevant values: `host`/`port` (who can reach the gateway),
`allowed_origins` (WS Origin allowlist), `tls` (downgrade switch),
`tls_cert`/`tls_key` (paths read at boot; the key is private material),
`tls_hosts` (SANs on a generated certificate). `static_dir` is the only benign
field and already has a human-driven override (`seal serve --static-dir`); it
moves with the table so a section never lives in two files.

## 2. Non-goals and deliberate consequences

- No new opcode, CLI verb, or HTTP route. No change to gateway/access-control
  *decisions* (ports, defaults, origin derivation, refusal matrix, passkey
  behavior).
- Not narrowing `updateSecurityConfig` (the CLI vault path); it stays a
  full-record writer for admin use, as the design accepts.
- Not changing the migration marker scan's semantics (see WU1.4).
- Not rewriting `CHANGELOG.md` history; a new entry is added.
- **Deliberate consequence A — an unreadable `security.toml` fails closed.** A
  document that does not parse becomes `BrSecurityUnparseable`
  (`BootPlan.hs:152-164`, `:182-184`), i.e. a boot refusal on every entry point.
  Same behavior `[access_control]` already has. (A wrong *value* is a different
  matter: every optional section is decoded through `Toml.dioptional`, which
  demotes a type mismatch to "absent" — pre-existing for every optional field
  in both files, and not changed here. The migration's warning branch therefore
  covers documents that do not parse, not individual typos.)
- **Deliberate consequence B — guard clauses on the two callback-taking
  writers.** `[gateway]` joins the sections asserted unchanged across the
  round-trip in `updateAccessControlSection` and `updateVaultKeySection`. The
  criterion: guards belong where a caller supplies a *function*
  (`AccessControlFileConfig -> AccessControlFileConfig`,
  `SecurityConfig -> Either e VaultKeyFields`) and can therefore express an
  arbitrary field change. `raiseMode`/`restoreMode` (`Security.hs:769-782`,
  `:787+`) take no function and hard-code `acfcMode`, so the type already bounds
  them. These guards implement the promise at `Security.hs:629` and keep the
  newest section from being the one with no back-door check.

## 3. Invariants

1. Every entry point resolves the same `GatewayConfig` it did before while the
   section may still be in `config.toml`:
   - `seal serve` / `seal tui` — `migrateSecurityConfig` runs at boot before the
     config is read (`Serve.hs:159`, `Tui.hs:88`).
   - `seal access-control status|enroll|disable|reset` — does **not** migrate
     (`Command/AccessControl.hs:56-65`), so `gatewayConfig` reads `security.toml`
     first and falls back to a **read-only** parse of `config.toml`'s table. No
     verb gains a write it did not have (WU1.3).
2. `config/templates/*.toml` still resolves to exactly the behavior of both
   files being absent (`TemplatesSpec` "written values resolve like absent
   keys", "keeps security.toml inert", and
   `configHasLegacySecurityFields configTomlTemplate == False` at
   `TemplatesSpec.hs:127`).
3. Migration is idempotent and fail-open, **and no write path can destroy the
   only copy of the settings**: `config.toml` is re-encoded only after
   `security.toml` was written successfully, and a re-encode that would drop a
   still-present `[gateway]` table is refused with instructions (WU1.5).
4. A future `RuntimeConfig -> RuntimeConfig` handler cannot name the gateway
   settings — compile error, asserted by a fixture.

## 4. Work units

Two units. The boundary is set by a three-way coupling that three review rounds
confirmed: `securityConfigCodec` (WU1.1), the `security.toml` template's live
keys (WU1.6, pinned by `TemplatesSpec`'s key-coverage assertion), the migration
marker (WU1.4, which decides whether the template is seeded before the
migration), and the deletion of `rcGateway` (WU1.2, without which
`cleanConfigToml` re-emits the table it just stripped). Any smaller split leaves
an intermediate tree that either fails `make check` or can seed a
`security.toml` that the next unit's "security wins" branch then uses to discard
the operator's real bind address.

Each unit ends with `make check` green (`build test lint frontend-test`, with
`-Werror`). Test modules are part of the built suite (`seal-harness.cabal:580`),
so a record literal, an unused import, or a key-coverage assertion is a **build**
break — and a fixture whose setup writes one file while the code reads another
is a *runtime* break that compiling cannot catch.

### WU1 — the section moves (atomic)

**Files**
- `src/Seal/Config/Security.hs`
- `src/Seal/Gateway/Config.hs`
- `src/Seal/Config/File.hs`
- `src/Seal/Config/Migrate.hs`
- `src/Seal/Command/Serve.hs`
- `src/Seal/Command/AccessControl.hs`
- `src/Seal/Command/Channel.hs`
- `config/templates/config.toml`, `config/templates/security.toml`
- `scripts/setup-walkthrough.sh`, `frontend/e2e/global-setup.ts`
- `test/Seal/Config/{SecuritySpec,TemplatesSpec,MigrateSpec,FileSpec}.hs`
- `test/Seal/Gateway/ConfigSpec.hs`, `test/Seal/Command/AccessControlSpec.hs`,
  `test/Seal/Command/ChannelSpec.hs`
- `test/Seal/Gateway/ApiSpec.hs` if a `RuntimeConfig` literal needs the field
  dropped (verify by running, not only compiling)

**1. Codec and type (`Security.hs`, `Gateway/Config.hs`)**
- `Seal.Gateway.Config` gains `gatewayTableCodec ::
  Toml.TomlCodec (Maybe PartialGatewayConfig)` =
  `Toml.dioptional (Toml.table gatewayConfigCodec "gateway")` — the single
  definition of "the `[gateway]` table", used by three consumers (security
  codec, legacy CLI read, write guard) — and
  `loadLegacyGatewayTable :: FilePath -> IO (Maybe PartialGatewayConfig)` (read
  a TOML file, decode just that table; `Nothing` on read/parse failure).
- `Seal.Config.Security` imports `Seal.Gateway.Config (GatewayConfig,
  PartialGatewayConfig, defaultGatewayConfig, gatewayTableCodec,
  withGatewayDefaults)`. **New** module edge (it currently imports only `Toml`,
  `Validation`, `Seal.Tools.Exec.{Types,Untrusted}`); safe because
  `Gateway/Config.hs:20-28` imports no `Seal.*` module and both modules are in
  the same library stanza.
- `scGateway :: Maybe PartialGatewayConfig` on `SecurityConfig`;
  `securityConfigCodec` gains `gatewayTableCodec .= scGateway` after the
  `access_control` clause (`:424`); `defaultSecurityConfig` gains
  `scGateway = Nothing` (`:400-409`).
- `gatewayConfigFromSecurity :: SecurityConfig -> GatewayConfig` =
  `maybe defaultGatewayConfig withGatewayDefaults . scGateway`.
- Guards from §2 B: `updateAccessControlSection` (`:583-603`) requires
  `scGateway roundTripped == scGateway cfg`; `updateVaultKeySection`
  (`:630-657`) adds it to the guard list at `:645-655`.

**2. Delete `rcGateway` (`File.hs`)**
- Remove the field (`:107`), the default (`:305`), the codec clause (`:475`).
  The module header gains: the gateway table joins the vault settings and
  `untrusted_execution` on the security side, so a `CONFIG_UPDATE` opcode typed
  on `RuntimeConfig` cannot name it.
- Swap the import at `:79` from `gatewayConfigCodec` to `gatewayTableCodec` —
  required, because the old import becomes entirely unused and `-Werror`
  turns that into a build break, and because WU1.5 uses the new one.

**3. Readers**
- `Serve.hs:184`: `let gwCfgForAccess = gatewayConfigFromSecurity secCfg`
  (`secCfg` loaded at `:176-183`; no new load, no new failure path). Drop
  `defaultGatewayConfig`/`withGatewayDefaults` from the import at `:81-83` —
  `:184` was their only use.
- `Command/AccessControl.hs:328-333` `gatewayConfig`: load `security.toml`; if
  it decodes and `scGateway` is `Just`, use `gatewayConfigFromSecurity`;
  otherwise fall back to `loadLegacyGatewayTable (configFilePath paths)`, merged
  with defaults; otherwise `defaultGatewayConfig`. **Read-only** — no
  `migrateSecurityConfig` call here: `status` and `enroll` are read-mostly verbs,
  and `securityWriteLock` is a process-local `MVar` (`Security.hs:547-549`), so a
  migration write during a pre-upgrade `serve` could lose a concurrent
  `raiseMode` from the HTTP registration path (`Gateway/AccessControl.hs:988` →
  `Security.hs:767-780`). The fallback expires on its own: the next
  `serve`/`tui` boot moves the table and `config.toml` loses it. Haddock both
  facts. Drop `RuntimeConfig (..)`/`loadRuntimeConfig` from the import at `:29`
  (their only use was `:330`).

**4. Migration (`Migrate.hs`)**
- `legacyMarkers` (`:84-92`) gains `"[gateway]"`. The scan stays a plain
  substring scan; no semantic change. Consequence: the pointer sentence added
  to `config.templates/config.toml` must not contain the literal `[gateway]`
  token, or a fresh install would defer seeding forever.
- **Case 1** (no `security.toml`): `migrateFields` already parses `config.toml`
  with `securityConfigCodec` and writes the result, so it picks the table up.
  Gate the gateway half on the semantic result (only migrate when the parse
  yields `scGateway = Just _`), so a commented-out line cannot conjure an empty
  table.
- **Case 2** (`security.toml` exists): merge-if-absent. Parse `config.toml`
  with `securityConfigCodec`; if it yields `Just gw` and the on-disk security
  config has `scGateway = Nothing`, write the security config with
  `scGateway = Just gw`. If the on-disk config already has the table, security
  wins and the config copy is only stripped. One log line per outcome.
- **Strip only after a successful write** (`cleanConfigToml`, `:122-127`). If
  the on-disk file does not parse, or `saveSecurityConfig` refuses
  (`PreserveCredentials` vs a pre-split `[access_control.credentials]` layout,
  `Security.hs:504-515`), log a warning and leave **both** files alone.
- **A document that does not parse must not vanish silently.** Today a
  `config.toml` that does not parse surfaces via `Serve.hs:168-172`; once
  `rcGateway` is gone, `runtimeConfigCodec` no longer knows the section and
  `migrateFields`' `Failure _ -> pure ()` (`:119-121`) would skip it silently.
  Add: if the marker is present but the document cannot be read, log a loud
  actionable warning naming `config.toml`, the parse error, and the fix, and
  change nothing.
- **Fix the fallback message** (`:114-118`): "Reading legacy fields from
  config.toml for this session" is already inaccurate for
  `untrusted_execution` (no legacy reader exists) and becomes inaccurate for the
  gateway. Replace with the truth: settings stay in `config.toml`, the file is
  untouched, boot continues on defaults, the next boot retries; remediation is
  the permissions fix.

**5. Stop other writers from dropping the table (`File.hs`)**
`saveRuntimeConfig` (`:686-692`) re-encodes through `runtimeConfigCodec`, which
after WU1.2 no longer knows `[gateway]`; `updateRuntimeConfig` (`:710-715`) is
that write behind a lock. `migrateSecurityConfig` runs only in `serve`/`tui`, so
an operator who upgrades and runs `seal provider add` / `seal agent default` /
`seal model …` / `seal channel …` before either would silently delete the table,
and the marker scan would then find nothing to recover.
- Add a refusal in `updateRuntimeConfig`: read the current file, decode
  `gatewayTableCodec`; if it yields `Just _`, return `Left` — "config.toml still
  carries a [gateway] table; start `seal serve` or `seal tui` once to move it
  into ~/.seal/security.toml, then retry." Refusing is safe (nothing written)
  and actionable; the gateway/API and TUI never hit it because both boot after
  the migration.
- `Command/Channel.hs` calls `saveRuntimeConfig` directly at `:376`, `:424`,
  `:509`, bypassing the guard; all three already load-modify-save, so switch
  them to `updateRuntimeConfig` and surface its `Left` through the existing
  error path. (`Command/{Provider,Agent,Model}.hs` already use
  `updateRuntimeConfig` — `Provider.hs:176,195,214,282,319`,
  `Agent.hs:107`, `Model.hs:283` — so the guard covers them unchanged.)
- `saveRuntimeConfig` stays the low-level primitive (the migration's
  `cleanConfigToml` uses it after a successful write, when refusing would be
  wrong).

**6. Templates**
- `security.toml`: add the moved `[gateway]` block, **live** (the file already
  writes live `vault_key_type`/`vault_unlock` values), with values that resolve
  exactly like absent keys: `host = "localhost"`, `port = 8080`,
  `allowed_origins = ["http://localhost:8080"]`, `tls = false`; `static_dir`,
  `ws_port`, `tls_cert`, `tls_key`, `tls_hosts` commented out. Extend the header
  prose to name the table and why it lives here.
- `config.toml`: delete the `# Web gateway` banner through the end of the TLS
  block (`:55-93`, keeping the `# Retrieval` banner at `:95`) and replace it with
  a short paragraph pointing at `~/.seal/security.toml`, saying why, and
  mentioning `seal serve --static-dir`. No literal `[gateway]` token.

**7. Tooling that writes the old location**
`frontend/e2e/global-setup.ts:64-73` writes a fresh `config.toml` containing the
table; `scripts/setup-walkthrough.sh:11-20` does the same and `:109` describes
`security.toml` as "only the three vault fields + access_control". Both launch
`seal serve` and would keep working *through the migration*, so this is not a
break — but leaving them on the old shape makes every run depend on the
migration and would hide a migration regression. Move the table into the
`security.toml` each already writes (`global-setup.ts:79-81`,
`setup-walkthrough.sh:19-20`) and fix the description.

**8. Tests**
- `SecuritySpec` — three full `SecurityConfig` literals gain `scGateway`:
  `:33-41` (default equality), `:81-92` (round-trip fixture), `:354-361`
  (`genSecurityConfig`). Plus: `[gateway]` round-trips through
  `saveSecurityConfig`/`loadSecurityConfig` field by field; absent table is
  `Nothing`; `gatewayConfigFromSecurity defaultSecurityConfig ==
  defaultGatewayConfig`; both guard clauses preserve an existing table.
- `ConfigSpec` — move the three round-trip tests at `:90-145` (they drive
  `loadRuntimeConfig`/`saveRuntimeConfig`) to `SecuritySpec`; the
  `Seal.Config.File` import at `:11` then becomes entirely unused and must be
  deleted (`-Werror`). Add `gatewayTableCodec` and `loadLegacyGatewayTable`
  cases (table found / file absent / unparseable).
- `TemplatesSpec` — `sampleSecurityConfig` (`:371-378`) gains `scGateway` with
  **all four** live keys set (`pgcHost`, `pgcPort`, `pgcAllowedOrigins`
  non-empty, `pgcTls`: `originsCodec`'s `maybeToList [] = Nothing` drops an empty
  list when encoding, so an empty value would keep the key out of `leafKeys` and
  fail the coverage test); `sampleRuntimeConfig` (`:341`) drops `rcGateway`;
  "keeps the loopback gateway default" (`:167`) moves to
  `decodeSecurityConfig securityTomlTemplate >>= scGateway`; the commented-header
  test (`:150-160`) gains `"[gateway]"` on the security side; config side keeps
  `configHasLegacySecurityFields configTomlTemplate == False`.
- `MigrateSpec` — Case 1 moves and strips; Case 2 merges when security lacks the
  table (assert `gcHost`/`gcPort` survive) and strips; both present → security
  wins; second run byte-identical; unparseable `security.toml` leaves both files
  untouched; `PreserveCredentials` refusal leaves `config.toml` intact;
  document that does not parse warns and moves nothing; commented `# [gateway]` migrates no
  setting and is a no-op on the second run.
- `AccessControlSpec` — the existing "refuses on a non-loopback bind"
  (`:157-161`, writes the table to `config.toml`) now exercises the legacy
  fallback and must keep passing (runtime assertion: run the suite); add the
  post-migration shape (table in `security.toml`), a both-files-disagree case
  (security wins), and an assertion that `status`/`enroll` write no file.
- `ChannelSpec` / `FileSpec` (`:44`, `:103`) — drop `rcGateway`; add an
  `updateRuntimeConfig` refusal test: a `config.toml` carrying `[gateway]` →
  `Left` and the file byte-identical.

**DoD**
- [ ] An install with `[gateway] host = "0.0.0.0"`, `port = 8443` only in
      `config.toml` and no `security.toml` boots `seal serve` on `0.0.0.0:8443`
      after the migration (test at the `migrateSecurityConfig` →
      `gatewayConfigFromSecurity` level, plus the manual boot in §6).
- [ ] Same install with `security.toml` present without the table: merged, not
      dropped. Both present: security wins, one warning, `config.toml` stripped.
- [ ] `seal access-control status` / `enroll --no-token` on an un-migrated
      install resolve the operator's bind via the read-only fallback, refuse the
      no-token window on a non-loopback bind, and write nothing.
- [ ] On an un-migrated install, `updateRuntimeConfig` (CLI and gateway) refuses
      rather than dropping the table; `config.toml` is unchanged.
- [ ] Migration twice = once; unparseable `security.toml`, a refused write, or a
      document that does not parse never strip `config.toml`.
- [ ] Fresh home: both templates seed, `security.toml` carries a live table
      resolving to `defaultGatewayConfig`, `config.toml` has none.
- [ ] `rg -n 'rcGateway' src test` empty.
- [ ] `make check` green. (`check` does not type-check
      `frontend/e2e/global-setup.ts` or run the walkthrough; both verified by
      inspection, plus one Playwright run when available.)

### WU2 — enforcement and prose

**Files:** `test/Seal/Config/SecurityScopingFailSpec.hs`;
`src/Seal/Config/Security.hs`, `src/Seal/Gateway/Config.hs`,
`src/Seal/Gateway/Server.hs`, `src/Seal/Types/Command.hs`,
`src/Seal/Command/Serve.hs`, `src/Seal/Gateway/OriginGuard.hs` (comments and one
message); `README.md`, `CHANGELOG.md`.

1. `SecurityScopingFailSpec`: add a case where a handler typed
   `RuntimeConfig -> RuntimeConfig` writes `rcGateway` and must fail with
   `Not in scope` (negative only — `Seal.TestHelpers.CompileFail` exports just
   `assertCompileFail`).
2. Prose rule: **no text may tell an operator to put gateway settings in
   `config.toml`**; a code comment naming the section is fine.
   - `README.md:265-273`: `config.toml`'s list drops "the gateway"
     (`:267-268`), `security.toml`'s list gains it (`:271-272`) with the reason.
     These bullets wrap, so they are edited by reading, not by a per-line grep.
   - `README.md:363-364`: the fence comment → `~/.seal/security.toml`; re-read
     the gateway section (`:340-410`) so no sentence still says config.toml
     (notably `:354`).
   - `Gateway/Server.hs:199` empty-embed message → security.toml;
     `Types/Command.hs:152-154` `--static-dir` haddock → security.toml;
     `Gateway/Config.hs` header → defined here, configured there;
     `OriginGuard.hs:12` and `Serve.hs:487` name the section, not a file — leave.
   - `Config/Security.hs` header: `[gateway]` is boot-only, agent-immutable, and
     outside both callback writers' reach.
   - `CHANGELOG.md` (`## 0.1.0.0 — unreleased`): the move, the automatic
     migration (merge-if-absent), the read-only CLI fallback, the
     `updateRuntimeConfig` refusal while un-migrated, and the manual recovery
     path.

**DoD**
- [ ] `rg -n 'rcGateway' src test` empty.
- [ ] No instruction places gateway settings in `config.toml`: the README
      inventory bullets and the gateway section read correctly, and
      `rg -n 'config\.toml' README.md src config/templates` reviewed in full
      (the grep is a prompt, not the proof — it cannot see a wrapped bullet).
- [ ] Compile-fail fixture passes; the pre-existing `scUntrustedExec` cases
      still pass.
- [ ] `make check` green.

## 5. Risks and coverage

| Risk | Mitigation |
|---|---|
| Upgrader's LAN/Tailscale bind reverts to loopback | Merge-if-absent + test + boot log line |
| A `config.toml` re-encode (CLI or gateway) drops the table before migration | `updateRuntimeConfig` refusal + `Channel.hs` switched to it + tests |
| Failed/refused merge strips the only copy | Strip only after a successful write; tests for unparseable + refusal |
| Unparseable document becomes invisible | Explicit warning, files untouched, test |
| Unreadable `security.toml` refuses boot | Deliberate (§2 A), CHANGELOG |
| `seal access-control` resolves stale config | Read-only fallback; no new writes; tested |
| Gateway could rewrite its own bind address | `rcGateway` deleted → compile error; fixture |
| Callback writer becomes a back door | Guard clauses + tests (§2 B) |
| Pointer comment defers seeding forever | No literal `[gateway]` token; `configHasLegacySecurityFields configTomlTemplate == False` guard |
| Comments/unknown keys lost on the one-time merge into `security.toml` | Documented in the file header; fires once; CHANGELOG |
| Tooling writes the old location | Updated in WU1.7 (motivation: stop depending on the migration, not a break) |

## 6. Verification

1. `make check` after each unit.
2. Scratch `SEAL_HOME`, `[gateway] host = "0.0.0.0"`, `port = 8443` in
   `config.toml`, no `security.toml`: `seal access-control status` → the
   operator's origin (fallback, nothing written); `seal provider add …` →
   refused with the migration hint and `config.toml` unchanged; `seal serve` →
   migration line, table in `security.toml` (0600), no table in
   `config.toml`, banner on `http://0.0.0.0:8443`.
3. Re-run `seal serve` → no second migration, no file churn (`stat`).
4. Fresh `SEAL_HOME` → both templates seed; `seal serve` on
   `http://localhost:8080`.
5. `rg -n 'rcGateway' src test` empty; `hlint src/ test/` clean; Playwright
   global-setup starts the gateway on its configured port.

## 7. Rollback

No backup is written (`saveRuntimeConfig` writes `path.tmp` then renames,
`File.hs:686-692`), so none is claimed. Reverting restores `rcGateway` and the
old template; the old build ignores the `[gateway]` table in `security.toml`
(unknown section), but `config.toml` no longer carries it, so a revert alone
lands on `localhost:8080`. Recovery is manual and exact: copy the `[gateway]`
block from `~/.seal/security.toml` into `~/.seal/config/config.toml` and
restart. The migration logs both file paths; the CHANGELOG says the same.

## 8. Open item for the operator

**RESOLVED (operator, 2026-11-09): refuse the write.** WU1.5's
`updateRuntimeConfig` refusal is the chosen behavior. On an un-migrated install,
`seal provider add` / `seal agent default` / `seal model …` / `seal channel …`
return the migration hint and write nothing, until `seal serve` or `seal tui`
has run once. Rejected alternatives: migrating inside those commands (adds a
`security.toml` write on verbs that had none, with the process-local-lock caveat
of §3.1) and accepting the window (silent loss of the bind address on a
CLI-first upgrade).

## 9. Known limitation (recorded, not fixed here)

The migration marker and the write guard both recognise the section as a TOML
table (`[gateway]`). The non-idiomatic dotted spelling — `gateway.host = "…"`
at the root — is not a table node, so neither the marker scan nor
`loadLegacyGatewayTable` sees it, and a later `updateRuntimeConfig` re-encode
drops those lines. Not a regression: the old `rcGateway` codec could not decode
that spelling either, so the value was already inert and the re-encode dropped
it then too. Closing it means teaching both the scan and the guard the dotted
form — a separate change to `Seal.Config.Migrate`'s scope.

## 10. Outcome (2026-11-09)

Implemented in two work units on `gateway/config-to-security-toml`, validated
with `make check` (build, 4182 tests, hlint, 969 frontend tests) plus a manual
boot in a scratch `SEAL_HOME`: an install with `[gateway] host/port` only in
`config.toml` migrates on `seal serve`, binds the configured address, and a
second boot rewrites neither file. One thing the implementation learned: every
optional section decodes through `Toml.dioptional`, which demotes an
unreadable *value* to "absent" — so the migration compares the raw key set
with the re-encoded one (`gatewayTableSurvives`) instead of relying on a decode
failure, and refuses to move a table it cannot write back losslessly.
