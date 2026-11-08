# Web First-Run Setup Wizard — Vault → LLM Provider

**Issue**: (filed alongside this revision — §15)
**Branch**: `feat/web-setup-wizard-<NN>`
**Date**: 2026-11-07
**Status**: Design — v6, re-based onto `gateway/passkey-access-control`; plan rev 3 (PM, Architect, Designer, Security APPROVED; CTO items folded in)

## 0. Rebase onto `gateway/passkey-access-control` — OVERRIDES §5/§7.1/§7.3

> The revision logs below (v2→v3, v3→v4, v4→v5) are **history**: where any of
them conflicts with §0 or the v5→v6 log, §0/v6 wins.

The work is based on `gateway/passkey-access-control` (per the operator), which
already ships a **WebAuthn access-control layer** for the gateway. It supplies
most of what §7 was inventing, and reading it changed the design. Where this
section disagrees with a later section, **this section wins**; the superseded
text is kept for the audit trail with a pointer.

### 0.1 What the base branch already provides

| Fact (verified in the tree) | Consequence for this design |
|---|---|
| `AccessGate` wraps `<App/>` in `main.tsx`; `AccessGate.tsx` + `AccessView.tsx` implement first-run **enrollment** (passkey) and an explicit "waive" (`mode = "none"`) | The wizard is the **second** gate in the chain, not the first: enrollment must complete first |
| `accessControlMiddleware` is **default-deny**: only `unconfiguredAllow` / `passkeyAllow` / session / service-token requests pass (`AccessControl.hs:292-340`) | `/api/setup/*` is unreachable while `AccessUnconfigured`, so the ordering is **server-enforced**, not just UI. In `passkey` mode it needs a session (the SPA's cookie) |
| Boot resolves the **canonical origin** (`acsOrigin`, `bpOrigin`) once, and WebAuthn verifies `clientDataJSON.origin` against it (`BootPlan.hs`, `AccessControl.hs`) | The Origin check in §7.1 should compare against **this** value — one trust anchor, no invented policy |
| `[gateway] host` is now authoritative for the actual bind (`setHost`) and defaults to `localhost` (base branch, landed) | The v4 `gcHost`-vs-bind problem and the **peer-address** check are moot → **deleted** |
| First run writes `config.toml` + `security.toml` from embedded templates (`Seal.Config.Templates`) | "file absent" is a legacy path, not the normal first run |
| A `security.toml` that does not decode **refuses boot** (`BootPlan.bootPlan`) | State row **V0 is unreachable** → deleted |
| Auth responses deliberately carry **no** `Access-Control-Allow-Origin` (`AccessControl.hs:550`) | Precedent for §7.1's CORS removal; `corsHeaders` (ACAO `*`) still exists on `apiApp` and still goes |
| `maxAuthBody = 64 KiB` with a bounded reader in `AccessControl` | Reuse that helper for `collectBodyLimited` rather than writing a second one |

### 0.2 Superseded decisions

1. **§7.1 origin guard — replaced.** No `GuardPolicy`, no `GuardHosts`, no
   `ghPeerLoopback`, no `isLoopbackPeer`, no `SockAddr` plumbing, and **no
   `TestHelpers`/`ApiSpec`/`ServerSpec`/`PatIngestionSpec`/`Phase7aSpec` edits**
   (that churn existed only because the v4 guard needed a peer address and a
   Host header). New verdict:

   ```haskell
   data GuardHeaders = GuardHeaders
     { ghOrigin :: Maybe Text, ghSecFetchSite :: Maybe Text }
   data GuardVerdict = Allowed | Rejected !Text
   -- | @Nothing@ = the boot plan resolved no origin (wildcard bind + mode=none,
   -- an explicit operator waiver).
   sameOriginVerdict :: Maybe Text -> GuardHeaders -> GuardVerdict
   ```

   Rules (v6): `Nothing` → `Allowed` (documented waiver). `Just canonical` →
   `Origin: null` rejected; `Origin` present is accepted when either it equals
   `canonical` exactly, **or** `canonical` is loopback and the origin's host is
   any loopback alias (`localhost`, `127.0.0.0/8`, `[::1]`) with `http`/`https`
   (that is what makes `127.0.0.1:PORT` and the vite-dev `localhost:5173` work);
   `Origin` absent allowed only when `Sec-Fetch-Site` is
   absent/`same-origin`/`none`. Applied to **all mutations** (they are either
   cookie-authenticated — where CSRF is real — or `open` mode, where nothing else
   protects them) and to `GET /api/setup`.
2. **§7.3 "no authentication" — withdrawn.** The gateway now has passkey
   sessions. The setup token / service token the base branch already mints is
   the per-run credential the round-2 reviewer asked for; v4's "theatre"
   verdict applied to *inventing* a token, not to this. Residual classes:
   service-token holders (CLI/channels) and `mode = "none"` (explicit waiver).
   Stated in the module header and the PR body.
3. **§5.1 V0 — deleted** (undecodable `security.toml` refuses boot). The rows
   that remain: V1 orphan vault file, V2 unreadable identity, V3 `startup`-mode
   locked, V4 configured-but-not-open, V5 resume, V6 ready.
4. **`ApiDeps` churn shrinks.** One new field (`adSetup`), and the guard takes
   the already-plumbed canonical origin (the base branch has it on the access
   handle — the handler reads it from there, so `adGuard` is dropped as well).
   Test literals gain `adSetup = stubSetupDeps` only (~28 sites, one line each).
5. **Ordering in the UI.** `main.tsx` becomes
   `<AccessGate><SetupGate><App/></SetupGate></AccessGate>`; `SetupGate` is the
   hook-driven wrapper this design specifies, and it is the reason `App` no
   longer needs the gate inside it (§6.1's "inside App" is superseded — hooks
   stay in `App`, the gate wraps it).
6. **Provider/test/setup endpoints remain behind the passkey middleware**, so
   their CSRF story is cookie-CSRF, not "unauthenticated loopback".
7. **`age-keygen`/`age-plugin-yubikey` exception list** is unchanged in intent,
   but `AGENTS.md` on the base branch already documents the trusted-binary
   rules for `age`; the edit becomes a one-line addition (§7.6).

### 0.3 What survives unchanged

The provisioning core (§8), the setup state model minus V0 (§5), the API
surface (§9), the wizard UI and step registry (§6), the frontend files (§10),
the test plan (§11) minus the peer/Host cases, the CORS removal and the
`collectBodyLimited` cap, and the work-unit structure (§12) with WU1's scope
reduced by the deleted guard plumbing.

## Revision log

### v2 → v3 (round-2 blockers)

Two rounds, five reviewers each. Round 2 verified v2 against the tree and found
that several of v2's *fixes* were themselves unimplementable. Each is resolved
below with a concrete decision, not a promise.

1. **`SetupDeps` had no construction site (Architect, CTO).** v2 claimed both
   "built inside `API.hs`" and "built in `Serve.hs`", and the provider-ping seam
   needs a `Manager`/`ProviderRuntime` that `ApiDeps` does not carry.
   **Decision:** `ApiDeps` gains two fields — `adSetup :: SetupDeps` and
   `adGuard :: GuardPolicy` — both built in `Serve.hs` and in
   `Seal.TestHelpers.ApiTestHarness`, with stub values exported for the ~20
   remaining record literals. This is real, bounded churn (§12 WU0) and v2's
   "zero `ApiDeps` churn" claim is withdrawn.
2. **The CAS was not expressible (Architect, CTO, Security).**
   `updateSecurityConfig` takes a *total* function, so "fail if a recipient is
   already recorded" cannot be reported. **Decision:** add
   `updateSecurityConfigEither :: FilePath -> (SecurityConfig -> Either Text SecurityConfig) -> IO (Either Text ())`
   in `Seal/Config/Security.hs` (WU1 owns that file), and type the seam with it.
3. **"Cross-process safe" was false (Architect).** `securityWriteLock` is a
   process-local `MVar`. **Decision:** an `O_EXCL` lock file next to
   `security.toml` (stale-safe, 30 s) makes concurrent *gateway* setup mutually
   exclusive; a concurrent TUI `/vault setup` remains excluded only by the CAS
   plus a post-init decrypt check that **refuses to report success** if the key
   on disk is not ours. Stated as a residual, not papered over.
4. **Provider readiness decrypted the vault (Architect, Security).** `configuredProviders`
   → `vhGet` → on-demand unlock → one `age` invocation per page load, and a
   touch prompt on a YubiKey. **Decision:** readiness never decrypts when the
   vault key type is `yubikey` (config-only signal); for `x25519` it reuses
   `adProviders`, which already decrypts once per `GET /api/providers` today —
   documented, not new.
5. **Guard rule "Host required" broke ~150 existing gateway tests (Architect,
   CTO, Security).** `Network.Wai.defaultRequest` sends no `Host`. **Decision:**
   keep the rule (browsers always send `Host`; absence is not a browser), and
   WU4 owns the mechanical test-helper update (add `Host: 127.0.0.1:<port>` to
   the mutating-request builders in ApiSpec / ApiTestHarness / ServerSpec /
   PatIngestionSpec / Phase7aSpec). `11.4` case 5 is rewritten accordingly and a
   "missing Host → 403" case is added.
6. **Non-loopback binds would become read-only (Security, Architect).** v2's
   header-only verdict rejected every mutation on a LAN bind, breaking a
   supported config. **Decision (this is why `adGuard` exists):**
   `GuardPolicy = GuardLoopback | GuardHosts [Text]`, derived from `gcHost` in
   `Serve.hs`. Loopback → loopback-only. Specific non-loopback host → that host
   plus `gcAllowedOrigins`. Wildcard (`0.0.0.0`/`::`) → loopback-only,
   fail-closed, with the wizard saying "complete setup on the host at
   `http://127.0.0.1:<port>`" (§6.1 has a dedicated 403 screen for it).
7. **WU order was unexecutable (CTO, Architect).** WU4's DoD drove routes that
   only exist after WU5. **Decision:** WU0 (ApiDeps fields) → WU1..WU3 as before
   → WU4 = guard wiring + CORS removal + body cap + test-helper Hosts, DoD =
   403 matrix on *existing* mutating routes and full suite green → WU5 = setup
   routes/handlers + remaining `SetupApiSpec` cases.
8. **Route count was wrong (Designer, Security, Architect):** four new routes →
   `expectedRouteCount` 62 → **66**, four dispatch arms, and `POST
   /api/providers/:name/test` gets its own work unit line.
9. **`resume` contradicted the 409 contract (PM).** **Decision:** `resume` is
   carved out of the CAS and out of the 409 row; it is the only backend that may
   succeed with a recorded key, and it performs no config write. HTTP-level test
   added.
10. **Failed `reopen` was an infinite loop (PM).** **Decision:** the 422 from
    `reopen` carries a terminal, copy-pasteable recovery (`mv` the vault file
    aside when it holds no secrets, or restore the matching key), rendered by
    the wizard; test asserts the loop terminates in instructions.
11. **Unparseable `security.toml` was only prose (PM).** **Decision:** new V0
    blocked row; never a CAS attempt; `detail` path-free.
12. **`stActions` were emitted and never rendered (Designer).** **Decision:** the
    wizard renders an action bar from `actions` for both `pending` and
    `blocked`; `StepProps` is defined; V3-resume / V4-reopen / V6-create are UI
    cases with tests.
13. **`ProviderError` type does not exist (CTO).** **Decision:** the seam is
    `KnownProvider -> ModelId -> IO (Either Text SomeProvider)`, matching
    `Seal.Providers.Registry.resolveProvider`.
14. **`skYubi` was ill-kinded (CTO).** **Decision:**
    `skYubi :: Text -> Bool -> Bool -> IO (Either ProvisionError ResolvedKey)`.
15. **The 422 YubiKey hint contains an absolute keys path (CTO, Designer,
    Security).** **Decision:** hints may contain the **tilde form**
    (`~/.seal/keys/default.yubikey.txt`) but never an absolute path and never
    `age1`; the property, `11.1.11` and `11.4.11` are aligned to that rule.
16. **The provider label map exists in four components (Architect, Designer).**
    **Decision:** `lib/providerLabels.ts` is extracted from all four, with a
    raw-name fallback.
17. **`App.test.tsx` (~20 `render(<App/>)` sites) would fail closed on an
    unmocked `/api/setup` (Designer).** **Decision:** `test-setup.ts` gains a
    default `/api/setup → {required_complete: true}` mock; WU6 owns it.
18. **e2e was self-contradictory (Designer, CTO).** **Decision:** two ordered
    specs against the shared fresh `SEAL_HOME`: `01-setup.spec.ts` drives the
    real wizard (vault + ollama) which provisions the server, `02-capstone.spec.ts`
    runs unchanged afterwards. `fullyParallel: false`, `workers: 1`; requires
    `age-keygen`; e2e stays local-only (CI does not run it).
19. **"Test connection" tested a different credential than the screen showed
    (Designer, Security).** **Decision:** Test is disabled while the key/base-URL
    fields are dirty ("save, then test"); it always tests stored config.
20. **`/setup` collides with the closed `TopSection` union (Designer).**
    **Decision:** `TopSection` gains `'setup'`, TopBar renders nav from an
    explicit list that excludes it, and `/setup` is full-screen (no chrome).
21. **Body cap scope (Security).** Setup mutations get a hard cap
    (`collectBodyLimited`, 8 KiB). Capping the other 30 `collectBody` call sites
    is a deferred follow-up (§14) — the cross-origin class it would defend
    against is already closed by the guard.

Rejected with rationale: a per-run admin token (v2 §7.3, unchanged — see §7.3);
dropping `mkAgeEncryptor` validation (the round-trip is the real check, but the
charset check is defence in depth); restricting the wizard to the local age key
backend (the operator asked for all three).

### v5 → v6 (plan-review round 2)

1. **Module layering had two import cycles.** `Provision` must import
   `Seal.Vault.Backend` (for `setupLocalAgeKey`/`setupYubiKey`) and
   `Seal.Security.Vault.Age` (for `AgeRecipient`/`VaultEncryptor`); putting the
   validators in `Provision` would have forced both to import it back.
   **Decision:** `mkAgeRecipient` lives in `Seal.Security.Vault.Age` (next to
   `AgeRecipient`, pure, used by `mkAgeEncryptor` in the same module), and
   `VaultIdentityPath`/`mkVaultIdentityPath` move to a new
   `src/Seal/Vault/IdentityPath.hs` that imports neither `Provision` nor
   `Backend`. `SetupKeygen.skUser` takes that type; no cycle.
2. **The canonical origin is `http://localhost:<port>` for loopback binds, but
   the SPA is reached at `http://127.0.0.1:<port>` (e2e) and
   `http://localhost:5173` (vite dev).** Exact string matching would 403 both.
   **Decision:** when the canonical origin is loopback, any **loopback alias**
   (`localhost`, `127.0.0.0/8`, `[::1]`) with any port is accepted; when it is
   not loopback, the origin must match exactly. An attacker cannot serve from a
   loopback name without already running code on the host, which is the class
   §7.3 documents as out of scope. This deletes the last use of
   `gcAllowedOrigins`-host matching in the guard.
3. **`--identity=<path>` / `--recipient=<value>` is an invocation change** (today
   they are two argv tokens), not a no-op: recorded in `CHANGELOG.md` as a
   change, alongside the CORS removal and the `startup`-mode reopen.
4. **`AGENTS.md` already has the permitted-exception list** (`age`, `ssh`,
   `tmux`) at its "two global invariants" section, so the edit *extends* it with
   `age-keygen` and `age-plugin-yubikey` rather than creating one.
5. **The design doc itself is normative and was left stale.** WU7 owns the
   edits: §3's superseded "loopback peer + Host" behaviour note, §10's
   `FormRow`/`providerLabels` migrations, §11.5's `App.test.tsx` router edits and
   `playwright.config.ts`, §12's WU table (peer/Host/`adGuard`, FormRow,
   `global-setup.ts`), §13/§14.7's peer residue, and §12's "two behaviour
   changes" → **four** (CORS, mutation origin, `startup` reopen, argv form).
