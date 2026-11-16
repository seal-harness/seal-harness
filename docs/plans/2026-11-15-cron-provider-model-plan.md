# Plan — Per-job provider + model for cron jobs (revision 4)

<!-- rev 4: fixes round-3 blocking findings -->

## What changed in revision 4

| Round-3 finding | Fix |
| --- | --- |
| `updateJob` never validates the provider, while `createJob` does — an update could smuggle in `"../seal"`, contradicting D1 and the existing invariant that update applies create's validators (`src/Seal/Cron/Operations.hs:117-128`) | WU-1 DoD 4 now requires `updateJob` to validate a supplied provider with `isProviderName` and reject it, with two tests (REST `PUT` ⇒ `400`, opcode `update` ⇒ error result). The API contract states `PUT` can now `400` on a bad provider. |
| WU-2's only verification was "click Trigger", but `CronView` has no trigger control (`:198-207`, `:459-516`), there is no trigger route (`src-gateway-types/.../Route.hs:175-179`) and no client call (`useApi.ts:1734-1786`) | Replaced with a real affordance. Two paths, both stated as manual: (a) drive `CRON_MANAGE {"action":"trigger","id":…}` — an existing, tested opcode (`src/Seal/ISA/Ops/Cron.hs:243`, `test/Seal/ISA/Ops/CronSpec.hs`) — from a `seal tui` session; (b) create a job on a `* * * * *` schedule and inspect the session the scheduler spawns within ~1 minute. The residual gap is labelled as a gap, not as covered. |
| WU-3 DoD 4 seeded the model from the provider's `defaultModel` and DoD 5 then always sent both — re-introducing the provider-default rule rev 3 removed, and persisting a model the operator never chose so the job stops following Seal's configured default | Model is **never** auto-seeded. Selecting a provider leaves the model at whatever the operator typed (empty by default) with placeholder `(use configured default)`; an empty model submits **no** `model` key, so the backend resolves Seal's configured default model. Nothing is pinned that the operator did not type. |
| `ProviderSelect`'s no-providers / loading / label state unspecified; `PROVIDER_LABELS` is module-local to `NewTabComposer.tsx:10-15` | WU-3 DoD 3 enumerates every state: `Loading…`, `(no providers configured — set an API key or start Ollama)`, `(use configured default)`, ` (default)` suffix, and `"<id> (missing)"`; `PROVIDER_LABELS` moves into the shared module. Each has a test. |
| D4 blessed `(provider = Nothing, model = Just x)` as meaningful while the UI makes it unreachable | D4 deleted. The fields are stored independently and no semantics are claimed for the combination; the UI simply only enables the model control once a provider is chosen. No contradiction to test. |
| Provider chosen with no default model, or an empty/failed model fetch, left the send-behaviour ambiguous (`ProviderInfo.defaultModel` is optional, `types.ts:257-259`) | Resolved by the same change: an empty model always submits no `model` key. Empty fetch and missing `defaultModel` therefore behave identically and are covered by one test. |

## User request (verbatim)

> The Cron page allows you to specify the agent that will be used for the cron
> job. Let's add the ability to specify a specific provider and model as well.
> These should be optional and if not supplied should use Seal's configured
> default provider and model. In the Cron UI, let's use the same provider and
> model controls that we currently use in the `Start a new tab` form.

## Scope

**In:**

- `CronJob` gains optional `provider` and `model` (`Maybe Text`, `.:?`).
- `CRON_MANAGE` create/update/read and `POST|PUT /api/cron` accept, validate,
  store and return them.
- The fire delegate honours them, falling back to today's chain when absent.
- The Cron form renders the same provider `<select>` and model combobox as the
  "Start a new tab" form, via two shared components.

**Out:**

- Any change to how defaults are computed for anything other than cron jobs —
  including the agent-def branch of the fire delegate, which keeps today's exact
  expressions.
- A model length cap; model-without-provider normalisation; provider-existence
  checks beyond the syntactic one available at the write boundary.
- `NewSessionComposer.tsx` (its duplicate combobox predates this change).
- Any change to `~/.seal/`. No new opcode, route, trust level or capability.

## Current behaviour (verified evidence)

- `CronJob` `src/Seal/Cron/Types.hs:158-170` (`cjAgentDefId`, no
  provider/model); `ToJSON` `:174-189`; `FromJSON` `:191-213`.
