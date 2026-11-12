# Handoff — web first-run setup wizard (PR B)

**Date**: 2026-11-07
**Repo / branch**: `seal-harness` @ `feat/web-setup-wizard-303`
**Base of this branch**: `feat/gateway-mutation-guard-302` (PR #304), which itself
branches off `gateway/passkey-access-control`

---

## 1. What the operator asked for

A **guided first-run wizard in the web UI**, with two **mandatory** steps:

1. the secrets vault, and
2. an LLM provider.

Then a **deferred** optional step (chat channels) that must be **easy to add
later** as an extra screen at the end. Decisions the operator made explicitly:

- Vault step must reach **backend parity with the CLI**: local age key,
  YubiKey (touch/PIN), and user-supplied identity.
- Chat channels are **out of scope** for this PR; the step list must be a
  registry so one entry + one component adds them.
- The gate is **blocking, no skip**.
- When channels land, they should **live-start** (a channel supervisor) — that
  work is deferred *with* channels, not part of this PR.
- Work is based on `gateway/passkey-access-control` (the passkey access-control
  layer).
- The operator approved splitting the work into **two PRs**.

## 2. Process state (all gates run)

| Step | State |
|---|---|
| Design Review Gate (5 reviewers, 3 rounds + targeted re-checks) | **APPROVED** (PM, Architect, Designer, Security); CTO's final item folded in |
| Plan Review Gate (3 reviewers, 3 rounds) | FAILed each round; every substantive finding fixed. Residual findings were doc-consistency in the design doc, **fixed** at the end. See §9 |
| GitHub issues | **#302** (PR A, done) and **#303** (PR B, the wizard) |
| PR A | **#304** — draft, open, base `gateway/passkey-access-control`, all green |
| PR B | not yet opened (this branch) |

**Normative documents** (read these first):

- Design: `docs/superpowers/specs/2026-11-07-web-first-run-setup-wizard-design.md`
  — **v6**. Read **§0 first**: it re-bases everything onto the passkey branch
  and overrides parts of §5/§7.1/§7.3. The revision logs are history; §0 and the
  v5→v6 log win.
- Plan: `docs/plans/2026-11-07-web-first-run-setup-wizard-plan.md` — **rev 3**,
  two PRs, **67 named tests**. This is the authoritative task list.

## 3. PR A — what landed (#302 / PR #304)

- `src/Seal/Gateway/OriginGuard.hs` — pure
  `sameOriginVerdict :: Maybe Text -> GuardHeaders -> GuardVerdict`. `Nothing`
  = boot plan resolved no origin (`mode = "none"` on a wildcard bind) ⇒ allowed.
  A **loopback** canonical origin accepts any loopback alias (any port) **with
  the same scheme**; a non-loopback canonical requires an exact
  scheme/host/port match; absent `Origin` is allowed unless `Sec-Fetch-Site`
  says `cross-site`/`same-site`; `Origin: null` rejected.
- `apiApp` runs the verdict in a **guard clause ahead of `dispatchApi`** for
  every `POST`/`PUT`/`DELETE` + `GET /api/setup`.
- `ApiDeps.adCanonicalOrigin :: Maybe Text`, wired in `Serve.hs` from
  `naOrigin access`. **34 `ApiDeps` construction sites** carry it (script
  inserted `, adCanonicalOrigin = Nothing` after each `adVault = …`).
- `corsHeaders` deleted; `OPTIONS` → `204` with no grant.
- `collectBodyLimited` + `maxSetupBodyBytes` (8 KiB) in
  `src/Seal/Gateway/Setup.hs` (byte-counting reader, stops at the cap).
- Tests: `OriginGuardSpec` (25 examples), `MutationGuardSpec` (13).
- Gate: `cabal test` → **3966 examples, 0 failures, 41 pending**; hlint → **No
  hints**.
- **Adversarial review caught a real bug** in a first version: the loopback
  clause ignored the scheme, so `https://localhost:8080` was admitted against an
  `http://localhost:8080` canonical. Fixed in `d64d7a3` with both directions
  tested and a scheme-aware property. Do not regress it.

## 4. PR B — progress so far on this branch

Files currently written (compiling, **committed with this handoff**):

- **`src/Seal/Vault/IdentityPath.hs` (NEW, done)** — `VaultIdentityPath`
  (constructor unexported) + `mkVaultIdentityPath :: FilePath -> IO (Either Text
  VaultIdentityPath)` (empty / control char / leading `-` / relative / missing /
  not-a-regular-file), plus `vaultIdentityPathText` (raw path, for `age` and
  storage) and `vaultIdentityPathDisplay` (file name only, log-safe). Registered
  in `seal-harness.cabal` after `Seal.Vault.Backend`.
- **`src/Seal/Security/Vault/Age.hs` (modified, done)** — added
  `mkAgeRecipient :: Text -> Either Text AgeRecipient` (shape only; the checksum
  is what the round-trip is for), `ageEncryptArgs` / `ageDecryptArgs` (single
  token `--recipient=<v>` / `--identity=<p>`), and validation of **both**
  credentials inside `mkAgeEncryptor` (single choke point: CLI, gateway,
  hand-edited `security.toml`). `validateAgeIdentity` checks structure only
  (non-empty, absolute, no `-` prefix, no control chars) — existence is
  `IdentityPath`'s job. **This changes the CLI's behaviour** for a malformed
  config: record it in `CHANGELOG.md` as a fix.
- **`src/Seal/Config/Security.hs` (modified, done)** — added `VaultKeyFields`
  (recipient / identity / keyType only) and
  `updateVaultKeySection :: FilePath -> (SecurityConfig -> Either e VaultKeyFields) -> IO (Either Text (Either e VaultKeyFields))`.
  The callback sees the **current** config and may reject, which is the
  **cross-process compare-and-swap**: read and write both happen inside
  `securityWriteLock`. The write is verified before commit (re-decode must
  round-trip the three fields **and** leave `access_control`,
  `untrusted_execution`, `vault_path`, `vault_unlock` untouched).

### ⚠️ Discovery that changes the design text (read carefully)

The passkey branch documents `updateAccessControlSection` as **"The ONLY writer
of `security.toml` reachable from the gateway"**, with a callback type that
*makes it a compile error* for the gateway to name vault fields. The design
(§7.4/§7.6) assumed a general `updateSecurityConfigEither`.

**Resolution taken:** keep the base branch's guarantee by adding a **second
narrow writer** (`updateVaultKeySection` + `VaultKeyFields`) whose callback
cannot name `access_control`/`untrusted_execution`, and the
`updateAccessControlSection` docstring now says "one of the TWO narrow writers".
The design doc still says `updateSecurityConfigEither` — **update the design
doc** (WU7 owns doc edits) to describe the two narrow writers instead.

## 5. What remains (plan rev 3, PR B)

Work units in dependency order. Each has a RED-test table in the plan; do not
skip the RED step.

### WU1 (in progress) — provisioning core + `adSetup` plumbing

Done: `IdentityPath`, `Age` additions, `Security.updateVaultKeySection`.

Remaining:

1. **`src/Seal/Vault/Provision.hs` (NEW)** — the core. Design §8 has the types;
   adjust `pdWriteConfig` to the new writer:

   ```haskell
   data VaultSpec = VaultSpecLocal | VaultSpecYubiKey { vsTouch, vsPin :: Bool }
                  | VaultSpecUser { vsRecipient :: AgeRecipient, vsIdentity :: VaultIdentityPath }
                  | VaultSpecResume
   data ProvisionError = ProvisionAlreadyExists | ProvisionInProgress
     | ProvisionKeygenMissing Text | ProvisionNeedsTty Text | ProvisionInvalidInput Text
     | ProvisionRoundTripFailed Text | ProvisionKeygenFailed Text
     | ProvisionVaultInitFailed | ProvisionVaultUnreadable | ProvisionConfigWriteFailed Text
   data SetupKeygen = SetupKeygen { skLocal :: IO (Either ProvisionError ResolvedKey)
                                  , skYubi  :: Text -> Bool -> Bool -> IO (Either ProvisionError ResolvedKey)
                                  , skUser  :: AgeRecipient -> VaultIdentityPath -> Either Text ResolvedKey }
   data SetupEncryptor = SetupEncryptor { seMk :: AgeRecipient -> AgeIdentity -> IO (Either VaultError VaultEncryptor)
                                        , seVerify :: VaultEncryptor -> IO (Either Text ()) }
   data ProvisionDeps = ProvisionDeps { pdKeygen :: SetupKeygen, pdEncryptor :: SetupEncryptor
                                      , pdWriteConfig :: (SecurityConfig -> Either ProvisionError VaultKeyFields)
                                                      -> IO (Either Text (Either ProvisionError VaultKeyFields))
                                      , pdLockPath :: FilePath }
   provisionVault :: SealPaths -> IORef (Maybe VaultHandle) -> ProvisionDeps -> VaultSpec
                  -> IO (Either ProvisionError ProvisionOutcome)
   renderProvisionError :: ProvisionError -> (Text, Maybe Text)   -- (error, hint); lives HERE
   ```

   Order (design §7.4): pre-check (config parses, no recipient recorded unless
   `resume`, no vault file) → take **O_EXCL lock file** (stale after 30 s) →
   obtain key → round-trip verify (`System.Timeout`) → CAS config write
   (`resume` skips) → `vhInit` → **decrypt-verify** (`vhList`; failure ⇒
   `ProvisionVaultUnreadable`) → `openVault` at the final path + `writeIORef`.
   `resume` is carved out of the CAS **and** the 409.
   `renderProvisionError` may name the keys dir (tilde form preferred) but never
   an identity path, a vault path, or an `age1` value.

2. **`src/Seal/Gateway/Setup.hs`** — add
   `SetupDeps { sdProvision :: ProvisionDeps, sdResolveProvider :: KnownProvider -> ModelId -> IO (Either Text SomeProvider) }`
   + `stubSetupDeps`.
3. **`ApiDeps.adSetup :: SetupDeps`** (one more field ⇒ the same 34 sites),
   wired **real** in `Serve.hs` (no stub: `prManager`/`prVault`/`prCallCounter`
   are in scope there).
4. Tests: `test/Seal/Vault/ProvisionSpec.hs` (plan WU1 1–22),
   `test/Seal/Security/Vault/AgeSpec.hs` (23–25, no `pendingWith`),
   `test/Seal/Config/SecuritySpec.hs` (26–28), and an **opacity compile-fail
   spec** for `VaultIdentityPath` (pattern:
   `test/Seal/Config/SecurityScopingFailSpec.hs` +
   `Seal.TestHelpers.CompileFail.assertCompileFail`).
5. `src/Seal/Vault/Backend.hs`: add
   `setupUserSuppliedFrom :: AgeRecipient -> VaultIdentityPath -> Either Text ResolvedKey`
   (**do NOT reroute the CLI's `runSetup`** and do not touch
   `setupUserSupplied` — deferred, plan rev 2 item 6). `setupYubiKey` needs a
   non-interactive core: plugin exit ≠ 0 / empty stdout ⇒
   `ProvisionNeedsTty command`.

### WU2 — `Seal.Setup.State` (plan WU2 1–18)

`StepStatus = StepReady | StepPending | StepBlocked`; `SetupStep { stId,
stRequired, stStatus, stDetail, stActions }`; `SetupState { ssRequiredComplete,
ssSteps, ssProviders }`; `deriveSetupState` over explicit inputs.

**V-rows in this order** (blocked-first): V1 orphan vault file → V2 unreadable
identity → V3 `startup`-mode locked → V4 configured-but-not-open (`reopen`) →
V5 key recorded + no vault file (`resume`) → V6 ready → fallback pending.

**`vsLocked` is never a readiness signal on its own**: `per_access` never
populates the cache yet reads work. **Provider rows**: `yubikey` vault ⇒
config-only (never call `adProviders`, which decrypts); `x25519` ⇒
`adProviders`. Use `adPaths` and the configured `scVaultPath`; **never**
`VaultRuntime.vrPaths` (`error "test stub"` in the fake).

### WU5 — setup routes (plan WU5 19–33)

Four routes: `GET /api/setup`, `POST /api/setup/vault`,
`POST /api/setup/vault/reopen`, `POST /api/providers/:name/test`.
`Route.hs` (`expectedRouteCount` 62 → **66**) + `OpenApi.hs` arms + dispatch
(literal `"setup"` before any capture arm) + `Cache-Control: no-store`.
`reopen` = `loadSecurityConfig → resolveEncryptor → openVault → vhUnlock
(startup) → writeIORef` under the setup lock (it cannot import
`Seal.Command.Serve`). Handlers are **default-denied by the passkey middleware**
until access control is configured; test 21 asserts that.

### WU6 — frontend (plan WU6 34–67)

`lib/setupSteps.ts` (+ wizard-local `lib/providerLabels.ts`), `hooks/useSetup.ts`
(returning `{status, error, hint}`),
`components/setup/{SetupGate,SetupWizard,VaultStep,ProviderStep,SetupComplete}.tsx`,
and **`main.tsx` becomes `<AccessGate><SetupGate><App/></SetupGate></AccessGate>`**
— `App.tsx` and `App.test.tsx` stay **untouched**. e2e: rename
`capstone.spec.ts` → `02-capstone.spec.ts`, add `01-setup.spec.ts` (drives the
real wizard; requires `age-keygen`), `global-setup.ts` owns the ordering;
`playwright.config.ts` is **verify-only** (`workers: 1`,
`fullyParallel: false` already set). Action bar renders from `step.actions`;
unknown verbs render no button; `configure` is a no-bar action; completion
screen gates `onComplete` behind "Start chatting"; no skip control (absence
assertion).

### WU7 — docs

README first-run section; `CHANGELOG.md` **four** behaviour changes (CORS and
mutation origin already added by PR A; add `startup`-mode reopen, the
`--identity=`/`--recipient=` argv form, and the `mkAgeEncryptor` validation as a
fix); `Config/Security.hs` docstrings (done for the two-writer model — verify);
`AGENTS.md` **extend** the existing exception list (`age`, `ssh`, `tmux`) with
`age-keygen` and `age-plugin-yubikey`; the layered-harness spec's CORS
invariants; **and the design doc's stale sections** (§3, §7.1 `GuardPolicy`
residue, §7.4/§7.6 `updateSecurityConfigEither` → the two narrow writers, §10,
§11.5, §12, §13, §14.7). PR body: S1b manual walkthrough + residual-threat
paragraph (service-token holders, `mode = "none"`, same-UID local processes).