6. **Coverage gate wording**: `.coverage-thresholds.json` records that HPC is
   not wired, so the DoD is "run the enforcement command (`make test`) and record
   its output", not "thresholds pass".

### v3 → v4 (round-3 blockers)

Round 3: PM and Architect APPROVED; Designer, Security and CTO each raised one
class of blocker. All four are narrow and are decided here.

1. **The guard's loopback verdict was derived from a value that does not
   describe the listener (Security B1).** Verified: `runGateway` calls
   `runSettings (setPort port settings)` and never `setHost`, so Warp binds
   `*4` (0.0.0.0) regardless of `gcHost`. A LAN peer could therefore send
   `Host: 127.0.0.1:<port>` with no `Origin` and pass rule 1. **Decision:** add
   a **peer-address** check — `GuardHeaders` gains `ghPeerLoopback :: Bool` from
   `Network.Wai.remoteHost`, populated at the `apiApp` dispatch site — and
   require a loopback peer under `GuardLoopback`. Honouring `gcHost` in the bind
   is a *separate* pre-existing bug (filed as a follow-up, §14) because
   `setHost` with a DNS name that is not an interface address would fail to bind
   and that risk does not belong in this PR.
2. **`per_access` was gated as "locked" forever (Designer B1).** Verified:
   `vsLocked = isNothing cache` and `per_access` never populates the cache by
   design, while reads still work. **Decision:** `V3` applies to `startup` only;
   `per_access` is `V6 Ready`. `reopen` now calls `vhUnlock` after opening (so a
   `startup` vault converges to Ready), and `StateSpec` adds both cases.
