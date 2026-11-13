# Files View Redesign — Design Document

> **Status**: Rev 2.2 — addresses Design Review Gate Rounds 1, 2 and 3.
> Round-1/2 findings: `2026-11-12-files-view-redesign-gate-round1.md`.
> **Date**: 2026-11-12
> **Branch**: `files/explorer2` (branched from `files/explorer`)
> **Author**: Human-authored decision, AI-assisted write-up

## 0. Revision log

Every blocker raised and how it is resolved. IDs match the gate report.

### Round 1

| ID | Blocker | Resolution |
|---|---|---|
| S1 | `~/.env` warning unreachable on read paths | §5.9 — warning channel on **both** content and download |
| S2 | 3 security controls claimed but never implemented | §6.1 — all three disclosed |
| A1 | Cache owner contradiction (§5.5 "view" vs §8 `useApi.ts`) | §5.5 — dedicated `useFileListingCache` hook |
| A2 | No probe-miss path | §5.3 fallback |
| A3 | §5.3 depends on §5.7, unstated | §5.3 + §7.8 WU order |
| A4 | `S\|`→`SD\|`/`SF\|` misses dangling symlinks | §5.7 `SX\|` |
| A5 | Local symlink fix would lose `isSymlink` | §5.7 preserve on every branch |
| C1–C7 | 8 of 23 existing tests dropped | §7.0 map + §7.1 T-matrix |
| C8 | Mock layer makes cache/budget unobservable | §7.4 fetch-level mocks |
| P1 | UC-4 promises listing retention §5.1 doesn't deliver | §4 UC-4 reworded |
| P2/P7 | Markdown toggle ungoaled, untested | **Deferred to v2** (§3) |
| P3/P5 | No user-outcome success criteria | §3.1 SC-1..SC-4 |
| P4 | UC-5 not delivered by this work | §4 relabelled retained capability |
| P6 | UC-3 "share with colleague" contradicts §6 | §4 UC-3 narrowed |
| D1 | `⋯` menu has no primitive; Download behind it | §5.1 `.icon-btn` inline actions |
| D2 | Rail error surface undefined | §5.6 rail error states |
| D3 | Long names / deep paths / scroll-into-view | §5.6 + T24 |
| — | `ControlPath` `~`-form wrong | §5.4 absolute path |

### Round 2

| ID | Blocker | Resolution |
|---|---|---|
| B1 (CTO) | §7.0 mapped tests to undefined `T1`-`T23` | §7.1 T-matrix, all defined |
| B2 (CTO) | `FileTree.test.tsx` zero tests | §7.2 — 18 tests |
| Sec-B1 | Download still a zero-signal path for `~/.env` | §5.9 Path B — `X-File-Warning` + pre-save confirm |
| Sec-B2 | Two stale audit docstrings, not one | §6.1 lists `API.hs:2355` **and** `:2375` |
| R2-D1 | Redesign deleted the only keyboard path to open a file | §5.6.1 main-pane row a11y |
| R2-D2 | Breadcrumb `…`-collapse untested | T24 |
| R2-D3 | Stale §9 cross-refs after renumber | §9 corrected |
| R2-D4 | "8 of 24" wrong | 23 |
| R2-D5 | Rail persistence undecided/untested | §5.6 `localStorage`, tested |
| R2-D6 | "touch-safe" imprecise | WCAG 2.5.8 stated |

### Round 3

| ID | Blocker | Resolution |
|---|---|---|
| A3-B1 | Cache keyed on `flPath`, unknowable pre-request → dedup impossible | §5.5 keys on **requested** path; `flPath` stored as value + alias |
| A3-B2 | "unmount drops it" false for module scope | §5.5 `clear-on-last-unmount` + TTL |
| PM-N3 | Download confirm modal has no goal or primitive | §5.10 goal + `role="dialog"` primitive |
| PM-N2 | §5.9 cited undefined T28/T29 | §7.1 T28/T29 defined |
| Sec-B1-R3 | "Pre-save" confirm unimplementable — `downloadFile` saves before returning | §5.9 step 4: two-phase `requestDownload`/`save()` |
| CTO-R3-1 | §5.10 cited T29 (empty-dir) not T28 | §5.10 → T28 |
| DS-R3-1 | §5.10 cited an `aria-modal="false"` dialog as the pattern | §5.10 → `ChatArea.tsx:658` / `AccessGate.tsx:420` |
| — | Warning-free `feReadFileBytes` left alongside | §5.9 step 5: replace in place, enforced by 3 handle arms |
| D3-1 | T26 "focus ring present" unimplementable in jsdom; `App.css` absent from §8 | T26 → activeElement + class proxy (ring is Playwright); `App.css` added to §8, WU5 |
| D3-3 | Directory-row keyboard path mandated but unasserted | T25 extended to a directory row (`role="link"`, Enter + Space) |
| D3-S1 | T24's "tail pinned" is a layout assertion jsdom can't make | T24 asserts ellipsis + first/last only; pinning is e2e |
| D3-S2 | §5.10 claimed "focus containment" but no Tab trap exists | §5.10 says "focus restore + Escape" |
| A3-S1 | Alias rationale self-cancelling | §5.5 — real value is the `$HOME` case; normalisation deliberately skipped, backend authoritative |
| A3-S2 | §5.7 said dangling click "404s" but §7.2 said "non-navigable" | §5.7 navigable + T18; §7.2 reworded |
| A3-S3 | `feReadFileBytes` retain-or-replace unstated | §5.9 step 5 — replaced in place, 3 constructors + 1 call site named |
| A3-S4 | Symlink bypasses `blockedNames` (new, enabled by §5.7) | §6.1 accepted-residual entry — stated, not fixed |
| A3-S5 | §8 missing `useApi.test.ts` and the confirm dialog | both added to §8 |
| PM-R3-1 | SC-2/3/4 claimed "CI" but no frontend CI job exists | §3.1 → "local `make check`", with the gap stated; CI job is a follow-up |
| PM-R3-2 | SC-3 cited T22 (absent-path), not a cold-bookmark test | **T30** added; SC-3 points at it |
| PM-R3-3 | ⟳ refresh button had no Goal/UC | §3 Goal added tying it to UC-1 staleness |
| PM-R3-4 | SC-2's "≤1 fetch" false after TTL expiry | §3.1 states "within the 30s TTL" |
| PM-R3-5 | §5.10 "without blocking" overstated a modal | → "without preventing the download" |
| — | TTL "30s mirroring ExecCache" wrong | `defaultDiscoveryTTL = 60` (`ExecCache.hs:84`); §5.5 uses 30s **by choice** |
| — | `FileContent` declared in `types.ts`, not `useApi.ts` | §8 corrected (`types.ts:574`) |

## 1. Problem

The file explorer works, but does not look or feel like the rest of the
frontend. **This is the primary justification for the work.** The use cases in
§4 are secondary benefits.

