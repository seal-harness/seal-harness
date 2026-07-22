# Implementation Plan — Tamper-Proof Remote-Only Enforcement

> **Design:** `docs/superpowers/specs/2026-07-22-remote-enforcement-tamper-proof-design.md` (approved, 5/5 gate)
> **Branch:** `feat/remote-enforcement-hardening`
> **Method:** RED-GREEN (TDD); `make check` gate (build + test + lint with -Werror)

## Goal

Split `FileConfig` into `BootstrapConfig` (boot-only, agent-immutable) and
`MutableConfig` (agent/operator-tunable), move the `untrusted_execution`
section + vault settings into a separate `security.toml` at `~/.seal/security.toml`
(outside the git-versioned `config/` tree), and narrow `updateFileConfig` to
`MutableConfig` so neither the future `CONFIG_UPDATE` opcode nor the existing
HTTP Gateway caller can express a change to the security-critical fields.
Serialize config writes behind a process-wide `MVar`. Add compile-fail
fixtures proving the type-level guarantee.

## Type names (per user feedback)

The user noted "maybe with slightly different type names as it makes sense."
The design used `BootstrapConfig` / `MutableConfig`. Given the codebase
convention is `*Config` / `*FileConfig` (e.g. `FileConfig`,
`UntrustedExecFileConfig`, `ProviderConfig`), and the split is between
"security-critical, boot-only" vs "operator/agent-tunable at runtime":

- **`SecurityConfig`** — the boot-only, agent-immutable config loaded from
  `security.toml`. Carries `UntrustedExecConfig` + vault settings. This
  aligns with the file name `security.toml` and the design's §6 terminology.
- **`RuntimeConfig`** — the agent/operator-tunable config loaded from
  `config.toml`. This is the renamed `FileConfig` minus the moved fields.

Using `SecurityConfig` / `RuntimeConfig` (both lifecycle+purpose terms, more
symmetric than `Bootstrap`/`Mutable` — addresses Designer reviewer S4).

## Work units

### W1 — Type split: `FileConfig` → `SecurityConfig` + `RuntimeConfig` [PRIMARY]

**Files:**
- `src/Seal/Config/File.hs` — rename `FileConfig` → `RuntimeConfig`; remove
  `fcUntrustedExec`, `fcVaultPath`, `fcVaultRecipient`, `fcVaultIdentity`,
  `fcVaultUnlock`, `fcVaultKeyType` from `RuntimeConfig`; delete
  `untrustedExecConfigFromFile` (moves to the security loader in W2); update
  `fileConfigCodec` (rename to `runtimeConfigCodec`) to drop the
  `[untrusted_execution]` line (File.hs:258); update `defaultFileConfig` →
  `defaultRuntimeConfig`; update `saveFileConfig`/`updateFileConfig` →
  `saveRuntimeConfig`/`updateRuntimeConfig` with narrowed
  `RuntimeConfig -> RuntimeConfig` signature; delete `UntrustedExecFileConfig`/
  `UntrustedExecRemoteFileConfig` (move to a new `Seal.Config.Security` module
  in W2); delete `untrustedExecConfigCodec`/`untrustedExecRemoteConfigCodec`.
- `src/Seal/Config/Security.hs` — **NEW module**: `SecurityConfig` type +
  codec + `loadSecurityConfig`/`saveSecurityConfig` (path hard-wired to
  `~/.seal/security.toml` via `SealPaths`, never caller-supplied — V3). Reuses
  the `UntrustedExecFileConfig`/`UntrustedExecRemoteFileConfig` types + codecs
  moved here, plus the vault fields moved from `FileConfig`.
- `src/Seal/Config/Paths.hs` — add `securityFilePath :: SealPaths -> FilePath`
  returning `spHome </> "security.toml"` (sibling of `config/`, NOT inside it
  — V8). Update `ensureSealDirs` to create the parent if needed.

**Full file list (22 source + 14 test files import `FileConfig`, verified by
`rg -l FileConfig`):**

