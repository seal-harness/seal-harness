# Tab Dispositions (X → disposition menu, filter by disposition)

**Date**: 2026-11-03 · **Status**: revised (round 5, + derived sidecar; scope is PR 0–3) · **Branches**: `perf/derived-sidecar` (PR 0), `feat/session-dispositions-{be,ui,pile}` (PR 1–3), each off `main` · **Issue**: TBD · **Plan**: TBD

> **Human authorship note.** The vocabulary (§5.1) is the operator's product rule.
> It was set in round 3 and is not open for re-litigation by reviewers; the code
> must follow it.

---

## 0. Design review history

- **Round 1** — 5 reviewers (PM, Architect, Designer, Security, CTO), all
  NEEDS_REVISION. 27 blockers verified against the code and resolved (§0.1).
- **Round 2** — filter extended to the Active Tabs list (operator), one sidebar
  control, display invariants I9–I11.
- **Round 3** — **taxonomy replaced by the operator.** Dispositions are now
  section-scoped: four open states that hold a tab, four closed states that do
  not. The category layer is gone (it was 1:1 ceremony), the legacy migration
  becomes a no-op, and `Archived` regains its actual meaning.
  **Round 2's taxonomy is superseded and must not be implemented.**
- **Round 4** — **the Active Tabs filter is a set of independent per-disposition
  toggles**, not a single-select. Each of the four open dispositions can be shown
  or hidden independently (§6.2). This also settles two gaps round 3 left open:
  a brand-new tab now starts as `Todo` rather than untagged (D5 — **superseded in
  round 8**, see §14.9: there are no automatic writers), and hiding is
  literal while attention is surfaced rather than silently dropped (I12).
- **Round 5** — **the derived sidecar is in scope, as PR 0** (operator). The
  listing path's §5.11 problem turned out to be independent of dispositions —
  it is a derived-scalar-recomputed-on-read problem — so it ships first, alone,
  where it is measurable in isolation. The "why not SQLite" decision is recorded
  in §13 so it is not re-litigated.
- **Round 6** — PR 0's first plan failed a 3-reviewer plan gate. §5.11 was
  corrected to cache a single value, validate by byte count, write best-effort,
  and keep the append hook. The design and the plan are now in agreement.

### 0.1 Round-1 blocker resolutions (still in force)

| # | Blocker | Resolution |
|---|---|---|
| 1 | `Disposition` collides with `Seal.Ingest.Disposition` (`Gateway/Send.hs:77`, `Channel/Cli.hs:59`) | Type is **`SessionDisposition`** |
| 2 | Auto-tab-on-send undoes a close — `ensureTabForSession` on every turn (`Send.hs:558,578,587`) | **D4**: a successful turn sets `In Progress` |
| 3 | `removeTabH` is index-based; removal compacts | **`removeTabByRefH`** (one STM transaction, returns the removed `Tab`) |
| 4 | Disk write and tab mutation unsynchronized; `session.json` RMW unlocked | Per-session lock on `ApiDeps` + store-level MVar |
| 5 | Legacy resolution stated twice, owned by nobody | Resolved **server-side** in the serializer (§5.3) |
| 6 | Marker-as-write-projection can diverge | Projection moves to **read time** (§5.4) |
| 7 | `name`+`category` duplicated truth; I3 vacuous | **Slug only**; I3 deleted |
| 8 | `POST` + client-echoed category | **`PUT`**, body `{"name":"<slug>"}` |
| 9 | Cap-full silent; I1 false by construction | Response reports tab outcome; I1 restated; **I7**, **I9** |
| 10 | §5.5 vs §8 contradicted on the archived route | Route **reconciles** through the same serialized path |
| 11 | Wiring half-specified; `expectedRouteCount` | §8.2 lists every site |
| 12 | `SessionMeta` arity breaks 125 positional sites / 12 test modules | Named in W2 + §10 |
| 13 | Frontend tests gated by nothing | Each frontend unit names its command (Q-B) |
| 14 | Pill vs trigger: two controls for one field | Pill **is** the trigger |
| 15 | `role="menu"` without a keyboard contract | Plain-button popover + `aria-expanded` |
| 16 | No empty state; hidden rows uncountable | Per-section `visible of total · N hidden` |
| 17 | Do dead tabs demand a decision? | **No** — dead rows keep Dismiss |
| 18 | "No new security exposure" was wrong | Accepted risk + named follow-up (§5.8) |
| 19 | PM: cut `Todo` | **Overridden by the operator** (round 3 keeps it; it is a board column) |
| 20 | Default filter included `Backlog` | Superseded by per-section filters (§6.2) |
| 21 | Menu default item could be terminal | Initial highlight = **current** disposition |
| 22 | Optimistic tab close can't be rolled back | Only the disposition field patches optimistically |
| 23 | Benefits were conformance tests, not user metrics | §4 now has baseline + thresholds |
| 24 | One slice too big | **3 PRs** (§8) |
| 25 | Agent-facing `SESSION_LIST` view changes unmentioned | §5.4 consumer list |
| 26 | Citation drift | All refs re-verified |
| 27 | No issue / no plan doc | §12 prerequisites |

## 1. Problem

The sidebar sorts sessions by **where they are and how old they are** (open tab /
recently touched / archived). It never records **what the user decided about
them**. The only control for "I'm done with this" is the row's ✕, which removes
the tab and records nothing.

Evidence the teardown vocabulary is already overloaded: four verbs — `close`,
`dismiss`, `release`, `destroy` (`src/Seal/Gateway/API.hs:666-679`) — and none
says what the user concluded. (`release` doesn't even tear anything down; it maps
to `handleTabAck`.) The information lost at close time is the most valuable
signal the harness has: **the user was willing to spend tokens on this session.**

Consequences today:

- **Recent Sessions grows monotonically** (`listSessions`, every non-archived
  session dir, `src/Seal/Session/Store.hs:146-161`). There is no "not now"
  bucket, so the only way to shorten it is to archive.
- **Archived is a one-way boolean with one action** — `updateSessionArchived`
  (`Store.hs:223-240`) toggles a marker; the UI offers Unarchive and nothing
  else.
- **The ✕ is ambiguous.** Closing a tab and archiving a session are different
  operations on different objects, and which one to reach for depends on which
  section the row is in.

## 2. Why dispositions on the *session*, not the *tab*

A tab is a **seat**: `Tab = { tIndex, tRef, tKind, tLabel, tStatus }`
(`src-gateway-types/Seal/Gateway/Types/TabList.hs:55-62`); `tStatus` is liveness
only; the index is the routing grammar (`0-9a-z`, 36 slots,
`Types/Tab.hs:27-58`); removal **renumbers** to stay contiguous
(`Types/TabList.hs:132-144`). "Tab 3" is a position that moves, so there is
nowhere on a tab to hang durable state — and a disposition that died with the
tab would be lost exactly when it becomes the only thing worth keeping.

The durable record is the session (`session.json`). So the disposition goes
there.

**Explicit non-change:** `Tab` and `TabList`
(`src-gateway-types/Seal/Gateway/Types/{Tab,TabList}.hs`) are **not touched**.
`tStatus` stays `Live | Dead`; there is no `tDisposition`; no tab-schema change
of any kind.

## 3. Use cases

1. **WHO** Zoe **WANTS** to close a tab while recording that the work is finished
   **SO THAT** she can find it later under `Done` **WHEN** the agent reports the
   task complete.
2. **WHO** Zoe **WANTS** to keep an unstarted idea on the board without it
   looking like active work **SO THAT** she can see the whole shape of the effort
   **WHEN** she is choosing what to pick up next.
3. **WHO** Zoe **WANTS** a `Needs Review` column **SO THAT** finished-but-unverified
   work surfaces at the top for her acceptance **WHEN** an agent finishes a task.
4. **WHO** Zoe **WANTS** to explicitly abandon a dead end **SO THAT** it stops
   resurfacing and she does not re-litigate it **WHEN** an approach clearly will
   not work.
5. **WHO** Zoe **WANTS** to hide a session from every view without destroying its
   transcript **SO THAT** the pile stays readable **WHEN** a session is noise but
   might be worth reading later.
6. **WHO** Zoe **WANTS** to see one column at a time **SO THAT** the sidebar stays
   scannable as sessions accumulate **WHEN** she is hunting for something.

## 4. User benefit (measurable)

Baseline captured **before** PR 2 lands, recorded in the PR description:

```bash
seal session list | wc -l            # pile size
ls -1 ~/.seal/state/sessions | wc -l # total sessions
```

- **Metric 1 — adoption.** ≥ 60% of sessions whose `lastActive` falls in the 30
  days after release carry a disposition. Instrument: count `session.json` files
  with a non-untagged disposition in that window.
- **Metric 2 — the board stays bounded.** Active Tabs never exceeds 36 (a
  structural consequence of the cap) and the default Sessions view renders
  ≤ 25 rows at day 30.
- **Metric 3 — triage is cheap.** Median time from opening the menu to a
  persisted disposition < 5 s (dev-build timing; the project ships no telemetry).
- **Evaluation trigger:** 50 dispositions recorded, or 2026-12-01, whichever
  first.
- **Rollback criterion (measured).** Capture closes/week for 4 weeks pre-change.
  If at day 14 it is below 70% of that baseline, revert the ✕ to plain close and
  keep the field + filters (that revert is PR 2 minus the menu, i.e. nearly
  free).
- **Metric 4 — listing latency (PR 0).** `buildListsSnapshot` CPU time at the
  operator's real store size. Baseline measured by `make bench-lists` **before**
  PR 0 lands; target: **≥ 5× reduction** in wall time, with identical output
  (I16). The
  bench also prints *modelled bytes* (Σ `size(entries.jsonl)` vs
  Σ `size(derived.json)`) — file-size accounting, not syscall instrumentation,
  labelled as such because the repo has none. At 704 sessions the current path
  parses ~90 MB of JSON per snapshot (§5.11). This threshold is a **gate**, not
  a report: if it is not met the PR is not opened and the findings are
  escalated.
- **Spec-conformance assertions** (tests, not benefits): I1–I17 in §7.

## 5. Design

### 5.1 The vocabulary (operator-set, round 3)

Eight dispositions, each belonging to exactly one section. A three-valued
**class** carries the behaviour, so the code needs one predicate rather than a
per-disposition table:

| Section | Disposition   | slug          | Class    | Seat effect (D1/D2) | Default-visible |
|---------|---------------|---------------|----------|-------------|-----------------|
| **Active Tabs** | Backlog       | `backlog`      | `open`   | yes         | yes |
|                 | Todo          | `todo`         | `open`   | yes         | yes |
|                 | In Progress   | `in-progress`  | `open`   | yes         | yes |
|                 | Needs Review  | `needs-review` | `open`   | yes         | yes |
| **Sessions**    | Done          | `done`         | `closed` | no          | yes |
|                 | Canceled      | `canceled`     | `closed` | no          | yes |
|                 | Archived      | `archived`     | `closed` | no          | yes |
|                 | Deleted       | `deleted`      | `hidden` | no          | **no** |

```haskell
data DispositionClass = ClassOpen | ClassClosed | ClassHidden

data SessionDisposition = SessionDisposition
  { sdName  :: Text               -- ^ slug, the only persisted value
  , sdClass :: DispositionClass   -- ^ derived from the registry, never supplied
  }

lookupDisposition :: Text -> Maybe SessionDisposition
defaultDispositions :: [SessionDisposition]   -- ^ in board order
dispositionRank :: SessionDisposition -> Int  -- ^ Active Tabs sort key
```

**There is no category layer.** Round 2's six-category abstraction became 1:1
with the eight names, i.e. pure ceremony. The class axis is what the code
actually branches on (tab effect, default visibility, section), and it is also
the axis a future user-defined disposition would need — a custom "Icebox" is
just a name with class `open`. Custom dispositions stay a follow-up (§11.3).