3. **CAS rejection lost its type at the seam (CTO B1).** `pdWriteConfig`
   collapsed "a recipient appeared" and "load failed" into one `Left Text`, so
   the 409 was unreachable. **Decision:**
   `updateSecurityConfigEither :: FilePath -> (SecurityConfig -> Either e SecurityConfig) -> IO (Either Text (Either e ()))`
   — the callback's `Left e` is preserved; `ProvisionAlreadyExists` maps to 409,
   only load/parse failure maps to 500. `SecuritySpec` and `ProvisionSpec` each
   gain a case pinning that split.
4. **WU0 could not compile alone (CTO B2), WU4's DoD still needed WU5 routes
   (CTO B3), and the `test-setup.ts` mock cannot work (CTO B4, Designer).**
   **Decision:** WU0 is merged into WU1 ("Provision core + dependency
   plumbing", which owns `Vault/Provision.hs`, the cabal entry, `ApiDeps`,
   `Serve.hs` wiring with **real** deps — no stub to forget — and the ~33
   `ApiDeps` literal sites); WU4's DoD is restricted to the guard/CORS/body-cap
   and Host-helper cases on **existing** routes and it registers
   `SetupApiSpec` in cabal + `test/Main.hs`; and `App.test.tsx` keeps its own
   stubs — `defaultFetchDispatch()` plus the inline routers each gain an
   `/api/setup` branch (~18 one-line edits). `test-setup.ts` is dropped from the
   plan.
5. Small fixes folded in: `GuardHosts = nub (gcHost : map hostOfOrigin gcAllowedOrigins)`
   (single-sourced, §7.1); `Seal.Gateway.Setup` carries its own JSON/body
   helpers so `API.hs` does not widen its exported surface; `reopen` is spelled
   out as `loadSecurityConfig → resolveEncryptor → openVault → vhUnlock →
   writeIORef` (it cannot import `Seal.Command.Serve`); WU5 flips nothing
   because WU1 wired the real deps; §11.4 case 1 is split (1a WU4, 1b WU5);
   §11.4.10 names one code; the `age-keygen` case declares `pendingWith`; the
   provider step renders from `SetupState.providers` (no decrypting call) and
   `configure` is a no-bar action; V2 drops `reopen`; `§6.3` gains the 400 row;
   `§5.2` deletes the unimplementable "config says it was configured"; path rule
   is split (GET state = path-free, mutation hints may name the keys dir).

## 1. Problem

The web gateway assumes a working environment. Two things must be true before
the UI is useful:

1. **A secrets vault exists and is open.** Every provider credential, channel
   token, and repo secret lives in it. With no vault, `POST /api/secrets`,
   `POST /api/providers`, and every credential-consuming path fail with
   `vault not configured — run /vault setup`.
2. **An LLM provider is configured and set as the default.** With none, the
   composer creates sessions that cannot complete a turn.

Today both are reachable **only from the CLI/TUI** (`/vault setup`,
`/provider add`, `/provider default`). A first-time operator who runs
`seal serve` gets a web UI in which every meaningful action dead-ends in a
slash-command error message pointing at a TUI they may not be running.

## 2. Goals

- **G1** On first run — vault or provider not usable — the web UI shows a guided
  wizard instead of the app shell. No interaction with the broken app until both
  mandatory steps are done.
- **G2** Vault step reaches backend parity with the CLI: local age key,
  YubiKey (touch/PIN policy), existing age identity. The browser never receives
  private key material.
- **G3** Provider step configures anthropic / openrouter / ollama, stores the
  credential in the vault, seeds `config.toml`, sets the default provider, and
  offers a live "Test connection" against **saved** config.
- **G4** Setup state is derived from the real system, never a sticky flag.
- **G5** The step list is a registry: adding a "chat channels" step later is one
  entry plus one component.
- **G6** Every state-changing request is defended against cross-site forgery,
  and the permissive CORS headers that make loopback data readable from any web
  page are removed.
- **G7** TDD throughout.

### 2.1 Success criteria

| # | Criterion | Verification |
|---|---|---|
| S1a | Empty `~/.seal/` → gate lifted, **zero CLI commands** | e2e `01-setup` spec (automated, local-only) |
| S1b | …and a first chat turn completes against a real provider | Manual walkthrough (needs a live credential/network — explicitly *not* automated) |
| S2 | A configured host **never** sees the wizard | First `StateSpec` case; `SetupGate` tests (plan WU6 64–67); e2e `02-capstone` runs ungated after `01-setup` provisions |
| S3 | A hostile web page cannot create a vault, change a provider, or read the transcript | 403 matrix in `OriginGuardSpec`/`SetupApiSpec`; no `Access-Control-Allow-Origin` on any response |
| S4 | Every `StepBlocked` row names an action, and the wizard can act on it in place | `StateSpec` blocked rows + `SetupWizard` action-bar tests |
| S5 | No workflow regresses: `make check`, `npm test`, existing e2e | CI + local gate |

Worst regression is S2 (bricking existing operators): it is the first test and
the reason `GET /api/setup` derives state instead of reading a flag.

## 3. Non-goals and explicit behaviour changes

- **Chat channels** step and the **channel supervisor** (live start without
  restart): deferred. Channel forks capture the boot-time vault handle
  (`Serve.hs:429-431`), so a wizard-created vault reaches channels on next
  restart — stated so the deferred step is not mistaken for working.
- **Anthropic OAuth** in the browser: CLI-only (`/provider login`).
- **Vault key rotation** from the browser: CLI-only.
- **`localhost`-any-port is trusted.** Any loopback origin (any port) may
  mutate. Rationale: only code already running on the host can serve from
  `http://localhost:*`; it keeps `vite dev` working.
- **Behaviour change 1 — CORS removed.** `Access-Control-Allow-Origin: *` and
  the permissive `OPTIONS` catch-all are deleted; no in-repo client depends on
  them (verified: no test, no frontend code, Swagger and SPA are same-origin,
  chat channels are non-browser clients). Recorded in `CHANGELOG.md`.
- **Behaviour change 2 — mutations must come from the gateway's own origin.**
  With a passkey session, a cookie is sent cross-origin, so every
  `POST`/`PUT`/`DELETE` now requires `Origin` to match the boot-resolved
  canonical origin (or any loopback alias when that origin is loopback), or to be
  absent with no cross-site fetch metadata. `mode = "none"` with no resolvable
  origin (wildcard bind) is an explicit operator waiver and is allowed. Recorded
  in `CHANGELOG.md` and §13.
- **`vault_unlock = "startup"` is a first-run interaction.** `seal serve` does
  not unlock at boot, so such a deployment now lands on V3 and needs one
  `reopen` (possibly a YubiKey touch). Correct behaviour, recorded in
  `CHANGELOG.md` as a third behaviour-change note.
- **Cross-UID local processes are out of scope.** Loopback is host-wide;
  `~/.seal` is owner-writable but the HTTP port is not. Another local account on
  a first-run host can POST setup and pin its own recipient. Mitigating that
  needs authentication, which is a larger feature (§14).
- **Authentication / multi-user**: unchanged (loopback, single operator).

## 4. Use cases

| # | Who | Wants | So that | When |
|---|-----|-------|---------|------|
| UC1 | First-time operator (empty `~/.seal/`) | To click through vault → provider and reach an **unblocked shell where a chat turn can be attempted** | They do not need the TUI to get started | First page load |
| UC2 | Operator with a vault, no provider | To see only the provider step | They are not asked to redo work | First page load |
| UC3 | Operator with a broken/partial vault (unparseable config, orphan vault, unreadable identity, locked vault, key that cannot open the file) | To be told exactly what is wrong, be handed the command, and retry in place | They are not stuck | First load, or after a CLI repair |
| UC4 | Operator whose browser has a hostile page open | To be safe from a page that POSTs to their gateway | No attacker-keyed vault, no readable transcripts | Always |
| UC5 | Operator who already configured everything | To use the app normally, never seeing the wizard | No regression | Every load |
| UC6 | Operator with a YubiKey | To **start** YubiKey setup in the browser with the touch/PIN policy they chose, and — when the plugin needs a TTY — to be handed the exact command with that policy baked in | No silent failure, no lost choice | Vault step |
| UC7 | Operator who already has an age identity | To paste recipient + identity path with validation and a round-trip check | Not able to save a broken pair | Vault step |
| UC8 | Operator who mistyped an API key | To save, press Test, and see the failure inline | They fix it before a broken session | Provider step |
| UC9 | Operator on a LAN/wildcard bind | To be told why setup must be finished on the host, with the URL | Not a generic error loop | Any mutation |

## 5. Setup state model

Computed per request by `Seal.Setup.State`. Inputs: `SealPaths` (from
`adPaths`, never `VaultRuntime.vrPaths` — that is `error "test stub"` in the
fake), `RuntimeConfig` + `SecurityConfig` fresh from disk, the live
`Maybe VaultHandle`, `adProviders` (see §5.2), and `stat` on the configured vault
path (`scVaultPath` when set, else `vaultFilePath`) and identity file. No
`vhList`, no `vhGet` on the vault step.

