# CRON_MANAGE Web UI — Implementation Plan (rev 6)

**Date**: 2026-10-23
**Design**: `docs/plans/2026-10-22-cron-web-ui-design.md` (rev 2)
**Branch**: `cron-design` (base `main` @ `3ca34c4`)
**Method**: TDD per work unit — failing test first, minimal implementation,
commit. Each work unit is one commit.

> **Rev 4 changelog.** The plan-review gate returned PASS (feasibility),
> FAIL (completeness), FAIL (scope & alignment) × 3 rounds. Rev 4 fixes
> every blocker from all three FAIL rounds:
>
> - **WU-4 was unsound and would have broken the web app.** It rejected any
>   write whose `Origin` was not in a hand-derived list — which cannot
>   match a TLS-proxy public origin or a default-port origin — and its
>   proposed "same-origin ⇒ allow" rule did **not** stop DNS rebinding
>   (a rebound request carries `Origin: http://evil.com` *and*
>   `Host: evil.com`, so they match). WU-4 is rewritten with a rule that
>   is correct in every deployment shape, and every shape is asserted.
> - **The trusted-host set now includes the loopback *names***
>   (`localhost`, `ip6-localhost`) — the gateway binds `127.0.0.1` by
>   default, but an operator may browse `http://localhost:8080`, and
>   without the name every write from that browser would 403.
> - **IPv6 literals are compared unbracketed** (`[::1]` → `::1`).
> - **One config knob, not two.** `allowed_origins` already exists and
>   already means "origins beyond the bound host" for the WS guard; it is
>   reused, and only its documentation changes.
> - **The 403 body names the knob**, so a deployment that failed closed
>   says why.
> - **`ApiDeps` literal count corrected** 28 → **29** (measured).
> - **WU-1's agent-surface blast radius** and **the list/detail split** are
>   now explicit sign-off items, not buried notes.
>
> - **Round 5/6 fixes**: the `ApiDeps` field set is now consistently
>   **two** fields (`adCronStore`, `adAllowedOrigins`) — the redundant
>   `adPublicOrigins` third field is gone, since `allowed_origins` already
>   carries both the derived and the configured origins; the id-shape
>   assertions are now written against the **measured** path-semantics
>   table (400 for ids that reach the handler, 404 for paths WAI
>   normalises away) so the RED test can go green; the test-store stub
>   now *raises* in every field, matching the rule; the 403 in-band hint
>   and the loopback-name case are now explicit WU-4 DoD checkboxes; and
>   `Serve.hs` is listed in WU-4's files because the wildcard-bind startup
>   warning lives at the boot site.
>
> The design doc is at rev 2 with the corrected WU-4 rule folded in.

## Decisions needing your sign-off (raised by the scope reviewer)

**1. WU-4 changes the behaviour of every existing `/api/*` write endpoint,
not just cron.** This is beyond the literal "add a Cron tab" request. The
rationale for doing it anyway: cron-create is *less* dangerous than
siblings that already exist — `POST /api/sessions/:id/send` runs a full
agent turn with the whole tool set, `POST /api/providers` writes API keys
into the vault, `POST /api/secrets` writes the vault. A cron-only Origin
check would leave the class open while creating the impression it was
addressed. The alternatives are (a) gateway-wide, as planned, or (b) a
separate plan/PR. **This is your call — say the word and I will split WU-4
into its own plan.**

> **Correction from round 2.** The previous revision of WU-4 was *unsound*
> and would have broken the web app in common deployments. It rejected any
> write whose `Origin` was not in a hand-derived list, and that list could
> not match a TLS-terminating proxy's public origin or a default-port
> origin (no port in the `Origin` header). It also proposed a "same-origin
> ⇒ allow" rule, which **does not stop DNS rebinding**: a rebound request
> carries `Origin: http://evil.com` *and* `Host: evil.com`, so they match.
> WU-4 has been rewritten with a rule that is correct in all three
> deployments. See WU-4's steps.

**2. Run history (`GET /api/cron/:id/runs` + the run-history panel) is
adjacent to, not inside, "basic CRUD … view, edit, and manage".** It is
read-only and cheap, and the design's success metric S3 needs it to diagnose
a failing job. **Confirm you want it**; dropping it makes the route count 65
and removes the run-history panel from WU-6.

Both are noted, not silently assumed.

**If you decline either**, the knock-on changes are:

- **Declining the run-history endpoint**: drop `GET /api/cron/:id/runs`
  (WU-3), the route count becomes **65**, WU-6 drops the run-history
  panel, and WU-5's types lose the `CronRun` type. The design's success
  metric S3 then reads "the list shows the consecutive-failure count"
  rather than "the operator sees the run history".
- **Declining the gateway-wide Origin check**: drop WU-4 entirely. The cron
  endpoints then carry no Origin protection, which is the residual risk
  stated in design §5.2/T1 — the drive-by-webpage vector stays open for
  cron (and, as it already is today, for every other `/api/*` write
  endpoint). I would record that as an accepted, documented risk rather
  than quietly shipping it.

Both declines are one-line changes to the plan; say which and I will
adjust before writing any code.

**3. WU-1 changes agent-visible behaviour, not just the web UI.**
*(This one is not really a choice — declining it re-introduces the
scheduler-thread crash and removes the shared module WU-3 depends on, so
the plan cannot proceed without it. It is listed for visibility, not for
a decision.)*
`computeNextFire` becomes total (an unknown timezone yields no next-fire
instead of an exception) and the **agent-facing** `CRON_MANAGE` opcode is
refactored to delegate to a new shared module. It is included because a
user-supplied timezone would otherwise kill the scheduler thread (design
§5.2/T4) and because the shared module is what stops the agent path and
the web path from drifting. The unmodified pre-existing `CronSpec` is the
regression guard. Flagged so it is understood as riding along with a UI
feature, not as part of one.