*Source — rename to `RuntimeConfig` (no field changes needed unless noted):*
- `src/Seal/Command/Provider.hs` (4 `updateFileConfig` sites → `updateRuntimeConfig`)
- `src/Seal/Command/Model.hs` (1 site)
- `src/Seal/Command/Agent.hs` (1 site)
- `src/Seal/Command/Channel.hs` (2 `saveFileConfig` sites — channel config, stays)
- `src/Seal/Command/New.hs` (`ndCfg :: IO FileConfig` field → `IO RuntimeConfig`)
- `src/Seal/Gateway/API.hs` (2 sites — set `fcDefaultAgent`, stays in `RuntimeConfig`)
- `src/Seal/Gateway/Send.hs` (loads config per session → `loadRuntimeConfig`)
- `src/Seal/Channel/Cli.hs` (`execBackendFromFile` → consume `SecurityConfig`, see W2)
- `src/Seal/Channels/Loop.hs` (per-session load → `loadRuntimeConfig`; security via deps, see W2)
- `src/Seal/Channels/Signal/Run.hs`, `src/Seal/Channels/Telegram/Run.hs` (boot sites)
- `src/Seal/Command/Serve.hs`, `src/Seal/Tui.hs` (boot sites)
- `src/Seal/Providers/Registry.hs` (imports `FileConfig` → rename)
- `src/Seal/Session/Store.hs` (5 uses — `srConfigPath`, session selection → rename)
- `src/Seal/Agent/Runtime/Delegation.hs` (imports `FileConfig` → rename)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` (imports `FileConfig` → rename)
- `src/Seal/Signal/Config.hs`, `src/Seal/Telegram/Config.hs` (Haddock refs → rename)
- `src/Seal/Config/File.hs` (the type itself + codec + loaders — renamed)

*Source — migrate vault fields to `SecurityConfig` (functional change, not just rename):*
- `src/Seal/Vault/Commands.hs:225,287` — set `fcVaultRecipient`/`fcVaultIdentity`/
  `fcVaultKeyType` (moving to `SecurityConfig`). Admin CLI ops (`/vault setup`),
  not agent opcodes. Must call `saveSecurityConfig` (writes `security.toml`), not
  `updateRuntimeConfig`.
- `src/Seal/Vault/Backend.hs:235` — **`resolveEncryptor :: FileConfig -> ...`**
  consumes `fcVaultRecipient`/`fcVaultIdentity` (both moving to `SecurityConfig`).
  This is the vault encryptor resolver, critical to vault boot. Signature changes
  to `resolveEncryptor :: SecurityConfig -> ...`. The boot site that calls it
  (currently passes `FileConfig`) must pass the `SecurityConfig` loaded at boot.

*Test — rename + field-move updates:*
- `test/Seal/Config/FileSpec.hs` (move untrusted_execution tests to SecuritySpec; rename)
- `test/Seal/Vault/BackendSpec.hs` (tests `resolveEncryptor` with `FileConfig` → `SecurityConfig`)
- `test/Seal/Vault/CommandsSpec.hs` (tests vault commands that now write `security.toml`)
- `test/Seal/Channels/LoopSpec.hs`, `test/Seal/Command/{Agent,Channel,Model,Provider}Spec.hs`
- `test/Seal/Gateway/{ApiSpec,ConfigSpec}.hs`, `test/Seal/Providers/RegistrySpec.hs`
- `test/Seal/Session/StoreSpec.hs`, `test/Seal/Signal/ConfigSpec.hs`, `test/Seal/Telegram/ConfigSpec.hs`

**W1-notes — vault field migration:** `Vault/Commands.hs:225,287` and
`Vault/Backend.hs:235` (`resolveEncryptor`) consume the vault fields moving
to `SecurityConfig`. These are admin/boot concerns (vault setup, encryptor
resolution), NOT agent opcodes — they run as the operator at boot or via
`/vault` CLI. They must consume `SecurityConfig` and call `saveSecurityConfig`.
This is correct: vault setup is a boot-time/admin concern, matching the
`SecurityConfig` classification. The boot sequence loads `SecurityConfig`
first, then constructs `VaultRuntime` (which calls `resolveEncryptor`) from it.

**`AgentEnv` wiring:** `AgentEnv` (`Agent/Env.hs`) already holds
`aeExecBackend :: ExecBackend` set once at session-env construction (line 33).
The security config is loaded at boot and resolved into `ExecBackend` before
`AgentEnv` is built — no new `AgentEnv` field needed for the untrusted-exec
path (per Architect reviewer Q1 and Designer reviewer Q1). The vault runtime
(`VaultRuntime`) is similarly constructed at boot from the security config.

**DoD:**
1. `grep -rn "FileConfig" src/ test/` returns 0 hits (renamed to `RuntimeConfig`).
2. `grep -rn "fcUntrustedExec\|fcVaultPath\|fcVaultRecipient\|fcVaultIdentity\|fcVaultUnlock\|fcVaultKeyType" src/` returns 0 hits in `RuntimeConfig` (they live in `SecurityConfig` as `scUntrustedExec` etc.).
3. `updateRuntimeConfig` has type `FilePath -> (RuntimeConfig -> RuntimeConfig) -> IO (Either Text ())` — a lambda touching `scUntrustedExec` fails to compile.
4. `make check` passes (build + test + lint).

**Tests (RED first):**
- `test/Seal/Config/SecuritySpec.hs` — **NEW** (mirrors `FileSpec.hs`):
  parse `security.toml` with `[untrusted_execution]` + `[vault]` sections;
  absent file → `defaultSecurityConfig`; round-trip; malformed TOML → parser
  `Left` (the boot-fail-open wrapper is tested in W2's `MigrateSpec`/
  `SecuritySpec` boot-behavior section — see W2 DoD #8).
- `test/Seal/Config/FileSpec.hs` — move the `"untrusted_execution section"`
  describe block (lines 244-332) to `SecuritySpec.hs`; delete the round-trip
  test for `[untrusted_execution]` in `FileSpec` (the field is no longer in
  `config.toml`); rename `FileConfig` → `RuntimeConfig` throughout.

---

### W2 — Separate `security.toml` file + boot-time migration

**Files:**
- `src/Seal/Config/Security.hs` (from W1) — `loadSecurityConfig` reads
  `~/.seal/security.toml`; `saveSecurityConfig` writes it atomically with
  mode 0600 (`setFileMode` after rename, like the vault).
- `src/Seal/Config/Migrate.hs` — **NEW**: `migrateSecurityConfig :: SealPaths
  -> IO ()` — one-time, idempotent. Cases:
  1. **`security.toml` absent, `config.toml` has legacy sections:** read the
     old `[untrusted_execution]`/`vault_*` values from `config.toml`, write
     `security.toml`, rewrite `config.toml` without the moved sections, emit
     a stderr warning.
  2. **`security.toml` exists, `config.toml` has stale legacy sections:**
     `security.toml` wins (precedence — design §9.2). Remove the stale
     `[untrusted_execution]`/`vault_*` sections from `config.toml` (cleanup),
     emit a warning. Do NOT overwrite `security.toml`.
  3. **`security.toml` exists, `config.toml` clean:** no-op (idempotent).
  4. **Neither exists:** no-op (defaults apply).
  5. **Write fails (permissions):** log a loud error and proceed (fail-open
     for boot — the legacy `config.toml` values are read directly for this
     session only; re-tried next boot — self-healing).
- Boot sites (`src/Seal/Tui.hs:72`, `src/Seal/Command/Serve.hs:72`,
  `src/Seal/Channels/Signal/Run.hs:232`,
  `src/Seal/Channels/Telegram/Run.hs:83`): call `migrateSecurityConfig paths`
  before `loadSecurityConfig`/`loadRuntimeConfig`. Then load both: security
  from `security.toml`, runtime from `config.toml`.
- `src/Seal/Channel/Cli.hs:667-684` (`execBackendFromFile`) — change to
  consume `SecurityConfig` (not `FileConfig`). Signature:
  `execBackendFromSecurity :: WorkspaceRoot -> SecurityConfig -> ExecBackend`.
- `src/Seal/Channels/Loop.hs:498`, `Gateway/Send.hs:276` — the per-session
  `loadFileConfig` calls now load `RuntimeConfig` (no security fields); the
  security config is loaded ONCE at boot and threaded through the channel
  deps, NOT re-loaded per session (closes V2 — the session-start seam no
  longer re-reads the security config). The `execBackend` is resolved once
  from `SecurityConfig` at boot and passed via channel deps, not re-derived
  per session.

**DoD:**
1. `~/.seal/security.toml` is read at boot; `~/.seal/config/config.toml` no
   longer contains `[untrusted_execution]` or `vault_*` keys post-migration.
2. `security.toml` file mode is 0600.
3. `security.toml` lives at `~/.seal/security.toml` (NOT inside
   `~/.seal/config/` — verifiable by path assertion).
4. Migration is idempotent (running twice does not duplicate or error).
5. Migration failure (permission denied) logs an error, boot proceeds;
   re-tried next boot (self-healing).
6. **Both files present:** `security.toml` wins; stale `config.toml`
   sections are cleaned up with a warning (design §9.2 precedence).
7. The security config is loaded ONCE at boot, NOT re-loaded per session
   (the session-start seams `Loop.hs:498` etc. load `RuntimeConfig` only).
8. **Malformed `security.toml` (exists but unparseable) → boot proceeds**
   (fail-open for boot per design §9.2): `loadSecurityConfig` catches the
   parse error, logs a stderr error, returns `defaultSecurityConfig` (which
   has no remote → untrusted opcodes fail-closed at call time on hardened
   build; defaults to `mode=local` on default build). Boot does NOT abort.
9. `make check` passes.

**Rollback / downgrade note:** Migration removes `[untrusted_execution]`/
`vault_*` from `config.toml`. An operator who downgrades to an older `seal`
binary (which reads `config.toml` only) would find no `[untrusted_execution]`
section and silently default to `mode=local` — defeating remote-only on the
downgraded binary. **Mitigation:** the migration writes a commented-out
`# [untrusted_execution] migrated to ~/.seal/security.toml on <date>` marker
in `config.toml` so a downgrading operator sees the migration happened.
Pre-alpha status (README:17) means backward-downgrade compatibility is not a
hard requirement, but the marker + release notes are the mitigation. Full
rollback (re-writing `config.toml` with the section) is not automated — an
operator who needs to downgrade must manually copy values from
`security.toml` back to `config.toml`.