1. **It is the only section without a rail.** Providers, Agents, Skills,
   Repos, Secrets, Channels and Access all use one skeleton: a 280px
   `--bg-surface` rail with `border-right`, an uppercase header
   (`letterSpacing: 0.08em`), and `agent-row` selection items. Files renders a
   single full-bleed table. *(Verified: `width: 280` in exactly 7 non-Files
   views.)*
2. **It references design tokens that do not exist**, each with an invented
   hex fallback (§2).
3. **It is the only component using emoji as icons** — 21 SVG icons exist;
   `FilesView` is the sole emoji file. Emoji cannot be tinted with tokens.
4. **Navigating costs a full page swap** — no way to keep your place.

**Evidence basis (stated honestly):** the above is a code and visual audit,
not user research. §4's use cases are reasoned from the feature's purpose.

## 2. Evidence (token and idiom audit)

### 2.1 Undefined tokens in `FilesView.tsx`

| Referenced | Defined? | Rest of the app uses |
|---|---|---|
| `var(--text-warning, #c47b00)` | no | `var(--warning)` `#FBBF24` |
| `var(--text-warning, #c48017)` | no | same concept, *different* hex |
| `var(--text-danger, #d44)` | no | `var(--needs-input)` `#FF6B6B` (63 uses) |
| `var(--accent, #4a9eff)` | no | `var(--accent-secondary)` `#4F8EF7` |
| `var(--border-subtle, …)` | no | silent no-op |

All five verified absent by grep (count 0). **Independently confirmed by the
Designer reviewer.**

**Scope boundary:** `var(--accent)` with no fallback also appears in
`HarnessControls.tsx:124,130` and `ReposView.tsx:578`. Same drift, outside this
PR's file scope — follow-up (§10).

### 2.2 Icon idiom

`FilesView.tsx` is the only file under `components/` containing emoji
(`📁 📄 ↪`). Everywhere else uses inline SVG (`viewBox="0 0 16 16"`,
`stroke="currentColor"`, `strokeWidth={1.6}`, 11-12px). 21 exist.

### 2.3 Layout idiom

All seven sibling views share `width: 280`, `background: var(--bg-surface)`,
`borderRight: 1px solid var(--border)`, and `agent-row` rows.

## 3. Goals / Non-Goals

### Goals (v1)

- Files becomes the eighth member of the master-detail family.
- A directory tree in the left rail; the right pane shows the selected
  directory's detail listing or a selected file's contents.
- One URL parameter defines what the main pane shows; the rail root is derived.
- Remote mode stays within a **two-SSH-operation** budget per view.
- Fix the palette, icon and control drift (§2).
- Fix the sensitive-directory warning on **both** read paths (§5.9).
- Main-pane rows are keyboard-operable (§5.6.1) — non-negotiable, not a goal
  to trade off.
- **A manual refresh affordance (⟳) exists so a 30s-cached listing never
  hides a file the agent just wrote.** This is the staleness escape hatch for
  UC-1: the TTL (§5.5) is what makes sibling switching free, and ⟳ is what
  keeps that cache from becoming wrong. Without it, UC-1's "verify the file
  the agent just modified" can fail by design.

### Non-Goals (v1)

- File editing, upload, deletion, creation.
- Recursive/eager tree loading.
- A batched multi-path API endpoint (§5.4).
- File search or a command palette.
- **Markdown Rendered/Raw toggle — deferred to v2.** No goal, no use case, no
  test; it also pulls `MarkdownView` + `lib/transcriptViewMode.ts` into scope.
- **Row action menu (`⋯`)** — replaced by inline `.icon-btn` actions (§5.1).

### 3.1 Success criteria (user outcomes)

| # | Outcome | Measure | When |
|---|---|---|---|
| SC-1 (UC-1) | Verify an agent-modified file without leaving the browser | Operator completes the task with **zero terminal invocations** | Post-merge walkthrough |
| SC-2 (UC-4) | Switch sibling files without refetching the parent | **≤1 fetch per switch within the 30s TTL** (§5.5); asserted §7.3 | local `make check` |
| SC-3 (UC-3) | A bookmarked file cold-loads correctly | Correct file renders with no prior history; **T30** | local `make check` |
| SC-4 (UC-2) | Orient in an unfamiliar repo | Rail shows `T`'s ancestors expanded + `T` selected; (§7.5, title-only) | local `make check` |

**Evaluation point is `make check`, not CI.** `.github/workflows/ci.yml:94` runs
`cabal test` only — there is no `npm test`/vitest step in `ci.yml`,
`release.yml` or `flake.nix`. Frontend tests run via `make frontend-test`,
which is part of the local `make check` target (`Makefile:35,41`). A measure
no gate executes is not a measure, so this is stated honestly rather than
claiming CI coverage that does not exist. Adding a frontend CI job is a
worthwhile follow-up (§10).

**SC-2 is TTL-bounded.** "≤1 fetch" holds *within* the 30s TTL; after expiry a
sibling switch refetches the parent. Stated so the measure is not technically
false.

Failure signal: the operator still opens a terminal to read an agent-written
file, or remote navigation exceeds ~2s per click. Evaluation is post-merge
operator feedback — the project has no telemetry.

## 4. Use Cases

**UC-1 — Inspect an agent-written file.**
> **WHO** Zoe (web user) **WANTS** to read a file the agent just modified
> **SO THAT** she can verify its correctness **WHEN** reviewing a completed turn.

**UC-2 — Orient in an unfamiliar repo.**
> **WHO** Zoe **WANTS** to see the directory shape around a path **SO THAT**
> she understands where a file sits **WHEN** opening a deep-bookmarked file.

**UC-3 — Revisit a bookmarked path.**
> **WHO** Sam (remote-mode operator) **WANTS** a stable URL to a file he was
> looking at **SO THAT** he can reload or re-open it later **WHEN** returning
> to an artifact. The URL must survive a cold load in a fresh browser.
>
> **Narrowed.** Rev 1 said "share with a colleague"; §6 establishes that
> passkey mode returns 401 without an enrolled session, so sharing is not
> delivered here. Sharing to an *enrolled* second device works and is a
> non-goal.

**UC-4 — Switch between files in one directory.**
> **WHO** Zoe **WANTS** to click between sibling files **SO THAT** she can
> compare them **WHEN** reviewing a change set.
>
> **Reworded.** Rev 1 promised "without losing the listing", but §5.1 swaps
> the main pane to a viewer. The real benefit: switching is **free** (parent
> listing cached, §5.5) and **does not reload the page**. The rail keeps
> directory context visible at all times.

**UC-5 — Download an artifact (retained capability).**
> **WHO** Sam **WANTS** to download a remote file **SO THAT** he can inspect it
> locally **WHEN** an artifact is too large to read in-browser.
>
> **Relabelled.** Download already exists; this work relocates and restyles
> it. It is a retained capability, not new value — except for the new
> sensitive-path confirmation (§5.10), which *is* new.