**4. The list/detail split is an API-shape decision you did not ask for.**
The list response deliberately omits `next_fire` (the detail response
includes it), because computing next-fire for every job costs a timezone
load each (24 ms) and the list polls every 3 s. The operator sees the
schedule expression in the list and the next-fire time for the selected
job. It is documented in design §3/D5 and internally consistent, but it
is a decision, so it is flagged.

**5. WU-4 reuses the existing `allowed_origins` knob** (no new setting)
but gives it a **second, REST-specific meaning**: it now also declares the
public origin a TLS-terminating proxy serves, and the LAN host a
wildcard-bind deployment is reached at. With no proxy and the default
loopback bind, nothing needs to be configured. The knob's *documentation*
changes (it is currently described as "the WS Origin allowlist") — that
doc change is the only config-surface delta.

**If you decline WU-4**, the `adAllowedOrigins` field is also removed
from WU-2 — otherwise the plan would still pay the 29-site `ApiDeps`
churn for a field nothing reads. The accepted
drive-by-webpage risk is recorded in the design's §5.2/T1, **edited in
WU-8** (not left implicit). A cron-only Origin check remains available as
a middle ground if you prefer it over both the gateway-wide change and no
protection at all — say so and I will scope it that way.

**If you decline run history**, the route count is **65** (not 66), and
every "six" in the plan becomes "five": WU-3's endpoint list, the
`routeMeta` / `openApiMeta` arms, the `CronRun` type in WU-5, and the
run-history panel in WU-6.

## Prerequisites

- `nix develop --command cabal build all` is green on the branch (verified:
  186 modules, EXIT=0).
- `cd frontend && npx vitest run` is green (verified: 630 tests / 24 files).
- `nix develop --command hlint src/ test/` reports "No hints" (verified).

## Work units

### WU-1 — Shared cron operations module (the drift fix)

**Why first**: the opcode and the gateway must not each grow their own copy
of create/update/enable/delete. Everything else depends on this.