**Tests (RED first):**
- `test/Seal/Config/MigrateSpec.hs` — **NEW**: covers all 5 migration cases:
  (1) security.toml absent + legacy sections → migrate; (2) **both present →
  security.toml wins, stale config.toml sections cleaned up**; (3) security.toml
  exists + config.toml clean → no-op; (4) neither → no-op; (5) write failure →
  fail-open + error logged. Plus: idempotency (run twice), corrupted legacy
  input preserved, migration marker comment written to `config.toml`.
- `test/Seal/Config/SecuritySpec.hs` (boot-behavior section) — **malformed
  `security.toml` boot-fail-open** (design §9.2): a `security.toml` with
  invalid TOML → `loadSecurityConfig` catches the parse error, logs to
  stderr, returns `defaultSecurityConfig`; boot does not abort; on a hardened
  build untrusted opcodes fail-closed at call time (no remote configured).
- `test/Seal/Config/SecuritySpec.hs` — file-mode 0600 assertion;
  `security.toml` path is `~/.seal/security.toml` (not inside `config/`);
  absent + no legacy → `defaultSecurityConfig`.

---

### W3 — Process-wide `MVar` around config writes (V7) + path confinement (V3)

**Files:**
- `src/Seal/Config/File.hs` (→ `RuntimeConfig`): add a process-wide
  `MVar ()` lock around `updateRuntimeConfig` (and `saveRuntimeConfig`).
  Use `withMVar` to serialize load-modify-save. The `MVar` is a top-level
  `IORef`-free pure module-level `unsafePerformIO`-initialized `MVar` OR
  threaded explicitly. Prefer a module-level `MVar` (simplest; config writes
  are rare).
