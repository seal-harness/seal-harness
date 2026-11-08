# Web first-run setup wizard — implementation plan (rev 3)

**Design**: `docs/superpowers/specs/2026-11-07-web-first-run-setup-wizard-design.md` (v6 — §0 re-bases onto `gateway/passkey-access-control`)
**Base branch**: `gateway/passkey-access-control` (passkey access-control layer)
**Issues**: two, filed before implementation (each PR body carries `Closes #<NN>`)

## Rev 3 changes (from plan-review round 2 — all three reviewers FAILed again)

1. **Two import cycles were latent in WU1** (feasibility). `Provision` must
   import `Backend` and `Age`; putting the validators in `Provision` forced both
   to import it back. **Decision (design v6):** `mkAgeRecipient` lives in
   `Seal.Security.Vault.Age`; `VaultIdentityPath` + `mkVaultIdentityPath` live in
   a new `src/Seal/Vault/IdentityPath.hs` that imports neither. WU1's file list,
   tests and cabal entries are updated; no cycle.
2. **The canonical origin is `http://localhost:<port>` for loopback binds, but
   the SPA is reached at `127.0.0.1:<port>` (e2e) and `localhost:5173` (vite
   dev)** (completeness). Exact matching 403s both. **Decision:**
   `sameOriginVerdict` accepts any **loopback alias** (any port) when the
   canonical origin is loopback, and requires an exact match otherwise. New WU3
   tests pin both; WU4 test 12 uses `127.0.0.1` against a `localhost` canonical.
3. **e2e bootstrap must provision** (scope): `frontend/e2e/global-setup.ts`
   writes only `[gateway]` + `mode = "none"`, so with the gate the capstone
   cannot reach 'Active Tabs'. WU6 now owns `global-setup.ts` (provision via the
   real wizard in `01-setup.spec.ts`, which runs first) and states that
   `02-capstone`'s previously-skipped provider branch now runs with no live
   model — its existing visibility guards are what keep it green.
4. **Setup-route guard cases were unassigned** (completeness): WU5 gains test 22
   (evil Origin on `GET`/`POST /api/setup` → 403 **and no vault file, no
   `security.toml` change**), superseding the PR A deferral note.
5. **`AGENTS.md` already lists permitted exceptions** (`age`, `ssh`, `tmux`)
   (feasibility + completeness): WU7 **extends** it with `age-keygen` /
   `age-plugin-yubikey` instead of claiming to add a list.
6. **`--identity=` / `--recipient=` single-token argv is an invocation change**
   (feasibility): recorded in `CHANGELOG.md`, not described as unchanged.
7. **The design doc is normative and stale** (all three): WU7 owns edits to
   §3/§10/§11.5/§12/§13/§14.7, and the plan's WU7 DoD refers to §3 (not §12) for
   the behaviour changes, now **four**.
8. **Coverage gate wording** (completeness): `.coverage-thresholds.json` records
   HPC as not wired, so the DoD is "run `make test` (the enforcement command) and
   record its output".
9. Housekeeping: `ServerSpec` **does** construct `ApiDeps` (`ServerSpec.hs:99`),
   so it stays in the literal list (~34 construction sites), WU3's DoD allows
   `Data.Text.Encoding`/`Network.HTTP.Types`, BackendSpec's
   `setupUserSupplied` cases already accept either branch (no edit needed), and
   the stale "cap proved on an existing route" sentence is deleted (the reader is
   unit-tested in WU4 and exercised end-to-end in WU5).

## Rev 2 changes (from plan-review round 1 — all three reviewers FAILed)

1. **Split into two PRs** (scope reviewer). PR A is an independent security
   prerequisite touching *existing* routes; PR B is the wizard. A ~60-file PR
   mixing three change classes is not reviewable.
   - **PR A — "gateway mutation guard + CORS removal + body cap"** (`WU3`, `WU4`).
   - **PR B — "web first-run setup wizard"** (`WU1`, `WU2`, `WU5`, `WU6`, `WU7`),
     branched on top of PR A.
2. **The canonical origin is not reachable from `apiApp`** (feasibility +
   completeness + scope, all three). `ApiDeps` carries no access handle; the
   handle is applied *around* `apiApp` in `Server.hs:73-74`; `acsOrigin` is
   behind the MVar and unexported. **Decision:** `ApiDeps` gains
   **`adCanonicalOrigin :: Maybe Text`**, wired in `Serve.hs` from
   `naOrigin access` (already in scope at `Serve.hs:275/567`), plus ~28 test
   literals. Owned by **PR A's WU4** (it is the guard's input), not WU1.