```haskell
data StepStatus = StepReady | StepPending | StepBlocked deriving stock (Eq, Show)

data SetupStep = SetupStep
  { stId       :: Text
  , stRequired :: Bool
  , stStatus   :: StepStatus
  , stDetail   :: Maybe Text   -- path-free; may contain ~/.seal/... form
  , stActions  :: [Text]       -- "create" | "resume" | "reopen" | "recheck" | "configure"
  }

data SetupState = SetupState
  { ssRequiredComplete :: Bool
  , ssSteps            :: [SetupStep]
  , ssProviders        :: [ProviderCard]   -- id, label, configured, isDefault, defaultModel
  }
```

`ssRequiredComplete = all (\s -> not (stRequired s) || stStatus s == StepReady)`.

`detail` never contains an **absolute** path; it may contain the tilde form
`~/.seal/...`. It never contains a secret, a key, or a credential-presence
detail beyond "configured"/"not configured".

### 5.1 Vault step — ordered by terminality

| # | Condition (evaluated in this order) | Status | Detail / actions |
|---|---|---|---|
| V0 | `security.toml` exists but does not parse | `Blocked` | "security.toml could not be parsed (`<first diagnostic line, path-stripped>`). Fix or restore it, then Re-check." → `[recheck]`. Never attempts a write |
| V1 | Vault file exists **and** no recipient is recorded (orphan) | `Blocked` | "A vault file exists at `~/.seal/config/vault/vault.age` but no key is recorded. Run `seal tui`, then `/vault setup` to attach a key, then Re-check." → `[recheck]` — no destructive instruction |
| V2 | Recipient recorded, identity file missing / not a regular file / unreadable | `Blocked` | "security.toml names `<basename>`, which cannot be read. Fix `~/.seal/security.toml` or re-run `/vault setup` in `seal tui`, then Re-check." → `[recheck]` |
| V3 | Handle present, unlock mode **`startup`**, and the handle is locked | `Blocked` | "The vault is locked (mode: `startup`). Reopen it here, or run `/vault unlock` in `seal tui`." → `[reopen, recheck]` — `reopen` unlocks, so this row converges |
| V4 | Key recorded + vault file present + handle absent | `Blocked` | "The vault is configured but not open in this process." → `[reopen]` |
| V5 | Key recorded, no vault file | `Pending` | "Finish creating the vault (a key is already recorded)." → `[resume]` |
| V6 | Handle present, vault file present, identity readable, and (**mode is `on_demand`/unset**, **`per_access`** — whose cache is empty by design while reads still work — or mode is `startup` and unlocked) | `Ready` | "Key type: `x25519`." (no secret count: misleading before first access) |
| — | No key recorded, no vault file | `Pending` | "Create an encrypted vault for API keys and tokens." → `[create]` |

`vsLocked` is **never** used as a readiness signal on its own: `per_access`
never populates the cache (`currentMap` reads from disk per access), so a fully
working `per_access` vault reports `vsLocked = True` forever. Only `startup`
mode can be genuinely locked in-process, and `seal serve` does not unlock at
boot — `reopen` (which calls `vhUnlock`) is the in-product fix.

V1 precedes V2 deliberately: when both an orphan vault and a bad identity path
are present, the operator must attach a key first; the reverse order would give
advice that cannot fix the actual blocker (round-2 PM finding).

**Residual (documented, not solved here):** the unlock mode is read from
`security.toml` per request, but the handle's mode is frozen at boot by
`openVault`, and `VaultHandle` exposes no mode accessor. An out-of-band edit of
`vault_unlock` therefore applies after a restart; the wizard does not claim
otherwise.

**Reopen semantics.** `reopen` = `loadSecurityConfig` → `resolveEncryptor` →
`openVault` (with the configured unlock mode) → `vhUnlock` where the mode needs
it → `writeIORef`. It cannot import `Seal.Command.Serve` (cycle), so this is a
short composition, not a call into `tryOpenVault`. For `startup` mode this is
what makes V3 converge.

**Failed reopen is terminal.** `POST /api/setup/vault/reopen` answering 422
(vault file present but not openable with the recorded key) renders a dedicated
panel: *"The vault file cannot be opened with the recorded key — it was
probably written by a different key. If it holds no secrets yet:
`mv ~/.seal/config/vault/vault.age ~/.seal/config/vault/vault.age.bak`, then
Re-check. If it does hold secrets, restore the matching identity."* The server
deletes nothing. Tested for termination (§11.5).

### 5.2 Provider step — never decrypts for a YubiKey vault

Provider readiness comes from `config.toml` plus, for non-YubiKey vaults,
`adProviders` (`configuredProviders`), which decrypts once per call — that is
already today's behaviour for `GET /api/providers`. For a **YubiKey** vault the
step is config-only so that rendering the wizard never prompts for a touch:

| # | Condition | Status | Detail |
|---|---|---|---|
| P1 | `default_provider` set and (**yubikey vault**, or the provider is in `adProviders`) | `Ready` | `anthropic · claude-opus-4-8` |
| P2 | `default_provider` set, non-yubikey vault, credential missing | `Pending` | "Add credentials for `<provider>`." |
| P3 | Some provider configured, no default | `Pending` | "Choose which provider new sessions should use." |
| P4 | Nothing configured | `Pending` | "Add an LLM provider: anthropic, openrouter, or ollama." |

For a YubiKey vault, credential presence cannot be checked without a touch, so
the row is `Ready` once a default is set; the credential is verified by the
explicit Test button (which may prompt for a touch — its own in-flight state
says so). `ProviderCard`s are carried on `SetupState` (`ssProviders`) so the
provider step renders **without** calling `GET /api/providers/all`, which
decrypts once per provider name.

## 6. UI

### 6.1 Gate

`App` keeps all existing hooks mounted (rules of hooks) and renders either the
shell or `<SetupWizard>` from `useSetupState()`. The list/transcript streams are
therefore live when the gate lifts — no post-gate refresh, no hook changes.
Existing hooks keep their own backoff; if a gate-time retry storm ever shows up,
gating the hooks is a follow-up (noted, not hidden).

- `required_complete: true` → shell, exactly as today.
- `false` → wizard, full screen. URL ignored while gated.
- Probe fails (5xx / network / unparseable) → **fail closed**: transport error +
  Retry. A failing setup probe means the rest is equally untrustworthy.
- Probe returns **403** (non-loopback/wildcard bind) → dedicated terminal
  screen: "Setup must be completed on the host machine at
  `http://127.0.0.1:<port>`." + Retry. No generic error loop (UC9).
- After each successful action the wizard refetches → advances automatically
  when the current required step flips `Ready` → when the last one does, the
  **completion screen** renders; its "Start chatting" button calls
  `onComplete`. The gate never drops without that screen.
- **Deferred:** a reusable `/setup` page after completion. This PR only gates
  first run (`SetupGate`), so `TopSection`/`TopBar` are untouched.

### 6.2 Step registry

```ts
// frontend/src/lib/setupSteps.ts — pure, unit-tested
export type SetupStatus = 'ready' | 'pending' | 'blocked'
export interface StepProps { step: SetupStep; state: SetupState; onRefresh: () => void }
export interface SetupStepDef {
  id: string; title: string; required: boolean; blurb: string
  Component: React.ComponentType<StepProps>
}
export const SETUP_STEPS: SetupStepDef[] = [vaultStep, providerStep /* , channelsStep */]
export function parseSetupState(raw: unknown): SetupState            // fetch boundary validation
export function firstIncompleteStepIndex(s: SetupState): number | null
export function resolveRail(s: SetupState): RailItem[]              // server steps ∪ registry
```

`resolveRail` reconciles server and client: a server step without a registered
component renders a **generic card** (server title, `detail`, action bar) —
never vanishes; an unknown `status` becomes `pending` plus a visible banner
(`parseSetupState` is where that happens, so it is testable, not dead code).

### 6.3 Vault step — action bar

The step renders an **action bar from `step.actions`** (`create` / `resume` /
`reopen` / `recheck`), so V5-resume and V4-reopen are reachable without picking
a backend card. The three backend cards are offered only for `create`, and V5
shows resume as primary with the cards visually secondary (creating again is not
offered — it would 409).

Cards:

1. **Create a local age key — recommended.** One button.
2. **YubiKey.** Switches "Require touch" / "Require PIN" (both default on).
   In flight: *"Touch your YubiKey now… (waiting)"* with cancel. On `422` the
   rendered hint bakes in the chosen policy:
   `age-plugin-yubikey --generate --touch-policy always --pin-policy once > ~/.seal/keys/<name>.yubikey.txt`.
3. **Existing age identity.** `Recipient` + `Identity file path` (absolute).
   Validated and round-tripped server-side before anything is written.