## 5. Design Decisions

### 5.1 Layout — rail + detail

```
┌──────────────────┬────────────────────────────────────────────────────┐
│ FILES            │  / home zoe project src        ⟳    ⇩              │
│ ┌──────────────┐ ├────────────────────────────────────────────────────┤
│ │ ▾ ~ zoe      │ │  NAME              SIZE     MODIFIED              │
│ │   ▸ .seal    │ │  ▸ ⬚ components    —        2h ago                │
│ │   ▾ ⬚ project│ │  ▸ ⬚ hooks         —        1d ago                │
│ │     ▾ ⬚ src  │ │    ⬚ App.tsx       36 KB    3h ago    ⇩           │
│ │       · main │ │    ⬚ types.ts      8 KB     1d ago    ⇩           │
│ └──────────────┘ │                                                   │
│    280px rail    │   idle → "Select a file to view it."              │
└──────────────────┴────────────────────────────────────────────────────┘
```

- Rail width, background, border, header and row styling **reuse** the seven
  siblings' shape and `agent-row`.
- **Row actions are inline `.icon-btn`s, not a `⋯` menu.** `.session-archive`
  is a hover icon button, not a menu; the codebase has zero
  `role="menu"`/`aria-haspopup` and no popover CSS. `.icon-btn`
  (`App.css:372-399`) is 24×24 with a `:focus-visible` ring — an existing,
  focus-reachable primitive meeting WCAG 2.5.8 (Target Size Minimum, 24×24 —
  not 2.5.5 Enhanced's 44×44).
- Directories: the whole row navigates.
- Files: the row opens the viewer; the `⇩` icon-btn downloads.
- Markdown Rendered/Raw toggle: **deferred to v2** (§3).

### 5.2 URL model — one parameter

`/files?path=<T>` is the **entire** contract.

- `T` is what the main pane shows: a directory listing, or a file's contents.
- The rail roots at `parent(T)`, expanded along `T`'s ancestors with `T`
  selected.
- `T` absent → the backend resolves `$HOME`; the frontend learns the resolved
  path from the listing response's `flPath` and roots the rail at
  `parent(flPath)`.
- `T === "/"` → rail roots at `/`.

This drops `&view=content`, which conflated *where I am browsing* with *what
is open*. One axis, no invalid combinations.

**Preserved:** bookmarkability (UC-3). A cold load of `/files?path=/a/b/c.txt`
must render correctly with no history.

**Rail is convenience, not the only navigation.** The breadcrumb always works,
including paths outside the rail root (`/etc` cannot be expressed under `~`).
Guards UC-2/UC-3.

### 5.3 File-vs-directory resolution — parent-first probe

The backend reports the kind of `T` only *as an error*:
`FeNotADirectory → 400 "path is not a directory"` (`API.hs:2406`),
`FeIsDirectory → 400 "path is a directory"` (`API.hs:2405`).

A naive "try content, fall back to listing" costs **three** calls per file
view, because the failed probe is still a full remote operation.

**Resolution:** fetch `listing(parent(T))` first — needed for the rail
regardless. Its entries contain `T`'s basename, whose `isDir` decides the
main-pane request. Then issue exactly one more call.

| Main pane | Calls | Serial? |
|---|---|---|
| `T` is a directory | `listing(P)` + `listing(T)` | 1 dependency |
| `T` is a file | `listing(P)` + `content(T)` | 1 dependency |
| `T === "/"` | `listing("/")` only | none |

**Dependency:** correct only *after* §5.7 lands. Today a symlinked directory
has `isDir = False`, so the probe would route it to `content` and get `400`.
§5.7 ships first (§7.8 WU1).

**Probe-miss fallback.** `basename(T)` may be absent from `listing(P)` when:
the listing truncated at `listingEntryLimit = 10000` (`FileExplorer.hs:129`);
`T` does not exist; `P` itself 403/404s; or `parseRemoteListing` dropped the
line (names containing `|`, `FileExplorer.hs:583-585`). Then:

1. If `listing(P)` failed → main pane shows that error; rail shows its own
   error (§5.6).
2. If `listing(P)` succeeded but `T` is absent → issue **one** `content(T)`
   call as the fallback probe. `200` → viewer; `404` → "Path not found";
   `400 "path is a directory"` → list it.

This is the **only** path that can exceed two calls (a dropped directory entry
costs `content`→`listing(T)`, i.e. three total). It is a genuine miss (deleted
file, truncated listing), not the common path, and SC-2 concerns *sibling
switches after the parent is cached*, which is unaffected.

**Rejected alternative:** adding a `kind` discriminator to `/api/files` would
make the two calls parallel. Deferred — it changes `ApiFilesSpec.hs`, the spec
§5.4 contract and the OpenAPI entry for a latency gain the SSH mux (§5.4)
already makes negligible. The URL scheme is identical either way, so this
stays a pure backend swap if ever wanted.

### 5.4 SSH cost — the mux already amortizes it

`Seal/Tools/Exec/Remote.hs` multiplexes, and the file explorer rides it:
`remoteListDirectory`/`remoteReadFile` → `runRemoteShell` → `sshExecArgv` →
`muxArgs "m"` (`FileExplorer.hs:435, 462, 499`; `Remote.hs:93, 157-162`).

```
-o ControlMaster=auto
-o ControlPath=<absolute>/ssh-mux/m-%C     ← absolute, NOT ~-form
-o ControlPersist=600
```

First operation pays TCP + key exchange + auth. **Every subsequent operation
for ~10 minutes rides the persistent master socket** — a channel open, not a
handshake. Asserted by `RemoteSpec.hs:225-249`.

**Correction:** Rev 1 wrote `ControlPath=~/.seal/ssh-mux/m-%C`. The
implementation deliberately emits an **absolute** path because ssh does not
tilde-expand `-o` values (`Remote.hs:164-176`). Copying Rev 1's literal into
code would have silently broken muxing.

**Residual per-call cost:** local `ssh` spawn (~5-15ms), channel open
(~1-5ms), remote `sh -c` spawn (~1-5ms) — versus a ~200-500ms handshake.

**Caveat:** the budget holds on the success path. A timeout/abort runs
`killProcessGroup` (`Local.hs:213`), taking the master with it; the next call
re-handshakes. Acceptable — it trades a handshake for not leaking a hung
channel.

**Consequence: no batched endpoint is built.** At two calls per view the
connection overhead is amortized. Batching would only matter under *eager*
tree expansion (N nodes → N channels); lazy expansion avoids that by
construction (§5.6).

### 5.5 Caching

**Owner:** a dedicated hook, `useFileListingCache`
(`frontend/src/hooks/useFileListingCache.ts`). Not inside `useFileListing`,
not in `useApi.ts`.

Rationale: `useFileListing` holds per-instance `useState`
(`useApi.ts:1755`) — a `Map` there is per-hook-instance, so the rail (wanting
`P`) and main pane (wanting `T`) would never share it and the two-call budget
would silently become three.

**Key: the requested path, frontend-normalised — NOT `flPath`.** `flPath` only
exists in the *response* (`API.hs:2419`), so it cannot serve as a cache key: a
key must be computable *before* the request to (a) look up an entry and (b)
join an in-flight promise. Keying on `flPath` would make dedup impossible and
silently reinstate the three-call path.

- `flPath` is stored **in the value** and registered as a **secondary alias**.
  Its real value is the **absent-path / `$HOME` case** (§5.2): the frontend
  requests `listing(null)` and the backend resolves `$HOME`, so without the
  alias a later explicit request for that same resolved directory would miss.
  (Earlier drafts justified the alias by "spelling differs but normalises the
  same" — self-cancelling, since identical normalisation means the primary key
  already hits. Corrected.)
- **Frontend normalisation is deliberately NOT done.** There is no
  `lexicalCollapse` port and no new `lib/` module; the backend
  (`API.hs:2323`) is the sole authority. The cost: the *first* request for a
  given spelling always misses if the caller spelled it differently. Acceptable
  because `FilesView` derives every path by string-appending to a listing's
  `path`, so spellings are consistent within a session.
- §7.3 asserts the `$HOME` alias case.

Design:

- Value: `{ listing, fetchedAt }`.
- TTL: **30s, a deliberate choice.** (The `ExecCache` *pattern* is reused;
  its value is `defaultDiscoveryTTL = 60`, `ExecCache.hs:84` — different
  number, different purpose.)
- **In-flight dedup**: concurrent requests for the same key share one promise.
  Without this, rail and main pane mounting simultaneously double-fetch `P`.
- **Lifetime**: module-scope state survives unmount, so the hook registers a
  **clear-on-last-unmount** (refcounted) in addition to TTL expiry. Rev 2's
  claim that "unmount drops it" was false for module scope; this is the fix.
- Explicit refresh (⟳ in the header) clears **the whole map**.
- Exported `resetFileListingCache()` for test isolation (§7.3).

### 5.6 Tree loading — lazy, with defined states

Expansion is user-driven and lazy: one `listing(node)` per expand, cached
thereafter. No recursive/background walk — this keeps the call budget at two
and keeps remote mode from opening N channels.

Each node holds its own collapsed/expanded state, mirroring
`SkillGroupSection`/`AgentGroupSection`.

**Rail states.** A rail failure must not hijack the main pane:

| Situation | Rail rendering |
|---|---|
| Node loading | inline spinner on that node row |
| Node 403/404 on expand | inline error text on the node row + retry on re-click |
| Root listing failed | single inline message with a Retry button |
| Directory empty | "empty" inline on the expanded node |

**Rail listing warnings (`flWarning`).** Expanding `~/.ssh` in the rail lists
key *names* — `flWarning` exists on the listing response but the rail
currently has no banner for it. Decision: **accept for v1**, because the rail
exposes names only — it has no content read and no download affordance
(§5.6.1 keeps `⇩` off `treeitem`s). Any *content or download* of a sensitive
path still warns via the §5.9 channels. Surfacing a rail banner is a
candidate v2 refinement; recorded rather than silently omitted.

**Edge cases.**

- **Long filenames in a 280px rail**: `truncate` + `title`, matching
  `SessionRow`/`SkillGroupSection`.
- **Deep-path breadcrumb overflow**: horizontally scrollable with the tail
  pinned visible; middle segments collapse to `…` past ~5 segments.
- **Scroll-into-view on cold load**: after ancestors auto-expand, the selected
  node scrolls into view once (`scrollIntoView({ block: 'nearest' })`), not on
  every render.

**Persistence (R2-D5).** Expanded state persists to `localStorage` under
`seal.filesRailExpanded`, mirroring `loadTabLineFields`/`saveTabLineFields`
(`lib/tabLineConfig.ts`). Regardless of stored state, **`T`'s ancestors always
expand** on a cold bookmark load (UC-3 correctness); persistence only restores
nodes the user opened manually.

**Accessibility.** `role="tree"` on the root, `role="treeitem"` +
`aria-expanded` on nodes, `aria-selected` on the current node;
ArrowRight/ArrowLeft expand/collapse, Up/Down move, Enter activates.

### 5.6.1 Main-pane row accessibility (R2-D1 — blocker)

Rev 2 removed the file-row `View` `<button>` (`FilesView.tsx:276`) in favour
of a row click, but specified a plain `<div onClick>` with no `role`,
`tabIndex` or key handler — and §5.6's a11y paragraph covered only the rail.
That leaves **no keyboard path to open a file**, a WCAG 2.1.1 regression.

- Every main-pane row is focusable (`tabIndex={0}`) with `role="button"`
  (files) or `role="link"` (directories), plus an `aria-label` naming the
  target.
- `onKeyDown` handles **Enter and Space** (Space `preventDefault`ed).
- The row shows a `:focus-visible` ring matching `.icon-btn` (`App.css:391`).
- Tab order: row → its `⇩` download button → next row.
- Every in-row action handler calls `e.stopPropagation()`, or clicking `⇩`
  also navigates (codebase idiom, 8× in `ChatArea.tsx:494,508`).
- The `⇩` affordance appears on **main-pane rows only**, never on rail
  `treeitem`s (a nested focusable button breaks arrow-key focus management).

Main-pane rows stay **divs**, not `<table>`: the component and all seven
siblings use div rows, and a table would break the visual language. Semantics
come from ARIA roles.

### 5.7 Symlinked directories are currently dead ends (bug fix, ships first)

`localEntry` sets `isDir = False` for *every* symlink
(`FileExplorer.hs:274-281`), and `remoteListCmd` emits bare `S|$name`
(`FileExplorer.hs:551`). The frontend comment in `sortEntries` claims the
opposite. Consequence: a symlinked directory renders a download button,
clicking it requests `content` on a directory, and the user gets `400`. In a
tree it cannot be expanded — so UC-2 fails on any real repo (`node_modules`,
venvs, `dist` links).

**Fix:** resolve the target type while still marking the entry as a symlink.

- **Local**: follow with `doesDirectoryExist`/`doesFileExist`, and **preserve
  `feIsSymlink = True` on every branch**. The naive fix sends dangling links
  into the final fallback arm, which sets `feIsSymlink = False`
  (`FileExplorer.hs:309-316`), losing the badge. For a **local dangling**
  symlink (follow → both false), emit `isDir = false, isSymlink = true`; a
  click or download then 404s, which the error state handles (T18). It is
  **navigable** — the link resolves to nothing, and the 404 is the honest
  report. (This supersedes the earlier "non-navigable" phrasing in §7.2.)
- **Remote**: extend `S|name` → `SD|name` (dir target),
  `SF|name|size|mtime` (file target, via `stat -L` so symlinked files do not
  regress to `—`), and `SX|name` (dangling). Without `SX|`, a broken link
  (`-L` true, `-d` false, `-f` false — ubiquitous in `node_modules`, venvs,
  `/proc`) would fall through to `SF|` and claim a file that 404s.
- **Backward compatible**: `parseRemoteListing` is total and drops unknown
  tags (`_ -> Nothing`, `FileExplorer.hs:584-620`). `S|` is **retained** for
  mixed-version tolerance; the existing test (`FileExplorerSpec.hs:265`) stays.
- Update `feIsSymlink`'s stale "not followed in listing" comment
  (`FileExplorer.hs:81`) and `sortEntries`' stale comment
  (`FilesView.tsx:55`).

Sorting: a symlink-to-directory sorts with directories (`isDir = true`) and
carries a symlink badge. It remains navigable.

**Security note:** resolving symlink types lets the tree traverse *through*
symlinks outside the rail root. Consistent with §6's advisory stance (the
explorer is a whole-filesystem browser), but stated rather than implied.