**Files**
- `src/Seal/Cron/Operations.hs` — **new** (the 4 operations + the tz
  validator's *use*)
- `test/Seal/Cron/OperationsSpec.hs` — **new**
- `src/Seal/Cron/Types.hs` — `computeNextFire` made total
- `src/Seal/ISA/Ops/Cron.hs` — delegate to the shared module
- `seal-harness.cabal` — `exposed-modules:` + test `other-modules:`
- `test/Main.hs` — import + spec registration

**Two clarifications the feasibility reviewer asked for, answered:**

*`computeNextFire`'s signature does not change.* It is already
`computeNextFire :: CronExpr -> Maybe CronTimeZone -> UTCTime -> IO (Maybe UTCTime)`
— the `Maybe` is already in the return type. Making it *total* means
catching the `loadTZFromDB` exception **inside** the function and returning
`Nothing`, which the type already accommodates. **No caller changes**:
`src/Seal/ISA/Ops/Cron.hs` (3 call sites) and `src/Seal/Cron/Scheduler.hs`
(1 call site) keep compiling unchanged. `computeNextFire` is **not** exported
with a changed type, and `test/Seal/ISA/Ops/CronSpec.hs` does **not**
reference `computeNextFire` directly (it only asserts the *text* of the
`next_fire` field in a rendered message), so that spec stays unmodified.

*No store changes are needed.* The operations use only the existing
`CronStore` surface: `csList False` yields every job (so the 100-job cap is
`length (csList False)` and the dedup set is the same list's ids), `csRead`
is by id, and `csCreate` / `csSave` / `csDelete` are the writes. Run history
comes from the existing **`csListRuns :: CronJobId -> Int -> IO [CronRun]`**
(the runs endpoint in WU-3 uses it; it returns **newest-first** because
`recordRun` prepends). `Seal.Cron.Store` is **not** in this work unit's
file list because it does not change.

**Steps (TDD)**
1. RED: `OperationsSpec` — `validateCronTimeZone` accepts
   `America/New_York`; rejects `Not/AZone` (format-valid but **not in the
   tz database**) and `Not/A/Zone` (format-invalid). `computeNextFire`
   with an unknown zone returns `Nothing` (not an exception).
   **Both live in `Seal.Cron.Types`** and are **single exported entry
   points**:
   - `validateCronTimeZone :: CronTimeZone -> IO (Either Text ())` — the
     **one** timezone gate, doing *both* the format check and the
     tz-database existence check. It is the only function either caller
     uses; `Seal.Cron.Operations` calls it and re-implements neither
     half. `mkCronTimeZone` remains the pure format-only smart
     constructor, used by the opcode's *pure* authorize gate (which
     cannot do IO).
   - `computeNextFire` — made total, as below.
   Nothing is duplicated into `Seal.Cron.Operations`.
2. GREEN: implement `validateCronTimeZone` in `Seal.Cron.Types`; wrap the
   `loadTZFromDB` call in `computeNextFire` so it returns `Nothing` on
   failure. `Seal.Cron.Types` gains one export line.
3. RED: `OperationsSpec` — `createJob`:
   - slugifies the name and **dedups** against existing ids (`daily-review`,
     then `daily-review-2` — the dedup set comes from `csList False`);
   - rejects a name over 100 chars, a prompt over 4000 chars, an invalid cron
     expression, a format-invalid timezone, and a **format-valid-but-
     nonexistent** timezone (`Not/AZone`);
   - enforces the 100-job cap (`length (csList False) >= 100`);
   - defaults `enabled` to `False` when the field is absent.
   `updateJob`:
   - patches **only** the supplied fields and leaves the rest alone;
   - applies the **same** validation as `createJob` to the fields it does
     supply (name length, prompt length, schedule syntax, timezone existence)
     — an update must not be a way to smuggle in a value `createJob` would
     reject;
   - rejects an invalid schedule/timezone.
   `setJobEnabled` and `deleteJob` are idempotent.
4. GREEN: implement `createJob` / `updateJob` / `setJobEnabled` /
   `deleteJob` in `Seal.Cron.Operations`.
5. REFACTOR: `Seal.ISA.Ops.Cron` delegates to the shared module; delete its
   private `dedupSlug` (the shared module owns it now). **The pre-existing
   `test/Seal/ISA/Ops/CronSpec.hs` must still pass unchanged** — it is the
   regression guard for this refactor.
6. WIRE: add `Seal.Cron.Operations` to `seal-harness.cabal`
   `exposed-modules:` **and** `Seal.Cron.OperationsSpec` to the test-suite
   `other-modules:`; add `import qualified Seal.Cron.OperationsSpec` and
   `Seal.Cron.OperationsSpec.spec` to `test/Main.hs`. **Without this the
   new module is not built and its spec never runs** — it is a required
   step, not a file-list mention.
7. `make check`.

**DoD**
- [ ] `Seal.Cron.Operations` exists with the 4 operations; it **calls**
      `Seal.Cron.Types.validateCronTimeZone` (one implementation, two
      callers).
- [ ] `computeNextFire`'s signature is **unchanged**; it is total; its 4
      existing call sites compile untouched.
- [ ] `Seal.Cron.Store` is **unchanged**.
- [ ] `OperationsSpec` covers every row above — including the
      **update-path** validation, which mirrors create — and passes.
- [ ] The pre-existing `test/Seal/ISA/Ops/CronSpec.hs` passes **unmodified**.
- [ ] `seal-harness.cabal` has both new lines; `test/Main.hs` has both new
      lines; the new spec actually runs (`cabal test` output shows it).
- [ ] `hlint` clean; `make check` green.

---

### WU-2 — `ApiDeps` fields (the isolated merge-hotspot commit)

**Why separate**: `ApiDeps` has **29 record-literal sites** in the shared
`test/Seal/Gateway/ApiSpec.hs` — counted by a script that matches
`ApiDeps` followed by `{` (directly or on the next line), which is the
exact set that must list the new fields. (Earlier drafts said 28; 29 is
the measured number. There are **no** `ApiDeps` literals outside
`ApiSpec.hs` — `src/Seal/Command/Serve.hs` has the single production
one.) Isolating the churn into one commit makes any conflict a trivial
rebase.

**Files**
- `src/Seal/Gateway/API.hs` — add **two** fields to `ApiDeps`:
  `adCronStore :: CronStore` and `adAllowedOrigins :: [Text]`
- `src/Seal/Command/Serve.hs` — wire `adCronStore = bCronStore backends`
  and the derived origin list
- `test/Seal/Gateway/ApiSpec.hs` — update all 29 literal sites

**Steps**
1. Add the **two** fields (`adCronStore`, `adAllowedOrigins`) to the
   record; update the **29** sites with a pure `CronStore` value and a
   **neutral** origin list for tests. The list is *neutral* (loopback
   only), not "allow everything" — an allow-everything list at the bulk
   sites would mask WU-4's fail-closed assertion. The WU-4 cases that
   need a specific list build their own `ApiDeps` with an explicit one.
   **The test store must be a *pure* literal**, in the style of the existing
   `fakeRepoRegistryHandle` in `ApiSpec.hs` — several `ApiDeps` literals sit
   inside a pure `let` (`let deps = ApiDeps { ... }`), where the IO-only
   `memoryCronStore` cannot be called. `CronStore`'s fields are all IO
   functions, so a pure stub literal type-checks fine — but every field
   must **raise** (e.g. `csList = \_ -> error "cron store stub: ..."`),
   not return an empty list, so a mis-routed request is unmistakable. **The stub must fail *loudly*, not silently.** It raises
   (`error "cron store stub: a request was routed to a non-cron test deps"`)
   rather than returning an empty list / `Nothing`, so a mis-routed request
   is unmistakable instead of a plausible-looking empty 200. The cron tests
   build a real `memoryCronStore` in an IO context and inject it for the
   cron routes, so the stub is only ever reached if a route is wired to the
   wrong store.
2. In `Serve.hs`, derive the allowlist **the same way the WS guard does**:
   `httpOrigins = ["http://" <> gcHost <> ":" <> port]` (skipped for a
   wildcard host) `<> gcAllowedOrigins`. The WS derivation is at
   `Serve.hs:373-378` — mirror it rather than inventing a second rule.
   **One knob, not two.** `gcAllowedOrigins` already exists and already
   means "extra origins beyond the bound host" (the WS guard uses it as
   `httpOrigins <> gcAllowedOrigins`). The operator's proxied public
   origin goes in that same list — no new setting is introduced.
3. `make check`.

**DoD**
- [ ] `ApiDeps` has exactly **two** new fields: `adCronStore` and
      `adAllowedOrigins` (WU-4 reuses `adAllowedOrigins`; it adds no third
      field).
- [ ] `Serve.hs` wires the real `bCronStore` and the **derived** origin list.
- [ ] All **29** `ApiDeps` literal sites updated; the suite compiles. The
      per-site test store is a pure literal (works in the pure `let` sites)
      that **raises** if used, rather than returning an empty list that
      would look like a successful response; the cron tests build a real
      `memoryCronStore` in IO and inject it.
- [ ] `make check` green.

---

### WU-3 — The cron REST endpoints

**Files**
- `src/Seal/Gateway/API.hs` — 6 routes + handlers
- `src-gateway-types/Seal/Gateway/Types/Route.hs` — 6 `SealRoute`
  constructors + `routeMeta` arms + `allRoutes` entries + `CronJobIdOrErr`
  capture
- `src/Seal/Gateway/OpenApi.hs` — 6 `openApiMeta` arms
- `test/Seal/Gateway/ApiSpec.hs` — the API tests
- `test/Seal/Gateway/ApiRouteSpec.hs` — `expectedRouteCount` 60 → 66

**The accepted `:id` grammar** (the completeness reviewer asked for it
explicitly): `mkCronJobId` accepts **1–64 characters** from
`[a-z0-9-]`, with **no leading dash**. Everything else is rejected with
**400** — empty, `..`, `a/b`, `%2F`, uppercase, any dot, any slash, a
leading dash, and >64 chars. The `:id` is validated **before any store
call**, so a traversal-shaped id never reaches the filesystem.

**Measured path semantics.** WAI's `pathInfo` is the request path
**percent-decoded but not re-split on `/`**. Verified against a live WAI
server:

| Request path | `pathInfo` | Result |
|---|---|---|
| `/api/cron/abc` | `["api","cron","abc"]` | 3 segments → matches the route → id validated |
| `/api/cron/a%2Fb` | `["api","cron","a/b"]` | 3 segments → matches → `mkCronJobId "a/b"` fails → **400** |
| `/api/cron/..%2Fetc` | `["api","cron","../etc"]` | 3 segments → matches → `mkCronJobId "../etc"` fails → **400** |
| `/api/cron/a/b` | `["api","cron","a","b"]` | 4 segments → **no route match → 404** |
| `/api/cron/` | `["api","cron",""]` | 3 segments → matches → `mkCronJobId ""` fails → **400** |
| `/api/cron/..` | `["api",""]` | normalised → **no route match → 404** |
| `/api/cron/%2E%2E` | `["api",""]` | normalised → **no route match → 404** |

**This table is authoritative.** Two distinct outcomes, both safe — no
traversal-shaped id reaches a store call — but with **different** status
codes, and the RED test must assert the right one for each:

- **400** — the request reached the handler and the id failed
  `mkCronJobId`: `a%2Fb` (decodes to `a/b`), `..%2Fetc` (decodes to
  `../etc`), an **empty** id (`/api/cron/`), uppercase, a leading dash, and
  >64 chars.
- **404** — the request never reached the handler: a literal extra `/`
  (`/api/cron/a/b`) and a literal `..` path segment (`/api/cron/..`,
  `/api/cron/%2E%2E`), which WAI normalises away before dispatch.

Both classes are asserted to make **no store call**.

**Request body size cap** (also asked for explicitly): **64 KiB**.
Enforced by a **bounded collector**, not by measuring an already-collected
body: `collectBody` reads the request body unbounded, so a cap applied
after collection would bound the *parser* but not the *buffering*. The
cron handlers therefore use a size-limited collector that stops reading
and rejects with **400** once the limit is exceeded. The existing
`collectBody` is left alone (other endpoints share it); the cap is a new
helper used by the cron handlers.

**Steps (TDD)**
1. RED: `ApiSpec` — the six endpoints:
   - `GET /api/cron` → 200 + `[]` on an empty store; 200 + a job summary
     after a create; the summary **omits `next_fire`** and **includes
     `consecutive_failures`**.
   - `POST /api/cron` → 201 + the created job; the id is the slugified
     name; `enabled` is `false` unless the body says otherwise; **400** on a
     bad schedule / bad timezone / unknown timezone / over-long name /
     over-long prompt / bad `agent_def_id` / non-JSON body / unknown field
     / wrong field type / a body over the 64 KiB cap.
   - `GET /api/cron/:id` → 200 **including `next_fire`** (the detail shape
     differs from the list summary — both are asserted); 404 for an
     unknown id; **400** for each id shape that *reaches the handler* and
     fails `mkCronJobId` — `a%2Fb` (decodes to `a/b`), `..%2Fetc`
     (decodes to `../etc`), an **empty** id (`/api/cron/`), uppercase, a
     leading dash, and >64 chars — asserted **and** asserted to make **no
     store call** (the stub store at those `ApiDeps` literals proves it:
     a store call would surface). The shapes that never reach the handler
     — a literal extra `/` (`/api/cron/a/b`) and a literal `..` segment
     (`/api/cron/..`, `/api/cron/%2E%2E`) — are asserted as **404**,
     and also proven to make no store call.
   - `GET /api/cron/:id/runs` → 200 with the **newest run first**; 404 for
     an unknown id; 400 for a malformed id.
   - `PUT /api/cron/:id` → 200 with the updated fields; 404 unknown; 400
     malformed id; a partial patch leaves unspecified fields alone; a body
     carrying `run_count` / `created_at` / `last_fire` is **rejected** (no
     mass assignment); an update supplying a bad schedule / timezone /
     over-long name / over-long prompt is **rejected** (the update path
     validates exactly as create does); a body over the 64 KiB cap is
     **rejected** (asserted on PUT as well as POST — the bounded
     collector is shared by every body-bearing cron handler).
   - `DELETE /api/cron/:id` → 204; **idempotent** (a delete of an
     unknown id is also 204, matching the `CRON_MANAGE delete` action's
     "deleted (was not present)" semantics and the existing
     `DELETE /api/secrets/:name` / `DELETE /api/repos/:id` precedent);
     400 on a malformed id. **This asymmetry with GET/PUT (which 404 on
     an unknown id) is intentional** and asserted: DELETE reports "the
     desired end state", the others report "the resource". The frontend
     (WU-6) treats a 204 delete as success either way.
   - The 100-job cap is enforced on the API path.
2. GREEN: implement the handlers against `adCronStore`, using
   `Seal.Cron.Operations` for every mutation (never re-deriving the rules).
3. Register the routes in all three files; bump the route count to 66.
4. RED/GREEN: assert the **OpenAPI surface** — the generated spec
   (`GET /api/openapi.json`) contains the six cron paths. Without this the
   6 `openApiMeta` arms are unverified.
5. RED/GREEN: assert the **`routeMeta` arms** — in `ApiRouteSpec`, assert
   each of the six cron routes' **method and path shape** (not just the
   count), so the `routeMeta` and `openApiMeta` tables cannot drift apart
   and a wrong method cannot hide behind a passing count assertion.
