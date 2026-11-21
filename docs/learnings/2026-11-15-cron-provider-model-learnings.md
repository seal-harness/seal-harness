# Cron provider/model overrides — learnings (2026-11-15)

Branch `cron/cron-provider-model`. Adds optional `provider`/`model` to cron
jobs; the Cron editor reuses the "Start a new tab" provider select and model
combobox.

## What the plan review gate caught

Three iterations, three FAILs, every finding real.

**1. Work-unit file scopes that cannot compile.** Adding a record field and
changing a function's arity breaks *full record literals* and *positional call
sites* across `src/` **and** `test/`. `-Wall -Werror` implies
`-Wmissing-fields`, and the test suite does `import: settings`, so test code is
held to library standard. `test/Seal/Cron/StoreSpec.hs` and
`test/Seal/Cron/SchedulerSpec.hs` were in no work unit at all, which made WU-1
and WU-2 circularly dependent.

*Lesson:* before splitting work units, `grep` every construction site of the
type in `src/ test/ exe/` and put all of them in the unit that adds the field.

**2. A justification built on a failure path that does not exist.** The plan
claimed an unconfigured provider would land in cron run history as `CrFailed`,
auto-disable after five failures, and notify a human. None of that happens:
`csFireDelegate` returns `Right sid` (`src/Seal/Command/Serve.hs:361`) *before*
provider resolution, which happens inside the forked turn via `sdResolve`.
`CrFailed` is written only when the delegate itself returns `Left`, and it
returns `Left` only when `sendDeps` is uninitialised. `csNotifyHuman` is
`\_msg -> pure ()` in the gateway.

*Lesson:* verify a claimed failure path by finding who *writes* the failure
record, not who could theoretically fail.

**3. Invented limits, and a UI rule that re-broke the requirement.** A
258-character model cap whose derivation was wrong (256 + the 14-character
`[...truncated]` suffix = 270; and `smModel` has no cap at all, so cron would
have been stricter than every other session). Separately, the frontend DoD
seeded the model from the provider's `defaultModel` when a provider was picked
— persisting a model the operator never chose and defeating "if not supplied
use Seal's configured default model".

*Lesson:* an empty optional field must stay empty. Never auto-fill an optional
field to be helpful.

The gate also caught a manual verification step instructing the operator to
"click Trigger" on the Cron page. There is no trigger control, no trigger
route, and no client call — trigger is opcode-only (`CRON_MANAGE
action=trigger`).

## Decisions that survived

- **`Maybe Text` plus `""`-means-clear** for `PUT`; absent or `null` means
  unchanged. `.:?` cannot distinguish absent from `null`, so `""` is the only
  way a form can express "I emptied this field". This is scoped to the two new
  fields: `cuTimezone` and `cuAgentDefId` keep `Nothing` = unchanged and in fact
  *reject* `""` in their validators.
- **Validate the provider on both writes.** Create-only validation is a
  smuggling hole — `updateJobValidated` already applies create's validators to
  supplied fields, so the update path must too.
- **Extract the pure merge** (`applyUpdate` / `applyTriState` in
  `Seal.Cron.Operations`). Aligning a nested `let` inside three levels of `case`
  is unreadable; the original attempt failed to parse twice.
- **Provider existence is not validated at write time.** `Seal.Cron.Operations`
  is shared by the opcode and the gateway and holds no config handle. A
  syntactically valid but unconfigured name fails inside the session turn and
  does not auto-disable the job. Documented honestly rather than overclaimed.
- **Do not hoist `Row` / `inputStyle` between the two forms.** `NewTabComposer`'s
  `Row` centres its content and takes no `hint`; `CronView`'s takes `hint` and
  aligns to start. Sharing them forces a visual change at one site. Share only
  what is identical (`CustomModelCombobox`, `ProviderSelect`).

## Frontend gotcha (found in self-review; the review subagent timed out)

`{provider === '' ? <input value="" disabled/> : <Combobox/>}` hid a stored
model even though the submit body still sent it — display disagreed with
behaviour. Fixed to `value={model} readOnly disabled`.

*Lesson:* a disabled control must still display the value the form will submit.

## Test-side notes

- Every `ApiDeps` in `test/Seal/Gateway/ApiSpec.hs` sets
  `adCronStore = stubCronStore`, whose methods all `error`. To test cron CRUD,
  build deps with `mkDepsFor` and then record-update
  `base { adCronStore = store }` with a `memoryCronStore`. `adCronStore` is a
  plain exported field, so no new harness helper is needed.
- The `vi.mock('../../hooks/useApi')` factory in `CronView.test.tsx` is a
  whole-module mock: any new hook or function the component calls must be added
  to it or the render throws.
- Bulk-editing Haskell record literals with a regex is a trap — it mangled
  `OperationsSpec.hs` twice (double-inserted fields, then under-inserted
  arity). Sequential `python` `str.replace` with an asserted match count, one
  edit at a time, is the reliable path.