- Fire delegate `src/Seal/Command/Serve.hs:340-361`: `resolveDefaultAgent`
  `:349`; `defaultSessionSelection cronCfg` `:350`; agent-def id `:351-355`;
  `provider = fromMaybe cfgProv mProv` `:356`; `model = fromMaybe cfgModel
  mModel` `:357`; `newSession paths provider model "cron" mJobAgent` `:358`;
  `void (forkIO (void (handleSend …)))` `:360`; `Right sid` `:361`.
  Provider resolution happens later inside the forked turn via
  `sdResolve = resolveSessionProvider` (`Serve.hs:514`,
  `src/Seal/Command/Provider.hs:350`).
- `CrFailed` is written only when the delegate returns `Left`
  (`src/Seal/Cron/Scheduler.hs:130` `fireJob`, `:148`, `:152`); the delegate
  returns `Left` only when `sendDeps` is uninitialised (`Serve.hs:343`).
  `csNotifyHuman` is `\_msg -> pure ()` (`Serve.hs:377`).
- `createJob`/`updateJob`/`setJobEnabled`/`deleteJob`
  `src/Seal/Cron/Operations.hs:40-160`, shared by the opcode
  (`src/Seal/ISA/Ops/Cron.hs:95`, `:142-156`) and REST
  (`src/Seal/Gateway/API.hs:920`, `:960`). `updateJobValidated` applies
  create's validators to supplied fields (`Operations.hs:117-128`).
- Cron JSON: `cronJobSummaryJson`/`cronJobDetailJson` `API.hs:979-1016`;
  `CronCreateInput`/`parseCronCreateInput` `:1017-1040`;
  `parseCronUpdateInput` `:1042-1060`.
- `renderJob` `src/Seal/ISA/Ops/Cron.hs:328-341`; `authorizeCronManage`
  `:249-283`; the `CaTrigger` arm at `:243`, exercised by
  `test/Seal/ISA/Ops/CronSpec.hs`.
- `isProviderName :: Text -> Bool` `src/Seal/Providers/Registry.hs:127-130`.
- `ModelId` is `newtype ModelId = ModelId Text`
  (`src-gateway-types/Seal/Gateway/Types/Core.hs:39`); `newSession` takes
  `Text` (`src/Seal/Session/Store.hs:103`).
- Existing independent provider/model fallback `src/Seal/Session/Store.hs:283-290`.
- "Start a new tab" controls: provider `<select>` `NewTabComposer.tsx:173-195`
  (incl. `Loading…` `:184` and no-providers option `:185-187`);
  `PROVIDER_LABELS` `:10-15`; model row `:197-207`; `CustomModelCombobox`
  `:507-624`; `Row` `:481-492`; `inputStyle` `:466-478`.
- `useNewTabSpec.ts:253-258` model suggestions; `fetchProviderModels` returns
  `[]` on any failure (`useApi.ts:755-758`); `useConfiguredProviders`
  `useApi.ts:718`.
- `CronView` local `Row` `:35-52`, `inputStyle` `:20-33`, agent picker
  `:360-410` (loading `:379`, `(missing)` `:394-403`), buttons `:198-207`,
  `:456-516`. `CronView.test.tsx`: mock factory `:25-42`, `makeJob` `:46-61`.
- Every `ApiDeps` in `test/Seal/Gateway/ApiSpec.hs` sets
  `adCronStore = stubCronStore` (`:550-558`), which `error`s on every method.

## Design decisions

**D1 — Plain `Maybe Text`, validated on both writes.** `createJob` and
`updateJob` both run `isProviderName`, so neither surface can store an
injection-shaped name (`../seal`, uppercase, leading dash). Neither can detect a
syntactically valid but *unconfigured* provider, because `Seal.Cron.Operations`
holds no config handle and is shared by surfaces with different runtime
contexts.

**D2 — What actually happens with an unconfigured provider (stated, not
overclaimed).** The delegate returns `Right` at `Serve.hs:361` before provider
resolution; `"unknown provider in session: <name>"` surfaces in the spawned
session's transcript, exactly as for any other session. The run is recorded
`CrRunning`, the job is **not** auto-disabled, and `csNotifyHuman` is a no-op.
Pre-existing behaviour of the cron fire path; neither introduced nor fixed here.

**D3 — Field-wise fallback, exactly the request's words.** At `Serve.hs:356-357`:

```haskell
provider = fromMaybe (fromMaybe cfgProv mProv) (cjProvider job)
model    = fromMaybe (fromMaybe cfgModel mModel) (cjModel job)
```

