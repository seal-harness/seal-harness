# CRON_MANAGE Web UI — Design (rev 2)

**Date**: 2026-10-22
**Status**: Design — rev 2, after the round-1 design review gate
**Related**: `docs/superpowers/specs/2026-10-03-cron-manage-design.md` (the
`CRON_MANAGE` opcode + scheduler design this UI sits on top of)
**Branch**: `cron-design` (base `main` @ `3ca34c4`)

> **Rev 2 changelog.** The round-1 security review found that three load-bearing
> claims in rev 1 were **factually wrong about the code**. Rev 2 corrects
> them and changes three decisions as a result. See §9 for the full list.

## 1. Problem

The `cron-design` branch ships the backend cron machinery — `Seal.Cron.Types`,
`Seal.Cron.Store`, `Seal.Cron.Scheduler`, and the `CRON_MANAGE` opcode — but
the **web frontend has no way to see or manage any of it**. The operator's only
surface is an agent turn: they must type a `CRON_MANAGE` JSON blob into chat
and parse prose output to learn what the job id was.

Every other operator-facing resource in Seal has a CRUD tab: Providers, Agents,
Skills, Repos, Secrets. Cron is the odd one out. The operator cannot look at
their scheduled jobs, see when they next fire, notice that one has been
failing, or turn one off — without leaving the UI and writing JSON by hand.

**Goal**: a `Cron` tab in the top menu bar, between `Repos` and `Secrets`,
that lists cron jobs and lets the operator view, create, edit, enable/disable,
and delete them.

### 1.0 Personas

**Operator** — the human who runs `seal serve` and unlocks the vault. They
define cron jobs, choose schedules, review outputs, and are the beneficiary.
The operator is the WHO for every use case below.

**Agent** — the AI that executes a cron job's prompt in an isolated session.
The agent is the mechanism, not the beneficiary. It inherits the harness tool
set minus `CRON_MANAGE` and runs at the configured autonomy.

### 1.1 Use cases (WHO / WANTS / SO THAT / WHEN)

1. **Operator reviews their cron jobs** — *As* an operator, *I want* to see
   every scheduled job with its schedule, enabled state, and last-run
   summary, *so that* I can verify my automations at a glance, *when* I open
   the Cron tab.
2. **Operator creates a job without writing JSON** — *As* an operator, *I
   want* a form for name / schedule / prompt, *so that* I can schedule a
   recurring task without hand-writing an opcode payload, *when* I want a
   daily code review.
3. **Operator edits an existing job's prompt** — *As* an operator, *I want* to
   change the prompt or schedule of a job, *so that* I can correct a job
   whose prompt no longer does what I meant, *when* the scheduled output
   stops meeting my intent.
4. **Operator pauses a job** — *As* an operator, *I want* to disable a job
   without deleting it, *so that* I can stop a misbehaving schedule
   temporarily, *when* it is causing noise or cost.
5. **Operator deletes a job** — *As* an operator, *I want* to remove a job I
   no longer want, *so that* my list reflects reality, *when* the
   automation is obsolete.
6. **Operator sees a job's run history** — *As* an operator, *I want* to see
   when a job last ran and whether it failed, *so that* I can diagnose a
   misbehaving schedule, *when* a job appears not to be producing output.

### 1.2 Success metrics

- **S1**: The operator can create a job from the Cron tab and see it listed
  with its schedule and enabled state, without touching the chat or the CLI.
- **S2**: The operator can disable and re-enable a job and observe the
  listed enabled state change, without deleting and recreating it.
- **S3**: The operator can find a job that is failing — the list shows its
  consecutive-failure count, and selecting it shows recent runs with their
  status and error.
- **S4**: A malformed schedule, name, or timezone entered in the form is
  rejected with an inline message naming the offending field — the form never
  silently discards input.

## 2. Scope

### In scope

- A `Cron` section in the top bar, positioned between `Repos` and `Secrets`.
- A `CronView` pane: list of jobs on the left, editor on the right (the
  established `SecretsView` / `ReposView` two-pane shape).
- View / create / edit / enable / disable / delete of cron jobs.
- Run history for a selected job.
- A `GET /api/cron` + `GET /api/cron/:id` + `GET /api/cron/:id/runs` +
  `POST` + `PUT` + `DELETE` REST surface in the gateway, so the frontend can
  reach the `CronStore` that already exists.

### Out of scope (explicitly)

- **Wiring the cron fire delegate.** `bCronFire` is `Nothing` everywhere and
  `Serve.hs` starts the scheduler with a stub delegate that always returns
  `"cron fire delegate not yet wired"`. Scheduled jobs therefore do not yet
  actually fire, and `CRON_MANAGE trigger` returns an error. **This UI
  therefore does not ship a "Run now" button** — a button that always fails
  is worse than no button. Wiring the delegate is a separate, larger piece of
  work (it needs `runDelegateAsync` plumbed into the `serve` boot path). When
  that lands, a "Run now" affordance is a small follow-up.