## 6. Commands and gotchas

```bash
# build / test / lint — always inside the nix shell
nix develop --command cabal build all
nix develop --command cabal test            # redirect to a file!
nix develop --command hlint src/ test/      # must print "No hints"

# run one spec (hspec --match takes a substring, NOT a regex)
nix develop --command cabal test --test-options='--match ProvisionSpec'
```

- **Never pipe Haskell binaries through `head`/`tail`** — the RTS ignores
  SIGPIPE and the command hangs/EPIPEs. `> /tmp/x.log 2>&1` then grep the file.
- `hlint` is the gate, not the plan's aspirational import list: it wants
  `Data.Char (isDigit)`, so keep it.
- Adding an `ApiDeps` field means editing **34** construction sites. The cheap
  trick used for `adCanonicalOrigin`: `python3` regex-insert
  `, adField = <default>` immediately after `adVault = …` in
  `test/Seal/{Gateway/{ApiSpec,ServerSpec,PatIngestionSpec},TestHelpers/ApiTestHarness}.hs`
  and `test/Seal/Phase7aSpec.hs`, and wire the real value in
  `src/Seal/Command/Serve.hs`.
- **Never force-push, never `--no-verify`.** One commit per work unit.
- `make check` = build + test + hlint.
- Coverage: `.coverage-thresholds.json` records that HPC is not wired; the DoD
  is "run `make test` and record the output".