### 5.8 Visual alignment — mechanical

- Replace the five undefined tokens with their real equivalents (§2.1).
- Replace emoji with inline SVGs following the 21 existing icons.
- Replace ad-hoc `buttonStyle` with `.btn .btn-ghost` (viewer) and
  `.icon-btn` (row actions).
- Replace the bespoke warning banner with the `channel-restart-notice` shape
  (`--bg-elevated` + `--border` + `--radius-sm` + 13px), using `var(--warning)`.

### 5.9 Sensitive-directory warning on the read paths (S1, Sec-B1)

**The bug:** `checkBlocked` runs only on the listing arm
(`FileExplorer.hs:234, :422`). `FileContent` has no `warning` field —
`fileContentJson` emits `path/content/truncated/linesRead/isBinary` only.
`blockedNames` = `.env .ssh .gnupg .netrc .seal` (`Path.hs:52-53`), matched
per path component. So `GET /api/files/content?path=~/.env` — whose parent
`$HOME` is *not* blocked — produces **zero warning end-to-end**. Spec §4.1
named exactly this class as the catastrophe, and §5.2/UC-3 make bookmarked
content reads routine.

There are **two** silent read paths. Both are fixed.

**Path A — content view (`/api/files/content`).**

1. Add `fcWarning :: !(Maybe Text)` to `FileContent`, populated from
   `checkBlocked` at **both** construction sites: `FileExplorer.hs:338`
   (local) and `:478` (remote). Remote is UC-3's context. The field is
   non-optional, so the compiler enforces both arms.