- **Enforcing the cron-spawn restrictions** (`cronSpawnBlocklist` is not
  applied anywhere in `src/` today, and `AutonomyLevel` has no `AckRequired`
  constructor — see §5.2/T2). This is a **pre-existing gap in the branch**,
  not something this UI creates. It does, however, gate one decision (§3/D2).
- Natural-language scheduling, RRULE, calendar UI.
- Editing a job's *run history* (read-only).
- Changing the `CRON_MANAGE` opcode's own action set.
- Per-job agent-def editing (the operator picks an existing agent def).
- Closing the general "the REST API has no auth" gap for the other ~60
  endpoints (see §5.2/T1) — that is a gateway-wide change, tracked as a
  follow-up, not smuggled into a UI feature.

## 3. Key design decisions

### D1 — The web UI gets its own REST surface; it does not go through the opcode

The frontend talks to the backend **only** over HTTP `/api/*`; there is no
generic "dispatch any opcode over HTTP" endpoint. So the UI cannot reuse
`CRON_MANAGE` directly. Two options:

- (a) Expose the `CRON_MANAGE` opcode's actions over new REST endpoints.
- (b) Add REST endpoints that operate on the same `CronStore` the opcode uses.

**Decision: (b).** The gateway's existing CRUD resources (`/api/skills`,
`/api/repos`, `/api/secrets`) all talk to their backend record directly
(`SkillBackend`, `RepoRegistryHandle`, `VaultHandle`) rather than through an
opcode. `CronStore` is exactly that shape — a concrete record of IO fields.
The two surfaces share the *store*, so a UI edit and an agent edit are visible
to each other immediately (same files on disk).

### D2 — One shared implementation of the job operations, used by both surfaces

Rev 1 had the gateway re-implement create/update/enable alongside the
opcode's own handlers. That would let the two drift — a validation rule added
to one and not the other is a security gap, not a style nit.

**Decision: a new module `src/Seal/Cron/Operations.hs`** holds the job
operations (`createJob`, `updateJob`, `setJobEnabled`, `deleteJob`) and the
timezone validation, expressed against `CronStore` and the smart-constructed
types. **Both** `Seal.ISA.Ops.Cron` and `Seal.Gateway.API` call it.

This also fixes a latent bug: `dedupSlug` (which prevents a new job from
**overwriting** an existing job whose slugified name collides) is currently
private to `Seal.ISA.Ops.Cron`. The shared module owns it, so both surfaces
dedup identically.

Cost: one `exposed-modules:` line in `seal-harness.cabal` and one test module
in `test/Main.hs`. Both are merge hotspots; this is a single small edit in
each, in one dedicated commit.

### D3 — The web UI creates jobs **disabled**; the operator enables them explicitly

Rev 1 had the UI create jobs in whatever enabled state the operator chose,
arguing "the operator typed the prompt, so the operator has approved it".

**That argument does not hold, and rev 1's supporting claim was factually
wrong.** Rev 1 asserted "an agent cannot create an auto-enabled job". The
code says otherwise: `authorizeCronManage`'s `CaCreate` arm validates only the
name, schedule, and timezone — it never rejects `enabled: true`, and
`handleCreate` applies the field verbatim. An agent **can** create an
auto-enabled job through the opcode today.

More importantly, the original spec's §5 operator-approval model ("a job
created by an agent defaults to `enabled: false`; the operator must explicitly
enable it after reviewing the prompt") is **not implemented in the branch**:
`CronJob` has no `cjApproved` field, and `enable`/`disable` are not gated on
operator-vs-agent session (`cronManageOp` ignores its `SessionId` argument).

So the branch currently has **no** enforced approval gate anywhere. Rather
than extend that gap to a second surface, this UI adopts the spec's intent
going forward:

**Decision: the web UI's create form defaults to `enabled: false` and the
operator enables the job as a separate, explicit action** — matching the
agent-facing path and the spec's stated model. The form still *shows* the
enabled toggle, but the default state of a new job is disabled, and the
"Enable" action is a distinct button the operator clicks after reviewing the
prompt. This makes the operator's review an observable, separate step in
**both** surfaces.

This is a deliberate tightening of rev 1. The cost is one extra click for a
job the operator just wrote; the benefit is that the approval gate the spec
describes actually exists, and it exists in the same shape on both surfaces.

### D4 — Validate the timezone against the tz database, at the store boundary

`mkCronTimeZone` validates **format only** — `"Not/AZone"` passes (two
alphanumeric components), and then `loadTZFromDB` **throws** an uncaught
`IOException` inside `computeNextFire`. This is not merely a crash in a
request handler:

- `computeNextFire` is also called from `fireIfDue` inside the scheduler's
  `tick`, with no exception handling anywhere in `startCronScheduler`. One
  stored job with a bad zone therefore **kills the scheduler thread** — all
  cron scheduling is dead until the job is removed or the process restarts.
- The zone is *persisted*, so the failure is permanent, not transient.