3. **WU4's body-cap case needed WU5's routes** (feasibility). PR A no longer
   claims a 413 on `/api/setup/*`; PR A proves the cap on
   `collectBodyLimited`'s unit behaviour + one existing route that uses it;
   the setup-route 413 case moves to PR B.
4. **e2e file names were invented** (feasibility + completeness). The tree has
   `frontend/e2e/capstone.spec.ts`. PR B **renames** it to
   `02-capstone.spec.ts` and adds `01-setup.spec.ts`;
   `playwright.config.ts` already sets `workers: 1` / `fullyParallel: false`
   (`frontend/playwright.config.ts:15,18`) → **verify, do not edit**.
5. **Dropped from scope** (scope reviewer): the post-completion `/setup`
   view + `TopSection`/`TopBar` changes (no test, not requested); the
   `FormRow` extraction and the four-component `providerLabels` migration
   (refactors with no wizard behaviour). The wizard gets its own small local
   row component and a local label map; both refactors are follow-ups.
6. **No silent CLI behaviour change** (scope reviewer): WU1 no longer reroutes
   the CLI's `runSetup` through `provisionVault`, and leaves
   `setupUserSupplied` untouched. The web path uses a **new** validated
   `setupUserSuppliedFrom`; the CLI's unvalidated prompt path is a declared
   follow-up. `mkAgeEncryptor`'s new validation *is* a user-visible
   improvement — a CHANGELOG "fixes" entry, not a silent change.
7. **Coverage gate, S1b, access-mode behaviour, residual-threat statement,
   runtime-unparseable config, and the missing §11.5 cases** are now assigned
   (§DoD, WU2 case 16, WU5 case 21, WU7 items 6–7, WU6 cases 29–34).
8. `collectBodyLimited` cannot reuse AccessControl's reader (unexported);
   PR A writes one bounded reader in `Seal.Gateway.Setup` and exports it for
   tests. `maxAuthBody` stays where it is.
9. Path fix: `test/Seal/TestHelpers/ApiTestHarness.hs`.
10. WU1's argv test (#28) is **not** `pendingWith`: the `--identity=` form is
    asserted through a new pure `ageDecryptArgs :: FilePath -> [String]`
    exported from `Seal.Security.Vault.Age` and called by `mkAgeEncryptor`, with
    the process invocation unchanged.

## Goal

On a host whose vault or LLM provider is not usable, the web UI — *after* the
existing passkey `AccessGate` — shows a blocking, guided wizard: **vault** →
**provider**. Both steps reach CLI parity (three vault backends; three
providers), the browser never receives key material, and the step list is a
registry so a "chat channels" step can be added later without restructuring.

## Definition of done

**PR A**
- `OriginGuardSpec` (pure verdict) + `MutationGuardSpec` (API level) green:
  403 matrix on existing mutating routes, 200/201 for the canonical origin,
  `GET /api/setup` guarded once it exists (PR B asserts that), no
  `Access-Control-Allow-Origin` on any response, bounded-reader unit tests.
- `make check` green; full suite green; `CHANGELOG.md` records the CORS removal
  and the mutation-origin requirement.
- No `TestHelpers`/`ApiSpec` request-builder edits: the guard reads headers that
  already exist, and the canonical origin defaults to `Nothing` in tests (no
  origin ⇒ allowed), so only the new `adCanonicalOrigin = Nothing` field line is
  added to each literal.

**PR B**
- `ProvisionSpec`, `StateSpec`, `SetupApiSpec`, extended `SecuritySpec`,
  frontend vitest suites green; `make check` green; `npm test` green.
- Coverage gate: run the enforcement command from `.coverage-thresholds.json`
  (`make test`) and record its output in the PR body. The file notes HPC is not
  wired, so "passing" means "the command ran and its numbers are recorded", not
  "thresholds enforced".
- e2e locally green: `01-setup.spec.ts` (drives the wizard; needs
  `age-keygen`) then `02-capstone.spec.ts` (unchanged behaviour).
- **S1b manual walkthrough** recorded in the PR body: empty `~/.seal/` → passkey
  enrollment → vault → provider → a completed first chat turn against a real
  provider (not automatable: needs a live credential/network).
- No response any setup endpoint returns contains key material, an identity
  file's contents, or an `age1` value other than the returned recipient.
- `Seal.Gateway.Setup` + `Seal.Gateway.OriginGuard` module headers and the PR
  body state the residual threat classes (service-token holders; `mode = none`).

## Conventions for every work unit

1. **RED first**: failing test, seen to fail for the right reason, then
   implement.
2. `nix develop --command cabal test` — never pipe Haskell binaries through
   `head`/`tail`; redirect to a file and page it.