2. Emit `warning` in `fileContentJson` (`API.hs`).
3. Add `warning: string | null` to `FileContent` in `types.ts:574`.
4. Render the banner in the viewer when `warning` is non-null.

**Path B — download (`/api/files/download`).** `handleFileDownload` goes
through `feReadFileBytes`, which returns `Either FileExplorerErr (ByteString, Bool)`
(`FileExplorer.hs:114`) — no warning channel — and the response carries only
`X-Truncated`, `X-Content-Type-Options`, `Content-Disposition`,
`Content-Type` (`API.hs:2390-2398`). With §5.1's `⇩` on the listing row, a
user whose `$HOME` listing is unblocked can download `~/.env` with no viewer,
no content fetch and no banner — strictly weaker than Path A.

1. **Change** the capability's signature to carry the warning:
   `feReadFileBytes :: FilePath -> IO (Either FileExplorerErr (ByteString, Bool, Maybe Text))`.
   (Changed in place, not added alongside — see step 5.)
2. Emit `X-File-Warning: sensitive` on the download response, mirroring the
   existing `X-Truncated` idiom.
3. `downloadFile()` in `useApi.ts` already reads `X-Truncated`
   (`useApi.ts:1820-1828`); it reads `X-File-Warning` the same way and
   surfaces it to the caller.
4. **`downloadFile` must be split into two phases (Sec-B1-R3).** As it stands
   (`useApi.ts:1824-1837`) it creates the blob URL, clicks a synthetic
   `<a download>`, revokes, and *then* returns — so by the time a caller can
   inspect `X-File-Warning`, the file is already saved. A "pre-save"
   confirmation is therefore impossible against the current signature.

   Replace it with:
   ```ts
   requestDownload(path) : Promise<
     { kind: 'ok'; truncated: boolean; warning: string | null; save: () => void }
     | { kind: 'error'; error: string }
   >
   ```
   The header check happens **before** `createObjectURL`; `save()` performs
   the anchor click. The caller shows the confirmation (§5.10) between the
   two. `downloadFile` is retained only as a thin wrapper that calls
   `requestDownload` then `save()`, for non-sensitive call sites.
5. **Replace, do not add alongside.** `feReadFileBytes` must be *replaced* by
   the warning-carrying variant — its signature changes in place, at all
   three constructors (`FileExplorer.hs:195, 210, 407`) and its one call site
   (`API.hs:2388`). No warning-free reader is left on the handle.

   A warning-free reader left on the handle is exactly how this gap arose;
   changing the signature in place makes the three handle arms enforce the
   warning at the type level.

**Still advisory, not blocking** — unchanged from spec §4.3: the operator may
proceed on both paths. This closes the *silent* gap, not the access.

### 5.10 Sensitive-download confirmation (PM-N3)

**Goal (new, explicit):** *Reduce accidental exfiltration of sensitive files
via the download path, **without preventing the download** (an operator may
always proceed).* This is the v1 goal for
the confirmation; it is the only new user-facing interruption this PR adds.

**Behaviour:** when `downloadFile()` reports `X-File-Warning`, the UI shows a
confirmation dialog before saving: "This file is in a sensitive location.
Download anyway?" → Cancel (default focus) / Download.

**Primitive:** reuse the existing modal pattern — `role="dialog"` +
`aria-modal="true"`, as at `ChatArea.tsx:658` (raw-JSON modal) and
`AccessGate.tsx:420`. **Not** `ChatArea.tsx:118`, which is
`aria-modal="false"` — a blocking exfiltration confirmation must be modal.
No new modal component is introduced; the dialog follows those call sites'
structure (backdrop, **focus restore** on close, Escape to cancel). Note: the
cited primitives move and restore focus but do **not** trap Tab — this dialog
matches that behaviour rather than promising a trap.

**Why a modal and not a toast:** the `⇩` affordance is on the listing row, so
there is no other signal; and the viewer banner is post-hoc (content is
already in the DOM). The download confirmation is the one place a *pre-hoc*
interstitial is achievable.

**Acceptance:** cancel → nothing written, no blob URL created; confirm →
download proceeds. Asserted by **T28** (the empty-directory test is T29).

## 6. Security Decision

**No new Origin validation is added for this work.** The spec
(`2026-11-08-file-explorer.md` §4.2) required Origin-header validation on file
routes; it was never implemented, and the route-table comment claiming it is
inaccurate.

