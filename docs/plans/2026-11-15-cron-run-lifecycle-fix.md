# Plan — Fix the cron run lifecycle (revision 3)

<!-- rev 3: fixes round-2 gate findings -->

## Round-2 findings → fixes

| Finding | Fix |
| --- | --- |
| **My race fix was broken.** `csUpdateRun` keyed on `crSessionId`, but the pre-fire `Pending` row has `crSessionId = ""`, so a fast completion matches nothing and no-ops; the later `CrRunning` write then re-wedges. | `csUpdateRun :: CronJobId -> (CronRun -> CronRun) -> IO ()` — keyed on **job id**, updating the newest run row. Overlap protection guarantees at most one in-flight run per job, so "newest row" is unambiguous and needs no session id. |
| **Two writers race on one JSONL** with whole-file read-modify-write and no lock → lost updates recreate the wedge. | `CronStore` gains a store-wide `MVar`; `csRecordRun`, `csUpdateRun` and the job writers serialize through it. `csUpdateRun` is read-modify-write **inside** the lock. |
| **A single-slot `IORef` cannot hold per-fire handlers** (up to 5 concurrent fires). | `Serve.hs` holds `IORef (Map Text (Either Text () -> IO ()))`, keyed by session id, inserted before the turn can finish and deleted after it fires once. Not a single slot. |
| **`fireJob`'s post-delegate "set Running" clobbers a completion that already arrived.** | The transition is expressed as a `CronRun -> CronRun` function that is **idempotent and terminal-respecting**: it only moves `Pending → Running`; if the row is already `Completed`/`Failed` it is left alone. Tested directly. |
| `checkAutoDisableFor` referenced but never defined; `checkAutoDisable` is private and takes a `CronScheduler`. | WU-2 exports `checkAutoDisable :: CronStore -> Text -> UTCTime -> CronJob -> IO ()` (store + notify callback instead of the whole scheduler). WU-3 calls it; no undefined symbol. |
| `CRON_MANAGE action=trigger` also calls the fire delegate (`Isa/Ops/Cron.hs:179-197`) and writes no run row, so its completions vanish; that file is in no unit. | `src/Seal/ISA/Ops/Cron.hs` is added to WU-3's file list: `handleTrigger` records a `CrRunning` row before calling the delegate, so the same completion path applies. |
| No in-process backstop; a single lost completion re-wedges until restart. | Reinstate a **bounded staleness horizon** used only as a backstop: `isRunActive now r = status ∈ {Pending,Running} && now - crStartedAt < cronStaleAfterSeconds` (default 6h). It does **not** replace completion tracking (see below). |
| WU-2 DoD 7 ("completed rows are not counted") passes before the fix — verifies nothing. | Replaced: the test seeds five *wedged* runs, runs `reconcileStaleRuns`, and asserts the job then fires. That fails before the fix and passes after. |
| WU-2 DoD 6 unpassable with a fixed clock (`cjLastFire = now` makes the second tick not due). | DoD now specifies an advancing clock: fire at T, tick at T+120s. |
| WU-3 DoD 6's end-to-end test cannot run: the harness stubs `adCronStore`, sets `bCronFire = Nothing`, has no `CronScheduler`, and `Serve.hs`'s delegate is unreachable through its export list. | The end-to-end test is dropped as unimplementable **as specified** and replaced by a **delegate-level integration test**: a test-only `CronScheduler` built against a `memoryCronStore` with a delegate that records then completes, asserting the row reaches `CrCompleted`. This exercises scheduler + store + completion together, which is the whole bug. The remaining untested seam (`startPlainTurn` calling `sdTurnComplete`) gets a direct `SendSpec` unit test. Their composition is the manual check. |
| Fire-time rejection of `/`-leading prompts is an invented edge case, and at fire time it degrades into five silent `CrFailed` rows → auto-disable through a no-op notifier. | **Dropped** from the fire path. Moved to creation-time validation in `Seal.Cron.Operations.createJob` (where `name`/`prompt` are already validated), returning a `400` to the operator immediately instead of failing five times invisibly. |
| `sdTurnComplete` on `SendDeps` is disproportionate (8 literals, shared by web/TUI/Telegram/Signal). | **Retained, with justification** — see "Why the callback is still the choice" below. The 8 literals are enumerated and all are in WU-3. |