Job field wins; else the agent-def override; else the configured default. A job
setting neither resolves bit-for-bit as today, and every other session-minting
path is untouched. No provider-default-model rule, and the frontend never
auto-fills a model either (see D6).

**D4 — On PUT: absent/`null` = unchanged, `""` = clear, string = set.** With
`Maybe Text` and `.:?`, absent and `null` are indistinguishable and both mean
"not supplied"; `""` is the only way the form can express "the operator emptied
this field". Local to `cuProvider`/`cuModel`; their neighbours
`cuTimezone`/`cuAgentDefId` cannot be cleared this way today and are unchanged.

The two fields are stored independently. No claim is made about a `model` with
no `provider` beyond "it is stored and used against whatever provider resolves";
the UI simply leaves the model input disabled until a provider is chosen.

**D5 — Only the two controls are shared.** New
`frontend/src/components/ProviderModelFields.tsx` exports
`CustomModelCombobox` (moved verbatim from `NewTabComposer.tsx:507-624`),
`ProviderSelect` (the `<select>` from `:173-195`, with `PROVIDER_LABELS` moved
from `:10-15`), and its own copy of `inputStyle` (`NewTabComposer.tsx:466-478`).
`Row` and `inputStyle` stay per-site, because the two `Row`s genuinely differ
(`NewTabComposer.tsx:481-492` centres and takes no `hint`; `CronView.tsx:35-52`
takes `hint` and aligns to start). `NewTabComposer`'s rendered DOM is therefore
unchanged.

`ProviderSelect` props: `id`, `value`, `onChange`, `disabled`, `loading`,
`noProviders`, `showDefaultOption`, `providers` (each with `name`, `isDefault`,
`configured`), and `extraOptions` (for a synthetic `(missing)` entry). It
renders, in order: `Loading…` when `loading`; the no-providers notice when
`noProviders`; `(use configured default)` when `showDefaultOption`; any
`extraOptions`; then one option per configured provider labelled
`PROVIDER_LABELS[name] ?? name` with a ` (default)` suffix when `isDefault`.

## API contract

### `POST /api/cron` (route unchanged, body widened)

```jsonc
{
  "name": "Daily", "schedule": "0 9 * * *", "prompt": "…",
  "timezone": "America/New_York",   // optional
  "agent_def_id": "coder",          // optional
  "provider": "anthropic",          // NEW optional; "" = absent
  "model": "claude-opus-4-8",       // NEW optional; "" = absent
  "enabled": false, "one_shot": false
}
```

`201` → detail JSON. `400 {"error": …}` when a supplied provider fails
`isProviderName`; all other validation unchanged.

### `PUT /api/cron/:id` (route unchanged)

All fields optional. `provider`/`model`: key absent or `null` = unchanged;
`""` = clear; string = set (D4). `200` → detail JSON. `400 {"error": …}` when a
supplied provider fails `isProviderName` — **new** for this route, and stated
here so the contract is not overclaimed as "unchanged".

### `GET /api/cron`, `GET /api/cron/:id`

Every job object gains `"provider": string | null` and
`"model": string | null`.

### `CRON_MANAGE`

`toInSchema.properties` gains `provider` and `model` (`"type": "string"`,
described as optional overrides of the configured default); `create` and
`update` accept them (both validating the provider), `read` echoes them via
`renderJob`, and `authorizeCronManage` counts them toward "update requires at
least one field".

## Work units

Each unit ends with `make check` (build + `cabal test` + `hlint` + `npm test`)
green on its own.

### WU-1 — Backend: the fields exist end to end

*Files:* `src/Seal/Cron/Types.hs`, `src/Seal/Cron/Operations.hs`,
`src/Seal/ISA/Ops/Cron.hs`, `src/Seal/Gateway/API.hs`,
`test/Seal/Cron/TypesSpec.hs`, `test/Seal/Cron/OperationsSpec.hs`,
`test/Seal/Cron/StoreSpec.hs`, `test/Seal/Cron/SchedulerSpec.hs`,
`test/Seal/ISA/Ops/CronSpec.hs`, `test/Seal/Gateway/ApiSpec.hs`

Why one unit: adding fields to `CronJob`/`CronUpdate` and two parameters to
`createJob` breaks every full record literal and positional call under
`-Wall -Werror` (`-Wmissing-fields`) — `src/Seal/ISA/Ops/Cron.hs:95`,
`:142-156`; `src/Seal/Gateway/API.hs:920`, `:1058-1060`;
`test/Seal/Cron/StoreSpec.hs:23-38`; `test/Seal/Cron/SchedulerSpec.hs:28-41`;
`test/Seal/Cron/OperationsSpec.hs:53-233`. All are inside this unit's file list.