**Why it is not needed:** `accessControlMiddleware` gates *every* `api/*` path
— not only mutating methods (`Server.hs:68-74`). In `AccessPasskey` mode a
request without a valid session receives `401`; `/files` appears in neither
`passkeyAllow` nor `unconfiguredAllow`. The `seal_session` cookie is
`HttpOnly`, `SameSite=Strict` and host-scoped, so a DNS-rebound request from a
hostile origin carries no `localhost`-scoped cookie and fails closed with 401.
The mitigation §4.2 asked for is achieved by the access-control layer, which
landed after that spec was written. **Independently confirmed** by the
security reviewer.

### 6.1 Residual threats — stated, not claimed away

**Spec controls claimed but NOT implemented:**

| Spec | Claim | Reality |
|---|---|---|
| §4.1 | Non-loopback requests return 403 unless opted in | **Not implemented.** `Serve.hs:512` is `fromMaybe True (gcFileExplorerEnabled gwCfg)` with no loopback check. Four error strings still say "file explorer disabled (gateway is not loopback)" (`API.hs:2332, 2359, 2380, 2411`) — **all wrong**. Non-loopback binds are warned, never refused (`Serve.hs:621-622`). |
| §4.4 | Each content/download access logged at `InfoS` | **Not implemented.** `API.hs:72` says "audit logging deferred (design §4.4 is SHOULD not MUST)", yet **two** docstrings still assert it: `API.hs:2355` ("Audit-logs the access") and `API.hs:2375` ("...X-Truncated headers. Audit-logs the access."). |
| §4.2 | Origin-header validation on file routes | **Not implemented** (superseded by access control). |

**Follow-up (not this PR):** correct the four error strings and both docstrings
(`API.hs:2355`, `:2375`), and align spec §4.1/§4.2/§4.4 with reality. Trigger:
before any non-loopback bind is documented as supported — so "separate PR"
cannot drift indefinitely.

**Accepted residual risks, explicitly:**

- `access_control.mode = "none"` **with a wildcard bind** resolves no
  canonical origin, so `sameOriginVerdict Nothing = Allowed`
  (`OriginGuard.hs:76`) and the guard is bypassed. On a LAN that is
  unauthenticated arbitrary-file-read. An operator *waiver* written to disk,
  never inferred — but worse than Rev 1's phrasing implied. This covers
  `AccessOpen`, which allows all paths regardless of bind
  (`AccessControl.hs:305-306`).
- A per-run service token is authorised for `api/*`, bypassing passkey.
  In-process only, unreachable from a browser.
- `blockedNames` is **advisory** by design (spec §4.3): sensitive paths warn,
  they do not block. §5.9/§5.10 extend the warning to both read paths.
- `validateFilePath` (`API.hs:2319-2323`) is **lexical only**
  (`lexicalCollapse`), with no `WorkspaceRoot`/symlink containment — unlike
  `mkSafePath`. Correct for a whole-filesystem browser, but a repo symlink can
  be an arbitrary-read pivot, and §5.7 makes symlinks traversable in the tree.
  Stated, not fixed.
- File reads produce no transcript entry (correct — not an opcode) and no
  `seal.log` line (§4.4 unimplemented).
- **Symlink-based `blockedNames` bypass (§5.7 residual).** `checkBlocked`
  matches the *requested* path's components (`FileExplorer.hs:166-168`,
  verified). A symlink `~/x -> ~/.ssh/id_rsa` therefore produces **no
  warning** on either read path — and §5.7 is what makes such a link
  traversable in the tree. Closing this needs post-resolution checking
  (realpath before `checkBlocked`), which is a behaviour change to the
  whole-filesystem browser and is **not** in this PR. Stated, not fixed.

## 7. Testing Plan (TDD)

### 7.0 Existing-test coverage map

`FilesView.test.tsx` has **23** `it` blocks (lines 93-306). Every one maps to
a destination: either preserved, or deliberately inverted. Nothing is dropped
silently.

| # | Current test (line) | Destination |
|---|---|---|
| 1 | renders directory listing with entries (93) | T1 |
| 2 | sorts entries: dirs first, then files (103) | T2 |
| 3 | renders breadcrumb segments (122) | T3 |
| 4 | navigates into subdirectory via pushState (132) | T4 |
| 5 | breadcrumb segment click navigates to parent (147) | T5 |
| 6 | file entries have View link and Download button (158) | T6 |
| 7 | View link navigates to content view (166) | T7 |
| 8 | content in text-escaped `<pre>` + XSS `<script>` (178) | T8 |
| 9 | binary file message (190) | T9 |
| 10 | Download and Back buttons in content view (199) | T10 |
| 11 | download in content view calls downloadFile (207) | T11 |
| 12 | download in listing calls downloadFile via fetch (216) | T12 |
| 13 | truncation warning in listing, X-Truncated (225) | T13 |
| 14 | truncation warning toast, X-Truncated (235) | T14 |
| 15 | warning banner for sensitive directories (245) | T15 |
| 16 | truncation indicator, listing truncated (253) | T16 |
| 17 | truncation indicator, content truncated (260) | T17 |
| 18 | error message 404 (267) | T18 |
| 19 | error message 403 (275) | T19 |
| 20 | error message 400 (283) | T20 |
| 21 | loading spinner (291) | T21 |
| 22 | defaults to home dir with no path (298) | T22 |
| 23 | Back button returns to parent (306) | T23 |

**Back decision:** `content-back` is **retained** in the viewer header as a
breadcrumb-independent exit — a tree UI should not make the breadcrumb the
only way back.

**Truncation naming.** Two distinct mechanisms, currently inconsistently
named. Normalised: `download-truncated-warning` (listing),
`viewer-download-truncated-warning` (viewer). Both are download-`X-Truncated`;
distinct from data truncation (`listing.truncated` / `content.truncated`,
T16/T17).

### 7.1 T-matrix — every preserved test, with its assertion