3. `make lint` must report `No hints`; `-Wall -Werror` is on.
4. No partial functions, `Text` not `String`, named-field records
   (`_<type>_<field>`), `Either Text` for errors, strict fields by default.
5. Every module added in three places: cabal `exposed-modules` + test-suite
   `other-modules` + `test/Main.hs`.
6. One commit per WU, conventional message, never `--no-verify`.

---

# PR A — gateway mutation guard, CORS removal, body cap

Branch: `feat/gateway-mutation-guard-<NN>` off `gateway/passkey-access-control`.

## WU3 — `Seal.Gateway.OriginGuard` (pure verdict)

### RED tests — `test/Seal/Gateway/OriginGuardSpec.hs` (new)

| # | Test name | Assertion |
|---|---|---|
| 1 | `no canonical origin allows everything` | `Nothing` ⇒ `Allowed` (mode `none` waiver / tests) |
| 2 | `an exact matching origin is allowed` | `Just "http://localhost:8080"` + same `Origin` |
| 3 | `a different scheme is rejected` | `https://localhost:8080` ⇒ `Rejected` |
| 4 | `a different host is rejected` | `http://evil.example:8080` ⇒ `Rejected` |
| 5 | `a loopback alias with a different port is accepted` | canonical `http://localhost:8080`, origin `http://127.0.0.1:9999` ⇒ `Allowed` (dev proxy, e2e) |
| 5b | `a different port on a NON-loopback canonical is rejected` | canonical `http://seal.lan:8080`, origin `http://seal.lan:9999` ⇒ `Rejected` |
| 6 | `Origin: null is rejected` | |
| 7 | `a cross-site fetch without Origin is rejected` | `Sec-Fetch-Site: cross-site` and `same-site` |
| 8 | `a same-origin fetch without Origin is allowed` | `same-origin`, `none`, and absent |
| 9 | `the loopback alias set is exactly localhost / 127.0.0.0`8` / [::1]` | `127.1.2.3` allowed, `10.0.0.1` rejected, `localhost.evil.com` rejected |
| 9b | `case and trailing slash do not smuggle an origin` | `HTTP://LOCALHOST:8080` / `http://localhost:8080/` behaviour pinned |
| 10 | property: `Allowed` ⇒ canonical is `Nothing`, or Origin was absent with acceptable fetch metadata, or Origin was present and (exactly canonical, or loopback-aliased against a loopback canonical) | QuickCheck over generated header tuples |

### Implementation order

1. `src/Seal/Gateway/OriginGuard.hs` (new): `GuardHeaders`, `GuardVerdict`,
   `sameOriginVerdict :: Maybe Text -> GuardHeaders -> GuardVerdict`,
   `guardHeadersFrom :: Request -> GuardHeaders`. Pure — no IO, no config.
2. cabal + `test/Main.hs`.

**DoD**: 1–10 green; the module's imports are limited to `Data.Text`,
`Data.Text.Encoding`, `Network.Wai` and `Network.HTTP.Types` (no IO).

## WU4 — wiring, CORS removal, bounded body reader

### RED tests — `test/Seal/Gateway/MutationGuardSpec.hs` (new)

| # | Test name | Assertion |
|---|---|---|
| 11 | `a foreign-Origin mutation is rejected` | `POST /api/providers` with `Origin: https://evil.example` ⇒ 403 + error envelope, no state change |
| 12 | `the SPA's own origin passes` | `POST /api/secrets` with `Origin: http://127.0.0.1:<port>` against a `http://localhost:<port>` canonical ⇒ 200/201 |
| 13 | `a mutation with no Origin and cross-site metadata is rejected` | 403 |
| 14 | `a mutation with no Origin at all is allowed` | 200/201 (curl, channels, tests) |
| 15 | `every mutating method is guarded` | `POST`, `PUT`, `DELETE` on three existing routes ⇒ 403 with a foreign Origin |
| 16 | `the health endpoint is not guarded` | `GET /api/health` with a foreign Origin ⇒ 200 |
| 17 | `reads are not guarded in this PR` | `GET /api/lists` with a foreign Origin ⇒ 200 (the CORS removal is what protects it) |
| 18 | `no response carries Access-Control-Allow-Origin` | every response builder (`jsonOk`, `jsonLBS`, `errJson`, `jsonCreated`, `noContent`) + `OPTIONS` ⇒ 204 with no grant |
| 19 | `collectBodyLimited rejects an oversized body` | 8 KiB cap, unit level |
| 20 | `collectBodyLimited returns the body under the cap` | boundary at exactly the cap |

### Implementation order

1. `src/Seal/Gateway/API.hs`: add `adCanonicalOrigin :: Maybe Text` to
   `ApiDeps`; apply `sameOriginVerdict` at the top of `apiApp` for every
   `POST`/`PUT`/`DELETE` (and `GET /api/setup` once it exists — PR B), answering
   `403` with the standard envelope.