DoD:

1. `CronJob` has `cjProvider`, `cjModel :: !(Maybe Text)`; `ToJSON` emits
   `provider`/`model`; `FromJSON` uses `.:?`. Test: an object without the keys
   decodes with both `Nothing`.
2. Encode→decode round-trip preserves both fields for `Just` and `Nothing`.
3. `createJob` takes `Maybe Text` provider and model, validates the provider
   with `isProviderName`, treats `Just ""` as absent. Tests: accept,
   reject (`"../seal"`, `"Not A Provider"`), `""`-as-absent.
4. `CronUpdate` has `cuProvider`/`cuModel :: Maybe Text`. `updateJob`:
   (a) leaves them unchanged on `Nothing`; (b) clears on `Just ""`; (c) sets on
   `Just x`; (d) **rejects a supplied invalid provider** with `Left` naming the
   field — same validator as create (D1, `Operations.hs:117-128` precedent);
   (e) a clear leaves every other field untouched. Five tests.
5. `CRON_MANAGE create` stores both and `read` echoes them (`renderJob` gains
   two lines). `create` with `provider = "../seal"` returns an error result.
   `update` sets, `""`-clears, and rejects `provider = "../seal"`. Four tests in
   `test/Seal/ISA/Ops/CronSpec.hs`.
6. `cronJobSummaryJson`/`cronJobDetailJson` emit both keys (`null` when unset);
   `CronCreateInput`/`parseCronCreateInput`/`parseCronUpdateInput` carry them.
   REST tests, built as `deps <- mkDepsFor paths; store <- memoryCronStore; let
   deps' = deps { adCronStore = store }` (`adCronStore` is a plain exported
   record field, so no new helper is needed): POST with provider+model ⇒ `201`
   echoing both; GET list shows both; PUT `"provider": ""` ⇒ `200` with
   `provider: null` and `model` untouched; PUT omitting both keys leaves stored
   values unchanged; POST with `"provider": "Not A Provider"` ⇒ `400`; PUT with
   `"provider": "Not A Provider"` ⇒ `400`. Six tests in
   `test/Seal/Gateway/ApiSpec.hs`.
7. `test/Seal/Cron/StoreSpec.hs` and `test/Seal/Cron/SchedulerSpec.hs` literals
   gain the two fields as `Nothing`; existing tests otherwise unchanged.
8. `make check` green.

### WU-2 — Fire wiring

*Depends on:* WU-1. *Files:* `src/Seal/Command/Serve.hs`

DoD:

1. `Serve.hs:356-357` become the two nested `fromMaybe`s of D3, reading
   `cjProvider job` / `cjModel job`. Nothing else in the delegate changes
   (agent-def id `:351-355`, `newSession` `:358`, `forkIO handleSend` `:360`,
   `Right sid` `:361`).
2. `make check` green.
3. Manual verification — **stated as a residual gap, because it is one.** The
   Cron page has no trigger control and there is no trigger route, so this
   cannot be checked by clicking. Two executable procedures:
   (a) from a `seal tui` session, have the agent run
   `CRON_MANAGE {"action":"trigger","id":"<job-id>"}` (an existing opcode,
   covered by `test/Seal/ISA/Ops/CronSpec.hs`), then read the spawned
   `<session>/session.json` and confirm `provider`/`model`;
   (b) create a job on `* * * * *`, wait one tick, and inspect the session the
   scheduler spawns.
   Repeat both with no provider and no model set, and confirm the configured
   defaults appear. An automated test would need an injectable `newSession` seam
   in `runServeMainInner`; that refactor is out of scope for this change and is
   recorded as such rather than claimed as covered.

### WU-3 — Frontend

*Depends on:* WU-1 (JSON field names only).
*Files:* `frontend/src/components/ProviderModelFields.tsx` (new),
`frontend/src/components/NewTabComposer.tsx`,
`frontend/src/components/CronView.tsx`, `frontend/src/types.ts`,
`frontend/src/components/__tests__/CronView.test.tsx`

DoD:

1. `ProviderModelFields.tsx` exports `CustomModelCombobox` (verbatim from
   `NewTabComposer.tsx:507-624`), `ProviderSelect` (per D5, with
   `PROVIDER_LABELS` moved from `:10-15`), and `inputStyle` identical to
   `:466-478`.