Failure rendering: `400` (input rejected — attributed to the offending field:
`recipient` or `identity_path`), `409` (vault appeared — "Re-check" guidance),
`422` (plugin / TTY / round-trip, with hint; the hint branches: an unreadable
identity says *restore the identity*, not *move the vault aside*), `500` (config
write, states what was and was not written), `403` (the LAN screen),
`413`/`415` (rendered as a bug with the code). V2 offers `recheck` only —
`reopen` cannot help when the identity file is known unreadable.
`useSetup.ts` returns `{status, error, hint}` per call so the branch table is
implementable without string matching.

### 6.4 Provider step

Cards render from `SetupState.providers` (§5.2) — **no** decrypting call from
the step. Labels come from a wizard-local `lib/providerLabels.ts` with a
raw-name fallback; migrating the four existing copies is deferred.

Per card: key input (`type="password"`, memory only), base URL (ollama),
**Test connection**, **Use as default** radio. **Test is disabled while the form is dirty or has
never been saved** (a keyless ollama therefore becomes testable right after its
first save, and a write-only key field being empty after save does not disable
it), with "save, then test" copy — it always tests stored config (`UC8`: save
first). On a YubiKey vault the **save** request may block on a touch: the card
shows "Touch your YubiKey now… (waiting)", and the AbortController timeout
applies to Test only — a credential write is never aborted mid-flight. In flight it shows "Testing…" with an
`AbortController` + timeout (mirrors `createTab`).

Save: first run sends one `POST /api/providers` (it seeds `default_provider`
when unset); the follow-up `PUT /api/providers/default` is sent only when a
default already exists and the user picked a different one. Partial failure is
reported: "saved the provider, but could not set it as the default: <error>".

Initial fetch states: loading skeleton, fetch error + Retry, empty list.

### 6.5 Completion screen

Configured provider + model, vault key type, and the deferred next step naming
the concrete today-path as copyable commands (`/channel telegram`,
`/channel signal` in `seal tui`). Then "Start chatting" → shell. Focus moves
here when it appears.

## 7. Security design

### 7.1 `Seal.Gateway.OriginGuard` — one pure verdict

> **Superseded in part.** The `GuardPolicy`/`GuardHosts`/peer-address design in
> the revision-logged text below was dropped before implementation; §0.2 is
> normative. What shipped is the two-type, no-config-input verdict described
> below, in `src/Seal/Gateway/OriginGuard.hs`, called from `apiApp` ahead of
> the route table.

**Verified context.** `API.hs:2821-2826` attaches `Access-Control-Allow-Origin: *`
to every JSON response and `API.hs:691-692` answers `OPTIONS` for every path with
those headers, so a cross-origin JSON POST lands and cross-origin GET bodies are
readable. Both go away (§3, WU4).

```haskell
data GuardHeaders = GuardHeaders
  { ghOrigin       :: Maybe Text
  , ghSecFetchSite :: Maybe Text
  }
data GuardVerdict = Allowed | Rejected !Text
-- | @Nothing@ = the boot plan resolved no origin (wildcard bind + mode=none:
-- an explicit operator waiver).
sameOriginVerdict :: Maybe Text -> GuardHeaders -> GuardVerdict   -- pure
guardHeadersFrom :: Request -> GuardHeaders
```

Rules, in order (v6 — no Host field, no peer field, no config input):

1. **Canonical origin `Nothing`** → `Allowed`. This is the `mode = "none"` +
   wildcard-bind waiver, and it is what makes every existing test literal (whose
   canonical origin is `Nothing`) behave as before.
2. **`Origin: null`** → `Rejected`.
3. **`Origin` present** → accepted when either
   (a) it equals the canonical origin exactly, **or**
   (b) the canonical origin's host is loopback (`localhost`, `127.0.0.0/8`,
   `[::1]`) and the origin's host is a loopback alias with scheme `http`/`https`
   (any port). (b) exists because the boot plan canonicalises a loopback bind to
   `http://localhost:<port>` while the SPA is reached at
   `http://127.0.0.1:<port>` (e2e) or `http://localhost:5173` (vite dev). Only
   code already running on the host can serve from a loopback name — the class
   §7.3 documents as out of scope.
4. **`Origin` absent** → allowed only when `Sec-Fetch-Site` is absent,
   `same-origin`, or `none`; `cross-site`/`same-site` → `Rejected`.
5. **Body cap** on setup mutations (8 KiB) via `collectBodyLimited` (PR A's
   bounded reader), counting bytes as it reads.

**Scope.** Applied in `apiApp` to every `POST`/`PUT`/`DELETE` and to
`GET /api/setup`. It closes the provider-exfiltration primitive
(`POST /api/providers {base_url: <attacker>}` + `PUT /api/providers/default`).

**Why no Host or peer check.** The base branch wires `setHost` and defaults
`host` to `localhost`, so the socket now honours the configured host, and the
passkey middleware already decides network identity. A Host/peer check would add
plumbing (`remoteHost`, `Host` headers in every test builder) for a threat the
session layer covers.

**Tests** — `OriginGuardSpec` (pure table, plan WU3 tests 1–9b) and
`MutationGuardSpec` (API level, plan WU4 tests 11–18) plus the setup-route case
in plan WU5 test 22.

**Test-harness impact:** none beyond one new field. `adCanonicalOrigin =
Nothing` in every `ApiDeps` literal (~34 construction sites; one line each), so
existing requests stay allowed and **no** request builder changes.

### 7.2 Secret handling

- Local/YubiKey keys: generated server-side, `0600` under `~/.seal/keys/`, never
  returned. Responses carry `recipient` + `key_type` only.
- User-supplied identity: a *path*, never read into a request/response.
- Provider API keys: existing write-only pattern, unchanged.
- **Path rule, split by response class.** `GET /api/setup` (web-readable) is
  path-free: tilde form only (`~/.seal/...`). Mutation error bodies (guard-
  protected, one-shot) **may** name the configured keys directory as an absolute
  path when it is the only way to give a correct recovery command under a
  non-default `SEAL_HOME`; they never contain a secret, the identity file's
  contents, or an `age1` value other than the returned recipient. No raw
  `age`/plugin stderr in any response: the server logs the detail and returns a
  fixed reason + actionable hint.
- No bodies in logs (`requestTimingMiddleware` logs method/path/status/duration
  only). Response-shape assertions replace v2's vacuous log test.

### 7.3 `~/.seal/` boundary and the local-process threat

The endpoint is a human-driven admin command over the local control plane — the
same class as `/vault setup` and `/api/secrets`; it adds no opcode, no
`UntrustedIO`, no ISA path.

**Same-UID local processes are admitted** (they send no Origin). This is not a
widening: such a process can already write `~/.seal/security.toml` directly or
run `/vault setup` in `seal tui` (verified by the security reviewer in-session:
`SHELL_EXEC` confines `cwd` only; `~/.seal` blocking applies to `FILE_*`
opcodes). A per-run admin token was proposed and is **rejected** as theatre for
that class — it would be readable by the same process from the served HTML or
the banner. **Cross-UID local processes are also out of scope** (a second local account can
POST on a first-run host) — and, because the listener is wildcard by default,
so are **LAN peers**, which is precisely why the guard checks the actual peer
address (§7.1 rule 1) rather than trusting `gcHost`. Closing the remaining
classes needs real authentication (§14). All limitations are stated in the
module header, not just here.

### 7.4 Provisioning order, locking, rollback

Order (every partial state is benign **and** resumable):

1. **Pre-check** (no lock): security config parses; no recipient recorded; no
   vault file at the configured path; for `resume`, a recipient **is** recorded.
   Violations → `409` (or `resume`-specific errors) before any write.
2. Acquire the **setup lock file** `~/.seal/security.toml.lock` with
   `O_CREAT|O_EXCL` (0600). If present and older than 30 s → treat as stale,
   remove, retry once; if still present → `409 "another setup is in progress"`.
   Released in a bracket.
3. Obtain the key (local `age-keygen` / YubiKey plugin / validated user pair).
4. Build the encryptor and **round-trip verify** (encrypt+decrypt a nonce),
   under `System.Timeout` (a YubiKey identity can block on a PIN prompt;
   `readProcessNoInput` has no timeout).