6. `make check`.

**DoD**
- [ ] All six endpoints implemented and tested.
- [ ] The list response omits `next_fire` and includes `consecutive_failures`;
      the detail response **includes** `next_fire`. Both asserted.
- [ ] A malformed `:id` yields **400** (id reached the handler and failed
      `mkCronJobId`) or **404** (the path never matched a route) —
      **before any store call** — asserted for every shape in the measured
      path-semantics table above.
- [ ] The request body is parsed into a dedicated input record — a body
      carrying `run_count` / `created_at` / `last_fire` is rejected
      (asserted).
- [ ] A body over the 64 KiB cap is rejected with 400 (asserted).
- [ ] `agent_def_id` is validated with `mkAgentDefId` (asserted).
- [ ] The update path applies the same validation as create (asserted).
- [ ] The generated OpenAPI spec contains the six cron paths (asserted).
- [ ] `ApiRouteSpec` asserts each cron route's method + path (asserted), so
      the two route tables cannot drift.
- [ ] `allRoutes` has 66 entries; `expectedRouteCount = 66`; `ApiRouteSpec`
      passes. The count assertion is the drift guard: adding a 7th cron
      route without bumping it fails the suite.
- [ ] `make check` green.

---

### WU-4 — The gateway-wide write-path Origin check (T1)

