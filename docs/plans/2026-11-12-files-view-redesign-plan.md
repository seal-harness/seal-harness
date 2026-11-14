# Files View Redesign — Implementation Plan

<!-- status: draft v9 -->
<!-- branch: files/explorer2 -->
<!-- date: 2026-11-12 -->
<!-- design: docs/superpowers/specs/2026-11-12-files-view-redesign-design.md (Rev 2.2) -->
<!-- design-gate: 5 reviewers, 3 iterations, all blockers addressed -->
<!-- plan-gate: r1 Scope FAIL — security work re-scoped out; see §"Re-scoping" -->

## Goal

Turn the `Files` section into the eighth member of the frontend's
master-detail family (a 280px tree rail + a detail pane), matching the look and
feel of the other seven section views. **Frontend-only** — no Haskell, no API,
no route changes.

Canonical design: `docs/superpowers/specs/2026-11-12-files-view-redesign-design.md`
(Rev 2.2). Requirement ids R1–R6 refer to
`docs/plans/2026-11-12-files-view-redesign-request.md`.

## Re-scoping after Plan Review Gate round 1

The Scope & Alignment reviewer FAILED draft v1 for smuggling in a
sensitive-path warning channel (WU1 RED3/4/5, all of WU2, and the
`DownloadConfirmDialog`) that traces to no requirement. That finding is
**accepted**, on evidence I verified myself:

- `FilesView.tsx:281-284` **already** renders a per-row Download calling
  `downloadFile(fullPath)`. The redesign relocates a pre-existing control; it
  does not create the exposure. The security gap is a pre-existing bug.
- Draft v1 called WU1 "independently shippable … can land alone if the UI
  slips" — a unit that ships without the UI cannot be a prerequisite *of* it.

**Extracted to a follow-up PR** (not in this plan): `fcWarning` on
`FileContent`, `X-File-Warning` on `/download`, the `feReadFileBytes`
signature change, the two-phase `requestDownload`/`save()` split, and the
sensitive-download confirmation dialog. Design §§5.9, 5.10 remain their
specification; they are simply no longer delivered here.