| ID | Test title | Selects | Asserts |
|---|---|---|---|
| T1 | renders a directory's detail listing | `file-entry-<name>` | all four entry names present |
| T2 | sorts directories before files, alphabetical within group | `[data-testid^="file-entry-"]` order | alpha, beta, apple.txt, zebra.txt in that order |
| T3 | renders breadcrumb segments | `breadcrumb-<path>` | `/`, `/home`, `/home/user` present; "user" text |
| T4 | row click navigates into a subdirectory | `file-entry-documents` | `pushState` called; url has `path=` + encoded `/home/user/documents` |
| T5 | breadcrumb click navigates to that ancestor | `breadcrumb-/home` | `pushState` called; url has `path=` + encoded `/home` |
| T6 | file rows expose open + download affordances | `file-entry-readme.txt`, `download-readme.txt` | `⇩` `.icon-btn` present with an accessible name (focusability is T25's job) |
| T7 | activating a file row opens the viewer | `file-entry-readme.txt` | `pushState` url has `path=` + encoded `/home/user/readme.txt`, **no `view=`** |
| T8 | viewer escapes file content (XSS) | `file-content-pre` | `<pre>` exists; `textContent` contains literal `<script>alert(1)</script>`; `pre.querySelector('script')` is **null** |
| T9 | binary file shows message, no `<pre>` | `binary-file-message` | message present; no `<pre>` rendered |
| T10 | viewer exposes download + back | `content-download`, `content-back` | both present |
| T11 | viewer download uses fetch, not `<a href>` | `content-download` | `downloadFile('/home/user/readme.txt')` called |
| T12 | listing download does not navigate | `download-readme.txt` | `downloadFile` called **and** `pushState` **not** called |
| T13 | listing download truncation warns | `download-truncated-warning` | banner present after `{truncated:true}` |
| T14 | viewer download truncation warns | `viewer-download-truncated-warning` | banner present after truncated download |
| T15 | sensitive-directory banner (listing) | `warning-banner` | present; text matches `/sensitive/i` |
| T16 | listing data truncation | `listing-truncated` | present when `listing.truncated` |
| T17 | content data truncation | `content-truncated` | present when `content.truncated` |
| T18 | 404 error state | `files-error` | text matches `/not found/i` |
| T19 | 403 error state | `files-error` | text matches `/disabled\|forbidden/i` |
| T20 | 400 error state | `files-error` | text matches `/bad request\|invalid/i` |
| T21 | loading spinner | `files-loading` | present while loading |
| T22 | absent `path` defaults to home | — | `fetchFileListing` called with `null`/`undefined`; rail roots at `parent(flPath)`; correct file renders (SC-3) |
| T23 | viewer Back returns to parent | `content-back` | `pushState` url has `path=` + encoded `/home/user`, **no `view=`** |
| T24 | breadcrumb collapses middle segments | breadcrumb ellipsis | >5 segments renders `…`; first + last always visible. (Tail-pinning is a layout property jsdom cannot assert — that part is Playwright.) |
| T25 | rows are keyboard-operable (files **and** directories) | `file-entry-readme.txt`, `file-entry-documents` | file row: `tabIndex=0` + `role="button"` + `aria-label`; **Enter** and **Space** both open the viewer. directory row: `role="link"` + `aria-label`; **Enter** and **Space** both navigate. |
| T26 | rows are focusable and reachable by Tab | `file-entry-readme.txt` | row carries the class the ring rule targets **and** `document.activeElement` is the row after focus (jsdom cannot evaluate `:focus-visible`; the visual ring itself is Playwright). |
| T30 | a bookmarked file cold-loads to the correct view | rail + viewer | cold load of `/files?path=/a/b/c.txt` with empty cache renders the viewer for `c.txt`, with `a`/`b` expanded and selected in the rail (SC-3, UC-3) |
| T27 | viewer renders the sensitive-path banner | `viewer-warning-banner` | banner renders when `content.warning` non-null (§5.9 Path A) |
| T28 | download of a sensitive path confirms first | `download-readme.txt` + dialog | `X-File-Warning` → dialog (`role="dialog"`) appears; cancel writes nothing; confirm proceeds (§5.10) |
| T29 | empty directory shows a message | `empty-directory` | renders when `entries` is empty |

**Retained testids:** `file-entry-<name>`, `breadcrumb-<path>`,
`file-content-pre`, `binary-file-message`, `content-download`, `content-back`,
`download-<name>`, `download-truncated-warning`, `warning-banner`,
`listing-truncated`, `content-truncated`, `files-error`, `files-loading`.
**Renamed:** `download-truncation-warning` → `viewer-download-truncated-warning`;
`view-<name>` → removed (row activation replaces it, T7).
**New:** `rail-node-<path>`, `rail-error-<path>`, `rail-retry`,
`viewer-warning-banner`, `empty-directory`, download-confirm dialog.

### 7.2 `FileTree.test.tsx` — rail component

```
it "renders role=tree with role=treeitem nodes"
it "sets aria-expanded true/false on expand and collapse"
it "sets aria-selected on the current node only"
it "ArrowRight expands the focused node and moves to first child"
it "ArrowLeft collapses, then moves to the parent"
it "ArrowUp/ArrowDown move focus between visible nodes"
it "Enter activates the focused node"
it "shows a per-node spinner while that node's listing loads"
it "shows an inline per-node error when an expand 403s"
it "retries the node fetch on re-click after an error"
it "renders an empty marker for an empty directory"
it "truncates long node labels and sets a title attribute"
it "renders a directory-symlink node as expandable with a badge"
it "renders a dangling symlink node with a badge; activating it surfaces the 404"
it "does not fetch a child until its parent is expanded"
it "reuses a cached child listing on re-expand"
it "restores persisted expansion from localStorage"
it "always expands the target's ancestors on cold load, ignoring stored state"
```

The keyboard/a11y contract is tested **here**, not via `FilesView`, keeping
WU3 self-contained.

### 7.3 Cache unit spec — `useFileListingCache.test.ts`

```
it "returns a cached listing within the TTL"
it "refetches after the TTL expires"                        # fake timers
it "dedups concurrent requests for the same key"
it "hits the $HOME alias: listing(null) then listing(resolvedPath)"     # §5.2
it "stores flPath as a secondary alias"                                 # A3-B1
it "clears the whole map on explicit refresh"
it "clears on last unmount"                                             # A3-B2
it "resetFileListingCache() empties the map"
```

`FilesView.test.tsx` calls `resetFileListingCache()` in `beforeEach`;
otherwise module-scope state leaks across tests and fails in file order.

### 7.4 Mock strategy — fetch layer, not module replacement

Rev 1's plan was **unimplementable**: the current spec replaces the whole
`useApi` module (`FilesView.test.tsx:8-15`), so hooks are stubs, no cache code
runs, and neither the budget nor cache tests can observe anything.

`FilesView.test.tsx` mocks at the **fetch layer**
(`fetchFileListing`, `fetchFileContent`, `downloadFile` — all exported and
mockable via `vi.mock` with `importOriginal`) and uses the **real** hooks:

```ts
expect(fetchFileListing.mock.calls.map(c => c[0]))
  .toEqual(['/home/user'])                       // exactly one parent fetch
```

Cache internals are tested in §7.3, not here.

### 7.5 Frontend — new coverage beyond §7.0

```
it "derives the rail root as parent(path) for a bookmarked file"
it "derives the rail root as parent(flPath) when path is absent"
it "roots the rail at / when path is /"
it "selects and expands the path's ancestors in the rail"
it "scrolls the selected node into view on cold load"
it "reuses the cached parent listing when switching sibling files"
it "issues exactly two requests for a cold file bookmark"
it "issues exactly two requests for a cold directory bookmark"
it "falls back to a content probe when the basename is absent"
it "shows a rail inline error when a node expand 403s"
it "shows a rail retry when the root listing fails"
it "navigates via breadcrumb to a path outside the rail root"
it "renders SVG icons, not emoji"
it "uses --warning for the sensitive-directory banner"
```

### 7.6 Backend — `FileExplorerSpec.hs`

```
it "lists a symlink to a directory with isDir and isSymlink both set"
it "lists a dangling symlink with isSymlink set and isDir false"
it "preserves isSymlink through every local symlink branch"
it "parses SD| symlink-to-directory entries"
it "parses SF| symlink-to-file entries with size and mtime"
it "parses SX| dangling-symlink entries"
it "still parses legacy S| entries"
it "remote listing resolves symlink target type in one round trip"
it "sets fcWarning for ~/.env, ~/.ssh/id_rsa, ~/.netrc (local arm)"
it "sets fcWarning for the same paths (remote arm)"
it "leaves fcWarning Nothing for a normal path"
it "feReadFileBytes carries the warning for a blocked basename"
```

`ApiFilesSpec.hs`: `/content` includes `warning`; `/download` sets
`X-File-Warning` for a blocked path and omits it otherwise. `useApi.test.ts`:
`downloadFile()` surfaces the header.

### 7.7 Not changed

`ApiRouteSpec.hs` route count (73) and the OpenAPI route entry are untouched —
no routes added, and `ffBody` is free-form (`OpenApi.hs:201`) so the new
response field needs no schema change.

### 7.8 Work units

| WU | Scope | Depends on |
|---|---|---|
| WU1 | §5.7 symlink fix + §5.9 both read paths (§5.10) — backend + `FileExplorerSpec` | — |
| WU2 | `useFileListingCache` + §7.3 spec | — |
| WU3 | `FileTree` + §7.2 spec | WU1 |
| WU4 | `FilesView` rewrite + §7.0/§7.1/§7.5 matrix | WU1, WU2, WU3 |
| WU5 | §5.8 style/token/icon pass **+ the `App.css` `:focus-visible` row rule** (D3-1) | WU4 |

The `requestDownload`/`save()` split (§5.9 step 4) belongs to **WU1**: it is
the download-warning contract, not a UI concern.

WU1 is independently shippable (the only backend change) if the tree slips.

## 8. File Scope

Frontend:
- `frontend/src/App.css` — the main-pane row `:focus-visible` rule (§5.6.1),
  modelled on `.icon-btn` (`App.css:391`). **WU5 owns this.**
- `frontend/src/components/FilesView.tsx` — rewritten
- `frontend/src/components/FileTree.tsx` — **new** (§5.6)
- `frontend/src/hooks/useFileListingCache.ts` — **new** (§5.5)
- `frontend/src/hooks/useApi.ts` — `downloadFile` reads `X-File-Warning`
- `frontend/src/components/DownloadConfirmDialog.tsx` — **new**; the §5.10
  confirmation, modelled on `ChatArea.tsx:658`'s modal structure
- `frontend/src/types.ts` — `FileContent.warning` (declared at `:574`)
- `frontend/src/components/__tests__/FilesView.test.tsx` — rewritten
- `frontend/src/components/__tests__/FileTree.test.tsx` — **new**
- `frontend/src/hooks/__tests__/useFileListingCache.test.ts` — **new**
- `frontend/src/hooks/__tests__/useApi.test.ts` — `requestDownload` (§7.6)

Backend:
- `src/Seal/Tools/Exec/FileExplorer.hs` — symlink types (§5.7), `fcWarning` +
  `feReadFileBytes` signature change (§5.9)
- `src/Seal/Gateway/API.hs` — `warning` in `fileContentJson`, `X-File-Warning`
  header
- `test/Seal/Tools/Exec/FileExplorerSpec.hs` — additions
- `test/Seal/Gateway/ApiFilesSpec.hs` — `warning` + header

Docs:
- `docs/superpowers/specs/2026-11-08-file-explorer.md` — §4.1/§4.2/§4.4
  correction (follow-up, §6.1). `MarkdownView`/`transcriptViewMode` are **no
  longer** in scope.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Test rewrite loses coverage | §7.0 maps all 23 current tests; §7.1 defines their T-IDs with testid + assertion. (§7.2-§7.6 are specified by title only and carry no IDs — the audit guarantee covers §7.0/§7.1.) |
| Two-call budget regresses | §7.4 fetch-layer mocks assert exact path sequences (SC-2) |
| Rail root wrong for `/`, `$HOME`, absent path | T22 + §7.5 |
| Symlink protocol change breaks remote listing | `parseRemoteListing` is total (`mapMaybe`, `:584`); `S\|` retained; legacy test kept |
| Dangling symlink misreported as a file | `SX\|` (§5.7) |
| Local symlink fix loses `isSymlink` | "preserve flag on every branch" test (§7.6) |
| Remote tree expansion feels slow | Lazy + cache + dedup (§5.5, §5.6); mux amortizes handshakes |
| Probe-miss (deleted file, truncated listing) | Explicit fallback (§5.3); noted as the only >2-call path |
| Cache keyed on unknowable value | Key on requested path; `flPath` as alias (§5.5) |
| Scope creep into a batched endpoint | Rejected in §5.4 with rationale |
| Symlink window: `isDir:false` + `400 path is a directory` | WU1 ships before WU4 (§7.8); 400 stays user-legible (T20) |
| Keyboard regression on row activation | §5.6.1; T25/T26 assert it |
| New modal interrupts download | Scoped to sensitive paths only; goal in §5.10; T28 |

## 10. Open Questions

1. ~~Rail expanded-state persistence~~ — **resolved** (§5.6): persists to
   `localStorage`; `T`'s ancestors always expand on cold load.
2. ~~Markdown toggle~~ — **resolved: deferred to v2** (§3).
3. Backend TTL cache in v1 or stretch? *Lean: stretch — the frontend cache
   absorbs the common case; measure first.*
4. Follow-up: `var(--accent)` drift in `HarnessControls.tsx:124,130` and
   `ReposView.tsx:578` (§2.1) — separate PR.
5. Follow-up: correct the four "gateway is not loopback" error strings and
   **both** "Audit-logs the access" docstrings (`API.hs:2355`, `:2375`), plus
   spec §4.1/§4.2/§4.4 (§6.1) — separate PR, triggered before any
   non-loopback bind is documented as supported.
6. Discoverability of UC-1: how does the operator get from a finished turn to
   `/files?path=…`? Not addressed in v1; candidate follow-up (transcript links
   were already deferred by the original spec).
7. **Add a frontend CI job.** `.github/workflows/ci.yml:94` runs `cabal test`
   only, so vitest never runs in CI — frontend regressions are caught only by
   a local `make check`. Worth fixing independently of this PR (§3.1).
8. Rail `localStorage` expansion persistence has no UC/SC of its own; it is a
   convenience supporting UC-2 (orientation). Recorded, not promoted.
9. UC-4's "compare" means **cached back-and-forth**, not side-by-side. If
   side-by-side is ever wanted, UC-4 would not be satisfied by §5.1 and this
   design would need revisiting. Stated to close the round-1 question.