**Scope: this changes behaviour for every state-changing `/api/*` route.**
See "Decisions needing your sign-off" above.

**Files**
- `src/Seal/Gateway/API.hs` — the check
- `src/Seal/Command/Serve.hs` — the wildcard-bind startup warning (the
  API layer receives only `adAllowedOrigins` and cannot tell a wildcard
  bind from an empty configured list, so the warning belongs at boot)
- `src/Seal/Gateway/Config.hs` — the `allowed_origins` doc comment
  (it currently says "the WS Origin allowlist"; it now also governs
  state-changing `/api/*` calls)
- `test/Seal/Gateway/ApiSpec.hs` — the check's tests
(no new `ApiDeps` field, no new config setting, and no change to the
29 `ApiDeps` literal sites — WU-2's churn is not repeated)

**The rule** (each clause is necessary; none alone is sufficient):

Let `origin` = the request's `Origin` header, `originHost` = its host
component, `reqHost` = the request's `Host` header host component, and
`trustedHosts` = the gateway's own bound host plus the operator's
configured public hosts (all from the **existing** `gcAllowedOrigins`
knob — no new setting is introduced).

**`trustedHosts` holds host components** (never `scheme:port` strings)
and contains **all** of: the gateway's own bound host (`gcHost`); the
loopback addresses **and names** (`127.0.0.1`, `::1`, `localhost`,
`ip6-localhost`); and the host components of the configured public
origins. **IPv6 literals are compared unbracketed** (`[::1]` → `::1`),
because an IPv6 `Host`/`Origin` authority is bracketed and the set
members are not. **The loopback names are required**: the gateway binds
`127.0.0.1` by default, but an operator may browse
`http://localhost:8080` — a request whose `Host` is `localhost` is not
the bound host, and without the name in `trustedHosts` every write from
that browser would be rejected.

1. **No `Origin` header** → **allow**. That is a non-browser client
   (`curl`, a script) — the same rule the WS guard already uses. A browser
   always sends `Origin` on a cross-origin non-simple request, so it
   cannot suppress it.
2. **`Origin: null`** → **reject (403)**. Sandboxed iframes, `file://`,
   and some redirects produce it; it is never a legitimate UI origin.
3. **`originHost` is in the allowed set** (the operator's configured
   public origins, plus the host-derived origin) → **allow**.
4. **`originHost == reqHost`** *and* **`reqHost` is a trusted host**
   (loopback, or the gateway's own bound host, or an operator-configured
   public host) → **allow**. This is the "same-origin" case, and it is
   what makes the SPA work regardless of scheme, port, or proxy.
5. **Otherwise → reject (403).**

Why clause 4 needs the *second* condition: a DNS-rebinding request
carries `Origin: http://evil.com` **and** `Host: evil.com`, so
`originHost == reqHost` holds — a same-origin rule alone would **allow**
the attack. Requiring `reqHost` to be trusted is what defeats it. (This
is why the round-2 reviewer's proposed fix (iii) was rejected: it compares
the two attacker-controlled headers against each other.)

Why the operator needs a config knob: behind a TLS-terminating proxy the
browser's `Origin` is the **public** origin (`https://public-host`) while
the gateway sees `Host: internal-host`. Clause 4 would reject it because
`originHost != reqHost`. `allowed_origins` lets the operator declare the
public origin, which clause 3 then accepts. The knob is optional: with no
proxy, the default (loopback + the gateway's own host) covers every
deployment, and the knob only matters for proxied ones.

**Steps (TDD)**
1. RED: assert that a state-changing `/api/*` request with a disallowed
   `Origin` → **403**; with **no** `Origin` → allowed (curl); with the
   SPA's own origin → allowed; with `Origin: null` → 403. Assert the same
   for a **sibling** endpoint (`/api/secrets`) to prove the check is
   gateway-wide, not cron-specific.
   **Deployment-shape assertions** (the round-2 blocker, now concrete):
   - `Host: public-host` + `Origin: https://public-host` (a TLS-proxy
     deployment, with `public-host` in `allowed_origins`) → **allowed**.
   - `Host: public-host` + `Origin: https://public-host` with
     `public-host` **not** configured → **403** (fail closed, not
     silently open).
   - `Host: internal-host` + `Origin: https://public-host` with
     `public-host` configured → **allowed** (the proxy case).
   - A **default-port** origin (`Origin: http://host`, no port) against
     `Host: host` → **allowed** (clause 4 compares hosts, not
     scheme:port strings).
   - `Host: localhost:8080` + `Origin: http://localhost:8080` → **allowed**
     (the loopback **name** is trusted, even though the gateway binds
     `127.0.0.1`).
   - `Host: 127.0.0.1:8080` + `Origin: http://127.0.0.1:8080` → allowed.
   - **DNS rebinding**: `Host: evil.com` + `Origin: http://evil.com` →
     **403** (the hosts match, but `evil.com` is not a trusted host).
2. GREEN: implement one check in the API dispatch, applied to
   POST / PUT / DELETE, before the route match. It uses **only**
   `adAllowedOrigins` from WU-2 — which already carries the host-derived
   origin **and** the operator's configured `allowed_origins` entries, in
   one list. No third `ApiDeps` field is introduced.

   **Both configured lists are parsed down to host components** before
   comparison, so an operator may write either
   `https://public-host` or `public-host` in `allowed_origins`, and the
   comparison never depends on a scheme or a port.

   **The 403 body names the knob** when the rejection was a host
   mismatch, so a proxy deployment that failed closed says so instead of
   returning a bare error.

   WAI 3.2.4 has no `requestHeader` (singular) — use `requestHeaders` +
   `lookup` with `Data.CaseInsensitive` (the `Seal.Gateway.Stream.lookupHeader`
   pattern) for `Origin`, and `requestHeaderHost` (which does exist) for
   `Host`. The comparison is on **host components**, so a default-port
   origin and a proxied origin both behave.

   **Wildcard bind (`0.0.0.0` / `::`).** The gateway's own host is then
   not a specific address. The trusted-host set becomes the loopback
   addresses plus the operator's configured public hosts. A LAN deployment
   reaches the gateway by its LAN address, so the operator must list that
   host in `gcAllowedOrigins` — a **one-line config change**, and the
   gateway logs a startup warning naming the knob when the bound host is a
   wildcard. Without it, a LAN deployment's own browser writes are
   rejected — noisy but **fails closed**, and the warning says why.
3. `make check`.

**DoD**
- [ ] The check covers **every** state-changing `/api/*` route.
- [ ] The loopback deployment works with **no** configuration: a
      same-origin write is allowed (asserted).
- [ ] A TLS-proxy deployment works when the operator sets
      `allowed_origins` (asserted, both the public-host and
      internal-host variants).
- [ ] A TLS-proxy deployment **fails closed** when the operator has not
      set it (asserted: 403).
- [ ] A default-port origin is allowed (asserted).
- [ ] A **DNS-rebinding** request (matching but untrusted `Host`) is
      rejected with 403 (asserted).
- [ ] A cross-origin write is rejected (403) with a **non-empty** allowlist
      (asserted).
- [ ] `Origin: null` → 403.
- [ ] No-`Origin` (curl) → allowed; the SPA's own origin → allowed.
- [ ] A 403 from a host mismatch **names the `allowed_origins` knob** in
      its body, so a proxy deployment that failed closed says why
      (asserted).
- [ ] The loopback **name** case is asserted:
      `Host: localhost:8080` + `Origin: http://localhost:8080` → allowed.
- [ ] A wildcard bind logs a startup warning naming `allowed_origins`
      (implemented at the boot site in `Serve.hs`; verified by a
      **manual/logical check** at boot — it needs no new test module, so
      the cabal / `test/Main.hs` wiring is untouched).
- [ ] `make check` green.

---

### WU-5 — Frontend types + API hooks (+ their tests)

**Files**
- `frontend/src/types.ts` — the cron types
- `frontend/src/hooks/useApi.ts` — the fetch/create/update/delete functions
  + `useCronJobs`
- `frontend/src/hooks/__tests__/useApi.test.ts` — **extend** (the file
  already exists and already tests the polling hooks and the CRUD
  mutators)

**Steps (TDD)**
1. RED: extend `useApi.test.ts` with the cron cases, following the
   existing `useHarnesses` (polling hook) and `Agent CRUD` (mutators)
   patterns in that file:
   - `fetchCronJobs` GETs `/api/cron` and returns the list; `fetchCronJob`
     GETs `/api/cron/:id`; `fetchCronRuns` GETs `/api/cron/:id/runs`.
   - `createCronJob` POSTs and returns the created job; a **non-OK
     response** returns `{ok: false, error}` carrying the backend's
     message; a **network throw** returns `{ok: false, error: 'network
     error'}` (the existing convention).
   - `updateCronJob` PUTs; `deleteCronJob` DELETEs and returns a boolean.
   - `useCronJobs` **polls** on the interval and exposes `refresh()`.
2. GREEN: define the types to match the API responses exactly — the **list
   summary** (no `next_fire`, has `consecutive_failures`) and the **detail
   shape** (has `next_fire`) are **different types**, and the frontend
   depends on that distinction.
3. GREEN: implement the functions and the `useCronJobs` hook with the
   `useHarnesses` interval-poll shape (3 s) plus a `refresh()`.
4. RED/GREEN: a **fixture test** pinning the cron JSON shape, so a
   server/frontend field drift is caught at runtime and not only by `tsc`.
   **Location**: `frontend/src/hooks/__tests__/useApi.test.ts` (extended
   again) — the fixture is a literal JSON object asserted to satisfy the
   cron types, so a renamed field fails the test.
5. `npx vitest run` + `npm run build` (tsc) pass.

**DoD**
- [ ] The types match the API responses field-for-field, with the list
      summary and the detail shape as **distinct** types.
- [ ] `useCronJobs` polls on `POLL_INTERVAL` and exposes `refresh`.
- [ ] `useApi.test.ts` covers every function above — including the
      mutation **error** paths — and passes.
- [ ] A fixture test pins the cron JSON shape.
- [ ] `npx vitest run` green; `npm run build` (tsc) passes.

---

### WU-6 — The `CronView` component

**Files**
- `frontend/src/components/CronView.tsx` — **new**
- `frontend/src/components/__tests__/CronView.test.tsx` — **new**

**Steps (TDD)**
1. RED: component tests modelled on `ReposView.test.tsx` — render, empty
   state, create, edit, delete (with confirmation), enable/disable toggle,
   error surfacing, the "next fire" + run-history display in the detail
   pane, and **the create form's enabled toggle defaults to off**.
2. GREEN: implement `CronView` following `SecretsView`'s structure and
   styling vocabulary (`inputStyle`, the `Row` label/control grid,
   `btn btn-primary` / `btn btn-ghost` / `btn btn-danger-ghost`, the
   two-step delete confirmation).
3. `npx vitest run` passes.

**Detail-fetch policy** (the scope reviewer's coherence point): the **list
rows do not show a next-fire time** — the list response deliberately omits
it, because computing next-fire for every job costs a timezone load each
(24 ms) and the list polls every 3 s. The **selected job's** detail pane
shows the next-fire time, fetched **once on selection** (not per row, not
per poll). So the detail view costs one request per selection, not N+1 per
poll.

**DoD**
- [ ] `CronView` renders a list pane + editor pane, styled like
      `SecretsView`.
- [ ] The component tests cover every row above and pass.
- [ ] The create form's enabled toggle defaults to **off**.
- [ ] The next-fire time is shown in the **detail** pane for the selected
      job only — the list rows do not fetch per-row details, and the
      3 s poll does not re-fetch details.
- [ ] `npx vitest run` green.

---

### WU-7 — Top bar + routing (+ their tests)

**Files**
- `frontend/src/components/TopBar.tsx` — the `cron` section
- `frontend/src/App.tsx` — the `/cron` route + the render branch
- `frontend/src/components/__tests__/chrome.test.tsx` — **extend** (the file
  already exists and already has a `TopBar` describe block with a
  "renders a top-level menu button per section" test)
- `frontend/src/__tests__/App.test.tsx` — **extend** (the fetch mock **and**
  new assertions)

**Steps (TDD)**
1. RED: extend `chrome.test.tsx`'s TopBar block — assert the `Cron` button
   exists (`section-cron`) and that it is **between** `section-repos` and
   `section-secrets` in the DOM order (the user's explicit placement
   requirement, asserted rather than eyeballed).
2. RED: extend `App.test.tsx` — assert that clicking the Cron section
   button renders the Cron view, and that navigating to `/cron` selects the
   Cron section (the deep-link case). The existing fetch mock gains a
   `/api/cron` response so rendering the new section does not break the
   existing tests.
3. GREEN: add `'cron'` to the `TopSection` union and to `SECTION_LABELS`
   **between `repos` and `secrets`** (the record's insertion order is the
   display order); add the `/cron` case to `sectionFromPath` and the
   `CronView` branch to the section switch in `App.tsx`.
4. `npx vitest run` passes.

**DoD**
- [ ] `Cron` renders in the top bar between `Repos` and `Secrets` —
      asserted by DOM order in `chrome.test.tsx`.
- [ ] Clicking it opens `CronView`; `/cron` deep-links to it — both
      asserted in `App.test.tsx`.
- [ ] The existing `App.test.tsx` tests still pass.
- [ ] `npx vitest run` green.

---

### WU-8 — Full gate + docs

**Files**
- `docs/plans/2026-10-22-cron-web-ui-design.md` — mark the DoD boxes met
- `docs/plans/2026-10-22-cron-web-ui-plan.md` — mark this plan's status
- `docs/plans/active-plan.md` — point at this plan (set at **WU-0**, below)

**Steps**
1. `make check` (build + test + lint) — the CI gate.
2. `cd frontend && npx vitest run`.
3. Tick the design's DoD boxes that are verifiably met; leave the rest.

**DoD**
- [ ] `make check` green; `hlint` reports "No hints".
- [ ] Frontend `vitest run` green.
- [ ] The design's DoD reflects reality (no box ticked that isn't true).
- [ ] The `allowed_origins` setting's documentation in
      `src/Seal/Gateway/Config.hs` no longer says "the WS Origin
      allowlist" — it says the list also governs which origins may make
      state-changing `/api/*` calls (carried out in **WU-4**, whose file
      list includes `src/Seal/Gateway/Config.hs`).

---

### WU-0 — Set the active plan (before WU-1)

**Files**
- `docs/plans/active-plan.md`

**Steps**
1. Point `active-plan.md` at this plan. It currently points at the
   **completed** provider-CRUD plan (`provider-crud-ui-plan.md`), whose
   work is already merged (route count 60, `ProvidersView` present) — the
   pointer is stale.

**DoD**
- [ ] `active-plan.md` names this plan.

## Dependencies

```
WU-0 (active plan)
   |
WU-1 (shared operations) ──┐
                            ├──> WU-3 (REST endpoints) ──> WU-4 (origin check)
WU-2 (ApiDeps fields) ─────┘                                 │
                                                              ├──> WU-5 (hooks) ──> WU-6 (view) ──> WU-7 (wiring) ──> WU-8 (gate)
```

WU-1 and WU-2 are independent and can be done in parallel. WU-3 needs
both. WU-4 needs WU-2 (the `adAllowedOrigins` field) and WU-3 (the cron
routes exist to test against). WU-5..WU-7 are sequential and depend on the
API shape being settled by WU-3. WU-8 needs everything.

**Note on WU-1's blast radius.** WU-1 changes behaviour *outside* the
tab: `computeNextFire` becomes total (an exception becomes `Nothing`),
and the **agent-facing** `CRON_MANAGE` opcode is refactored to delegate to
the new shared module. That is a change to the agent tool surface, not
only to the web UI. It is included because a user-supplied timezone would
otherwise kill the scheduler thread (design §5.2/T4), and because the
shared module is what stops the two surfaces from drifting. The
unmodified pre-existing `CronSpec` is the regression guard for it.

## Commit plan

One commit per work unit, in WU order (WU-0 first). Never `--no-verify`,
never force-push. The WU-2 commit is the merge-hotspot one and touches only
`API.hs` / `Serve.hs` / `ApiSpec.hs`. Note that `API.hs` and `ApiSpec.hs`
are edited again in WU-3 and WU-4, so the *file-level* merge surface is
wider than the literal-churn surface — unavoidable, and each commit stays
small and self-contained.

## Risks

| Risk | Mitigation |
|---|---|
| The 29-site `ApiDeps` churn conflicts with parallel work | Isolated to WU-2, one commit, mechanical edit. The count is measured, not estimated. |
| The WU-1 refactor changes opcode behaviour | `CronSpec` (pre-existing) is the regression guard and must pass **unmodified**; `computeNextFire`'s signature is unchanged so no caller moves. |
| The Origin check breaks a legitimate client | Every deployment shape is asserted in WU-4: loopback (no config), the loopback **name** `localhost`, an IPv6 loopback, a default-port origin, and a TLS proxy with `allowed_origins` set. Same-origin and no-`Origin` (curl) always work; a wildcard-bind deployment needs its LAN host listed once. |
| A deployment that failed closed 403s every write | It **fails closed** by design, not silently: the 403 body names the `allowed_origins` knob, and a wildcard bind logs a startup warning naming it. A proxy deployment without the knob set is the one case that needs the operator to add one line of config. |
| DNS rebinding defeats the same-origin rule | It does not: the rule requires the request's `Host` to be a **trusted** host, and a rebound request's `Host` is the attacker's own host — asserted in WU-4. |
| An unknown timezone kills the scheduler thread | WU-1 makes `computeNextFire` total and validates at the write boundary on both paths. |
| The route-count assertion drifts from `allRoutes` | Both are updated in WU-3, and `ApiRouteSpec` asserts the count — a 7th cron route without a bump fails the suite. |
| A large request body is buffered before the cap is applied | The cron handlers use a **bounded collector** that stops reading at 64 KiB, so the cap bounds the buffering, not just the parse. The pre-existing unbounded `collectBody` is shared with other endpoints and is left unchanged. |
| The frontend polls every 3 s and each poll is a directory read | The list response does no next-fire computation (no timezone loads); the poll is a read + JSON encode. The detail fetch is once per selection, not per row. |
| WU-4 changes behaviour for endpoints the user did not ask about | Flagged in "Decisions needing your sign-off"; split into its own plan on request. |
| WU-1 changes agent-visible behaviour | Flagged in the WU-1 blast-radius note and in "Decisions needing your sign-off"; the pre-existing `CronSpec` is the regression guard. |
| The list/detail split (no `next_fire` in the list) is an API decision the user did not ask for | Documented in design §3/D5; the split is what keeps the 3 s poll from paying a timezone load per job. Flagged in "Decisions needing your sign-off". |