2. `NewTabComposer` imports them and drops its local copies; its rendered DOM is
   unchanged (same ids, same `provider-model-list` testid, same classes), and
   `NewTabComposer.test.tsx` passes **unmodified**.
3. `CronView` renders `ProviderSelect` (`id="cron-provider"`) inside its
   existing `Row`, with `showDefaultOption` (label `(use configured default)`),
   and keeps an unresolvable stored provider selectable as `"<id> (missing)"`
   via `extraOptions` — mirroring the agent picker at `CronView.tsx:379,394-403`.
   Tests: option list and `(default)` suffix; `Loading…` before
   `providersLoaded`; `(no providers configured …)` when the list is empty;
   `(missing)` preserved for a stored provider that no longer resolves.
4. `CronView` renders `CustomModelCombobox` (`id="cron-model"`) fed by the
   selected provider's configured `models`, else `fetchProviderModels`, tracking
   a `modelsLoading` flag and ignoring a response for a provider that is no
   longer selected (a `cancelled` guard, as `useNewTabSpec.ts:217-259` does). It
   is disabled, with placeholder `(use configured default)`, while no provider
   is selected. **The model is never auto-filled or seeded**: selecting a
   provider does not change the model value, and clearing the provider clears
   it. Tests: disabled-with-no-provider; selecting a provider does *not* change
   the model; clearing the provider clears it; an empty fetch
   (`fetchProviderModels` returns `[]` on failure) still allows free-text entry.
5. Create omits `provider`/`model` entirely when no provider is chosen
   (`body.provider === undefined`). When a provider is chosen, `provider` is
   sent and `model` is sent **only if the operator typed one** — an empty model
   sends no `model` key, so the backend resolves Seal's configured default model
   (D3). Two tests, one per branch.
6. Edit seeds both fields from the job; saving without touching them resends the
   stored values (including a `(missing)` provider id); clearing the provider
   sends `provider: ""` (D4) with the model cleared in the same submission.
   Three tests.
7. `types.ts`: `CronJobSummary`/`CronJobDetail` gain `provider: string | null`,
   `model: string | null`; `CronJobInput`/`CronJobUpdateInput` gain
   `provider?: string | null`, `model?: string | null`. `makeJob` in
   `CronView.test.tsx:46-61` gains both as `null`.
8. The `vi.mock('../../hooks/useApi')` factory at `CronView.test.tsx:25-42`
   gains `useConfiguredProviders` and `fetchProviderModels`.
9. `make check` green (includes `tsc` via `npm run build` and `npm test`).

## Verification

- `make check` after every unit. `.coverage-thresholds.json` records that HPC is
  not wired into this repo; its enforcement command is `make test`, which must
  pass.
- Automated coverage: WU-1 covers the type, both write paths (create and update,
  including provider rejection on each), both JSON shapes, the opcode surface,
  and `renderJob`.
- Manual-only, explicitly labelled: WU-2's fire wiring, via the two procedures in
  WU-2 DoD 3. This is the honest extent of verification for the delegate line
  changes; it is not presented as automated.

## Security considerations

- No new opcode, trust level, capability, subprocess or file path. The fields
  live in the same `config/cron/jobs/<id>.json` (mode 0600, committed to the
  config repo) that already holds the prompt.
- `provider` passes through `isProviderName` on **both** create and update, and
  is never interpolated into a command, URL or path. `model` is an opaque label
  passed to the provider client exactly as `smModel` already is; `smModel` has no
  length cap and this change adds none.
- No secret enters either field; credentials stay in the vault and are resolved
  per turn by `resolveSessionProvider`.
- D2 states the residual risk accurately: a syntactically valid but
  unconfigured provider fails inside the session turn, not at write time, and
  does not auto-disable the job.
- Nothing here reads or writes under `~/.seal/`.

## Backward compatibility / rollback

- Old `config/cron/jobs/*.json` decode with both fields `Nothing`, and because
  D3 leaves the agent-def and config branches untouched, a job setting neither
  field resolves and fires exactly as it does today.
- Rollback: `FromJSON` ignores unknown keys, so files written by the new build
  still *decode* in the old build — but the old build re-encodes job files from
  `ToJSON` on its next write (`src/Seal/Cron/Store.hs:60-72`), which drops the
  stored `provider`/`model`. Reverting therefore loses those values on the first
  subsequent job write. No migration or schema version bump either way.

## Human checkpoints

- **After WU-3, before opening the PR**: report the Cron form change and confirm
  the operator wants a PR opened — this repo's convention is `Closes #NN` and
  there is no issue for this request yet.