2. `src/Seal/Command/Serve.hs`: wire `adCanonicalOrigin = naOrigin access`
   (the `NewAccess` value is already in scope).
3. `test/Seal/TestHelpers/ApiTestHarness.hs`, `ApiSpec.hs`, `ServerSpec.hs`,
   `Phase7aSpec.hs`, `PatIngestionSpec.hs` literals (~34 `ApiDeps` construction
   sites): add `adCanonicalOrigin = Nothing` — **no** request-builder edits.
4. Delete `corsHeaders` from every response builder; `OPTIONS` ⇒ `204`, no
   CORS grant (matching `AccessControl.hs:550`'s existing precedent).
5. `src/Seal/Gateway/Setup.hs` (new, minimal): `collectBodyLimited` +
   `setupJson`/`setupErr` helpers (the handlers arrive in PR B).
6. cabal + `test/Main.hs` (both new specs).
7. `CHANGELOG.md`: CORS removal; mutations require the canonical origin.

**DoD**: 11–20 green; full suite green; **no** request-builder edits
(`git diff --stat` shows no hunk in `testRequest`/`testWithBody`/`testDelete`).

---

# PR B — the wizard

Branch: `feat/web-setup-wizard-<NN>` off PR A.

## WU1 — provisioning core + `adSetup` plumbing

### RED tests — `test/Seal/Vault/ProvisionSpec.hs` (new)

| # | Test name | Assertion |
|---|---|---|
| 1 | `mkVaultIdentityPath rejects relative paths` | `Left` |
| 2 | `mkVaultIdentityPath rejects a missing file` | `Left` |
| 3 | `mkVaultIdentityPath rejects a directory` | `Left` |
| 4 | `mkVaultIdentityPath rejects a leading-dash path` | `Left` (option injection) |
| 5 | `mkVaultIdentityPath rejects empty and control characters` | `""`, `"a\0b"`, `"a\nb"` |
| 6 | `mkVaultIdentityPath is total` (QuickCheck) | never throws; `Right` ⇒ exists + regular file |
| 7 | `mkAgeRecipient rejects malformed recipients` | empty, uppercase, bad charset, leading `-`, whitespace, over-length |
| 8 | `VaultSpec parses each backend` | `local`, `yubikey` (defaults `touch=pin=True`), `user`, `resume` |
| 9 | `VaultSpec rejects an unknown backend` | `Left` |
| 10 | `provisionVault writes exactly the three vault fields, the vault file, and the handle` | temp dir: `security.toml` fields only; vault created; `vrHandleRef` is `Just`; outcome = recipient + key type |
| 11 | `provisionVault reports AlreadyExists without calling the keygen` | keygen that fails the test if invoked |
| 12 | `provisionVault refuses an orphan vault file without touching it` | pre-check; file bytes unchanged |
| 13 | `provisionVault resume creates the vault and skips the config write` | no keygen, no `pdWriteConfig` call |
| 14 | `provisionVault maps a config-writer rejection to AlreadyExists` | `Left ProvisionAlreadyExists` (409, not 500) |
| 15 | `provisionVault maps an outer config-write failure to ConfigWriteFailed` | load/parse `Left` |
| 16 | `provisionVault does not create the vault file when the config write fails` | ordering |
| 17 | `provisionVault stops when the round-trip check fails` | `ProvisionRoundTripFailed`, nothing written |
| 18 | `provisionVault reports InProgress when the lock file is held` | |
| 19 | `provisionVault reclaims a stale lock` | mtime 60 s |
| 20 | `provisionVault refuses to report success when the vault is unreadable` | `ProvisionVaultUnreadable` |
| 21 | `two concurrent provisionVault calls yield one success` | `concurrently`; one key, one vault |
| 22 | `renderProvisionError never leaks secrets` | per constructor: no **identity or vault** path, no `age1`; `NeedsTty` hint may carry the configured keys directory (design §7.2 permits it for mutation errors) and the chosen policies |

### RED tests — `test/Seal/Security/Vault/AgeSpec.hs` (new or extended)

| # | Test name | Assertion |
|---|---|---|
| 23 | `ageDecryptArgs uses the single-token identity form` | `["--decrypt", "--identity=<path>"]` |
| 24 | `ageEncryptArgs uses the single-token recipient form` | `["--encrypt", "--recipient=<age1…>"]` |
| 25 | `mkAgeEncryptor rejects a malformed recipient` | `Left`, no process spawned |

### RED tests — `test/Seal/Config/SecuritySpec.hs` (extend)

| # | Test name | Assertion |
|---|---|---|
| 26 | `updateSecurityConfigEither propagates the callback rejection` | outer `Right (Left e)`, file unchanged, no `.tmp` |
| 27 | `updateSecurityConfigEither reports an unparseable file as an outer Left` | callback not called |
| 28 | `updateSecurityConfig still works` | regression |

### Implementation order

1. `src/Seal/Vault/IdentityPath.hs` (new): `VaultIdentityPath` (constructor
   unexported) + `mkVaultIdentityPath`. Imports neither `Provision` nor
   `Backend` — this is what keeps the graph acyclic.
2. `src/Seal/Security/Vault/Age.hs`: `mkAgeRecipient` (pure, next to
   `AgeRecipient`), `ageDecryptArgs`/`ageEncryptArgs` (pure, exported),
   validation inside `mkAgeEncryptor`.
3. `src/Seal/Vault/Provision.hs` (new): design §8's types,
   `parseVaultSpec`, `provisionVault` (lock → key → round-trip → CAS config →
   `vhInit` → decrypt-verify → ref), `renderProvisionError` (its home),
   `defaultProvisionDeps` (imports `Backend` + `Age` + `IdentityPath`).
4. `src/Seal/Config/Security.hs`: `updateSecurityConfigEither`.
6. `src/Seal/Vault/Backend.hs`: **new** `setupUserSuppliedFrom`
   (`AgeRecipient -> VaultIdentityPath -> Either Text ResolvedKey`);
   leave `setupUserSupplied` and the CLI paths untouched (declared follow-up).
5. `src/Seal/Gateway/Setup.hs`: `SetupDeps`, `stubSetupDeps`,
   `SetupEnv`-independent types.
6. `src/Seal/Gateway/API.hs`: `adSetup :: SetupDeps`; `src/Seal/Command/Serve.hs`
   wires the real deps; `stubSetupDeps` in `ApiTestHarness` + the ~28 literals.
7. Opacity compile-fail spec for `VaultIdentityPath` (pattern:
   `test/Seal/Config/SecurityScopingFailSpec.hs` + `Seal/TestHelpers/CompileFail`).
8. cabal + `test/Main.hs`; `make check`.

**DoD**: 1–28 green (no `pendingWith` in 23–25); full suite green; `make check`
green; `git grep -n "ccPrompt" src/Seal/Gateway` empty.

## WU2 — setup state

### RED tests — `test/Seal/Setup/StateSpec.hs` (new)

| # | Test name | Assertion |
|---|---|---|
| 1 | `an empty install reports both steps pending` | `required_complete == False` |
| 2 | `a working vault is ready` | V6 |
| 3 | `an orphan vault file blocks` | V1, detail path-free |
| 4 | `an unreadable identity blocks even when a handle exists` | V2 |
| 5 | `startup-mode locked is blocked` | V3 with `[reopen, recheck]` |
| 6 | `on_demand and per_access are ready` | V6 for both |
| 7 | `configured-but-not-open offers reopen` | V4 |
| 8 | `a recorded key with no vault file offers resume` | V5 |
| 9 | `provider: default + credential is ready` | P1 |
| 10 | `provider: keyless ollama is ready` | P1 |
| 11 | `provider: default without credential is pending, naming the provider` | P2 |
| 12 | `provider: a configured provider with no default is pending` | **P3** |
| 13 | `provider: nothing configured is pending` | P4 |
| 14 | `a yubikey vault never probes the vault for providers` | provider action fails the test if called |
| 15 | `the emitted state has exactly two required steps` | pin `stRequired` for both, so a future channels step cannot become required silently |
| 16 | `an undecodable security.toml degrades instead of throwing` | `StepBlocked` with a summarised, path-free reason (runtime case: boot refuses, a later edit can still break it) |
| 17 | `missing config files degrade` | absent `config.toml`/`security.toml` |
| 18 | property: `required_complete` == all-required-ready | QuickCheck |

### Implementation order

1. `src/Seal/Setup/State.hs` (new): `StepStatus`, `SetupStep`, `SetupState`,
   `ProviderCard`, `deriveSetupState` over an explicit inputs record (`paths`,
   `RuntimeConfig`, `SecurityConfig`, `Maybe VaultHandle`, `IO [KnownProvider]`,
   `stat` seams). Uses `adPaths` and the configured `scVaultPath`; never
   `VaultRuntime.vrPaths`; never `vhGet`/`vhList`.
2. cabal + `test/Main.hs`.

**DoD**: 1–18 green; module imports no vault read function beyond
`VaultStatus`.

## WU5 — setup API routes and handlers

### RED tests — `test/Seal/Gateway/SetupApiSpec.hs` (new)

| # | Test name | Assertion |
|---|---|---|
| 18b | `the setup routes are origin-guarded` | evil `Origin` on `GET /api/setup` and `POST /api/setup/vault` ⇒ 403 **and** no vault file / no `security.toml` change |
| 19 | `GET /api/setup returns the documented shape` | `required_complete`, `steps[]`, `providers[]`; `Cache-Control: no-store`; no absolute path |
| 20 | `GET /api/setup never 500s on missing or undecodable files` | degraded rows |
| 21 | `the setup routes sit behind the passkey middleware` | with `AccessUnconfigured` the four routes answer 403 `access_control_required`; with `AccessPasskey` and no session, 401; with a session, reachable (uses the base branch's own middleware, not a new gate) |
| 22 | `POST /api/setup/vault local reports AlreadyExists when a key is recorded` | 409 |
| 23 | `POST /api/setup/vault resume succeeds where local is refused` | 201 vs 409 in the same state |
| 24 | `POST /api/setup/vault maps ProvisionError to status codes` | 400 invalid input (**unknown backend** and **relative identity path**, separately), 409 exists/in-progress, 422 needs-TTY/round-trip, 500 unreadable/write-failed |
| 25 | `POST /api/setup/vault rejects a non-JSON content type` | 415 |
| 26 | `a setup body over the cap is rejected` | 413 (the PR A reader) |
| 27 | `POST /api/setup/vault/reopen reports no key, no file, unreadable` | 409/409/422 with a terminal hint |
| 28 | `POST /api/setup/vault/reopen opens and unlocks a startup-mode vault` | 200, `locked: false`, ref `Just` |
| 29 | `POST /api/providers/:name/test uses the resolver seam` | `{"ok":true}`; a provider failure ⇒ 200 `{"ok":false,"error":…}`; unknown ⇒ 400; vault absent ⇒ 500 |
| 30 | `POST /api/providers/:name/test re-reads config` | base URL saved after boot is the one pinged |
| 31 | `the local backend end to end` | `findExecutable "age-keygen"` or `pendingWith`; body keys exactly `recipient`/`key_type`; `GET /api/setup` then ready |
| 32 | `the yubikey TTY path returns a runnable hint` | 422; hint carries the keys dir + policies; no secret |
| 33 | `ApiRouteSpec expects 66 routes` | 62 + 4 |

### Implementation order

1. `src/Seal/Gateway/Setup.hs`: `handleSetupState`, `handleVaultCreate`,
   `handleVaultReopen`, `handleProviderTest`; `SetupEnv` built at the dispatch
   site (`adPaths`, `vrHandleRef`, `srConfigPath`, `securityFilePath`,
   `adProviders`, `adSetup`). `reopen` = `loadSecurityConfig →
   resolveEncryptor → openVault → vhUnlock (startup) → writeIORef` under the
   setup lock.
2. `src/Seal/Gateway/API.hs`: four dispatch arms (literal `"setup"` before any
   capture arm); `no-store` on the GET.
3. `src-gateway-types/.../Route.hs`: four constructors + `routeMeta` +
   `allRoutes`; `OpenApi.hs`: four `openApiMeta` arms; `ApiRouteSpec`: 62 → 66.
4. cabal + `test/Main.hs`.

**DoD**: 19–33 green (31 may be `pendingWith`); `ApiRouteSpec`/`OpenApiSpec`
green; full suite green.

## WU6 — frontend

### RED tests — `frontend/src/lib/__tests__/setupSteps.test.ts` (new)

| # | Test name |
|---|---|
| 34 | `parseSetupState accepts the wire shape` |
| 35 | `parseSetupState treats an unknown status as pending and flags it` |
| 36 | `parseSetupState rejects a malformed payload` |
| 37 | `firstIncompleteStepIndex returns null when everything is ready` |
| 38 | `firstIncompleteStepIndex returns the first pending step` |
| 39 | `resolveRail renders a generic card for an unregistered server step` |
| 40 | `the registry order is vault then provider` |
| 41 | `unknown action verbs render no bar button` |
| 42 | `providerLabels falls back to the raw id for an unknown provider` |

### RED tests — `frontend/src/components/__tests__/` (new)

| # | Test name |
|---|---|
| 43 | `SetupWizard renders the rail from state` |
| 44 | `SetupWizard auto-advances when the current step becomes ready` |
| 45 | `SetupWizard renders the action bar and dispatches resume/reopen/recheck` |
| 46 | `SetupWizard shows a blocked detail with its actions` |
| 47 | `a failed reopen terminates with recovery instructions` |
| 48 | `the completion screen gates onComplete behind Start chatting` |
| 49 | `there is no skip or close control` (absence assertion) |
| 50 | `an unknown required step renders a generic card, never a silent block` |
| 51 | `a 403 from /api/setup renders the setup-on-host screen` |
| 52 | `focus moves to the step heading on advance` |
| 52b | `the rail exposes aria-current and errors are role=alert` | a11y contract (design §10) |
| 53 | `VaultStep shows the backend cards only for create` |
| 54 | `VaultStep shows the YubiKey waiting state and policy in the hint` |
| 55 | `VaultStep sends recipient and identity_path for the user backend` |
| 56 | `VaultStep attributes a 400 to the offending field` |
| 57 | `VaultStep renders 409 and 422 copy and 413/415 as a bug with the code` |
| 58 | `VaultStep never pre-fills a key field` |
| 59 | `ProviderStep renders from state.providers without calling /api/providers/all` |
| 60 | `ProviderStep disables Test while dirty, enables it after save` |
| 61 | `ProviderStep sends one POST and no default PUT on first run` |
| 62 | `ProviderStep renders loading, fetch-error and empty states` |
| 63 | `ProviderStep renders an inline failure and the partial-default message` |
| 64 | `SetupGate shows the wizard when required_complete is false` |
| 65 | `SetupGate renders the app when required_complete is true` |
| 66 | `SetupGate fails closed on a probe error, with Retry` |
| 67 | `SetupGate keeps an /api/sessions error from painting over the wizard` |

### Implementation order

1. `frontend/src/lib/setupSteps.ts`, `frontend/src/lib/providerLabels.ts`
   (wizard-local map with raw-name fallback; **no** migration of the four
   existing components — follow-up).
2. `frontend/src/hooks/useSetup.ts` (`useSetupState`, `provisionVault`,
   `reopenVault`, `testProvider`, returning `{status, error, hint}`).
3. `frontend/src/components/setup/{SetupGate,SetupWizard,VaultStep,ProviderStep,SetupComplete}.tsx`
   (a small local `Row` in the wizard; **no** `FormRow` extraction).
4. `frontend/src/main.tsx`:
   `<AccessGate><SetupGate><App/></SetupGate></AccessGate>`.
   `App.tsx`/`App.test.tsx` are **unchanged** (the gate is outside `App`, so no
   `/api/setup` stubs are needed there) — this replaces plan rev 1's item 28.
5. `types.ts` additions only.
6. e2e: rename `capstone.spec.ts` → `02-capstone.spec.ts`; add
   `01-setup.spec.ts`, which drives the **real wizard** (vault `local` →
   provider `anthropic` with a placeholder key) and therefore provisions the
   shared `SEAL_HOME` before the capstone runs; `global-setup.ts` is edited only
   for the spec ordering it needs (it still writes `[gateway]` +
   `[access_control] mode = "none"`); `playwright.config.ts` **verified**, not
   edited (`workers: 1`, `fullyParallel: false` already set).
   **Expectation:** `02-capstone`'s previously-skipped provider branch now runs
   with no live model — its existing `isVisible` guards keep it green; the e2e
   DoD is "wizard + navigation assertions green, no live model required".

**DoD**: 34–67 green (`npm test`); `npm run build` type checks; e2e green
locally.

## WU7 — docs and invariants

1. `README.md`: "First run" — the two gates (passkey, then vault + provider),
   what each step writes, `age-keygen`/plugin dependencies, CLI parity and the
   rotation boundary, the four new endpoints.
2. `CHANGELOG.md`: **four** behaviour changes — CORS removal and the
   mutation-origin requirement (PR A); `startup`-mode vaults need one `reopen` on
   first run; `age` is now invoked with `--identity=`/`--recipient=` single
   tokens; `mkAgeEncryptor` rejects malformed recipients/identities (a fix).
3. `src/Seal/Config/Security.hs` docstrings: the file *is* now reachable from
   the gateway (loopback + origin-guarded + passkey-gated); writes limited to
   the three vault fields; `updateSecurityConfigEither` documented.
4. `AGENTS.md`: **extend** the existing permitted-exception list (it already
   names `age`, `ssh`, `tmux`) with `age-keygen` and `age-plugin-yubikey`.
5. `docs/superpowers/specs/2026-08-18-layered-harness-architecture.md`: note the
   CORS removal supersedes its §4.4/§8 invariants.
6. `src/Seal/Gateway/Setup.hs` + `src/Seal/Gateway/OriginGuard.hs` module
   headers: the residual threat statement (service-token holders; `mode = none`;
   same-UID local processes can already write `~/.seal/`).
7. **This design doc's stale sections** (§3 behaviour-change note, §10, §11.5,
   §12 WU table, §13, §14.7) — it is normative, so it must stop describing the
   dropped peer/Host guard, the `FormRow`/label migrations, the `App.test.tsx`
   router edits and the old behaviour-change count.
8. PR body: the S1b manual walkthrough, the residual-threat paragraph, and the
   follow-up issues (§ below).

**DoD**: `git grep -n "Access-Control-Allow-Origin" src/` shows only the auth
layer's explanatory comment; no doc claims the old behaviour; the design's §15
points at this file as **rev 3**, and its §3 lists the **four** behaviour changes
(CORS, mutation origin, `startup` reopen, `--identity=`/`--recipient=` argv).

---

## Files touched

**PR A — new**: `src/Seal/Gateway/OriginGuard.hs`,
`src/Seal/Gateway/Setup.hs` (helpers only),
`test/Seal/Gateway/{OriginGuardSpec,MutationGuardSpec}.hs`.
**PR A — modified**: `src/Seal/Gateway/API.hs` (`adCanonicalOrigin`, guard
call, CORS removal), `src/Seal/Command/Serve.hs` (wire the origin),
`test/Seal/TestHelpers/ApiTestHarness.hs` + ~28 `ApiDeps` literals,
`seal-harness.cabal`, `test/Main.hs`, `CHANGELOG.md`.

**PR B — new (Haskell)**: `src/Seal/Vault/IdentityPath.hs`,
`src/Seal/Vault/Provision.hs`,
`src/Seal/Setup/State.hs`, `test/Seal/Vault/ProvisionSpec.hs`,
`test/Seal/Setup/StateSpec.hs`, `test/Seal/Gateway/SetupApiSpec.hs`,
`test/Seal/Security/Vault/AgeSpec.hs` (or extended), opacity fail-spec.
**PR B — modified (Haskell)**: `src/Seal/Config/Security.hs`,
`src/Seal/Security/Vault/Age.hs`, `src/Seal/Vault/Backend.hs`
(`setupUserSuppliedFrom` only), `src/Seal/Gateway/{API,Setup,OpenApi}.hs`,
`src-gateway-types/Seal/Gateway/Types/Route.hs`, `src/Seal/Command/Serve.hs`,
`test/Seal/Config/SecuritySpec.hs`, `test/Seal/Gateway/ApiRouteSpec.hs`,
`test/Seal/TestHelpers/ApiTestHarness.hs` + literals, `seal-harness.cabal`,
`test/Main.hs`.
**PR B — new (frontend)**: `src/lib/setupSteps.ts`, `src/lib/providerLabels.ts`,
`src/hooks/useSetup.ts`,
`src/components/setup/{SetupGate,SetupWizard,VaultStep,ProviderStep,SetupComplete}.tsx`,
7 test files, `e2e/01-setup.spec.ts`.
**PR B — modified (frontend)**: `src/main.tsx`, `src/types.ts`,
`e2e/capstone.spec.ts` → `e2e/02-capstone.spec.ts`, `e2e/global-setup.ts`.
**PR B — docs**: `README.md`, `CHANGELOG.md`, `AGENTS.md`,
`docs/superpowers/specs/2026-08-18-layered-harness-architecture.md`.

## Risks and rollback

| Risk | Mitigation / rollback |
|---|---|
| PR A breaks a legitimate mutation client | Canonical origin comes from the same boot plan WebAuthn uses; `Nothing` in tests and in `mode = none` with no resolved origin ⇒ allowed; `MutationGuardSpec` cases 11–17 pin both directions |
| CORS removal breaks an unknown client | Verified no in-repo consumer; `CHANGELOG` entry; revert is one commit |
| Base branch moves under us | Both PRs branch off it; rebase before opening; PR B rebases onto PR A |
| Provisioning ordering wrong (partial state) | §7.4 crash matrix + tests 14–21; `resume` is the universal recovery |
| Wizard appears for a configured operator (worst regression) | Derived state; `StateSpec` cases 1–2; `SetupGate` test 65 |
| `age-keygen` absent | 422 + hint; `/vault setup` fallback; e2e declares the dependency |
| Gate placement breaks the app shell | `SetupGate` wraps `App` without touching it; `App.test.tsx` unchanged |

## Out of scope (file as follow-ups)

1. Chat channels step + channel supervisor (live start without restart).
2. Per-origin CORS grants if a legitimate cross-origin client appears.
3. Global body cap on the remaining `collectBody` call sites.
4. Anthropic OAuth login in the browser.
5. Vault key rotation from the browser.
6. Re-routing the CLI's `/vault setup` through `provisionVault`, and validating
   `setupUserSupplied`'s prompt path (CLI-only today).
7. `FormRow` extraction and the four-component `providerLabels` migration.
8. A reusable `/setup` page after completion (this PR only gates first run).