## Why the completion callback is still the choice (rejected alternatives, re-examined)

- **`sessionTurnInFlight` polling** (`Seal.Session.Lock:93-101`): rejected on two
  grounds. It returns `False` when no lock exists yet (`:97`), so a poll taken
  just after the fork records "done" before the turn even starts. And it cannot
  distinguish success from failure, so every run would be recorded
  `CrCompleted` — including one that failed to resolve a provider, which is the
  case most worth surfacing.
- **`tdOnTurnEnd`** (`TurnEngine.hs:457`): already owned by idle-wake
  (`Send.hs:299`), and its own Haddock says it does **not** fire on the
  provider-resolution early return (`:615-620`) — exactly the failure we must
  capture.
- **Bounded staleness horizon alone** (the reviewers' simpler proposal): I tested
  this reasoning and it does not hold. `countActiveRuns` fetches the newest **10**
  runs per job and counts every `Pending`/`Running` one (`Scheduler.hs:118-127`).
  A per-minute job that never completes accumulates ~360 rows inside a 6-hour
  horizon, so the counter stays above 5 and **every** job remains blocked. Making
  the horizon short enough to matter would silently change the firing cadence
  from every minute to once per horizon. The horizon is therefore kept only as a
  *backstop* on top of real completion tracking, never as the fix.

## Problem (verified)

`CrCompleted` is declared (`Types.hs:227`) and decodable (`:234`, `:243`), but
**no code writes it**. `Scheduler.hs` writes `CrRunning` (`:159`) and `CrFailed`
(`:148`); the `CrPending` base record at `:133-141` is never persisted.

Consequences (both reproduced with failing tests during the investigation):

1. A fired run stays `CrRunning` forever; `fireIfDue` (`Scheduler.hs:107-116`)
   skips that job as "overlapping itself" on every later tick — silently.
2. `countActiveRuns` (`:118-127`) counts those rows against
   `defaultMaxConcurrent = 5` (`:50`), so after five runs have ever fired,
   **all** jobs stop.

Why it survived: `SchedulerSpec.hs:135` asserts a successful fire leaves
`crStatus == CrRunning` — the test encodes the bug. The design doc's integration
test ("a `CronRun` is recorded with status `Completed` or `Failed`",
`2026-10-03-cron-manage-design.md:552`) was relaxed rather than fixed. Step
"(e) Async: when agent completes, update CronRun status" (`:351`) was never
implemented. `2026-10-22-cron-web-ui-design.md:186-200` separately flagged the
missing ticker exception handler, also never landed — the same pattern: a known
defect with no failing test behind it.

## Design

**D1 — One lock per store.** `CronStore` gains `csLock :: MVar ()`. Every
mutation (`csCreate`, `csSave`, `csDelete`, `csRecordRun`, `csUpdateRun`) takes
it. The file backend's read-modify-write of the JSONL is therefore atomic within
the process. (`seal serve` is single-process per `SEAL_HOME` — `claimSealHome`,
`Serve.hs:168` — so no cross-process lock is needed.)

**D2 — `csUpdateRun :: CronJobId -> (CronRun -> CronRun) -> IO ()`** updates the
**newest** run row for the job. Keyed by job, not session, so it works even when
the row has not yet been stamped with a session id.

**D3 — Persist before firing; terminal-respecting transitions.**
`fireJob`:
1. writes a `CrPending` row (the design doc's step (c), which the code skipped);
2. calls the delegate;
3. on `Right sid`, applies `markRunning sid`, which only transitions
   `Pending → Running`. If a completion already landed (`Completed`/`Failed`),
   `markRunning` leaves it alone.

`applyRunOutcome now outcome` sets `Completed`/`Failed` + `crEndedAt` (+ `crError`)
and is a no-op on an already-terminal row, so a duplicate callback cannot
regress a row.

**D4 — Per-fire completion handler, keyed by session id.**
`Serve.hs` owns `IORef (Map Text (Either Text () -> IO ()))`. The delegate
inserts `sid → handler` (closing over `CronJobId`) **before** forking the turn,
and the handler deletes its own entry after firing, so a later turn on the same
session cannot see a stale handler. `SendDeps.sdTurnComplete` looks the session
up in this map (no-op when absent), which is exactly why it can live on the
shared record: for non-cron sessions the map has no entry.

**D5 — Startup reconciliation is the backstop.** `reconcileStaleRuns :: CronStore
-> UTCTime -> IO Int` marks `Pending`/`Running` rows `CrFailed` ("reconciled at
startup…") and returns the count, logged when non-zero. Runs before the
scheduler forks, so a wedged store is repaired without manual intervention.

**D6 — Bounded staleness backstop.** `cronStaleAfterSeconds = 6 * 60 * 60` and
`isRunActive now r` (status active **and** started within the horizon) are used
by `fireIfDue` and `countActiveRuns`. Purpose: recover from a *lost* completion
while the process is up, without waiting for a restart. It cannot substitute for
D3/D4 (see above).

**D7 — Validate the prompt at creation.** `createJob` rejects a prompt starting
with `/` (`400`), instead of failing five times invisibly at fire time.

## Work units

Each ends with `make check` green; every construction site of an added field is
inside the unit that adds it.

### WU-1 — Store: lock + `csUpdateRun`, and all literals

*Files:* `src/Seal/Cron/Store.hs`, `test/Seal/Cron/StoreSpec.hs`,
`test/Seal/TestHelpers/ApiTestHarness.hs`, `test/Seal/Phase7aSpec.hs`,
`test/Seal/Gateway/ApiFilesSpec.hs`, `test/Seal/Gateway/PatIngestionSpec.hs`,
`test/Seal/Gateway/ServerSpec.hs`, `test/Seal/Gateway/SetupApiSpec.hs`,
`test/Seal/Gateway/MutationGuardSpec.hs`, `test/Seal/Gateway/ApiSpec.hs`

DoD:

1. `CronStore` has `csLock :: MVar ()` and `csUpdateRun :: CronJobId ->
   (CronRun -> CronRun) -> IO ()`; both backends implement them.
2. `csUpdateRun` updates the newest row for the job, preserving order and the
   100-run cap; file backend writes 0600 and `gitCommitAll`s.
3. A job with no runs, or an unknown job, is a no-op on both backends (no
   corruption, no commit) — tested.
4. Concurrent `csRecordRun`/`csUpdateRun` from many threads lose no update
   (test: N concurrent recordings + one update, assert the expected final state).
5. The 8 `stubCronStore` literals gain both fields.
6. `make check` green.

### WU-2 — Scheduler: ordering, transitions, reconciliation, staleness

*Depends on:* WU-1. *Files:* `src/Seal/Cron/Scheduler.hs`,
`test/Seal/Cron/SchedulerSpec.hs`

DoD:

1. `applyRunOutcome :: UTCTime -> Either Text () -> CronRun -> CronRun` exported;
   both branches tested; no-op on an already-terminal row (idempotent).
2. `markRunning :: Text -> UTCTime -> CronRun -> CronRun` exported; moves
   `Pending → Running`, leaves terminal rows untouched. Test: applying it after
   `applyRunOutcome` does **not** regress a `CrCompleted` row (this is the
   round-2 race, pinned by test).
3. `fireJob` writes the `CrPending` row before calling the delegate — test where
   the delegate inspects the store and sees its own `Pending` row.
4. Exactly **one** run row exists after a fire (no append-per-status).
5. `checkAutoDisable :: CronStore -> (Text -> IO ()) -> UTCTime -> CronJob -> IO ()`
   is exported; test: five consecutive `CrFailed` rows disable the job and invoke
   the notifier.
6. `cronStaleAfterSeconds` + `isRunActive` exported; boundary-tested; used by
   `fireIfDue` and `countActiveRuns`.
7. `reconcileStaleRuns` marks only `Pending`/`Running` rows `CrFailed`, returns
   the count, leaves terminal rows alone.
8. Regression — *"fires again on the next due tick"*: fire at T, tick at T+120s
   (advancing clock), assert two fires. Fails before the fix.
9. Regression — *"a wedged store resumes after reconciliation"*: seed five
   `CrRunning` rows, run `reconcileStaleRuns`, tick, assert the job fires.
   Combined with DoD 5 this is the "all jobs blocked" scenario, and it fails
   before the fix.
10. `CronScheduler` gains no field, so its 7 test literals and `Serve.hs:370`
    are untouched (verified).
11. `make check` green.

### WU-3 — Wiring: deliver completion, repair the store, validate prompts

*Depends on:* WU-2. *Files:* `src/Seal/Gateway/Send.hs`,
`src/Seal/Command/Serve.hs`, `src/Seal/ISA/Ops/Cron.hs`,
`src/Seal/Cron/Operations.hs`, `test/Seal/Gateway/SendSpec.hs`,
`test/Seal/TestHelpers/ApiTestHarness.hs`, `test/Seal/Gateway/ApiSpec.hs`,
`test/Seal/ISA/Ops/CronSpec.hs`, `test/Seal/Cron/OperationsSpec.hs`

DoD:

1. `SendDeps` gains `sdTurnComplete :: SessionId -> Either Text () -> IO ()`,
   with all 8 literals edited (D4 of rev 2 lists them).
2. `startPlainTurn` invokes it exactly once per turn for every outcome,
   including the thrown-turn branch, and never on paths that start no turn.
   Test with a recording callback: success ⇒ one `Right`; failing ⇒ one `Left`;
   slash ⇒ zero.
3. `Serve.hs`: `IORef (Map Text handler)` installed before the fork and deleted
   by the handler after one use; `sdTurnComplete` dispatches through it; a
   non-cron session (no map entry) is a no-op.
4. `Serve.hs` runs `reconcileStaleRuns` once before the scheduler forks and logs
   a non-zero count.
5. `handleTrigger` in `ISA/Ops/Cron.hs` records a `CrRunning` row before calling
   the delegate, so trigger-fired runs complete like scheduled ones.
6. `createJob` rejects a `/`-leading prompt (`400` at the API, error result on the
   opcode). Tests on both surfaces.
7. **Delegate-level integration test**: a `memoryCronStore` + a `CronScheduler`
   whose delegate records the run then invokes the completion callback; assert
   the stored run ends `CrCompleted` with `crEndedAt` set. This is the end-to-end
   assertion the previous attempt lacked.
8. `make check` green.

## Verification

- Regression tests from the investigation are permanent (WU-2 DoD 8, 9).
- WU-3 DoD 7 is the scheduler→store→completion integration gate.
- The only seam not covered by an automated test is
  `startPlainTurn → sdTurnComplete` in composition with the real `Serve.hs`
  delegate (it is unit-tested on each side). Manual: `seal serve`, a
  `* * * * *` job, confirm `config/cron/runs/<id>.jsonl` shows `completed` and a
  second fire a minute later. **Stated as a residual gap, not as covered.**
- `make check` per unit.

## Security

- No new opcode, trust level, capability, subprocess or file path.
- `crError` receives the turn's `Left` text — the same text already in the
  session transcript and log. The callback receives only `Either Text ()`; no
  prompt content or credentials.
- The store's new `MVar` serializes in-process writes only; `seal serve` is
  single-process per `SEAL_HOME` (`claimSealHome`), so no cross-process
  assumption is introduced.
- Nothing reads or writes under `~/.seal/`.

## Backward compatibility / rollback

- Run JSON unchanged; existing files decode. Stale `running` rows become
  `failed` at the next startup — accurate, not destructive.
- Reconciled `CrFailed` rows count toward `checkAutoDisable`, so a job whose runs
  never completed may auto-disable and notify. That is the correct outcome, but
  the gateway's `csNotifyHuman` is currently `\_ -> pure ()` (`Serve.hs:377`), so
  the notice is not delivered. **Explicit follow-up**, so the behaviour is not
  misrepresented.
- A `/`-leading prompt now fails at creation instead of silently at fire time.
  Existing jobs with such a prompt are rejected only on their next edit/creation,
  not retroactively.
- Rollback: drop the two `CronStore` fields and `sdTurnComplete`, and the call
  sites. Run files written in between carry `completed`/`failed`, which the old
  build decodes.

## Follow-ups (out of scope)

1. Crash-proof `startCronScheduler` against a throwing `tick`
   (`2026-10-22-cron-web-ui-design.md:186-200`).
2. Wire a real `csNotifyHuman` in `seal serve` (`Serve.hs:377`).
3. Expose run history via `GET /api/cron/:id` so status is visible in the UI.
4. A full end-to-end test through the real `Serve.hs` delegate (needs an
   exportable seam or a boot-path harness).

## Human checkpoint

- **After WU-2**: regression tests pass and a wedged store reconciles; confirm
  before wiring the live completion path.