- `src/Seal/Config/Security.hs`: `saveSecurityConfig` takes a `SealPaths`
  (not a raw `FilePath`) and resolves the path internally — the caller cannot
  supply an arbitrary path (V3). Add the same `MVar` lock for
  `saveSecurityConfig`.

**DoD:**
1. Concurrent `updateRuntimeConfig` calls are serialized (no lost-update).
2. `saveSecurityConfig` does not accept a caller-supplied `FilePath`.
3. `make check` passes.

**Tests (RED first):**
- `test/Seal/Config/FileSpec.hs` — a concurrent-write test: spawn N threads
  calling `updateRuntimeConfig` with different field updates; assert all N
  updates are present (no lost writes). Use `race` or `mapConcurrently`.

---

### W4 — Compile-fail fixtures (proves the type-level guarantee)

**Files:**
- `test/Seal/Config/SecurityScopingFailSpec.hs` — **NEW**: uses
  `assertCompileFail` (from `test/Seal/TestHelpers/CompileFail.hs`).
  - **Fixture 1 (opcode path):** a source string defining a handler typed
    `RuntimeConfig -> RuntimeConfig` that tries to reference
    `scUntrustedExec` (or `SecurityConfig`) fails with "Not in scope".
  - **Fixture 2 (Gateway path):** a source string calling
    `updateRuntimeConfig` with a lambda that tries to set a `SecurityConfig`
    field fails to compile (type mismatch: `RuntimeConfig` vs
    `SecurityConfig`).