- The base branch is large and in flight; **rebase onto
  `gateway/passkey-access-control` before opening the PR**, and note that
  `seal-harness.cabal`, `test/Main.hs`, `src-gateway-types/.../Route.hs` and
  `src/Seal/Gateway/API.hs` are merge hotspots — additive edits, rebased last.

## 7. Security constraints that must not slip

- The browser must never receive key material. Setup responses carry
  `recipient` + `key_type` only — no identity path, no vault path, no contents.
- `GET /api/setup` is **path-free** (tilde form only); **mutation error bodies**
  may name the configured keys directory (needed for a correct recovery command
  under a non-default `SEAL_HOME`), never an identity or vault path.
- Every value reaching `age`'s argv goes through a smart constructor
  (`mkAgeRecipient`, `mkVaultIdentityPath`, `validateAgeIdentity`) and is passed
  as a **single token**.
- The setup lock is an `O_CREAT|O_EXCL` file next to `security.toml` (0600, 30 s
  stale window). Two gateways cannot race; a concurrent TUI `/vault setup` is
  excluded only by the CAS plus the post-init decrypt check — that residual is
  documented, not claimed away.
- `~/.seal/` is writable by the operator's processes; this endpoint adds no
  capability for a same-UID local process (it can already write
  `security.toml`). Say so in the module header + PR body.

## 8. Definition of done for PR B

Plan rev 3's "PR B" DoD: all four specs + frontend suites green, `make check`
green, `npm test` green, coverage command run and recorded, e2e green locally,
**S1b manual walkthrough** recorded, no secret/path leakage, residual threats
stated. `Closes #303` in the PR body, branch off PR A, rebased before ready.

## 9. Known-unverified / open items

- The plan gate never returned all-PASS; the residual findings were
  doc-consistency and were fixed by hand afterwards. **Re-read the plan's WU
  tables against the design before starting each WU** rather than trusting
  either document alone.
- The design doc still contains older revision-log text that the v5→v6 log
  supersedes; §0 is authoritative.
- `Provision`'s exact signature is a sketch above; if a seam proves
  unimplementable, adjust the test list rather than weakening an assertion.
- PR A and PR B both add an `ApiDeps` field; if PR A merges first, rebase and
  the literal edits collapse into the same lines.