**Round 2 — backend symlink work also extracted.** The reviewer then FAILED
the symlink unit (draft v2's WU1) by the same principle: it fixes a
*pre-existing* bug (clicking a symlinked directory already 400s today,
`API.hs:2405`), and R1 explicitly says "the functionality seems to be working
as expected". Accepted.

**Round 3 — the frontend-only symlink work is ALSO extracted.** I
re-introduced it as a frontend probe, arguing the capability was recoverable
without Haskell. The reviewer rejected that as the same work in a different
language: `grep -i symlink` over the request file returns **zero** hits, and
"fixes a pre-existing bug" does not care which language the fix is written in.
It was also expensive — the recursion it introduced required a
`RAIL_MAX_DEPTH` cap, a `RAIL_MAX_LISTINGS` eviction policy, and six tests,
all for behaviour nothing requested. **Accepted and removed.**

Honest consequence: a symlinked directory still cannot be expanded, exactly as
today. The only change is that such a node now carries a symlink badge instead
of being indistinguishable from a file.

**Adopted simplification** (reviewer's alternative, verified): WU3's
module-scope cache (Map + refcount + TTL + in-flight dedup + 8 tests) is
replaced by lifting the parent listing — which the probe already fetches —
into `FilesView` state and passing it to `FileTree` as props. Both panes live
in one component (`FilesView.tsx:377`), so this removes a whole file and 8
tests while still giving the rail and detail pane one shared listing.

Also fixed from round 1: R5's passkey-reliance justification is now an
explicit plan item (§WU0), and the third stale security comment
(`API.hs:815-816`, "Non-loopback guard + Origin header validation") is added
to the follow-up list.

## Work units

| WU | Scope | Depends on |
|---|---|---|
| WU0 | Verify + record the passkey/Origin posture (R5) — no code | — |
| WU1 | Frontend: `FileTree` rail component | — |
| WU2 | Frontend: `FilesView` rewrite (integration) | WU1 |
| WU3 | Frontend: style, token and icon pass + `App.css` focus rule | WU2 |

**No backend work, and no symlink work.** Both were extracted (§"Re-scoping"
rounds 2 and 3). `seal-harness.cabal`, `test/Main.hs`, `API.hs` and every
Haskell source are untouched.

## Constraints inherited from the design gate

1. **No new API routes.** Route-count assertion (73,
   `test/Seal/Gateway/ApiRouteSpec.hs:19`) is untouched.
2. **No backend changes at all.** No `.hs`, no `seal-harness.cabal`, no
   `test/Main.hs`, no `API.hs`. Both hotspot files are untouched by
   construction.
3. **No batched endpoint.** Two calls per view is the budget for every
   **normal** path; the SSH mux (`Remote.hs:99-100,157-162`) amortizes
   connection setup (design §5.4). One degenerate case — **probe-miss** — costs
   three (§WU2 GREEN 2). It is bounded, measured, and asserted; see the budget
   note there.
4. **Markdown toggle out of scope** (design §3).
5. **No Origin validation added** (R5 — operator's explicit decision).

---

## WU0 — Verify and record the passkey/Origin posture (R5)

**Design refs**: §6. No code changes. This unit exists because R5's second
acceptance item — *"Reliance on the passkey gate must be justified, not
assumed"* — had no plan item in draft v1.

### Steps

1. Re-verify, with citations, that `accessControlMiddleware` gates every
   `api/*` path (`Server.hs:67,72,74`), that `/files` appears in neither
   `passkeyAllow` nor `unconfiguredAllow` (`AccessControl.hs:317-330`), and
   that the `seal_session` cookie is `HttpOnly` + `SameSite=Strict` and
   host-scoped — so a DNS-rebound cross-origin request carries no cookie and
   fails closed with 401.
2. Record the conclusion and its residual risks in the PR description, citing
   design §6 / §6.1. **Do not add Origin validation to the file routes.**
3. Add to the follow-up list: correct the four "gateway is not loopback" error
   strings (`API.hs:2332, 2359, 2380, 2411`), both "Audit-logs the access"
   docstrings (`API.hs:2355`, `:2375`), **and** the route-table comment
   `API.hs:815-816` ("Non-loopback guard + Origin header validation") — the one
   R5 directly concerns.

### Definition of Done

- [ ] The three verifications above are re-confirmed against current code and
      cited by `file:line` in the PR description.
- [ ] No Origin-validation code is added anywhere in this PR.
- [ ] The follow-up list names the seven stale claims (4 error strings,
      2 docstrings, 1 route comment) — recorded as prose in the PR body, not
      as seven separate citations. This is the minimum needed to stop R5's
      "spec is probably out of date" from silently persisting.

### Named verification (Completeness round 3)

Prose DoD is not verifiable, so each item has an executable check:

- `grep -n 'HttpOnly\|SameSite' src/Seal/Gateway/AccessControl.hs` — cookie
  attributes exist.
- `grep -n '"files"' src/Seal/Gateway/AccessControl.hs` — expect **no output**
  (the `/files` route appears in neither allow-list; the quoted form avoids
  matching the unrelated "two files" comment at `:986`).
- `grep -n '("api" : _)' src/Seal/Gateway/Server.hs` — the api branch is
  gated.
- `git diff 894190b -- src/Seal/Gateway/API.hs | grep -i origin` — expect
  **no output** (this PR adds no Origin validation). `894190b` is the work
  baseline (`files/explorer` tip, also the merge-base with
  `origin/files/explorer2`). **Do not use a bare `main`**: this clone has no
  `main` ref, so `git diff main` exits 128 rather than returning empty — the
  same hazard §R6 already documents for `origin/files/explorer`.
- The PR body contains seven `API.hs:` citations (4 error strings, 2
  docstrings, 1 route comment).

---

## WU1 — Frontend: `FileTree` rail component

**Design refs**: §5.6, §5.7 (badges), §7.2.
**Requirement**: R1 (tree explorer in a left rail).
**Depends on**: nothing.

### Files

- `frontend/src/components/FileTree.tsx` (new)
- `frontend/src/components/__tests__/FileTree.test.tsx` (new)

### Props

The tree is **fully controlled and presentational**. `FilesView` owns all
listings, all loading/error status, and every fetch. `FileTree` receives, per
node: `{ path, name, isDir, isSymlink, expanded, selected, status, children }`
— where `status` is `idle | loading | error`, `selected` marks the current
node, and `children` is the recursive node list (absent when collapsed or not
yet loaded) — plus callbacks `onToggle`, `onSelect`, `onRetry`.
`FileTree` performs **no** fetching and holds **no** state at all — every
value it renders arrives via props. This is what makes WU1 dependency-free.

This replaces design §5.5's module-scope cache. Rationale: both panes live in
one component (`FilesView.tsx:377`), so lifting the listings into `FilesView`
state gives the rail and the detail pane one shared copy without
module-scope lifetime management, refcounting, or a TTL. The 30s TTL is
dropped: a manual refresh (⟳) refetches, which satisfies UC-1's staleness
escape hatch without a timer.

### TDD steps

```
it "renders a nested list of agent-row styled nodes"
it "expands and collapses a directory on click, flipping ▸ to ▾"
it "marks the current node selected"
it "renders a node's loading state from its status prop"
it "renders a node's error state from its status prop, with a retry affordance"
it "calls onRetry when the retry affordance is clicked"
it "renders an empty marker for an empty directory"
it "truncates long node labels and sets a title attribute"
it "marks a symlink node with a badge and does not expand it"
it "calls onToggle once when a collapsed directory node is clicked"
it "does not render children for a collapsed node"
it "renders children passed in props for an expanded node"
it "always expands the target's ancestors on cold load"
it "exposes every node as a focusable button activatable with Enter and Space"
```

**Accessibility is a plain focusable button per node** (Enter + Space) — not a
roving-focus ARIA tree. Verified: there are **zero** `role="tree"` and zero
`aria-expanded` usages anywhere in `frontend/src/components/`, so a bespoke
tree widget would *diverge* from the app rather than match it — the opposite
of what R1 asks for.

### GREEN

Recursive node rendering driven **entirely by props** — expansion state lives
in `FilesView` and arrives via the node's `expanded` field; clicking calls
`onToggle(path)`. Visual shape mirrors the
`SkillGroupSection`/`AgentGroupSection` collapsible-header idiom
(`SkillsView.tsx:123-137`, `AgentsView.tsx:163`): `▸`/`▾` indicates state,
rows use `agent-row` classes. Each node is a focusable `<button>`
(Enter/Space), which is the app's existing affordance — no custom key handling,
no roving focus, **no internal `useState` for expansion**.

**No expansion persistence.** R2 asks the rail to *default* to a standard
state (the parent of `T`), not to restore stored state. Persisting it would
have to be overridden on every cold load anyway, so it buys nothing. Ancestors
of `T` always expand on mount.

**No `⇩` on rail nodes** — only the detail pane carries per-row actions.

**No `:focus-visible`-dependent assertions** — jsdom does not implement it
(there are zero `getComputedStyle`/`toHaveStyle` usages in the suite).

### Definition of Done

- [ ] All 14 tests pass.
- [ ] A collapsed node renders no children even when child listings exist in props (laziness is enforced by `FilesView`, which does not fetch children until `onToggle`).
- [ ] Every node is reachable and activatable by keyboard (Enter and Space).
- [ ] No `localStorage` key is introduced.
- [ ] `make check` green.

---

## WU2 — Frontend: `FilesView` rewrite (integration unit)

**Design refs**: §5.1, §5.2, §5.3, §5.6.1, §8, §7.0, §7.1, §7.5.
**Requirement**: R1, R2, R3.
**Depends on**: WU1.

### Files

- `frontend/src/components/FilesView.tsx` (rewritten)
- `frontend/src/components/__tests__/FilesView.test.tsx` (rewritten)

### Mock strategy change (mandatory)

The current spec replaces the whole `useApi` module (`:12-16`), so the hooks are
stubs and the budget cannot be observed. The replacement is to stub
**`global.fetch`**, which is what every existing network-touching test in this
suite already does (12 files, e.g. `hooks/__tests__/useApi.test.ts`,
`components/__tests__/AccessView.test.tsx`).

Do **not** try to `vi.mock` `fetchFileListing`/`fetchFileContent`. Verified:
the hooks call those as **module-internal bindings**
(`useApi.ts:1767`, `:1802`), so replacing the module export does not patch the
call sites — the mock would silently do nothing and the budget test would
observe zero fetches while passing.

Stub shape: `global.fetch = vi.fn(async (url) => …)` returning
`new Response(JSON.stringify(...), {status})`, dispatched on the `path=` query
param. Then assert on `fetch.mock.calls` URLs to prove the call budget.

**`URL.createObjectURL` must also be stubbed.** jsdom does not implement it
(verified: `frontend/src/test-setup.ts` stubs only `scrollIntoView`, `scrollTo`
and `WebSocket`), yet `downloadFile` calls it (`useApi.ts:1830`). Its `catch`
swallows the resulting throw and returns `{truncated:false}` — so T12/T13/T14
would fail for an unrelated reason with no useful error. Add to
`beforeEach`: `URL.createObjectURL = vi.fn(() => 'blob:x')` and
`URL.revokeObjectURL = vi.fn()`.


### TDD steps

**RED-A — the 23-test preservation matrix.** Write all 23 tests from design
§7.0/§7.1 (T1–T23) **before** touching the component. They fail against the old
component for the right reasons (testids / URL shape changed). Note two
deliberate inversions: T7 and T23 assert the *absence* of `view=` (R2 drops
it).

**RED-B — T24–T26, T29, T30** (5 tests, new behaviour in scope; **T27 is
out of scope with T28** — it needs `content.warning`, which is extracted):
breadcrumb ellipsis; file-row keyboard (Enter **and** Space); row
focusability; empty directory; cold-bookmark load. **T28** (sensitive-download
confirm) is **out of scope** — extracted to the follow-up PR.

**RED-C — 14 rail-integration tests**, numbered so the count cannot drift:

| # | Test |
|---|---|
| 1 | rail root = `parent(T)` for a bookmarked **file** |
| 2 | rail root = `parent(T)` for a bookmarked **directory** |
| 3 | rail root = `/` when `T` is `/` |
| 4 | rail root = `parent(flPath)` when `path` is **absent** (`$HOME`) |
| 5 | `T`'s ancestors expand and `T` is selected on cold load |
| 6 | the selected node scrolls into view once |
| 7 | switching to a sibling costs **≤1 fetch** (parent listing reused) |
| 8 | cold file bookmark = **exactly 2** requests |
| 9 | cold directory bookmark = **exactly 2** requests |
| 10 | probe-miss, `content` **200** = exactly **2** requests |
| 11 | probe-miss, `content` **400** = exactly **3** requests (documented case) |
| 12 | a node whose expand 403s shows an inline rail error |
| 13 | clicking a rail error node retries the fetch |
| 14 | the breadcrumb navigates to a path outside the rail root |

Design §7.5 contributes 12 of these; #10 and #11 are the probe-miss budget
cases this plan adds.

### GREEN

1. **URL model** — `/files?path=<T>` only; drop `&view=content`. Rail roots at
   `parent(T)`; absent `path` → rail roots at `parent(flPath)`.
2. **Probe** — fetch `listing(parent(T))` first, read `T`'s basename `isDir`,
   then one more call (**two total** for every normal path, R3).
   **Probe-miss** (basename absent: file deleted, listing truncated at
   10 000 entries, or a `|`-in-name drop) → one `content(T)` fallback:
   `200` → viewer (**2 calls**); `404` → not-found (**2 calls**); `400
   "path is a directory"` → it is a directory, so `listing(T)` is needed
   (**3 calls**).
   That third call is not avoidable frontend-only: the kind is unknowable
   without asking, and `listing(parent)` genuinely lacked the entry. It is
   confined to an error-ish path (nothing else in the view is missing) and
   asserted by a dedicated test so it cannot regress silently.
3. **Layout** — 280px `--bg-surface` rail + detail pane, reusing `agent-row`
   and the sibling header shape (`px-3 py-2`, uppercase, `letterSpacing:
   0.08em`).
4. **Rows** — each row is a real `<button>` (files) or a button-styled
   `<div role="button">` (directories), with an `aria-label`. Enter and Space
   both activate (native for `<button>`; Space `preventDefault`ed on the div so
   the pane does not scroll). Every in-row action calls `e.stopPropagation()`.
   Inline `.icon-btn` `⇩` for download; no `⋯` menu.
5. **State** — `FilesView` holds a `Map<path, listing>` seeded with the parent
   listing and grown by node expansion; passed to `FileTree` as props.
   Manual ⟳ clears it and refetches.
   Because `FilesView` owns the map, it calls `fetchFileListing` **directly**
   (imperatively, from event handlers and the seed effect) rather than through
   `useFileListing` — the hook holds per-instance state, which is exactly what
   the map replaces. `useFileListing`/`useFileContent` remain used only for
   the single focused file's content in the viewer.
6. **Viewer** — content in `<pre>` (XSS-safe, unchanged), `content-back`
   retained, download via the existing `downloadFile`.
7. **Error/truncation states** — render the warning/truncation banners (the
   visual shape is WU3's job); normalise the two download-truncation testids.

**REFACTOR.** Fix `sortEntries`' stale comment (`FilesView.tsx:55`) — it
claims the backend sets `isDir` for symlinks, which it does not. Correct the
comment; no behaviour change.

### Definition of Done

- [ ] All 23 T1–T23 tests pass (nothing dropped; T7/T23 deliberately inverted).
- [ ] T24–T26, T29, T30 pass.
- [ ] The 14 RED-C tests above (#1–#14) pass, each numbered case present.
- [ ] Budget test asserts the exact path sequence (`['/home/user']`), not a
      call count alone.
- [ ] The budget test fails if the call count is wrong **and** passes when
      correct — proven by temporarily breaking the implementation, because a
      mock that intercepts nothing would also "pass".
- [ ] Every row activatable by keyboard with Enter **and** Space.
- [ ] `content-back` still returns to the parent.
- [ ] `make check` green.

---

## WU3 — Frontend: style, token and icon pass

**Design refs**: §2.1, §5.8, §5.6.1 (the ring rule), §7.4.
**Requirement**: R1 ("matches the look and feel").
**Depends on**: WU2.

### Files

- `frontend/src/components/FilesView.tsx`
- `frontend/src/components/FileTree.tsx`
- `frontend/src/App.css` (the main-pane `:focus-visible` row rule)

### Steps

1. Replace the four undefined tokens with their real equivalents:
   `--text-warning` → `--warning` (`#FBBF24`), `--text-danger` →
   `--needs-input` (`#FF6B6B`), `--accent` → `--accent-secondary`
   (`#4F8EF7`), drop `--border-subtle`. (Design §2.1 — verified: all four grep
   to 0 in `design-tokens.css`.)
2. Replace the emoji (`📁 📄 ↪`) with inline SVGs following the existing idiom
   (`viewBox="0 0 16 16"`, `stroke="currentColor"`, `strokeWidth="1.6"` — the
   **string** form; there are zero uses of `{1.6}` — round caps, 11–12px).
   20 such icons already exist.
3. Replace ad-hoc `buttonStyle` with `.btn .btn-ghost` (viewer) and
   `.icon-btn` (row actions).
4. Add the row `:focus-visible` rule to `App.css`, modelled on `.icon-btn`
   (`App.css:391`).
5. Replace the bespoke warning banner with the `channel-restart-notice` shape.

### Definition of Done

This unit owns the **visual** assertions WU2 deliberately does not (SVG-not-emoji,
`--warning` token, banner shape). Every item is a shell check — this unit adds
no test file, and pretending otherwise is what an earlier draft did wrong.

- [ ] No emoji remain — `grep -nP '[\x{1F300}-\x{1FAFF}\x{2190}-\x{21FF}]' frontend/src/components/FilesView.tsx frontend/src/components/FileTree.tsx` → expect **no output**.
- [ ] No undefined tokens — for each `var(--x)` in the two files,
      `grep -q -- "--x:" frontend/design-tokens.css` must succeed.
- [ ] `grep -n 'focus-visible' frontend/src/App.css` → contains the row rule.
- [ ] `make check` green.

---

## Verification (whole plan)

`make frontend-test` → `npm test` (`Makefile:41`) runs the vitest suite. The
build/`cabal test`/`hlint` halves of `make check` are unaffected by this plan
(no Haskell changes), but running the whole target is still the safe habit.

This is the **honest** evaluation point: CI runs only `cabal test`
(`.github/workflows/ci.yml:94`), so the frontend suite is local only. A
frontend CI job is a follow-up, not part of this plan.

Never pipe `cabal`/`hlint` through `head` — redirect to a file (SIGPIPE).

## Risks

| Risk | Mitigation |
|---|---|
| WU2 drops a test during the rewrite | T1–T23 written **first** (RED-A) from the §7.0 map; reviewer audits the map |
| Budget test passes but production refetches | Fetch-layer mocks (not hook mocks) + exact path-sequence assertion |
| Probe-miss costs a third call | Confined to a missing-entry path; explicitly asserted (2-call and 3-call cases) so it is measured rather than assumed |
| Listing state leaks between tests | Listings live in component state — remount clears them; no module-scope map |
| Symlink entries cannot be expanded | Out of scope, as before this plan. A symlink node renders with a badge and is not expandable — the pre-existing 400 on activation is unchanged |
| Merge conflict in `.cabal`/`test/Main.hs` | **Zero edits** to either (all modules already registered) |
| Dropping `&view=content` breaks old deep links | Old bookmarks fall back to the directory listing (the path still resolves); documented in the PR body |

## R1 acceptance item 4 — "better UX" (mapped)

The request's fourth R1 checkbox ("Better UX than the current full-page
directory listing") is qualitative, so it gets a concrete proxy rather than
being left unmapped:

- [ ] The rail is visible alongside content at all times (never a full-page
      listing) — asserted by T1/T7: with a file open, both `rail-node-*` and
      `file-content-pre` are present in the same render.
- [ ] Selecting a file no longer replaces the whole page — asserted by T7 (no
      `view=` param, component not remounted) and by the cached-sibling-switch
      test (**≤1 fetch** when moving between siblings).

## R3 acceptance item 2 — connection reuse (mapped)

"Reuse a single SSH connection where possible" is a backend property this PR
does not change, so it is verified rather than implemented:

- [ ] `RemoteSpec.hs:225-249` still asserts `ControlMaster=auto`,
      `ControlPath=…/m-%C`, `ControlPersist=600`.
- [ ] The PR body records that every `/api/files*` call rides the `m-` mux
      pool, so N view calls = 1 handshake + N channel opens.

Verification: `nix develop --command cabal test` (the RemoteSpec suite) and a
sentence in the PR body citing `Remote.hs:99-100,157-162`.

## R6 — branch discipline (mapped)

R6 requires that all work lands on `files/explorer2` and that `files/explorer`
is not modified. That is an acceptance item, so it gets a DoD and a check
rather than a header comment:

- [ ] All commits for this plan are on `files/explorer2`.
- [ ] `files/explorer` is unmodified by this work.

Verification, run before opening the PR:

- `git rev-parse --abbrev-ref HEAD` → expect `files/explorer2`.
- `git ls-remote --heads origin` → confirms `files/explorer` still points at
  `894190b` (its pre-work tip), i.e. nothing was pushed onto it.
- `git diff --stat <that sha>..HEAD` → expect only this plan's files. (Do not
  use `origin/files/explorer` directly: there is no local remote-tracking ref
  for it in this clone, so that command errors `unknown revision`. Either
  fetch it first — `git fetch origin files/explorer:refs/remotes/origin/files/explorer --depth 1`
  — or diff against the sha from `ls-remote`.)


---

## Out of scope

- **Sensitive-path warning channel** — `fcWarning`, `X-File-Warning`, the
  `feReadFileBytes` signature change, the two-phase `requestDownload`/`save()`
  split, and the download confirmation dialog. **Extracted to a follow-up PR**;
  design §§5.9/5.10 remain its specification.
- Markdown Rendered/Raw toggle (design §3).
- Row action `⋯` menu.
- Batched API endpoint (§5.4).
- `var(--accent)` drift in `HarnessControls.tsx:124,130` /
  `ReposView.tsx:578`.
- Seven stale security claims (`API.hs:2332, 2359, 2380, 2411` error strings;
  `:2355` and `:2375` docstrings; `:815-816` route comment) — see WU0.
- Frontend CI job.
- Post-resolution `checkBlocked` (symlink bypass of `blockedNames`), design
  §6.1.