**Decisions:**
1. `computeNextFire` becomes **total** — it catches the load failure and
   returns `Nothing`. No caller can be crashed by a stored zone.
2. The timezone is validated against the tz database **at the write
   boundary**, in the shared `Seal.Cron.Operations` module, so a
   format-valid-but-nonexistent zone is rejected on **both** the opcode path
   and the web path, and can never enter the store.
3. The `mkCronTimeZone` pure smart constructor keeps its format-only check
   (it is used in the opcode's *pure* authorize gate, which cannot do IO);
   the database-backed check is a separate `IO` function
   (`validateCronTimeZone :: CronTimeZone -> IO (Either Text ())`).

### D5 — The list endpoint does no next-fire computation; the detail endpoint does

`loadTZFromDB` costs **~24 ms** per call and `tz-0.1.3.6` exposes no cached
loader (`getCachedTimeZone` does not exist in this version). A list endpoint
computing next-fire for N jobs would cost N × 24 ms for zone-aware jobs
(100 jobs ≈ 2.4 s) — unacceptable for a UI that polls.

**Decisions:**
- The **list** endpoint returns cheap fields only: id, name, schedule,
  enabled, one_shot, last_fire, run_count, **consecutive_failures**,
  created_at, updated_at. No next-fire computation; no zone loads at all.
  `consecutive_failures` is included because it is the signal that a job is
  failing (S3), and rev 1 omitted it while relying on the poll to reveal
  failures.
- The **detail** endpoint (`GET /api/cron/:id`) returns the full job
  *including* `next_fire`, computed once, loading the zone once (24 ms for a
  single detail view is fine).
- A per-request zone memo is **not** added: rev 1 proposed one, but with one
  job per detail request there is nothing to memoise. If a future endpoint
  needs next-fire for many jobs, that is when a memo belongs.

### D6 — `ApiDeps` gains two fields; the churn is isolated to one commit

The gateway needs (a) the `CronStore` and (b) the allowed-origins list for
the write-path origin check (D9). `ApiDeps` is the injection point, and the
gateway already holds a `SkillBackend` (`adSkills`) and an `AgentDefBackend`
(`adAgentDefs`) the same way.

Cost: `ApiDeps` has **28 literal sites** in `test/Seal/Gateway/ApiSpec.hs` —
a shared, merge-hotspot file. Both new fields are added in **one dedicated
commit** that touches nothing else, so any conflict is a trivial rebase.

`ApiDeps` is a record; every literal must list every field, so there is no
way to add a field without updating all 28 sites. The alternative — deriving
the store from `srPaths (adSessionRuntime deps)` as the provider-CRUD plan
did — does not work here: the cron store needs a `ConfigRepo` (for the
git audit-commit) and a directory that only `Backends` knows how to build
(`fileCronStore` creates `jobs/` and `runs/` subdirectories). Reconstructing
it per-request would also mean re-running `createDirectoryIfMissing` on every
call. A field is the honest representation.

### D7 — Route registration is a three-file edit

Every endpoint needs a `SealRoute` constructor + `routeMeta` arm +
`allRoutes` entry in `src-gateway-types/Seal/Gateway/Types/Route.hs`, an
`openApiMeta` arm in `src/Seal/Gateway/OpenApi.hs`, and a bump of
`expectedRouteCount` in `test/Seal/Gateway/ApiRouteSpec.hs` (60 → **66**).
`src-gateway-types` is a separate library that cannot import `seal-harness`,
so the capture codec follows the `SkillIdOrErr` / `RepoIdOrErr` pattern: a
`newtype CronJobIdOrErr = CronJobIdOrErr (Either Text Text)` that always
succeeds at the capture layer, with real validation (`mkCronJobId`) in the
handler. This is exactly how every other id-bearing route works.

Note the runtime dispatcher in `Seal.Gateway.API` matches on `pathInfo`
directly; the `SealRoute` GADT is the declarative spec that the OpenAPI
generator and the route-count test read. Both must be updated.

### D8 — The write path validates everything and returns structured errors

| Input | Validation | Where |
|---|---|---|
| `:id` path segment | `mkCronJobId`: 1–64 chars from `[a-z0-9-]`, no leading dash. Rejects empty, `..`, `a/b`, uppercase, any dot or slash, leading dash, >64 chars. | handler, **before any store call** |
| `name` | 1–100 chars | shared operations module |
| `prompt` | 1–4000 chars | shared operations module |
| `schedule` | `mkCronExpr` (5-field cron) | shared operations module |
| `timezone` | `mkCronTimeZone` (format) **+** `validateCronTimeZone` (exists in tzdb) | shared operations module |
| `agent_def_id` | `mkAgentDefId` (exists, charset-checked) | shared operations module |
| `enabled` / `one_shot` | strict JSON boolean | handler |
| unknown body fields | rejected | handler |
| request body size | ≤ 64 KiB, checked before parsing | handler |

**Job names and prompts are free text and are never used as path
components** — only `cjId` is, and the id is generated by slugifying the name
(`slugify`, path-safe) with dedup against existing ids.

**No mass assignment.** The request body is parsed into a dedicated input
record, never into a `CronJob` — `FromJSON CronJob` accepts `created_at`,
`run_count`, `consecutive_failures`, and `last_fire`, which a client must not
be able to set.

**The update path validates exactly as the create path does.** An update
that supplies a name over 100 chars, a prompt over 4000 chars, an invalid
schedule, or a nonexistent timezone is rejected — otherwise `PUT` would be a
way to smuggle in a value `POST` refuses. Both live in the shared
operations module, so this holds by construction rather than by
convention.

**The body-size cap is explicit and bounds the buffering**, not just the
parse: `collectBody` reads the request body unbounded, so the cron handlers
use a size-limited collector that stops reading at 64 KiB. 64 KiB is far
above the largest legitimate cron request (a 4000-character prompt plus a
schedule) and well below anything that would strain the gateway.

**Two id-outcome classes, both safe.** A traversal-shaped id either
reaches the handler and fails `mkCronJobId` (**400**), or never matches a
route because WAI normalised the path away (**404**). Neither reaches a
store call. The exact split is measured and tabulated in the plan
("Measured path semantics").

Error mapping:

| Condition | HTTP |
|---|---|
| malformed `:id` (fails `mkCronJobId`) | 400 |
| unknown job id | 404 |
| invalid schedule / timezone / name / prompt / agent-def | 400 with the reason |
| body not valid JSON / unknown field / wrong type | 400 |
| body over the size cap | 400 |
| cross-origin write (§5.2/T1) | 403 |
| store write failure | 500 |

### D9 — The web write path checks Origin, and the check is gateway-wide

See §5.2/T1. The mitigation is an **Origin allowlist on all
state-changing `/api/*` requests**, with the allowlist derived the same way
the WebSocket guard derives it (host-derived origin + the configured list),
failing **closed** on a wildcard bind. The check lives in one place (the API
dispatch), not per-route.

### D10 — Frontend shape follows `SecretsView`

`CronView.tsx` = list pane (left) + editor pane (right), matching
`SecretsView.tsx` in structure and styling vocabulary (same `inputStyle`,
`Row` label/control grid, `btn btn-primary` / `btn btn-ghost` /
`btn btn-danger-ghost` classes, same two-step delete confirmation). The
`TopBar` section is added to the `TopSection` union and to `SECTION_LABELS`
**between `repos` and `secrets`** — the record's insertion order is the
display order, so this is a one-line placement.

`App.tsx` gains a `/cron` case in `sectionFromPath` and a `CronView` branch
in the section switch.

### D11 — The UI polls, and the poll is cheap

`useCronJobs` polls `GET /api/cron` on the established `POLL_INTERVAL` (3 s)
cadence, using the `useHarnesses` shape (`setInterval(poll, POLL_INTERVAL)`
plus a mount-time fetch).

Note the distinction from `useRepos` / `useSecrets` / `useAgentDefs`: those
fetch on mount and on an explicit `refresh()` only, and get server-pushed
updates via a `*-changed` WebSocket frame. Cron has no such frame, and it
genuinely changes in the background — the 60 s scheduler tick updates
`last_fire`, `run_count`, and `consecutive_failures`, and can auto-disable a
job after repeated failures. Without a poll the operator would not see a job
fail or disable itself until they reloaded the tab.

Because the list endpoint does no next-fire computation (D5), each poll is a
directory read plus a JSON encode. A `cron-changed` WS frame is a reasonable
follow-up if the list ever grows expensive.

## 4. Architecture summary

**Backend** (new REST surface over the existing `CronStore`):

```
GET    /api/cron          → list jobs (cheap fields, no next-fire)
POST   /api/cron          → create job (disabled by default — D3)
GET    /api/cron/:id      → read job (full fields + next_fire)
GET    /api/cron/:id/runs → recent runs (newest first)
PUT    /api/cron/:id      → update job (partial patch)
DELETE /api/cron/:id      → delete job (idempotent, 204)
```

`ApiDeps` gains `adCronStore :: CronStore` and
`adAllowedOrigins :: [Text]`, wired in `Serve.hs`. The `CronStore` is
file-backed under `~/.seal/config/cron/` (jobs in `jobs/<id>.json`, run
history in `runs/<id>.jsonl`), so the UI and the opcode observe the same
state.

**New backend module** — `src/Seal/Cron/Operations.hs`: the shared job
operations + timezone validation, used by both the opcode and the gateway.

**Frontend**:

- `frontend/src/types.ts` — cron types.
- `frontend/src/hooks/useApi.ts` — cron fetch/create/update/delete + `useCronJobs`.
- `frontend/src/components/CronView.tsx` — the two-pane CRUD view.
- `frontend/src/components/TopBar.tsx` — the `cron` section.
- `frontend/src/App.tsx` — routing + render branch.

**Backend supporting changes**:

- `Seal.Cron.Types` — `computeNextFire` made total.
- `Seal.Cron.Operations` (new) — shared operations + tz validation.
- `Seal.ISA.Ops.Cron` — delegate to the shared module; drop the now-duplicate
  `dedupSlug`.

## 5. Security analysis

### 5.1 Threats

**T1 — Cross-origin state changes (CSRF).** The gateway's REST API has **no
authentication** and every response carries
`Access-Control-Allow-Origin: *`. Any web page the operator visits can
`POST` to `http://127.0.0.1:8080/api/...` and the browser will send the
request. The gateway binds `127.0.0.1` by default, but `runGateway` only
*warns* on a non-loopback bind outside remote-only mode, so the exposure is
"the operator's own browser", not merely "the local machine".

This is **not new to cron**, and cron is **not the worst endpoint**:
`POST /api/sessions/:id/send` runs a full agent turn with the whole tool
set, `POST /api/providers` writes API keys into the vault, and
`POST /api/secrets` writes the vault. Rev 1 proposed an Origin check on the
cron endpoints alone, which would have left all of those open while creating
the impression the class was addressed. A check on five endpoints out of
sixty-five is not a fix.

**Decision**: apply the check to **every state-changing `/api/*` request**
(POST / PUT / DELETE), at the API dispatch point — one place, uniform, and it
covers cron plus the strictly-worse siblings. Details that matter:

Let `origin` = the request's `Origin` header, `originHost` = its **host
component**, `reqHost` = the request's `Host` header **host component**,
and `trustedHosts` = the gateway's own bound host, the loopback addresses,
and the operator's configured public hosts.

**`trustedHosts` is a set of host components** (not `scheme:port`
strings), and it contains **all** of:

- the gateway's own bound host (`gcHost`),
- the loopback addresses **and names**: `127.0.0.1`, `::1`, `localhost`,
  `ip6-localhost`,
- the host components of the operator's configured public origins.

The loopback **names** matter: the gateway binds `127.0.0.1` by default,
but the operator may well browse `http://localhost:8080` — a request
whose `Host` is `localhost` is not in the bound-host set, and without the
name in `trustedHosts` every write from that browser would be rejected.

1. **No `Origin` header** → **allow**. A non-browser client (`curl`, a
   script) — the same rule the WS guard already uses. A browser always
   sends `Origin` on a cross-origin non-simple request, so it cannot
   suppress it.
2. **`Origin: null`** (sandboxed iframes, `file://`, some redirects) →
   **reject (403)**. It is never a legitimate UI origin.
3. **`originHost` is in the allowed set** (the operator's configured public
   origins, plus the host-derived origin) → **allow**.
4. **`originHost == reqHost`** *and* **`reqHost` is a trusted host** →
   **allow**. This is the same-origin case.
5. **Otherwise → reject (403).**

**Clause 4 needs both conditions, and that is the subtle part.** A
DNS-rebinding request carries `Origin: http://evil.com` **and**
`Host: evil.com` — the two attacker-controlled headers *match*. A
same-origin rule that compares them against each other would therefore
**allow** the attack. Requiring `reqHost` to be a *trusted* host
(loopback, the gateway's own bound host, or an operator-configured public
host) is what actually defeats rebinding.

**Comparisons are on host components, not `scheme:port` strings.** That is
what makes a default-port origin (`Origin: http://host`, no port) and a
proxied origin (`Host: internal-host`, `Origin: https://public-host`)
behave sensibly.

**The operator needs a config knob for proxied deployments.** Behind a
TLS-terminating proxy the browser's `Origin` is the **public** origin
while the gateway sees the internal `Host`, so clause 4 does not apply and
clause 3 needs the public origin declared. The **existing**
`[gateway] allowed_origins` setting provides it — the WS guard already
treats that list as "origins beyond the bound host"
(`httpOrigins <> gcAllowedOrigins`); its documentation changes from "the
WS Origin allowlist" to "origins permitted to make state-changing
`/api/*` calls". **No new setting is introduced.** Without a proxy it is
unnecessary: loopback plus the gateway's own host covers every
deployment.

**A wildcard bind (`0.0.0.0` / `::`) is the case needing the knob.** The
gateway's own host is not a specific address there, so the trusted-host
set is the loopback addresses plus the configured public hosts; a LAN
deployment reaches the gateway by its LAN address and must list it. The
gateway logs a startup warning naming the setting when the bound host is
a wildcard. Without it, a LAN deployment's own browser writes are
rejected — noisy, but **fails closed**, and the warning says why.

**A missing `Origin` header is allowed** — that is a non-browser client
(`curl`, a script), matching the WS guard's existing behaviour, and the
attacker in a browser cannot suppress `Origin` on a cross-origin
non-simple request.

**Scope note.** This changes the write behaviour of every existing
`/api/*` endpoint, not only cron — beyond the literal "add a Cron tab"
request. It is proposed gateway-wide because cron-create is *less*
dangerous than siblings that already exist (`POST /api/sessions/:id/send`
runs a full agent turn; `POST /api/providers` and `POST /api/secrets` write
to the vault), so a cron-only check would leave the class open while
creating the impression it was addressed. Whether to deliver it here or as a
separate security change is the operator's decision.

Residual risk that this does **not** cover, stated plainly: a non-browser
client on the machine can still drive the API (no auth), and on a non-loopback
bind a network peer can too. The gateway-wide "add auth to the REST API" work
is the real fix and is tracked as a follow-up; this change does not pretend to
be it.

**T2 — Stored prompt injection.** A cron prompt is arbitrary text that
becomes an agent goal. The original spec's mitigations are the
`cronSpawnBlocklist` and a per-job autonomy ceiling. **Neither is implemented
in the branch today**: `cronSpawnBlocklist` is defined in
`Seal.Cron.Scheduler` but referenced nowhere else in `src/`, and
`AutonomyLevel` is `Full | Supervised | Deny` — there is no `AckRequired`
constructor. The cron fire delegate is a stub, so **no cron session is
spawned at all** yet, which is the actual reason there is no live exposure
today.

Rev 1 claimed the web UI "does not weaken" these restrictions. That claim was
wrong: there are no restrictions in the code to weaken. The honest statement
is that the UI does not weaken them **because they are not yet enforced
anywhere**, and that D3 (create disabled by default) is a step toward the
spec's model rather than a claim that the model already holds. Wiring the
fire delegate must land the blocklist and the autonomy ceiling with it.

**T3 — Path traversal via the job id.** Mitigated by `mkCronJobId`
(`[a-z0-9-]+`, ≤ 64 chars, no leading dash, no dots or slashes) and by
never using the name or prompt as a path component. The API validates the
`:id` path segment with `mkCronJobId` **before any store call**.

**T4 — Uncaught exception from a bad timezone (D4).** Fixed by validating
against the tz database at the write boundary on both paths, and by making
`computeNextFire` total. This is a **blocker**, not a nicety: an unhandled
exception in the scheduler's `tick` kills the scheduler thread and stops all
cron scheduling.

**T5 — Resource exhaustion.** The store caps jobs at 100 (enforced in the
shared operations module, on both paths); name ≤ 100 chars and prompt ≤ 4000
chars are validated server-side, not just in the form. The request body is
size-capped before parsing, and the API does not expose an unbounded write
rate.

**T6 — Data exposure in responses.** The cron `prompt` is returned to the UI
because the operator must be able to edit it. The prompt is operator-authored
content, not vault material. Two retention notes: (a) the job file is mode
0600, but the **git audit-commit** puts the prompt into the config repo's
object store, where it survives the job file's deletion; (b) run history
contains `crError`, which may echo a failing command's output. Both are
inherent to the existing store design; they are recorded, not fixed here.

**T7 — Unvalidated `agent_def_id`.** `cjAgentDefId` is raw `Text` today. The
API validates it with `mkAgentDefId` (D8) so a web-supplied value cannot be
an arbitrary string reaching a later agent-def lookup.

**T8 — Mass assignment.** The API parses the body into a dedicated input
record, never into `CronJob` (D8), so a client cannot set `created_at`,
`run_count`, `consecutive_failures`, or `last_fire`.

**T9 — Missing audit trail on the web path.** The `CRON_MANAGE` opcode is
`Audited`; the REST path is not in the ISA layer, so UI-made changes are not
in the cross-session audit log. The store's git audit-commit
(`seal: CRON write <id>`) is the compensating record for now.

### 5.2 Invariants preserved

- **No shell-wrapping.** The new handlers use `CronStore` (native file I/O)
  only. No `System.Process` in the new code paths.
- **Type-guaranteed sanitization.** The `:id` path segment is validated
  with `mkCronJobId`; name, prompt, and agent-def id are validated by smart
  constructors; none of them reach a path.
- **Transcript as source of truth.** Unchanged. The UI is a *view* over the
  same materialized store the agent-facing opcode writes; it does not
  introduce a second source of truth.
- **Agent-immutable `~/.seal/`.** The cron store lives under
  `~/.seal/config/cron/`, alongside `config/skills/` and `config/agents/` —
  the established location for operator-managed resources, and the path
  `Path.hs`'s `blockedNames` already blocks agents from reaching directly.

## 6. Testing strategy

### Backend unit tests — `test/Seal/Cron/OperationsSpec.hs` (new)

- `createJob` slugifies the name, **dedups** against existing ids
  (`daily-review`, then `daily-review-2`), rejects a name over 100 chars, a
  prompt over 4000 chars, an invalid cron expression, a format-invalid
  timezone, and a **format-valid-but-nonexistent** timezone (`Not/AZone`).
- `createJob` respects the 100-job cap.
- `createJob` defaults `enabled` to `False` when the field is absent (D3).
- `updateJob` patches only the supplied fields; leaves the rest alone;
  rejects an invalid schedule/timezone.
- `setJobEnabled` is idempotent; `deleteJob` is idempotent.
- `validateCronTimeZone` accepts `America/New_York`, rejects `Not/AZone`
  and `Not/A/Zone`.
- `computeNextFire` with an unknown zone returns `Nothing` rather than
  throwing (regression test for T4).

### Backend API tests — `test/Seal/Gateway/ApiSpec.hs` (extend)

- `GET /api/cron` → 200 + `[]` on an empty store; 200 + a job summary
  after a create; the summary omits `next_fire` and includes
  `consecutive_failures`.
- `POST /api/cron` → 201 + the created job; the id is the slugified name;
  `enabled` is `false` unless the body says otherwise; 400 on a bad
  schedule / bad timezone / over-long name / over-long prompt / bad
  agent-def id / non-JSON body / unknown field / wrong type / oversized body.
- `GET /api/cron/:id` → 200 with `next_fire`; 404 for an unknown id; 400 for
  a malformed id (`../etc`, `A/B`, `UPPER`).
- `GET /api/cron/:id/runs` → 200 with the newest run first; 404 for an
  unknown id; 400 for a malformed id.
- `PUT /api/cron/:id` → 200 with the updated fields; 404 unknown; 400
  malformed id; a partial patch leaves unspecified fields alone; a body
  carrying `run_count` / `created_at` is rejected (no mass assignment).
- `DELETE /api/cron/:id` → 204; idempotent on a second delete; 400 on a
  malformed id.
- **Origin check**: a state-changing request with a disallowed `Origin`
  → 403; with no `Origin` → allowed; with the SPA's own origin → allowed;
  `Origin: null` → 403. Applied to `/api/cron` **and** to a sibling
  endpoint (`/api/secrets`) to prove the check is gateway-wide, not
  cron-specific.
- The 100-job cap is enforced on the API path.
- `ApiDeps` literal sites all updated (28) — compile-level check.

### Frontend tests — `frontend/src/components/__tests__/CronView.test.tsx` (new)

Modeled on `ReposView.test.tsx` / `ProvidersView.test.tsx`: mock
`../../hooks/useApi`, assert render / empty state / create / edit / delete
(with confirmation) / enable-disable toggle / error surfacing / the
"next fire" and run-history display in the detail pane. Also assert the
create form's enabled toggle **defaults to off** (D3).

`frontend/src/__tests__/App.test.tsx` — the existing fetch mock must gain a
`/api/cron` response so rendering the new section does not break existing
tests.

### Quality gates

- `make check` (build + `cabal test` + `hlint`) green.
- `cd frontend && npx vitest run` green.
- Route count assertion updated in lockstep with `allRoutes`.

## 7. File impact

### New files

| File | Purpose |
|---|---|
| `src/Seal/Cron/Operations.hs` | shared job operations + tz validation |
| `test/Seal/Cron/OperationsSpec.hs` | the shared operations' tests |
| `frontend/src/components/CronView.tsx` | the CRUD pane |
| `frontend/src/components/__tests__/CronView.test.tsx` | component tests |

### Modified files

| File | Change |
|---|---|
| `src/Seal/Cron/Types.hs` | `computeNextFire` made total; export the tz validator |
| `src/Seal/Cron/Operations.hs` | (new) shared create/update/enable/delete + tz validation |
| `src/Seal/ISA/Ops/Cron.hs` | delegate to the shared module; drop the duplicated `dedupSlug` |
| `src/Seal/Gateway/API.hs` | 2 `ApiDeps` fields; 6 cron routes + handlers; the gateway-wide write-origin check |
| `src/Seal/Command/Serve.hs` | wire `adCronStore = bCronStore backends` + the derived origin list |
| `src-gateway-types/Seal/Gateway/Types/Route.hs` | 6 `SealRoute` constructors + `routeMeta` arms + `allRoutes` entries + `CronJobIdOrErr` capture |
| `src/Seal/Gateway/OpenApi.hs` | 6 `openApiMeta` arms |
| `frontend/src/types.ts` | cron types |
| `frontend/src/hooks/useApi.ts` | cron fetch/create/update/delete + `useCronJobs` |
| `frontend/src/components/TopBar.tsx` | `cron` section between `repos` and `secrets` |
| `frontend/src/App.tsx` | `/cron` route + render branch |
| `test/Seal/Gateway/ApiSpec.hs` | cron API tests + 28 `ApiDeps` literal updates |
| `test/Seal/Gateway/ApiRouteSpec.hs` | `expectedRouteCount` 60 → 66 |
| `seal-harness.cabal` | one `exposed-modules:` line (`Seal.Cron.Operations`) + one test `other-modules:` line |
| `test/Main.hs` | one import + one spec registration |

`seal-harness.cabal` and `test/Main.hs` are merge hotspots; both edits are a
single line each and land in the same commit as the new module.

## 8. Definition of done

- [ ] `Cron` appears in the top bar between `Repos` and `Secrets`.
- [ ] Clicking it opens a list of cron jobs with schedule, enabled state, and
      consecutive-failure count.
- [ ] The operator can create a job with name / schedule / prompt /
      timezone / agent-def; it appears in the list, **disabled by default**.
- [ ] The operator can enable / disable a job as a distinct action; the list
      reflects it.
- [ ] The operator can edit a job's fields and save.
- [ ] The operator can delete a job, with a confirmation step.
- [ ] Selecting a job shows its next fire time and recent run history
      (newest first, with status and error).
- [ ] An invalid schedule / timezone / name / prompt / agent-def is rejected
      inline with a message naming the field; nothing is silently discarded.
- [ ] A malformed job id in the URL yields 400, never a store call.
- [ ] A request body carrying `run_count` / `created_at` / an unknown field
      is rejected, not silently accepted or ignored.
- [ ] An oversized request body is rejected.
- [ ] A cross-origin state-changing request to any `/api/*` endpoint is
      rejected with 403; the same-origin SPA still works.
- [ ] An unknown timezone is a 400 with a readable message, and cannot enter
      the store by either path.
- [ ] `make check` green; frontend `vitest run` green; `hlint` reports
      "No hints".

## 9. Rev 2 changelog (round-1 review findings, all verified against the code)

| # | Finding | Resolution |
|---|---|---|
| 1 | Rev 1 claimed "an agent cannot create an auto-enabled job". **False** — `authorizeCronManage`'s `CaCreate` never rejects `enabled: true`. | D3: the web UI also creates disabled by default; the claim is withdrawn. |
| 2 | The spec's operator-approval model (`cjApproved`) is **not implemented** — no such field; `enable` is not session-gated; `cronManageOp` ignores its `SessionId`. | T2 restated honestly; D3 moves the web path toward the spec's model. |
| 3 | Rev 1 claimed the cron-spawn blocklist and `AckRequired` autonomy were existing mitigations. **Neither is** — `cronSpawnBlocklist` is referenced nowhere in `src/`, and `AutonomyLevel` has no `AckRequired` constructor. | T2 restated; the gap is listed as out of scope and is a precondition for wiring the fire delegate. |
| 4 | Rev 1's Origin check, using raw `gcAllowedOrigins`, would **reject the operator's own UI at `127.0.0.1:8080`** (the default bind). | D9: reuse the WS guard's *derived* list (`httpOrigins <> gcAllowedOrigins`). |
| 5 | Copying the WS wildcard rule (empty allowlist = accept any) to REST would **disarm the defence** exactly when the API is most exposed. | D9: the REST check fails **closed**. |
| 6 | A cron-only Origin check leaves `POST /api/sessions/:id/send` (full agent turn) and the vault-writing endpoints open. | D9: the check is gateway-wide. |
| 7 | Cross-origin **reads** were also open; the SPA is same-origin so cron needs no CORS. | T1: noted; the gateway-wide check covers the write path, and the read path is called out in the follow-up. |
| 8 | The DoD required run history but the API surface had **no runs endpoint**. | §4 adds `GET /api/cron/:id/runs`; route count 60 → 66. |
| 9 | `consecutive_failures` was missing from the list summary, though the poll's stated purpose was to reveal failures. | D5: added to the summary. |
| 10 | The API create path had **no slug dedup** — it would overwrite a colliding job. `dedupSlug` was private to the opcode. | D2: a shared `Seal.Cron.Operations` module owns dedup for both paths. |
| 11 | No rate limiting and no body-size cap; every write spawns 2 git subprocesses. | D8: body-size cap + the store's own caps. |
| 12 | `agent_def_id` was unvalidated (raw `Text`). | D8: validated with `mkAgentDefId`. |
| 13 | Mass assignment via `FromJSON CronJob` (`run_count`, `created_at`, …). | D8: a dedicated input record. |
| 14 | Origin-violation status code was inconsistent (400 in the test plan, 403 in the DoD). | D8: 403. |
| 15 | DNS rebinding needs a Host check, not just Origin. | D9: Host check included. |
| 16 | The REST path bypasses the Audited ISA layer, so UI changes are not in the audit log. | T9: recorded; the git audit-commit is the compensating record. |
| 17 | An unhandled exception in `computeNextFire` **kills the scheduler thread** — all cron scheduling stops. Rev 1 understated this as "crashes the handler". | D4: the totality fix is a blocker; validation is at the write boundary on both paths. |
| 18 | Deleted jobs' prompts persist in the config repo's git objects. | T6: recorded. |
| 19 | Rev 1's D9 mis-stated the frontend polling precedent (`useRepos`/`useSecrets`/`useAgentDefs` are WS-driven, not interval-polled). | D11 corrected to the `useHarnesses` shape. |
| 20 | Rev 1's route count was internally inconsistent (65 vs 66). | Consistent at 66. |
| 21 | Rev 1's D4 proposed a per-request zone memo that memoises nothing (the detail view returns one job). | D5: memo dropped. |
| 22 | Rev 1 proposed a "per-request timezone memo" in `Seal.Cron.Store` — the store is a record of IO functions with no request scope. | D5: no store change; the detail view loads the zone once. |