5. **CAS the config write** via the second narrow writer
   `updateVaultKeySection :: FilePath -> (SecurityConfig -> Either e VaultKeyFields) -> IO (Either Text (Either e VaultKeyFields))`
   (inside `securityWriteLock`): the callback returns
   `Left ProvisionAlreadyExists` when a recipient is already recorded, which the
   handler maps to `409`; only a load/parse failure becomes
   `ProvisionConfigWriteFailed`/`500`. `resume` skips this step.

   *Implementation note (supersedes this section's `updateSecurityConfigEither`):*
   the base branch guarantees that `updateAccessControlSection` is a narrow
   writer whose callback cannot name vault fields. A general
   `updateSecurityConfigEither` would have removed that guarantee, so the
   implementation kept it and added a **second** narrow writer instead. Neither
   callback can express the other's fields, and both verify the re-encoded
   document before committing.
6. `vhInit` the vault at the configured path (`VaultAlreadyExists` → `409`
   unless `resume`).
7. **Decrypt-verify**: `vhList` the freshly created vault; if it fails, the file
   was not written with our key → `500`, config left in place, message states
   that the vault file could not be opened (do not delete anything).
8. `openVault` at the final path + put the handle in `vrHandleRef`; release lock.

Crash matrix: crash before 5 → nothing recorded (stray key file only, inert);
crash between 5 and 6 → **V5 resume** (one click); crash after 6 → complete
(either the handle is in the ref or V4 reopen finds it). There is no ordering
that produces "vault file whose key nobody knows" — V1's state now requires a
foreign writer, and step 7 refuses to declare success in that case.

Cross-process: the lock file excludes concurrent *gateway* processes. A
concurrent TUI `/vault setup` takes only the process-local `securityWriteLock`;
residual race, mitigated by the CAS (no silent overwrite) and step 7 (no false
success). Documented, not claimed away.

`resume` carve-out: `resume` is the only backend that runs with a recorded key,
performs no config write, and is not subject to the step-5 CAS or the `409`
row — otherwise the one browser-completable recovery from a crash would be
unreachable (round-2 PM blocker).

### 7.5 Invariant 2 at the argv seam

- `mkVaultIdentityPath :: FilePath -> IO (Either Text VaultIdentityPath)`,
  constructor unexported, **home: new `src/Seal/Vault/IdentityPath.hs`** (imports
  neither `Provision` nor `Backend`, so both may use it): absolute, exists,
  regular, readable, no `-` prefix, no control chars. The CLI's
  `setupUserSupplied` is left unchanged this PR (follow-up).
- `mkAgeRecipient :: Text -> Either Text AgeRecipient` (**home:
  `Seal.Security.Vault.Age`**, next to the type, so `mkAgeEncryptor` can use it
  without a cycle): `age1…` charset
  `[a-z0-9]`, no whitespace/control chars, non-empty, length-bounded. It cannot
  validate the bech32 checksum — the round-trip in §7.4 step 4 is the real
  check, stated where it matters.
- `mkAgeEncryptor` validates both (single choke point, so a hand-edited
  `security.toml` is checked) and runs `--decrypt --identity=<path>`
  **and** `--encrypt --recipient=<value>` as single tokens.
- `AgeIdentity`/`AgeRecipient` keep exported constructors (they are built from
  config in `resolveEncryptor`); `mkAgeEncryptor`'s validation is the control.
- Opacity compile-fail test for `VaultIdentityPath`, following
  `Seal.Config.SecurityScopingFailSpec`.

### 7.6 `security.toml` invariant amendments

`Seal/Config/Security.hs` says the file is "not exposed via any opcode or the
HTTP Gateway" and that `updateSecurityConfig` is "NEVER called by … the HTTP
Gateway". In this PR: both docstrings are rewritten to describe the
loopback-only, origin-guarded setup API and the restricted field set
(`vault_recipient`, `vault_identity`, `vault_key_type` only);
a second narrow writer (`updateVaultKeySection`) is added and documented next
to `updateAccessControlSection` — **not** a general
`updateSecurityConfigEither` (see §7.4 step 5); `untrusted_execution` /
remote-mode decisions keep using the boot-time `adSecurityConfig` snapshot and
the per-turn re-read in `TurnEngine`; `AGENTS.md`'s trusted-binary exception list
gains `age-keygen` and `age-plugin-yubikey`; and
`docs/superpowers/specs/2026-08-18-layered-harness-architecture.md` (§4.4/§8
assert the CORS invariants being removed) is amended in WU7.

## 8. Provisioning core (`Seal.Vault.Provision`)

```haskell
data VaultSpec
  = VaultSpecLocal
  | VaultSpecYubiKey { vsTouch :: Bool, vsPin :: Bool }
  | VaultSpecUser    { vsRecipient :: AgeRecipient, vsIdentity :: VaultIdentityPath }
  | VaultSpecResume
  deriving stock (Eq, Show)

data ProvisionError
  = ProvisionAlreadyExists
  | ProvisionInProgress
  | ProvisionKeygenMissing Text      -- "age-keygen" | "age-plugin-yubikey"
  | ProvisionNeedsTty Text           -- hint (tilde paths only)
  | ProvisionInvalidInput Text
  | ProvisionRoundTripFailed Text    -- logged detail; rendered reason is fixed
  | ProvisionKeygenFailed Text
  | ProvisionVaultInitFailed
  | ProvisionVaultUnreadable         -- step 7
  | ProvisionConfigWriteFailed Text
  deriving stock (Eq, Show)

data ProvisionDeps = ProvisionDeps
  { pdKeygen     :: SetupKeygen
  , pdEncryptor  :: SetupEncryptor
  , pdWriteConfig :: (SecurityConfig -> Either ProvisionError SecurityConfig)
                  -> IO (Either Text (Either ProvisionError ()))   -- §7.4 step 5
  , pdLockPath   :: FilePath
  }

data SetupKeygen = SetupKeygen
  { skLocal :: IO (Either ProvisionError ResolvedKey)
  , skYubi  :: Text -> Bool -> Bool -> IO (Either ProvisionError ResolvedKey)
    -- ^ name, touch, pin. The name is always the server-side literal
    -- @"default"@ (never request-derived) and is validated before it is
    -- interpolated into a command or a filename.
  , skUser  :: AgeRecipient -> VaultIdentityPath -> Either Text ResolvedKey
  }

data SetupEncryptor = SetupEncryptor
  { seMk     :: AgeRecipient -> AgeIdentity -> IO (Either VaultError VaultEncryptor)
  , seVerify :: VaultEncryptor -> IO (Either Text ())     -- round-trip nonce
  }

data ProvisionOutcome = ProvisionOutcome { poRecipient :: Text, poKeyType :: Text }

provisionVault
  :: SealPaths -> IORef (Maybe VaultHandle) -> ProvisionDeps -> VaultSpec
  -> IO (Either ProvisionError ProvisionOutcome)

renderProvisionError :: ProvisionError -> (Text, Maybe Text)   -- (error, hint), path-free (§7.2)
```

`defaultProvisionDeps :: SealPaths -> ProvisionDeps` wires the real seams;
`renderProvisionError` lives **here** (asserted by both §11.1 and §11.4).

Pure/property-tested: `VaultSpec` JSON parsing, `mkAgeRecipient`,
`mkVaultIdentityPath`, `renderProvisionError` shape (no absolute path, no
keys-dir absolute segment, no `age1` substring — tilde allowed).

## 9. API

`Seal.Gateway.Setup` owns handlers, `SetupDeps`, and the guard adapter; it never
imports `Seal.Gateway.API` (no cycle). `API.hs` gains four dispatch arms, the
guard call, and the `SetupEnv` construction.

```haskell
data SetupDeps = SetupDeps
  { sdProvision :: ProvisionDeps
  , sdResolveProvider :: KnownProvider -> ModelId -> IO (Either Text SomeProvider)
  }
stubSetupDeps :: SetupDeps      -- for the ~20 ApiDeps literals in tests
```

Handlers take a `SetupEnv` built at the dispatch site from `adPaths`,
the `IORef (Maybe VaultHandle)` inside `adVault` (not `VaultRuntime` — its
`vrPaths` is a bomb in tests), `srConfigPath`, `securityFilePath`, `adProviders`,
and `SetupDeps`.

`sdResolveProvider` **re-reads `config.toml` from `srConfigPath` on every call**
(the `loadCfg` pattern) and reads `vrHandleRef` fresh, so a provider saved during
setup — including a new ollama base URL — is what Test-connection pings. Closing
over the boot-time config would silently test the pre-wizard value.

`Seal.Gateway.Setup` defines its own `setupJson`/`setupErr`/`collectBodyLimited`
helpers (API.hs's are unexported locals; widening its surface is not worth it).

Routes (four; `expectedRouteCount` 62 → **66**):
`GET /api/setup`, `POST /api/setup/vault`, `POST /api/setup/vault/reopen`,
`POST /api/providers/:name/test`.

### 9.1 `GET /api/setup`

`200`, `Cache-Control: no-store`:

```json
{"required_complete": false,
 "steps": [{"id":"vault","required":true,"status":"pending",
            "detail":"Create an encrypted vault for API keys and tokens.",
            "actions":["create"]},
           {"id":"provider","required":true,"status":"pending",
            "detail":"Add an LLM provider: anthropic, openrouter, or ollama.",
            "actions":["configure"]}],
 "providers": [{"id":"anthropic","label":"Anthropic","configured":false,
                "isDefault":false,"default_model":null}]}
```

Never `500` on missing/unparseable config: missing degrades to "nothing
configured"; unparseable is V0.

### 9.2 `POST /api/setup/vault`

`201 Created` on success (matches `POST /api/providers`, `POST /api/secrets`).

```json
{"backend":"local"}
{"backend":"yubikey","touch":true,"pin":true}
{"backend":"user","recipient":"age1…","identity_path":"/Users/me/.config/age/keys.txt"}
{"backend":"resume"}
```

| Code | When |
|---|---|
| `201` | `{"recipient":"age1…","key_type":"x25519"}` (also for `resume`) |
| `400` | unknown backend; missing field; `mkAgeRecipient`/`mkVaultIdentityPath` rejection |
| `403` | guard rejection (§7.1) |
| `409` | recipient already recorded (non-`resume`); vault file already exists; another setup in progress |
| `413` / `415` | body > 8 KiB / content type not `application/json` |
| `422` | keygen/plugin missing, plugin needs a TTY, round-trip failed — `{"error":…,"hint":"<command, tilde paths>"}` |
| `500` | `vhInit` failed, vault unreadable after init, config write failed (states exactly what was and was not written) |

Envelope everywhere: `{"error": Text, "hint": Text?}`.

### 9.3 `POST /api/setup/vault/reopen`

Re-runs the open against the live ref, under the setup lock (single-flight; no
touch-prompt spray), and **unlocks** where the configured mode requires it:
`loadSecurityConfig → resolveEncryptor → openVault → vhUnlock (startup) →
writeIORef`. `200 {"opened":true,"key_type":…,"locked":false}`; `409` no key
recorded, or no vault file (a missing file is `resume`, not `reopen`); `422` key
cannot load **or** the file cannot be decrypted (`hint` = the terminal recovery
of §5.1, branched: unreadable identity ⇒ restore it; undecryptable file ⇒ the
`mv`-aside option); `500` I/O. Never creates or rotates.

### 9.4 `POST /api/providers/:name/test`

Pings **stored** config through `sdResolveProvider`. `200 {"ok":true,"detail":…}`
/ `200 {"ok":false,"error":…}` (a failed provider is not an HTTP error;
documented in the OpenAPI description). `400` unknown provider; `500` vault not
configured/locked. No string matching on `Left Text` beyond mapping the
vault-unavailable case, which is decided by reading the handle first.

## 10. Frontend files

New (v6 — no shared-refactor extraction): `lib/setupSteps.ts`,
`lib/providerLabels.ts` (wizard-local, raw-name fallback),
`hooks/useSetup.ts`, `components/setup/SetupGate.tsx`, `SetupWizard.tsx`,
`VaultStep.tsx`, `ProviderStep.tsx`, `SetupComplete.tsx`. `FormRow` extraction
and the four-component label migration are **deferred** (follow-up).

Modified: `main.tsx` (`<AccessGate><SetupGate><App/></SetupGate></AccessGate>`),
`types.ts`. **`App.tsx` and `App.test.tsx` are untouched**: the gate wraps
`App`, so no component inside it fetches `/api/setup`.

Tests: `src/lib/__tests__/setupSteps.test.ts`, plus
`src/components/__tests__/{SetupWizard,VaultStep,ProviderStep,App.gate}.test.tsx`
(flat convention; lib tests stay in `lib/__tests__`).

A11y: rail buttons with `aria-current`; results in `aria-live="polite"`; errors
`role="alert"`; focus moves to the step heading on advance and to the completion
heading when the last step flips.

## 11. Testing plan (TDD)

### 11.1 `test/Seal/Vault/ProvisionSpec.hs` (+ Backend/Age specs)

1. `mkVaultIdentityPath` rejects relative, missing, directory, leading `-`,
   empty, control chars. (unit)
2. `mkAgeRecipient` rejects empty/uppercase/whitespace/leading `-`/invalid
   charset/over-length. (unit)
3. Property: `mkVaultIdentityPath` is total (never throws) and `Right` implies
   `doesFileExist` + regular file.
4. Happy path (fake keygen/encryptor, real temp dirs): exactly the three vault
   fields written, vault file created, handle in the ref, outcome = recipient +
   key type.
5. `ProvisionAlreadyExists` with a recorded recipient — keygen fails the test if
   called.
6. Pre-existing **vault file** with no recorded key → `ProvisionAlreadyExists`,
   file bytes unchanged, keygen not called (pre-check, §7.4 step 1).
7. `VaultSpecResume` (key recorded, no file) → creates it, returns the recorded
   recipient, **no** config write, no keygen.
8. Config-writer returns an outer `Left` (load/parse) →
   `ProvisionConfigWriteFailed`; vault file not created.
8b. Config-writer callback returns `Left ProvisionAlreadyExists` →
   `Left ProvisionAlreadyExists` (409, **not** 500), and neither keygen nor
   vault init is called again.
9. `seVerify` fails → `ProvisionRoundTripFailed`, nothing written.
10. Lock: second `provisionVault` while the lock file exists → `ProvisionInProgress`;
    stale lock (mtime 60 s) → proceeds.
11. Post-init `vhList` failure (foreign key) → `ProvisionVaultUnreadable`,
    config left in place, no success.
12. Concurrency: two calls under `concurrently` → exactly one `Right`.
13. `renderProvisionError` per constructor: no absolute path, no `age1`;
    `ProvisionNeedsTty` hint contains the tilde keys path and the chosen
    policies.
14. `VaultSpec` JSON parsing: shapes, unknown backend, defaults for
    `touch`/`pin`.
15. `mkAgeEncryptor` rejects a malformed recipient/identity (new validation).
    `BackendSpec`'s `setupUserSupplied` cases need **no** change: they already
    accept either branch (verified), and the CLI path is untouched this PR.

### 11.2 `test/Seal/Setup/StateSpec.hs`

1. **Nothing configured → both pending** (S2 guard, first).
2. Live handle + working config → vault ready; no provider → provider pending.
3. Unparseable `security.toml` → V0 blocked, no exception, no write attempt.
4. Orphan vault file (no key) → V1 blocked even when the identity is also
   unreadable (ordering).
5. Identity missing with a live handle → V2 blocked (the "handle masks a broken
   identity" regression).
6. Key recorded + no vault file → V5 pending with `resume`.
7. Key + file + no handle → V4 blocked with `reopen`.
8. Locked + `unlock = "startup"` → V3 blocked; `on_demand` → V6 ready;
   **`per_access`** (cache empty by design, reads work) → V6 ready.
9. `reopen` on a `startup`-mode vault returns 200 with `locked: false` and the
   state then reports V6 ready (V3 converges).
10. Provider: default + credential → ready; keyless ollama → ready; default with
    no credential → pending; **yubikey vault → ready without calling
    `adProviders`** (asserted with a provider action that fails the test if
    forced).
11. Property: `required_complete` == all-required-ready.
12. Absent `config.toml` / absent `security.toml` → degraded rows, no crash.

### 11.2b `test/Seal/Config/SecuritySpec.hs`

`updateSecurityConfigEither`: the callback's `Left e` is propagated unchanged
(outer `Right (Left e)`); an outer `Left` occurs only for an unreadable or
unparseable file; a rejecting callback leaves the file bytes unchanged and no
`.tmp` behind.

### 11.3 `test/Seal/Gateway/OriginGuardSpec.hs`

Pure table over §7.1, exactly as enumerated in plan WU3 tests 1–9b:
`Nothing` ⇒ allowed; exact match; different scheme/host on a non-loopback
canonical; loopback alias with a different port accepted; non-loopback canonical
with a different port rejected; `Origin: null`; `cross-site`/`same-site` without
Origin; `same-origin`/`none`/absent without Origin; loopback alias set pinned
(`127.1.2.3` yes, `10.0.0.1` no, `localhost.evil.com` no); case/trailing-slash
behaviour pinned. Property: `Allowed` ⇒ canonical is `Nothing`, **or** `Origin`
was absent with acceptable fetch metadata, **or** `Origin` was present and
loopback-aliased against a loopback canonical.

### 11.4 `test/Seal/Gateway/SetupApiSpec.hs`

1a. (WU4) Evil Origin → 403 on an **existing** mutating route (`POST
    /api/providers`) — the guard works before any setup route exists.
1b. (WU5) `GET /api/setup`: shape incl. `providers`, `no-store`, reflects a live
    fake vault, no absolute path in any `detail`; 403 for an evil Origin with a
    readable body.
2. `POST /api/setup/vault`: evil Origin → 403 **and no vault file, no
   `security.toml` change**.
3. 403: `Origin: null`; a foreign `Origin`; `Sec-Fetch-Site: cross-site` with no
   Origin. (No Host/peer cases: v6 has neither field.)
4. 415 `text/plain`; 413 9 KiB; 400 unknown backend; 400 relative
   `identity_path`.
5. 201 for loopback Origin and for **loopback Host with no Origin/Sec-Fetch-Site**
   (the curl path).
6. 201 for `backend: "resume"` when a key is recorded and no vault file exists;
   409 for `backend: "local"` in the same state (resume carve-out).
7. `Origin` absent with `Sec-Fetch-Site: same-origin` → admitted on a mutating
   route (the curl/channel path).
8. Guard covers siblings: 403 for evil Origin on `POST /api/providers`,
   `PUT /api/providers/default`, `POST /api/secrets`,
   `POST /api/sessions/:id/send`; 200 with a loopback Origin.
9. No `Access-Control-Allow-Origin` on any response (CORS removal).
10. `POST /api/providers/:name/test` with the stubbed `sdResolveProvider` →
   `{"ok":true}`; unknown provider → 400; vault absent → 500.
10. `reopen`: no key → 409; no vault file → 409 (`resume` is the answer);
    unreadable file → 422 with a terminal `hint`; working config → 200, the ref
    is `Just`, and `vsLocked == False` for a `startup`-mode vault.
11. Local backend end-to-end, guarded by `findExecutable "age-keygen"` else
    `pendingWith` (a skip is acceptable; the DoD reads "§11.4 green or
    explicitly pending"): response keys exactly `recipient`/`key_type`; body contains
    no identity path and no absolute path; a following `GET /api/setup` reports
    vault ready.
12. YubiKey `NeedsTty` path (fake keygen) → 422 whose `hint` contains the tilde
    keys path and the chosen touch/PIN policy, and no absolute path.

### 11.5 Frontend

- `setupSteps.test.ts`: `parseSetupState` (unknown status → pending + banner;
  garbage → error), `firstIncompleteStepIndex` (none/one/both → `null`),
  `resolveRail` (generic card for an unregistered server step), registry order.
- `SetupWizard.test.tsx`: rail; auto-advance on ready; **action bar renders and
  dispatches `resume`/`reopen`/`recheck`**; blocked step renders `detail` +
  actions; failed-reopen panel terminates with the recovery instructions;
  completion screen gated behind "Start chatting"; no skip control
  (`queryByRole` absence); unknown-step banner; 403 screen; focus moves.
- `VaultStep.test.tsx`: backend cards for `create` only; YubiKey waiting state +
  policy in the hint; `user` submit body; 409/422 copy; key inputs not
  pre-filled.
- `ProviderStep.test.tsx`: Test disabled while dirty, enabled after save; inline
  failure; first-run save sends one POST and no default PUT; partial default
  failure copy; loading/error/empty states.
- `App.gate.test.tsx`: `required_complete:false` → wizard only;
  `true` → shell only; probe 5xx → fail-closed wizard + Retry; probe 403 → LAN
  screen; with the gate up, a failing `/api/sessions` must not paint an error
  banner over the wizard.
- `SetupGate.test.tsx` (not `App.test.tsx` — the gate is outside `App`, so
  `App.test.tsx` needs no `/api/setup` mock at all and stays untouched).
- `setupSteps.test.ts` also asserts unknown action verbs (`configure`) render no
  bar button and that `parseSetupState` validates `providers`.

### 11.6 Gate

`make check` (build + test + hlint), `cd frontend && npm test`, coverage gate
(`.coverage-thresholds.json`, `blockPRCreation: true`), and locally
`npx playwright test` (two ordered specs, `workers: 1`; CI does not run
frontend/e2e — stated in the PR body with the reproduction command).

## 12. Work units

| WU | Scope | Key files | DoD |
|---|---|---|---|
| **WU1** *(PR B)* | Provision core + `adSetup` plumbing: `IdentityPath`, `Provision`, `mkAgeRecipient`/`mkAgeEncryptor` validation + single-token argv, `updateSecurityConfigEither`, `setupUserSuppliedFrom`, `setupYubiKey` non-interactive core; `ApiDeps` gains `adSetup` (real deps wired in `Serve.hs`) | `Vault/IdentityPath.hs` (new), `Vault/Provision.hs` (new), `Config/Security.hs`, `Security/Vault/Age.hs`, `Vault/Backend.hs`, `Gateway/Setup.hs` (types/helpers), `Gateway/API.hs`, `Command/Serve.hs`, `TestHelpers/ApiTestHarness.hs` + ~34 `ApiDeps` literals, `test/Seal/Vault/ProvisionSpec.hs`, `test/Seal/Security/Vault/AgeSpec.hs`, `test/Seal/Config/SecuritySpec.hs`, opacity fail-spec (new), cabal, `test/Main.hs` | §11.1 green; full suite green; `make check` |
| **WU2** | `Seal.Setup.State` | `Setup/State.hs` (new), `test/Seal/Setup/StateSpec.hs`, cabal, `test/Main.hs` | §11.2 green |
| **WU3** | `Seal.Gateway.OriginGuard` verdict (pure) + `GuardHeaders` incl. peer | `Gateway/OriginGuard.hs`, `test/Seal/Gateway/OriginGuardSpec.hs`, cabal, `test/Main.hs` | §11.3 green |
| **WU4** *(PR A)* | `adCanonicalOrigin` + guard call + CORS removal + bounded reader | `Gateway/API.hs`, `Command/Serve.hs` (`naOrigin access`), `TestHelpers/ApiTestHarness.hs` + ~34 literals (`= Nothing`), `Gateway/Setup.hs` (helpers), `MutationGuardSpec.hs` (new), cabal, `test/Main.hs`, `CHANGELOG.md` | guard + CORS + reader cases green on **existing** routes; no request-builder edits |
| **WU5** | Setup handlers + 4 routes + OpenAPI + reopen + provider test | `Gateway/Setup.hs`, `Gateway/API.hs` (dispatch), `src-gateway-types/.../Route.hs`, `Gateway/OpenApi.hs`, `ApiRouteSpec.hs` (62→66), `SetupApiSpec.hs` (rest) | §11.4 cases 1b, 2, 4–6, 9–12 green (11 may be pending without `age-keygen`); `ApiRouteSpec`/`OpenApiSpec` green |
| **WU6** | Frontend: registry, hooks, wizard, `SetupGate` in `main.tsx`, wizard-local label map | §10 files + tests + `frontend/e2e/{01-setup.spec.ts,global-setup.ts}` and `capstone → 02-capstone` rename | §11.5 green; e2e local green |
| **WU7** | Docs: README, `CHANGELOG.md` (**four** behaviour changes: CORS, mutation origin, `startup` reopen, argv form), `Config/Security.hs` docstrings, `AGENTS.md` exception-list extension, layered-harness arch doc, **this design doc's stale sections** (§3, §10, §11.5, §12, §13, §14.7) | those files | docs match behaviour; no stale invariant text |

Merge hotspots (`seal-harness.cabal`, `test/Main.hs`, `Route.hs`, `API.hs`):
additive edits, rebased last.

## 13. Risks

| Risk | Mitigation |
|---|---|
| `age-keygen` absent from the server's PATH | `422` + install hint + `/vault setup` fallback; same dependency the CLI has; e2e notes it |
| YubiKey plugin needs a TTY | `422` + exact command with the chosen policy; waiting state; never claims success |
| Blocking gate + broken vault | Ordered blocked matrix with per-row actions, `reopen`, `resume`, failed-reopen panel; S4 tests |
| Guard breaks a legitimate client | Loopback-alias rule (vite dev, e2e `127.0.0.1`), no-Origin rule (channels/curl); 200 cases tested per client shape |
| Wildcard bind → read-only | Explicit 403 screen + `CHANGELOG` entry (§3) |
| Listener is wildcard regardless of `gcHost` (pre-existing) | Guard checks the **peer address**, not `gcHost`; bind fix filed as a follow-up (§14); stated in §3/§7.3 |
| Removing CORS breaks something | Verified no in-repo consumer; `CHANGELOG` behaviour-change entry; follow-up issue for per-origin grants |
| `ApiDeps` churn breaks parallel work | PR A adds `adCanonicalOrigin` (~34 construction sites) and PR B adds `adSetup` to the same ones; both are one-line edits with `Nothing`/`stubSetupDeps`, and PR A lands first |
| Gate appears on a configured host (S2) | Derived state, first `StateSpec` case, default App test mock |
| Provider readiness decrypts on a YubiKey vault | Config-only signal for `yubikey` (§5.2), asserted by a failing-if-called provider action |

## 14. Deferred (tracked in the PR body)

1. Chat channels step + channel supervisor (live start without restart).
2. Per-origin CORS grants (if a legitimate cross-origin client appears).
3. Global body cap on the remaining `collectBody` call sites.
4. Anthropic OAuth login in the browser.
5. Vault key rotation from the browser.
6. Authentication for loopback (cross-UID and LAN peers, §7.3) — the base
   branch's passkey layer already covers network peers; this is the residual
   local class.
7. (Closed by the base branch: `setHost` is wired and `host` defaults to
   `localhost`.)
8. Gating the list/WS hooks while the wizard is up (only if a retry storm
   appears).

## 15. Process

- GitHub issue filed before implementation; branch
  `feat/web-setup-wizard-<NN>`; PR body `Closes #NN`.
- Implementation plan:
  `docs/plans/2026-11-07-web-first-run-setup-wizard-plan.md` (rev 3 — two PRs:
  a gateway mutation-guard prerequisite, then the wizard), reviewed by the Plan
  Review Gate before execution.
- Coverage gate before PR creation.