**DoD:**
1. `SecurityScopingFailSpec` passes (both fixtures fail to compile as
   expected).
2. **QuickCheck property (design §9.6):** "no value of `RuntimeConfig`
   affects `selectExecBackend`'s remote-only arm" — a property asserting
   that arbitrary `RuntimeConfig` values do not change the backend selected
   by `selectExecBackend` under `mode=remote`. This proves the bootstrap
   field is provably unreachable from the mutable config. Add to
   `test/Seal/Config/SecuritySpec.hs` (or `UntrustedSpec.hs` alongside the
   existing §8 property at lines 53-58, 83-88). The existing property "∀
   config/opcode, untrusted ⇒ Ssh-or-failure" is preserved unchanged (the
   select functions are unchanged); this is a NEW property over the split.
3. `make check` passes.

**Tests:** the compile-fail fixtures ARE the test (RED = write the fixture,
GREEN = it passes once the type split from W1 lands). The QuickCheck property
is RED-first in `SecuritySpec.hs`.

---

### W5 — Approach D sharpening (ignore `mode` for resolution under flag)

**Files:**
- `src/Seal/Config/Security.hs` — under `REMOTE_ONLY_UNTRUSTED` CPP,
  `untrustedExecConfigFromSecurity` (the renamed resolver) ignores the
  parsed `mode` and always returns `UemRemote` for backend resolution.
  `enforceRemoteOnly` (in `Tools/Exec/Untrusted.hs`) is UNCHANGED — still
  rejects `mode=local` as a config-error signal (existing tests pass).

**DoD:**
1. Under `-f remote-only-untrusted`, a `mode=local` in `security.toml`
   still resolves to `UemRemote` for backend selection (field ignored).
2. `enforceRemoteOnly` still rejects `mode=local` (existing tests
   `UntrustedSpec.hs:106-116`, `Phase4Spec.hs:88-92` pass unchanged).
3. `cabal build all -f remote-only-untrusted` succeeds.
4. `make check` passes (default build); hardened build compiles.