Why these four open states (the operator's ladder, and it is a good one):

- They are the columns of a small board, in order: `Backlog → Todo → In Progress
  → Needs Review`. The *ordering* is the information the names carry; all four
  hold a tab, so they are not distinguished by mechanism.
- `Needs Review` is the trust boundary made visible: the agent may believe work
  is finished; only the human asserts `Done`. It is the first column in the sort
  because it is the human's queue (§5.7).
- `Archived` now means *archived* — put away without a verdict — which is what
  the existing marker has always meant. Round 2 mapped every legacy marker to
  `Done`, asserting completions nobody made; that is gone.
- `Deleted` is the operator's term for **soft delete** (§5.9), not destruction.

### 5.2 Storage

`SessionMeta` gains one field (`src/Seal/Session/Meta.hs:20-99` — the record
**and** the hand-written `ToJSON`/`FromJSON`; a forgotten encoder silently drops
the field on the next save):

```haskell
smDisposition :: Maybe Text
-- ^ A 'SessionDisposition' slug. 'Nothing' = untagged (a pre-existing session
-- nobody has filed yet). Not a settable state.
```

**The slug is the only persisted truth.** The class is derived from the registry
at read time.

Wire shape (response): `"disposition": {"name": "in-progress", "class": "open"}`,
or `null` for untagged — see §5.3 for why untagged stays null here (round 2's
non-null rule was justified by a legacy mapping that no longer exists).

```haskell
-- Wire type, src-gateway-types/Seal/Gateway/Types/Disposition.hs
-- (pure, no IO; the main library already depends on seal-gateway-types,
--  seal-harness.cabal:349, so no build-depends change)
```

**Two decoders, deliberately different:**

- **Wire (strict):** `PUT` body `{"name": "<slug>"}`; unknown slug → 400.
- **Disk (lenient):** the field is a bare string. An unknown slug resolves to
  untagged (`Nothing`) at the read layer with a warning **once per sid per
  process** (the read runs on every broadcast; a tampered file must not spam
  `seal.log`). A malformed value must never hide a session: `listSessions`
  silently skips undecodable files (`Store.hs:146-161`), so a strict disk decoder
  would make one bad byte erase a row with no error.
  **RED case:** `"disposition": 42` still lists, and reads as untagged.

### 5.3 Resolution on the wire

```
smDisposition = Just slug  → registry entry (unknown slug → untagged + warn)
smDisposition = Nothing    → Archived  if the legacy marker exists
                           → null      otherwise (untagged)
```

`isArchived` is threaded into `sessionInfoJson` / `sessionInfoJsonWithSnippet`
(`src/Seal/Gateway/SessionJson.hs:80,102`). The knowledge exists at exactly the
call sites that know which list a meta came from — `ListsSnapshot.hs:53-55` and
the `/api/sessions` + `/api/sessions/archived` handlers in `API.hs`. Those are
the only edits; `Seal.Tabs.Partition` is untouched (§5.6).

**Migration is a no-op.** A legacy archived session reads as `Archived` — which
is where it already renders today. A legacy unarchived session reads as untagged
and renders exactly as it does today, with no pill. Nothing moves, nothing is
asserted, no disk write.

### 5.4 The archived marker becomes a read-time projection

A session is archived (i.e. excluded from `listSessions`, and therefore from the
agent's `SESSION_LIST`) iff:

```
disposition ∈ {archived, deleted}   when a disposition exists
marker file exists                  otherwise (legacy)
```

Two lines in `listSessions` / `listArchivedSessions` (`Store.hs:146-186`). The
marker is still **written** (matching the projection) so every other consumer
keeps behaving — `Session/Search.hs:89,199`, `ListsSnapshot.hs:46`, the API list
routes, `ISA/Ops/Session.hs:363`, the CLI, older frontends. With read-time
projection the marker is a compatibility cache, not a truth claim, so a failed
marker write is cosmetic rather than divergent.

Consumer note: `Done` and `Canceled` are *not* archived, so they remain in
`listSessions` and stay visible to the agent and the CLI by default. Only
`Archived` and `Deleted` disappear from the agent's view. That is the intended
asymmetry: a completed session is still useful context; a filed-away one is not.

### 5.5 Tab coupling

- **D1 (open class ⇒ seat).** Setting a `ClassOpen` disposition ensures a tab
  exists, by **reusing `ensureTabForSession`** (`src/Seal/Tabs.hs:155-165`) — it
  is already idempotent and already logs cap-full ids-only. (`insertTabH` returns
  an undifferentiated `Left Text`, so a fresh implementation would have to
  string-match the message.)
- **D2 (closed/hidden class ⇒ no seat).** Setting a `ClassClosed` or
  `ClassHidden` disposition removes the session's tab, via a new atomic helper
  `removeTabByRefH :: TabsHandle -> TabRef -> IO (Maybe Tab)` — lookup, remove,
  renumber, persist in **one** STM transaction, returning the removed tab so the
  close notifier fires for the right ref. (`removeTabH` is index-based and
  `removeTab` compacts, so a snapshot-then-remove pair can delete a *different*
  session's tab and notify the wrong channel.)
- **D3 (untagged is inert).** No disposition → tab state unchanged. This is what
  makes migration safe.
- **D4 (every disposition is user-authored; there are no automatic writers).**
  **This supersedes the earlier D4/D5.** All eight values — open and closed — are
  produced only by the operator through the row's status control (§6.1). Nothing
  in the harness writes a disposition on its own: not a turn, not a tab
  creation, not an agent, not a channel message, not a timer.
  Consequences, accepted deliberately:
  - A successful turn does **not** promote `Backlog`/`Todo` to `In Progress`.
    The operator decides when work started.
  - A new tab does **not** get `Todo`. New sessions are **untagged** until the
    operator files them, and untagged is therefore a permanent, legitimate state
    rather than a legacy-only one (§5.1's earlier claim is withdrawn).
  - `ensureTabForSession` still auto-creates a seat on a successful turn
    (`Send.hs:558,578,587`), preserving the existing `isTabCommand` exclusion
    (`Send.hs:606-612`). That is a **seat**, not a disposition: it never changes
    what the operator decided.
  Rationale: the value of this field is that it records the operator's judgment
  and nothing else. A harness that guesses the judgment produces a field that
  looks maintained and is not — the failure the operator set out to escape. So
  the field is honest about being manual, and §1's "beats a stale TODO list"
  claim is withdrawn: what beats a stale list here is that **the session is the
  work** (tokens were spent, the transcript exists), not that the status keeps
  itself current.



**Section membership follows the disposition.** A session appears in *Active
Tabs* iff its disposition is `ClassOpen`, and in *Sessions* iff `ClassClosed` or
`ClassHidden`; untagged sessions appear in *Sessions*. The tab is the **seat**
(needed to interact with a row, and to give it a `/N` shortcut), not the
grouping key. When a closed session receives a message it still gets a seat
(auto-tab), but it stays in *Sessions* under its own disposition — so the
operator's decision is never silently overridden, and the earlier "a `Done`
session renders in Active Tabs with a Done pill" oddity disappears.

This means the frontend groups rows by disposition and uses `tabSessions` only
to know which rows have seats (for the "open in tab" affordance and the index
chip). `partitionSessions` keeps doing what it does for dedup; its three lists
are no longer the section definition.

 They are in
lockstep by D1/D2 *except* under board pressure: if the 36-slot list is full, a
`ClassOpen` disposition is still **persisted** (I2) and the row renders in
*Sessions* with a muted "no seat — board full" affordance and a retry on click
(I9 governs the persistence half of this). The alternative — dropping the
intent to keep the sections consistent — would discard the user's decision; the alternative after that — hiding the
disagreement — is what reviewers rejected in round 1.

There is **no "close without deciding"** for live session-backed tabs. Freeing a
seat now requires one of the four closed states, all of which are honest
verdicts. Escape hatches that remain: dead rows keep Dismiss (§6.1), harness and
shell tabs have no session, and reading from the pile never opens a tab.

### 5.6 Why `Seal.Tabs.Partition` does not move

`partitionSessions` (`src/Seal/Tabs/Partition.hs:33-54`) partitions by tab
presence and the archive marker. Active Tabs = tabbed; Sessions = untabbed
(`recent ∪ archived`, merged in the frontend). Every session row carries its
disposition (§5.3), so the frontend can group and filter without the backend
learning about dispositions. The union is total and duplicate-free.

Caveats recorded explicitly:

- `Partition.hs`'s "tab wins" rule means an `Archived`-with-a-surviving-tab
  session renders in Active Tabs. D2 makes that unreachable through this route,
  but a concurrent `ensureTabForSession` can produce it; it is a display oddity,
  not state corruption, and §5.5's no-seat affordance covers the mirror case.
- `Partition.hs`'s haddock ("the archive flag stays on disk and resurfaces when
  the tab closes") becomes stale. Comment-only edit, in scope.

### 5.7 Sort

Active Tabs sorts **disposition first**, then attention, then recency:

1. `needs-review` (my queue), 2. `in-progress`, 3. `todo`, 4. `backlog`,
5. untagged. Within a column: the existing bucket order (idle-unread → idle-read
→ thinking) then newest `lastUserMessageAt`
(`frontend/src/lib/tabStatus.ts:52-102`).

This is a deliberate behaviour change: disposition outranks unread, because the
column is the stronger signal and because D4 means an unread reply in `Backlog`
is rare (sending promotes to `In Progress`).

Sessions sorts newest-first within the selected disposition (`lastActive`), as
today.

### 5.8 Security posture (accepted risk, recorded)

The gateway REST surface has **no authentication** and returns
`Access-Control-Allow-Origin: *` on every response
(`src/Seal/Gateway/API.hs:2807-2810`), and the agent's `SHELL_EXEC` opcode can
`curl` loopback. So any web page the operator visits, and any model-driven loop,
can drive this route — including asserting `Done`. Round 1's "no new exposure"
was wrong.

What this slice does: adds **no opcode**, hands the model **no path**, and
appends **nothing to the transcript** (a disposition write touches only
`session.json` and the marker — pinned by tests, not prose).

What it accepts: the reachability the existing `archived` route already has, with
a wider impact (a metadata rewrite, a tab-list mutation, and `Done` is an
assertion of judgment). Accepted for a single-operator loopback tool, with a
named follow-up: restrict `Access-Control-Allow-Origin` to `gcAllowedOrigins` and
reject non-allowlisted `Origin` on state-mutating routes
(`Gateway/Stream.hs:106-156` already does this for the WS path).

**Where the writes land.** Both paths (and PR 0's sidecar) write under the state
root, `<state>/sessions/<sid>/`, and never touch the agent-immutable members
AGENTS.md enumerates under `~/.seal/` (`security.toml`, `exec-known-hosts`,
`keys/`, `config/vault/`, `ssh-mux/`). That is permissible because the writer is
the gateway (Trusted/Audited, in-process), not an opcode — stated here because
the rule is the repo's first and a reader will ask.

Constraint on §11.2 (future opcode): it must call `updateSessionDisposition`
in-process on a server-resolved `SessionId`, must never receive a path or an id
from model output, and must be restricted to non-`Done` dispositions so "only
the human accepts" is structural rather than promised.

### 5.9 `Deleted` is soft delete

- Hidden from every default view: excluded from the Sessions `All` filter,
  reachable only by selecting `Deleted` explicitly.
- Marker set, so it drops out of `listSessions` and out of the agent's
  `SESSION_LIST` and the CLI default listing.
- **The transcript is never touched.** No file moves, no directory removal.
- Reversible: setting any other disposition restores it.
- The menu requires a **second confirmation** on that item only, because
  "Deleted" reads like destruction and is not.
- Hard delete remains an explicit admin/CLI action, never a row button.

### 5.10 API

```
PUT /api/sessions/:id/disposition
Body: {"name": "needs-review"}
200   {"ok": true,
       "disposition": {"name":"needs-review","class":"open"},
       "tab": {"effect":"opened","index":4}}   // or "removed" | "none" | "cap_full"
400   unknown disposition | invalid body | invalid session id   (fixed strings)
404   session not found
```

`PUT` and `:id`, matching the three siblings on the same sub-resource
(`PUT /api/sessions/:id/{archived,description,prompt}`) — setting a disposition
is idempotent state assignment.

`PUT /api/sessions/:id/archived` is **kept but no longer a plain marker toggle**:
`archive=true → Archived`, `archive=false → null` (untagged, marker removed),
through the same serialized path. Round 1 said "kept, unchanged" and then relied
on a reconcile mitigation in the risks table — mutually exclusive. Reconciling is
required, or the CLI can leave marker-present + `In Progress`, which is exactly
the divergence projection is meant to prevent.

Handler sequence, under a per-session lock:

1. Resolve `name` → registry entry (400 on unknown). Body errors use **fixed
   strings**; the submitted slug is never echoed and never logged raw.
2. `updateSessionDisposition paths sid slug` — read-modify-write of `session.json`
   under a store-level MVar, then the marker reconcile (tolerant: an IOException
   is logged ids-only and swallowed). `False` → 404.
3. D1/D2 against `adTabsHandle`.
4. `triggerBroadcast deps`.
5. On a removed tab, `adTabCloseNotifier` — exactly as `handleTabRemove`
   (`API.hs:2063-2075`) — with the ref returned by `removeTabByRefH`.

**Store contract (all MUST):**

- `doesFileExist (sessionMetaPath …)` **first**, returning `False` before touching
  the writer: `writeMetaFileAtomic` calls `createDirectoryIfMissing True`
  (`Store.hs:118-127`), so an unauthenticated request with a syntactically valid
  id must not create empty dirs under the state root that every broadcast then
  enumerates.
- Re-derive the class inside the store; never accept one from a caller.
- A per-session `MVar` on `ApiDeps` (the existing `SessionWakeMutex` shape) held
  across disk → marker → tab → broadcast, so two concurrent `PUT`s cannot
  interleave into "disk says In Progress, tab is gone".
- `bracketOnError` around the temp-file write; marker removal `catch`-tolerant.

### 5.11 PR 0 — the derived sidecar (`derived.json`)

**The problem, measured.** `buildListsSnapshot`
(`src/Seal/Gateway/ListsSnapshot.hs:41-62`) calls `sessionInfoJsonWithSnippet`
once per session, and that calls `lastUserMessageAtFast`
(`src/Seal/Gateway/Transcript.hs:994-1002`), which **reads the whole
`entries.jsonl`** (avg ~128 KB) and JSON-decodes every line. At the real store
size (704+ sessions, per the code's own comment at `Transcript.hs:948`), one
snapshot parses **~90 MB of JSON**, twenty times a minute at
`POLL_INTERVAL = 3000` (`frontend/src/hooks/useApi.ts:26`).

That value is a pure function of the transcript. We recompute it on every read
instead of materializing it once on write.

**The fix.** A per-session sidecar `<sessionDir>/derived.json`:

```json
{"version": 1, "last_user_message_at": "2026-11-03T04:12:31Z", "entries_bytes": 131072}
```

Three decisions, each forced by review of the first draft:

1. **Exactly one derived value.** The first draft cached
   `first_user_message_snippet` alongside it — but that value derives from
   `conversation.jsonl` / legacy `transcript.jsonl`
   (`Transcript.hs:963-985`), not from `entries.jsonl`, so no single validity key
   could guard both, and a heal driven by one accessor would persist a `null`
   sibling that the other accessor then trusted (silently breaking I16). The
   snippet stays on its streaming path, which stops at the first user message and
   is bounded by the head of the file.
2. **Validity by byte count, not mtime.** Reading `entries.jsonl` and then
   writing the sidecar lets a concurrent append land in between: the sidecar ends
   up *newer* than the transcript while omitting that append, so an mtime rule
   would certify a stale value. Recording `entries_bytes` and requiring equality
   with the current file size closes that window, and it matches the in-repo
   precedent — `conversation.idx` validates by size/offset, not time
   (`src/Seal/Transcript/ConvIndex.hs:331-343`).
3. **Best-effort, no directory creation.** The write is guarded by
   `doesDirectoryExist` and its whole body is `catch`ed (ids-only log), because
   the read path is also exercised against non-existent roots in tests
   (`test/Seal/Gateway/TranscriptSpec.hs:717-721`) and a heal must never throw or
   create a session directory.

**Written by the read path. The append hook is deferred (§11.9).**

A miss or a size mismatch falls back to today's implementation, returns the
fresh value, and rewrites the sidecar. That heals the 704 existing sessions on
first read with no batch migration, and covers every append.

The first draft put the update on the append path. That was dropped after
verification, not for convenience:

- `withIndexedTranscript :: FilePath -> (IndexedTranscriptHandle -> IO a) -> IO a`
  (`src/Seal/Handles/Transcript.hs:331`) is **path-only**; the `entries.jsonl`
  append happens inside it where `dir :: FilePath` is in scope and no
  `SealPaths`/`SessionId` exists. Attaching a sidecar path means either a
  signature change (call sites: `Gateway/Send.hs`, `Command/Stop.hs:77`,
  `test/Seal/Gateway/SendSpec.hs:149`, `test/Seal/Agent/LoopSpec.hs:334,396`)
  or a new handle accessor plus one edit at each site.
- It buys almost nothing. Every turn appends many **non-request** entries after
  the request, so the recorded byte count is stale again within the same turn,
  and the read path re-derives exactly as it would with no hook. The daemon also
  has no record of the last request timestamp (`IndexedTranscriptState`,
  `:295-330`), so a non-request append can only refresh `entries_bytes` — which
  would certify a `null` or stale value as fresh, the one thing I16 forbids.

So: heal-on-read only, one scalar, one source, size-keyed. `/session reindex`
exists for operators who want the pass done up front; it is a **slash**
subcommand (`GroupSession`), not a new top-level binary command.

**Never authoritative.** The sidecar is a materialized view in the same sense as
`conversation.idx` — the in-repo precedent for exactly this pattern. Deleting
every sidecar changes nothing observable except latency (I16).

**Forward home for derived metrics.** Token totals, turn counts and
last-assistant timestamps belong here later; this is where §11.1's evidence
ranking will read from, which is why the SQLite question (§13) can wait.

**Why this is not a database problem.** Filtering and sorting for dispositions
happen in the frontend over rows it already holds. The sidecar removes the only
whole-file read on the hot path. SQLite would leave the derivation problem
exactly where it is.

## 6. UI

### 6.1 The row control: a status icon that opens the menu

**One control per session-backed row.** The ✕ is replaced by a **status icon**
whose glyph and colour encode the session's current disposition. Clicking it
opens a dropdown listing all eight values. There is no separate pill and no
second affordance — one control both *shows* and *sets* the state, which is what
resolves the round-7 objection that "the pill and the trigger are two controls
for one field".

```
  b   ◐  Fix the flaky integration test        ·  repo    ·  web    2h
      ↑
      status icon: current disposition, click for the menu
```

| Disposition   | Glyph | Colour |
|---------------|-------|--------|
| untagged      | ○     | faint  |
| Backlog       | ◔     | muted  |
| Todo          | ◑     | muted  |
| In Progress   | ◐     | accent |
| Needs Review  | ◉     | accent-2 |
| Done          | ●     | success |
| Canceled      | ⊘     | faint  |
| Archived      | ▣     | faint  |
| Deleted       | ⨯     | faint  |

The menu, grouped by destination section so the move is predictable:

```
  Active Tabs
   ✓ In Progress          ← current, initial highlight
     Needs Review
     Todo
     Backlog
  ──────────────────────
  Sessions
     Done
     Canceled
     Archived
     Delete…               ← requires a second activation
```

Rules (each closes a round-7 finding):

- **Always perceivable, never hover-only.** The icon is always in the tab order
  and in the accessibility tree; on low-emphasis rows it may be revealed by
  `opacity`, never by `display: none` — `.session-archive`'s `display: none`
  pattern is exactly the bug that made the old controls keyboard-unreachable
  (`App.css:816-836`). Accessible name is stable across states:
  `Disposition: <current>` with `aria-haspopup="true"` and `aria-expanded`.
- **The menu is portalled**, `position: fixed` from the trigger's rect, with
  flip/clamp and a max height — it lives inside the sidebar's scrolling list and
  would otherwise clip (precedent: `NewTabComposer.tsx:595-601`).
- **Initial highlight is the current disposition**, so `Enter` means "no change,
  dismiss". A terminal value is never pre-selected.
- **`Delete…`'s confirmation disarms** on popover close, Escape, focus loss, or
  choosing any other item — otherwise the confirm is theatre.
- **Picking an open value from a Sessions row** moves the row to Active Tabs; the
  menu names the destination, the section header counts update, and selection is
  re-pointed from the `tab.index` in the 200 response. If the board is full the
  row stays put with the "no seat — board full" affordance.
- **Dead rows** (`exited`/`orphaned`) keep Dismiss. Harness and raw-shell tabs
  have no session and keep Close/Dismiss/Release verbatim.
- No `role="menu"`: a plain-button popover, as elsewhere in this UI. Upgrading to
  a real menu (roving tabindex, `menuitemradio`, arrows) is a follow-up.

### 6.2 The Active Tabs filter: per-disposition toggles

The four Active Tabs dispositions are **independently toggleable**. This is a
show/hide control over the board's columns, not a single-selection filter — you
can look at `Needs Review` + `In Progress` together, or turn `Backlog` off and
forget it exists, without losing the others.

The trigger lives in the Active Tabs header and opens a popover (the
`TabLineConfigBar` pattern — plain buttons, `aria-expanded` on the trigger, no
`role="menu"`). Four options, each with a live count; `Untagged (legacy)` appears
as a fifth **only when its count is non-zero**, so it self-cleans as the back
catalogue gets filed:

```
Active Tabs                        [+]  [ ⊟ 4/5 ]
  …rows…
```

```
┌──────────────────────────────┐
│ Show in Active Tabs          │
│  ☑ Needs Review            1 │
│  ☑ In Progress             3 │
│  ☐ Todo                    0 │
│  ☑ Backlog                 2 │
│  ☐ Untagged (legacy)       1 │
│ ────────────────────────────  │
│  All on   ·   All off         │
└──────────────────────────────┘
```

- **All toggles default on.** The board is bounded at 36 seats, so it cannot run
  away; there is no reason to hide a column by default.
- **The popover doubles as a board summary** — the counts are the column sizes,
  visible in one glance.
- **All-off is allowed** and renders the zero-row line ("No columns shown —
  [turn one back on]"), because collapsing a section is a legitimate gesture.
- **The trigger shows state**: a neutral glyph when everything is on, `4/5`
  when something is hidden, and `N hidden with unread` when any hidden row
  carries attention (I12).
- Persistence: the **hidden set** is stored, not the visible set, so a future
  custom disposition defaults to visible. Per-browser `localStorage` (the
  `tabLineConfig` pattern, `src/lib/tabLineConfig.ts:39-58`).
- The header keeps `visible of total` so the hidden count is always legible even
  with the popover closed.
- Filtering is applied **per section** (§6.3). The Sessions section keeps its
  single-select dropdown for now — see Q-F, which asks whether to make it
  identical (one component, two instances, nearly free).

### 6.2.1 Why toggles rather than a single-select

A single-select ("show only Done") is a *query*: it answers "where is the thing
I am looking for". Toggles are a *view configuration*: they answer "what do I
want my board to look like". The operator asked for the second, and it is the
right choice for the Active Tabs list specifically — the list is small (≤ 36),
ordered, and read as a board, so the useful gesture is "collapse the columns I
am not working on", not "search". The Sessions list is large and unordered, so
a query-style control fits it better; hence the deliberate asymmetry until Q-F
settles it.

### 6.3 Resulting sidebar

```
Active Tabs                     [+]  [ ⊟ 4/5 ]
  Needs Review  1   the thing I must accept
  In Progress   3   …
  Backlog       2   …
  (Todo hidden)
Running Harnesses                       3
  …unchanged, never filtered…
Sessions                                12 of 34 [ All ▾ ]
  …recent ∪ archived, newest first…
```

`ArchivedSection` is removed: `Archived` is now a Sessions filter entry, and its
count is in the header. The header keeps the terse noun-phrase convention;
"Everything else" is dropped because it was a label for a joke, not a list.

## 7. Invariants

Starting states are **enumerated and finite** (AGENTS.md: bound all generators):

`S0` no tab bound · `S1` this session bound at slot 3 · `S2` a different session
bound at slot 0 · `S3` list full at 36.

- **I1.** For every default disposition `d` and every `s ∈ {S0,S1,S2,S3}`: after
  applying `d`, `tabBound(sid) == (class d == open)` **except** when `s == S3` and
  `class d == open`, in which case `tabBound == False` and `d` is still persisted.
- **I2.** Applying `d` always persists `d`, regardless of tab outcome.
- **I3.** *(deleted in round 2 — was vacuous.)*
- **I4.** For a session with a disposition, archived-ness (as `listSessions`
  reports it) equals `d ∈ {archived, deleted}` — enforced at read, so a failed
  marker write cannot break it.
- **I5.** Untagged never changes tab state.
- **I6.** `lookupDisposition . sdName` is total over the default set; slugs are
  unique; each section has exactly its four; the wire decoder accepts exactly the
  default set.
- **I7.** A closed/hidden disposition on a session with a live tab removes exactly
  that session's tab and returns the removed ref (concurrent variant: with two
  tabs bound, the other survives).
- **I8.** A disposition write appends nothing to `conversation.jsonl` /
  `entries.jsonl` and does not change `smLastActive`.
- **I9.** A `ClassOpen` disposition on a full board persists and reports
  `cap_full`; it never removes or reorders an existing tab.
- **I10.** D4: a successful turn sets `In Progress` and `tabBound == True`, for
  every prior disposition (including the closed/hidden ones).

Display invariants (frontend tests, not QuickCheck):

- **I11.** The Active Tabs filter never hides the **selected** tab's row — the
  main pane must never show a session with no row in the list.
- **I12.** Hiding is **literal**: a toggle that is off hides its rows, including
  rows carrying attention (`thinking` / `idle-unread`). Attention is instead
  *surfaced*: the trigger renders `N hidden with unread` whenever a hidden row
  carries attention. Rationale — an override that silently ignores an explicit
  toggle is a worse lie than a visible count, and the count still prevents the
  "I forgot to look" failure this feature exists to remove. *(Rejected alternative
  — pinning attention rows into the list — is recorded here so it is not
  re-proposed.)*
- **I13.** Harness and raw-shell rows are never filtered (no session ⇒ no
  disposition).
- **I14.** `Deleted` is never visible in the Sessions default view; only under an
  explicit `Deleted` selection.
- **I15.** The hidden set persists as *hidden*, so a disposition added later is
  visible by default.
- **I16.** The sidecar is never authoritative: with every `derived.json`
  deleted, `sessionInfoJsonWithSnippet` — the shared leaf behind `/api/lists`,
  `/api/sessions` and `/api/sessions/archived` — produces byte-identical JSON,
  as does `buildListsSnapshot`. Enforced by a delete-and-diff test.
- **I17.** The sidecar is validated by **byte count**, not mtime: it is trusted
  iff `entries_bytes == size(entries.jsonl)`. An append changes the size, so a
  sidecar write that races an append cannot certify a stale value.

## 8. TDD plan — four PRs

`make check` = `build` (`tsc && vite build`) + `cabal test` + `hlint`. **Vitest is
in none of them**, and CI runs only `cabal test --enable-coverage`. Every frontend
unit therefore names its own command and is run by hand (Q-B covers promoting it).

### PR 0 — the derived sidecar (independent, ships first, measurable alone)

**W0a — bench instrument (`exe/bench-lists`).** A separate executable (not a
`seal` subcommand: the binary exposes only `tui`/`serve`/`gen-openapi`,
`src/Seal/Types/Command.hs:15-19`). Calls the production `buildListsSnapshot`;
one unmeasured warm-up, then N measured iterations; prints session count, the
cold iteration separately, the measured median, and *modelled bytes*
(Σ `size(entries.jsonl)` vs Σ `size(derived.json)`) — file-size accounting, not
syscall instrumentation. `make bench-lists` wraps it in `nix develop`.

**W0b — `Seal.Session.Derived`.** New module: `derived.json` encode/decode,
atomic `0o600` write that never creates a directory and never throws
(`writeDerived :: … -> IO Bool`), `readDerived`, `entriesSize`,
`derivedIsFresh` (byte-count key), and `computeDerived` — the single
stat → read → stat producer that both the read path and reindex call.

**W0c — read path.** `lastUserMessageAtFast`
(`src/Seal/Gateway/Transcript.hs`) consults the sidecar and heals on miss or
size mismatch, using `computeDerived`. **`firstUserMessageSnippetFast` is
untouched** — it derives from `conversation.jsonl`, so it is neither cached nor
keyed by this sidecar (§5.11 decision 1).

**W0d — `/session reindex`.** A slash subcommand (`GroupSession`), not a binary
command: processes `listSessions <> listArchivedSessions`, prints
`written / skipped / failed`, idempotent.

**Deferred: the append-time hook** (§5.11, §11.9) — it needs `withIndexedTranscript`
to carry a sidecar path and the daemon to track the last request timestamp, and
it buys ~nothing because every turn appends non-request entries afterwards.

Wiring: `seal-harness.cabal` (library exposed-modules; test-suite
`other-modules`; the new `executable bench-lists` stanza), `test/Main.hs`.

RED: codec round-trip; unknown `version` → treated as absent (and the heal
rewrites it as `version: 1`); corrupt JSON → treated as absent **and the session
still lists**; `entries.jsonl` deleted while a sidecar exists → the sidecar is
ignored, the value is `Nothing`, and the orphan file is left in place;
writeDerived returns `False` on a missing session dir and leaves no temp file;
mode `0o600`; **I16** (delete all sidecars → byte-identical
`sessionInfoJsonWithSnippet` *and* `buildListsSnapshot` output); **I17** (append
to `entries.jsonl` → the value is current and the sidecar is rewritten);
`/session reindex` writes correct values (identity with the no-sidecar run) and
is idempotent.

**No behaviour change, no wire change, no UI change** — revertible with zero
user-visible effect.

### PR 1 — vocabulary, storage, route, coupling (backend only, nothing user-visible)

**W1 — `SessionDisposition` + registry (pure).**
`src-gateway-types/Seal/Gateway/Types/Disposition.hs`,
`test/Seal/Tabs/DispositionSpec.hs` (tested from the `Seal.Tabs.*` side like
`TypesSpec`; no `test/Seal/Gateway/Types/` directory exists).
RED: lookup total over the eight, rejects unknown; slugs unique; four per
section; class derives from slug and cannot be supplied; `dispositionRank` is a
strict order over the four open states; I6.
Wiring: `seal-harness.cabal:38-70` (`library seal-gateway-types`
exposed-modules), `seal-harness.cabal:363+` (test-suite `other-modules`),
`test/Main.hs` (import + registration).

**W2 — `SessionMeta` field + store.**
`src/Seal/Session/Meta.hs` (record **and** the hand-written `ToJSON`/`FromJSON`),
`src/Seal/Session/Store.hs` (`updateSessionDisposition`, read-time projection in
`listSessions`/`listArchivedSessions`, MVar around metadata RMW,
`bracketOnError`).
RED: absent field → lists and reads untagged; malformed value → still lists;
`"disposition":"nonsense"` → untagged + one warning per process; set → readable;
I4 both directions; missing `session.json` → `False`; no `.tmp` left behind; I8.
**Breaking:** `SessionMeta` has no smart constructor, so **125 positional
construction sites across 12 test modules** gain the field in this commit
(`ApiSpec.hs` 65, `ISA/Ops/SessionSpec.hs` 17, `Command/ModelSpec.hs` 12,
`Gateway/SendSpec.hs` 10, others ≤5). `-Wmissing-fields` under `-Werror` finds
them; the build cannot be green otherwise.

**W3 — route + coupling + D4.**
`src-gateway-types/Seal/Gateway/Types/Route.hs` (constructor, `routeMeta`,
`allRoutes`), `src/Seal/Gateway/OpenApi.hs:74-99` (exhaustive `λcase`),
`src/Seal/Gateway/API.hs` (dispatch arm, handler, archived-route reconcile),
`src/Seal/Tabs.hs` (`removeTabByRefH`), `src/Seal/Gateway/Send.hs` +
`src/Seal/Core/TurnEngine.hs` (D4 at the three `ensureTabForSession` sites),
**`test/Seal/Gateway/ApiRouteSpec.hs:14` `expectedRouteCount` 62 → 63**.
RED: 200 + persisted; 400 unknown slug; 400 invalid id; 404 missing; I1 over
`{S0..S3}`; I2/I9 cap-full; I7 incl. the two-tab variant; I10 (every prior
disposition + a turn); notifier fires exactly once for the right ref; idempotent
re-apply = one broadcast, zero tab mutations; archived route reconciles both
directions; `/tab close` still excluded from auto-tab.

### PR 2 — wire type, menu, API client (sidebar shape unchanged)

**W4 — `types.ts` + `lib/dispositions.ts`**
(+ `lib/__tests__/dispositions.test.ts`). Six `makeSession(overrides:
Partial<SessionInfo>)` factories gain the field.
RED: the eight, ordering, classes; `holdsTab`; filter maths over an 8-session
fixture; `Deleted` excluded from `All`; untagged renders no pill.
Command: `cd frontend && npm test -- src/lib/__tests__/dispositions.test.ts`.

**W5 — `DispositionMenu.tsx` + `DispositionFilterPopover.tsx` + row wiring.** Extract `Pill` from
`ActiveTabs.tsx:187` into `RowLayout.tsx` (the shared row module; `Sidebar`
currently duplicates it as a raw `span.pill`). Add a
`tabDisposition :: TabInfo -> SessionDisposition | null` resolver prop (the
existing `tabLabel`/`tabModel`/`tabAgeText` convention) and `onSetDisposition`
threaded `App.tsx → Sidebar → ActiveTabs → TabRow`.
New `ActiveTabs.test.tsx` (none exists) **and** `DispositionMenu.test.tsx`.
RED: trigger renders for session-backed rows, not harness rows; dead rows keep
Dismiss; all eight listed in two groups; initial highlight is current; Enter with
no movement is a no-op; `Deleted` needs two activations; selecting calls
`onSetDisposition(name)` without selecting the row; Escape closes; disposition-
first sort (§5.7).
Command: `cd frontend && npm test -- src/components/__tests__/DispositionMenu.test.tsx`.

**W7 — API client + optimistic patch.** `hooks/useApi.ts`
(`setSessionDisposition`, mirroring `setSessionArchived` at :441), `App.tsx`.
RED: the disposition field patches optimistically; 400/404 reverts it; the tab is
**not** optimistically closed (a compacted slot cannot be rolled back faithfully —
tab state follows the broadcast); `cap_full` surfaces the §5.5 no-seat
affordance.

### PR 3 — filters + section collapse (the only visible regression lives here)

**W6 — per-section filters + `ArchivedSection` removal.** `Sidebar.tsx` merges
`recentSessions ∪ archivedSessions`, sorts the union jointly, and renders two
filters.
RED: four independent toggles, all on by default; toggling one off hides exactly
those rows and nothing else; toggling two gives the union; all-off renders the
zero-row line while the selected row stays pinned (I11); every toggle shows a
live count; the trigger renders `4/5` when something is hidden and
`N hidden with unread` when a hidden row carries attention (I12); the `Untagged`
toggle renders only when its count > 0 and disappears at zero; the **hidden** set
persists and a newly added disposition is visible (I15); harness rows survive
(I13). Sessions keeps its single-select: default `All` minus `Deleted`, `Deleted`
reachable only explicitly (I14). Plus: a tab-backed session never appears in
Sessions.
Test churn to enumerate in the unit: `Sidebar.test.tsx` is ~1250 lines with
archived-section testids, expand/collapse, three-section indent parity (:346-372),
archive/unarchive (:422-445), second-line tests (:1051-1118); `App.tsx:282-290,881-891`
(`archivedOptimistically`, `handleUnarchiveSession`) and the
`onArchiveSession`/`onUnarchiveSession` props go.

## 9. Risks

| Risk | Mitigation |
|---|---|
| The board fills up (all four open states consume slots) and the only way out is a closed verdict | That is the design's intent, and `cap_full` is now a first-class UI state (I9) rather than a logged warning. If it proves annoying, the follow-up is Backlog-without-seat |
| Demanding a decision on every close becomes friction | Default highlight = current disposition; four honest exits; measured rollback (§4) |
| Removing `ArchivedSection` is a visible regression | `Archived` is a filter entry; header `hidden` count replaces the `Archived (N)` glance |
| `Deleted` mistaken for destruction | Soft-delete semantics (§5.9), second-activation confirm, reversible, transcript untouched |
| Marker-as-cache still written by three paths | Read-time projection (§5.4) makes the cache non-authoritative |
| Concurrent metadata writers clobber each other | Store MVar + per-session lock (§5.10) — also fixes the 5 pre-existing writers |
| Wildcard CORS + no auth + agent `SHELL_EXEC` | Accepted and recorded (§5.8) with a named follow-up |
| Sidecar goes stale after an append | The size check fails, the read path re-derives and rewrites it (I17) |
| Sidecar corrupt/unknown-version hides data | Treated as absent, session still lists, slow path heals it; I16 asserts output identity |
| Extra write per transcript append | Written by the append path that is already opening + fsyncing; a small sidecar next to a 2.7 MB transcript |
| Sort change (disposition before unread) surprises people | Called out in §5.7; one-line revert if disliked |
| A user hides a column and forgets what is in it | Trigger shows `N hidden` and `N hidden with unread` (I12); counts live in the popover; all-off is one click to undo |

## 10. Breaking changes

1. **`SessionMeta` arity** — 125 positional sites / 12 test modules (W2).
2. **`SealRoute` exhaustiveness** — 4 files + `expectedRouteCount` 62 → 63 (W3).
3. **`Sidebar` props** — `onArchiveSession`, `onUnarchiveSession`,
   `ArchivedSection` removed; `onSetDisposition` added (W5/W6).
4. **✕ semantics on live session-backed tabs** — closing requires a disposition
   (W5). `POST /api/tabs/:i/close` survives; the UI stops calling it.
5. **Marker writers** — `PUT /sessions/:id/archived` now also writes a
   disposition; `seal session archive` inherits `Archived`.
6. **Agent view** — `SESSION_LIST` loses `Archived`/`Deleted` sessions (unchanged
   from today for archived; `Deleted` is new).
7. **Active Tabs sort order** — disposition now outranks the activity bucket
   (§5.7).

## 11. Out of scope / follow-ups

1. Evidence ranking, a `blocked` flag, resurfacing — reads from the §5.11
   sidecar, which is why it can be built without a database.
2. Agent-proposed dispositions via an opcode (in-process, non-`Done` only).
3. User-defined dispositions (§5.1: a name + a class, so additive).
4. `/tab close <N> --disposition <slug>`, a CLI `session dispose`, and
   `GET /api/sessions?disposition=` so the filter has one definition.
5. `disposition` as a `TabLineField`.
6. Real `role="menu"` keyboard contract.
7. CORS/Origin hardening on state-mutating routes.
8. Backlog-without-seat, if board pressure proves annoying (§9).
9. The append-time sidecar hook (§5.11): needs `withIndexedTranscript` to carry a
   sidecar path (or a handle accessor) plus a tracked last-request timestamp.
   Deferred because heal-on-read already bounds the cost to sessions appended
   since the last snapshot, and the hook cannot write a correct value for
   non-request appends without that extra daemon state.

## 12. Prerequisites and open decisions

- **Q-A.** *(Closed in round 3 — the operator set the taxonomy. Round 2's
  `In Review`/`Todo`-as-close design must not be implemented.)*
- **Q-B.** Promote `npm test` into `make check` and CI as part of this work, or
  accept that frontend tests are run by hand? (Today they are gated by nothing.)
- **Q-C.** Accept the wildcard-CORS/unauthenticated-gateway exposure for this
  route with a named follow-up (recommended, §5.8), or land the Origin-allowlist
  fix first as a blocking prerequisite?
- **Q-D.** *(Settled in round 5: four PRs, sidecar first.)* Residual question:
  may PR 0 merge on its own before the disposition work starts? Recommended —
  it is measurable, revertible, and it de-risks the sidecar pattern before
  anything depends on it.
- **Q-G.** Ship `make bench-lists` (a target that times `buildListsSnapshot` and
  prints bytes-read per phase) as part of PR 0? It is ~30 lines, it produces the
  §4-Metric-4 baseline, and it is how we would justify (or refuse) §13 later.
  Recommended: yes.
- **Q-E.** Prerequisites before implementation: a GitHub issue and a plan doc
  (`docs/superpowers/plans/2026-11-03-tab-dispositions-plan.md`) — both
  human-authored per AGENTS.md.
- **Q-F.** Give the Sessions section the same toggle control (one component, two
  instances, ~free) or keep its single-select? The asymmetry is deliberate right
  now — toggles suit a small board you configure, a query suits a large pile you
  search — but two filter idioms in one 280px sidebar is a real cost. Recommendation:
  make them identical.

## 13. Recorded decision: no SQLite for session metadata (2026-11-03)

Reviewed by measurement, not preference. **We keep the filesystem for session
metadata; dispositions add a `session.json` string and no database.**

The pain that suggested SQLite is real but misdiagnosed: it is not a query-layer
problem, it is one derived scalar recomputed on every read (§5.11). Materializing
it removes ~90 MB of JSON parsing per snapshot with no new dependency and no new
failure class.

What SQLite would genuinely buy, and where we stand:

| Capability | Needed now? | Verdict |
|---|---|---|
| Filter/sort by disposition (≤36 board rows + a pile already in memory) | no — array ops in TS | SQL buys nothing |
| Full-text search across transcripts | already 3 tiers: engram / ripgrep / in-memory (`Session/Search.hs:1-30`) | `rg` is excellent; revisit only if latency disappoints |
| Ranking by derived metrics (tokens, turns) | not yet | §5.11's sidecar is the landing site |
| Transactional multi-field metadata updates | **partly** — 7 writers read-modify-write `session.json` | an MVar covers in-process; multi-process CLI-vs-`serve` is the residual (§9) |

Costs of adopting it today: zero existing SQLite anywhere (absent from
`seal-harness.cabal` and `flake.nix`), a native dep on Linux + macOS CI, four
processes sharing the state dir (`serve`, channels, CLI, TUI), WAL/locking as a
new failure class, a placement decision under the control-plane/untrusted-plane
split, and a rewrite of the tests that assume temp-dir files.

**Adopt SQLite for the session index when two of these hold:**

1. A read path needs a query shape we cannot precompute.
2. Full-text search must beat `rg` on latency.
3. The store passes ~5k sessions.
4. Multi-process metadata writes are *observed* to drop fields.

**If it happens, the shape is fixed in advance:** `~/.seal/state/index.sqlite`,
derived and rebuildable, **never authoritative**, populated by a reindex pass,
with `seal index rebuild` and a test that deletes the file and asserts identical
output — the same contract as §5.11 and `conversation.idx`. The architecture's
"transcript is truth, everything else is a materialized view" rule is what makes
that guarantee cheap; a database must enter under it, not around it.

## 14. Gate round 7 — full 5-agent design review + plan re-review: NOT READY

Round 7 ran the full Design Review Gate (PM, Architect, Designer, Security,
CTO) against this design *and* against PR 0 as actually shipped on
`perf/derived-sidecar` (`5e00a0d`, `1937a8f`), plus a completeness review of the
PR 0 plan. **Result: 0 of 6 approved.** The blockers below are consolidated and
de-duplicated; each was verified against the code by the reviewer that raised it.

### 14.1 The blocker that invalidates the premise

**Nothing produces `Needs Review`.** D4 sets `In Progress` on every successful
turn; D5 sets `Todo` when a tab is created. Those are the only automatic
writers. `Needs Review` — described here as "the trust boundary made visible"
and "the first column because it is the human's queue" — has no producer at all;
the only mechanism that would give it one (§11.2, agent-proposed dispositions)
is deferred.

Consequence: the field's only automatically-maintained value is a constant, and
every judgment-bearing state is hand-maintained. **A field that is 90% one value
does not beat a stale TODO list; it is a stale TODO list that looks maintained,
which is worse.** The operator's original thesis ("to-do lists get out of date")
is therefore not answered by this design as written, and §1's claim that the
disposition is what makes tabs beat a stale list must be withdrawn or earned.

**Decision required (operator).** Either:

- **(a)** Give it a producer inside this epic: the same disposition menu in the
  composer footer when a turn ends ("Done · Needs review · Keep"). It asks for
  the judgment at the only moment the operator has the context, needs no opcode
  and no new security surface, and turns §3's use case 3 into a real trigger; or
- **(b)** Withdraw the claim, and accept that the field is a manual annotation
  with a one-way ratchet to `In Progress`. If (b), the epic should probably not
  be built.

### 14.2 PR 0 as shipped is inert, and its own gate was never applied

Verified on the branch: the only production consumer of `Seal.Session.Derived`
is `renderIso`; `lastUserMessageAtFast` is byte-for-byte unchanged and
`readDerived` / `derivedIsFresh` / `computeDerived` / `writeDerived` have no
caller outside the spec. So PR 0 added an on-disk format, a write path, a
validation rule and 275 lines of tests **with zero runtime effect**, while §4
Metric 4 declared the ≥5× threshold "a gate, not a report: if it is not met the
PR is not opened". That is exactly the unmeasured-micro-optimisation pattern
this document elsewhere refuses. The "no behaviour change, revertible with zero
user-visible effect" defence is trivially true of code nothing calls.

**Decision:** PR 0 is not mergeable in this state. It either lands **complete**
(W0a bench + W0c read path + the gate cleared) or is **reverted**. §4 Q-D's
"may PR 0 merge standalone" is answered **no** until then.

### 14.3 Tab-coupling funnel is incomplete

D1–D5 cover three of at least eight tab-binding paths. Missing: `POST
/api/tabs/new {resume}` and `/tab resume` both call `insertTabH (BoundSession
sid)` without reading the disposition, so a `Done`/`Archived`/`Deleted` session
can acquire a live seat by a plain user action — so §5.6's "unreachable through
this route" is false (it is not a race). D5 covers only `handleTabNew`'s provider
branch, so `POST /api/sessions/new`, `POST /api/sessions/:id/new` and the CLI
`/tab new` still create untagged sessions, which falsifies §5.1's "untagged then
only ever means legacy" and makes the `Untagged` toggle permanent (it can never
self-clean). D4 also lands in `Core/TurnEngine.hs` for every non-web channel,
which the work-unit list does not name.

**Decision:** replace D1–D5 with **one funnel** — a single
`applyDisposition`/`bindSeatFor` that every writer calls — and enumerate all
sites in the work unit. Make section membership a read-time function of the
disposition so a missed site is *invisible* rather than corrupting.

### 14.4 The concurrency story does not deliver its guarantee

There is no `adSessionLocks`; the in-repo per-session lock is `SessionLocks`
(`Session/Lock.hs:75-95`), held for the whole turn by design. A new MVar on
`ApiDeps` serialises PUT-vs-PUT only, while D4 runs inside a turn under
`SessionLocks` and cannot reach `ApiDeps` — so D4 (`In Progress`) and a PUT
(`Done`) interleave freely and leave disk-says-Done with a live tab, unrepairable.
Separately `TabsHandle.thSave` snapshots *before* taking the persist MVar
(`Tabs.hs:64`), so two concurrent mutations can persist the older list last, and
`seedTabsHandle` loads exactly that at boot. And there is no repair path.

**Decision:** the write must be **one critical section** (store MVar: session.json
→ marker → tab reconcile → broadcast) that *every* writer goes through
(`PUT`, the archived route, D4, D5, resume). Last-writer-wins then gives a total
order and disk/marker/tab agree by construction, with no turn lock. Take the tab
snapshot inside the persist lock. Restate I1 with its full exception list.

### 14.5 `Archived` projection is destructive on one side and incomplete on the other

`archive=false → untagged` unconditionally clears the field, so the existing
Unarchive button silently erases a `Done` verdict. And projecting archived-ness
from the disposition requires *both* enumerators to apply one shared predicate in
both directions — a marker-less session whose disposition is `Archived` must
still come back from `listArchivedSessions`, or the row exists in neither list and
disappears from the UI. The current shape cannot express that (it skips
marker-present dirs without decoding), and decoding every dir twice per snapshot
undercuts PR 0's own goal. Also: `.:?` on a `"disposition": 42` field fails the
whole record and `listSessions` silently skips undecodable files, so the session
vanishes instead of reading as untagged.

**Decision:** one `listSessionsPartitioned :: SealPaths -> IO ([SessionMeta],
[SessionMeta])` doing a single enumeration and one predicate application;
`archive=false` = `Archived → untagged`, anything else unchanged; tolerant disk
decode via `parseMaybe` on the field.

### 14.6 §5.8's security claims are wrong on the facts

"Touches only `session.json` and the marker — pinned by tests, not prose" is
false: closing a tab through the route also persists `<state>/tabs.json`
(`Tabs.hs:52`), persists `<state>/cursors.json` via the close notifier
(`Cursor.hs:73-79`), and sends outbound user-visible messages to attached
Telegram/Signal sinks (`Loop.hs:171`). That is network egress from an
unauthenticated route. And the "single-operator loopback tool" premise is not
enforced — `gw.host` is configurable and `Server.hs:265-283` binds `0.0.0.0` with
a warning. And "the sidecar never touches `keys/` / `config/vault/`" is filename
luck, not structure: `SessionMeta`'s `FromJSON` never runs `isValidSessionId`, so
a crafted `"id"` reaches `sessionDir`; today it is a read, but W0c turns it into a
write. `/session reindex` is also reachable from the unauthenticated
`POST /api/sessions/:id/send` slash dispatch — a new amplification primitive.

**Decisions:** (i) restate §5.8's effect set accurately, including egress;
(ii) validate `smId` at the `SessionMeta` decode boundary (precedent:
`Session/Workdir.hs:60-103`); (iii) add invariant **I18**: no code path may branch
on a disposition for authorization, spending, deletion or scheduling — so
"only the human asserts Done" is honestly advisory, not security; (iv) add an
ids-only audit line per transition; (v) bound `/session reindex` (single-flight).

### 14.7 UX blockers (Designer)

- **The suppressed-row trigger is unreachable by keyboard.** The pattern it
  extends, `.session-archive`, uses `display: none` until hover, which removes
  the element from the tab order — `:focus-visible` can never fire, so a
  keyboard user cannot open the menu on any row whose pill is suppressed. After
  D4 that is nearly every Active Tabs row. It is also untestable as configured:
  `App.css` is imported only in `main.tsx`, so jsdom applies none of it.
  **Fix:** reserve the slot and reveal by `opacity`, never `display`; add a RED
  that asserts perceivability (slot reserved, focusable, stable accessible name).
- **The pill-suppression predicate is undefined** now that Active Tabs uses
  independent toggles ("equals the filter's single selection" no longer exists),
  and suppression removes the only marker distinguishing archived rows once
  `ArchivedSection` goes.
- **The menu has no geometry**: it is inside the sidebar's `overflow-y-auto`
  container, so eight items (~268px) clip or scroll the list. Use a portal with
  `position: fixed` + flip/clamp (precedent: `NewTabComposer.tsx:595-601`).
- **`Deleted`'s second activation never resets** — the confirm is theatre unless
  popover close / Escape / focus loss / another item disarm it.
- **Attention copy is wrong**: the set is `thinking` + `idle-unread`, so hiding a
  *thinking* row renders "1 hidden with unread". Make the §6.3 muted
  `(Todo hidden)` per-column line normative instead (`Todo · hidden · 1 unread`).
- **Removing `ArchivedSection` puts archived rows at full height in the default
  view**, so archiving no longer visibly shortens the list. Default Sessions to
  `All` *excluding* `Archived`, or keep a collapsed archived group.
- **Metrics.** Metric 1 (adoption ≥60%) cannot fail — every session active in
  the window was tagged by D4/D5. Count **menu-originated** writes only and
  report the distribution. Metric 2 (≤25 rows at day 30) is unreachable: the real
  store has ~335 non-archived untagged sessions and the design has no bulk path —
  state a legacy policy (e.g. untagged && `lastActive` older than N days resolves
  to `Archived` at read time) or a bulk action. The rollback criterion is not
  computable — no tab-close is recorded anywhere; emit one server-side line per
  removal first.

### 14.8 What happens now

- **The epic is NOT READY.** PR 1–3 must not start.
- **PR 0** is incomplete on `perf/derived-sidecar`; it must be finished
  (W0a bench + W0c read path, gate cleared) or reverted before merge.
- The operator must answer §14.1(a)/(b) before anything else, because (b)
  removes the reason to build the epic. Open questions Q-H (who produces
  `Needs Review`), Q-I (the 335 legacy sessions), Q-J (do channel-originated
  sessions belong on the board) join Q-B/Q-C/Q-F in §12.

### 14.9 Round 8 — operator decision resolves §14.1

The operator settled the premise question: **all disposition values, open and
closed, are produced by the operator from the frontend control.** There is no
automatic producer, and none is wanted.

What that changes:

- §14.1 is resolved by **withdrawing** the anti-rot claim rather than by adding a
  producer. §5.5's D4/D5 are replaced (see D4 there); §1 no longer claims the
  field maintains itself. The honest proposition is that the transcript is the
  evidence a session mattered, and the disposition records what the operator
  decided — a manual annotation with a truthful scope, not a to-do list that
  pretends to keep itself current.
- §14.3's D5 gap (untagged is not legacy-only) is now **by design**: untagged is a
  permanent valid state, so the `Untagged` filter entry stays available and does
  not claim to self-clean.
- §14.7's pill-vs-trigger objection is **resolved by construction**: §6.1 is now a
  single status icon that opens the menu, so there is one control per row.
- The remaining round-7 blockers still stand and still block PR 1–3:
  the tab-coupling funnel (§14.3), the single critical section (§14.4), the
  partitioned enumerator and non-destructive unarchive (§14.5), the security
  fact-corrections and `smId` validation (§14.6), the menu geometry and keyboard
  contract (§14.7, now specified in §6.1), and the metrics that cannot fail
  (§14.7). Those are design work, not questions.
- **PR 0 is unaffected by this decision** and remains not mergeable until W0a
  (bench) and W0c (read path) land and clear the §4 gate.