**Tests (RED first):**
- `test/Seal/Config/SecuritySpec.hs` — new test (CPP-gated or conditional):
  under the flag, `mode=local` resolves to `UemRemote`. Note: flag-conditional
  testing may need a separate test-suite stanza or CPP guard (per CTO
  reviewer suggestion). Use CPP `#if defined(REMOTE_ONLY_UNTRUSTED)` in the
  test.

---

### W6 — Gateway fail-closed on non-loopback when `mode=remote` (V6)

**Files:**
- `src/Seal/Gateway/Server.hs:66-77` — change the non-loopback warning to a
  hard refusal when `SecurityConfig` indicates `mode=remote`. Print an error
  and exit (do not call `run`). When `mode=local`, keep the warning (the
  existing behavior).
- `src/Seal/Command/Serve.hs` — pass the resolved `SecurityConfig` (or just
  the `UntrustedExecMode`) to `runGateway` so it can check.

**DoD:**
1. Gateway with `mode=remote` + non-loopback bind → refuses to start (exit
   with error message).
2. Gateway with `mode=local` + non-loopback bind → warns (unchanged).
3. Gateway with loopback bind → starts (unchanged).
4. `make check` passes.

**Tests (RED first):**
- `test/Seal/Gateway/ServerSpec.hs` (extend or create) — assert refusal
  when `mode=remote` + non-loopback. (May need to factor `runGateway` to
  accept a pure check function for testability.)

---

## Dependency ordering

```
W1 (type split) ──┬──> W2 (security.toml + migration) ──> W5 (Approach D)
                  │
                  ├──> W3 (MVar + path confinement)
                  │
                  └──> W4 (compile-fail fixtures)

W2 ──> W6 (Gateway fail-closed, needs SecurityConfig)
```

W1 is the foundation; W2-W4 can proceed in parallel after W1; W5 needs W2;
W6 needs W2. **Recommended order:** W1 → W4 (prove the guarantee immediately)
→ W2 → W3 → W5 → W6.

## Human checkpoints

1. **After W1** — review the type split + field assignment before proceeding.
   The rename touches ~15 files; confirm the vault-command migration
   (`Vault/Commands.hs` → `saveSecurityConfig`) is correct.
2. **After W2** — review the migration logic + the session-start seam change
   (security config loaded once at boot, not per session). This is the
   core security guarantee; pause for user review.
3. **After W6** — review the Gateway fail-closed behavior before merge.

## Verification

- `make check` after every work unit (build + test + lint with -Werror).
- `cabal build all -f remote-only-untrusted` after W5 (hardened build).
- The compile-fail fixtures (W4) are the structural proof — they must pass.
- `grep -rn "FileConfig" src/ test/` = 0 after W1.

## Out of scope (this plan)

- Implementing `CONFIG_UPDATE` / `CONFIG_VIEW` opcodes (future task; the type
  split prepares for them).
- `seal config show` CLI (future; noted in design §12 W8 — not security-
  critical, can land separately).
- Approach C (signed config) — deferred per design §6.
- **Approach A (runtime immutability predicate)** — the design §6 item 4
  lists this as "cheap insurance against a future refactor that re-merges
  the types." This plan relies on E's type split (compile-time guarantee) +
  W2's boot-only-load (no per-session re-read) to fully close V1/V2. A
  separate runtime predicate is subsumed: if the types are split, there is
  no field for a predicate to guard. The compile-fail fixture (W4) is the
  structural proof. If the types are ever re-merged in a future refactor,
  the W4 fixture breaks — that IS the alarm. A separate predicate would be
  redundant. (If the user prefers the belt-and-suspenders predicate too,
  it can be added as a follow-up — ~20 lines in `Security.hs`.)
- The `SEAL_HOME` V4 vector — mitigated by W2 (security config loaded once at
  boot from a boot-resolved path); confirm `resolveSealHome` is called once
  at boot and cached (already true per `Paths.hs` — `getSealPaths` is called
  at boot sites).