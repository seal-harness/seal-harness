# Handoff: Files view tree-rail redesign — feature complete, no PR opened

**Date**: 2026-11-12 · **Branch**: `files/explorer2` (branched from `files/explorer`)
**PR**: **none** — the operator asked for a push without a PR. `files/explorer`
has its own open PR; leave it alone.

---

## 0. TL;DR

**The work is complete.** Three commits, all pushed, tree clean, everything green:

| Gate | Result |
|---|---|
| `cabal test` | 4294 examples, 0 failures, 41 pending |
| frontend `npm test` | 1030 tests / 43 files |
| `hlint src/ test/` | No hints |
| `cabal build all` | clean |
| `npm run build` | clean |

No pending work units. The next step is whatever the operator wants: open a PR,
continue polishing, or merge into `files/explorer`.

```
d0a72d1 Merge origin/files/explorer2 (main sync) into the batched-listing work
d93a8d6 Files view: batch rail listings into one remote operation
d5b65c9 Files view: root the tree rail at / and stop re-rooting it
f930a10 Files view: tree rail + detail pane
```

---

## 1. What was built

The Files tab was a full-bleed directory listing — the only section view in the
frontend without the shared 280px rail + detail-pane idiom. It is now the eighth
member of that family.

**Frontend**
- `FileTree.tsx` (new) — the rail. Fully **presentational**: expansion,
  selection, status and children all arrive via props; every intent leaves via
  `onToggle`/`onSelect`/`onRetry`. It performs no fetching and holds no state.
- `FilesView.tsx` (rewritten) — owns all listings, status and fetching.
- `App.css` — `.files-row:focus-visible` rule.
- `useApi.ts` — `fetchFileListingWithRail()` for the batched call.

**Backend**
- `FileExplorer.hs` — `feListDirectories :: [FilePath] -> IO (Either Err [FileListing])`
  on the capability handle (local + remote + fail-closed arms), `remoteListDirsCmd`,
  `parseBatchedListing`.
- `API.hs` — optional repeatable `paths` query param on `GET /api/files`.

---

## 2. The four decisions that took the longest — don't relitigate

### 2.1 No ARIA tree

A bespoke `role="tree"` widget with roving focus and arrow keys was specified and
then **removed**. There are **zero** `role="tree"` and **zero** `aria-expanded`
usages anywhere in `frontend/src/components/`. The app's real idiom is a
click-to-expand list of `agent-row`-styled buttons (`SkillsView.tsx:123-137`,
`AgentsView.tsx:163`). Each rail node is a real `<button>`: Enter/Space come for
free, and it matches the codebase instead of diverging from it.

### 2.2 The rail is rooted at `/` and never re-roots

It used to root at `parent(path)`, so it moved under the user on every
navigation. Now:

- Seeded **once** from `/`; main-pane resolution is a separate effect.
- First load expands the current path's ancestors, everything else collapsed.
- Navigation only ever **adds** expansions ("sticky additions"). It never
  collapses, and never re-opens a node the user explicitly collapsed —
  tracked in `collapsedByUser` / `collapsedRef`.

`files/explorer2` commit `d5b65c9`.

### 2.3 Batched listings (this is why the budget is 2)

Rooting at `/` meant one SSH operation per path level. `GET /api/files` now
takes a repeatable `paths` parameter and returns those listings under `rail`,
served by **one** framed shell command.

| Scenario | Budget |
|---|---|
| Cold directory bookmark | **1** request |
| Cold file bookmark | **2** requests (batch + content) |
| Independent of depth | yes |

**Backwards compatible by design:** the single-listing fields stay at the top
level; `rail` appears only when `paths` is supplied. An early draft wrapped the
whole response in `{listing, rail}` and broke existing clients — the
non-batched API test caught it. Do not re-wrap.

### 2.4 The 50 KB transport cap

`Remote.hs:250` caps each operation at 50 KB, and a batch shares that budget
where N separate calls each got their own. **A truncated batch drops the
incomplete directories only**; the frontend re-requests those individually
(`batch.railShort` → `loadListing`). A test asserts a truncated batch returns
only the complete listing. Correctness does not depend on the optimization.

---

## 3. Traps that cost real time — read before editing

**`URL.createObjectURL` is not implemented in jsdom.** `useApi.ts:1830`
(`downloadFile`) calls it; `test-setup.ts` stubs only `scrollIntoView`,
`scrollTo` and `WebSocket`. `FilesView.test.tsx` stubs it in `beforeEach`. Miss
this and three download tests fail for a misleading reason.

**Mock at the fetch layer, not the hook layer.** `useApi.ts:1767`/`:1802` call
`fetchFileListing`/`fetchFileContent` as *module-internal bindings*, so
`vi.mock`-ing the exports intercepts nothing — the test passes while observing
zero fetches. The suite stubs `global.fetch` (the established idiom, 12 files).

**The test mock must register `/`.** The rail seed always asks for it. A missing
`/` route returns 404, the seed's batched call fails, and the cache stays empty —
which manifests as mysterious extra requests. `ensureRoot()` in
`FilesView.test.tsx` handles this centrally.

**`ancestorsOf()` must exclude file targets from the batched `paths`.** Asking
the listing endpoint for a file is a 400 that fails the entire batch. Only
ancestor *directories* are batched.

**Never pipe `cabal`/`hlint` through `head`.** The GHC RTS sets SIGPIPE to
`SIG_IGN`, so the writer hangs. Redirect to a file and read it.

---

## 4. Known follow-ups (all deliberately out of scope)

1. **Sensitive-path warning channel** — the content view and the download path
   both produce zero warning for `~/.env`-class files. Design doc §§5.9/5.10
   are its full specification; it was extracted as unrequested scope. **This is
   the most valuable follow-up** — it closes a real pre-existing gap.
2. **Seven stale security claims** — four `"gateway is not loopback"` error
   strings (`API.hs:2332, 2359, 2380, 2411`), two `"Audit-logs the access"`
   docstrings (`:2355`, `:2375`), and the route comment `API.hs:815-816` which
   still claims *"Non-loopback guard + Origin header validation"*. None of the
   three controls was ever implemented; §4.1/§4.2/§4.4 of
   `docs/superpowers/specs/2026-11-08-file-explorer.md` are out of date.
3. **No frontend CI job** — `.github/workflows/ci.yml:94` runs `cabal test`
   only. Vitest never runs in CI, so frontend regressions are caught only by a
   local `make check`.
4. **Symlinked directories cannot be expanded.** The backend reports
   `isDir = false` for every symlink (`FileExplorer.hs:274-281`), so the rail
   renders one with a `↪` badge and no disclosure. Fixing it needs either a
   realpath check for cycles or a depth cap — it was tried and extracted twice
   as unrequested.
5. `var(--accent)` drift in `HarnessControls.tsx:124,130` and
   `ReposView.tsx:578`.
6. Markdown Rendered/Raw toggle for the viewer — deferred, would reuse
   `MarkdownView` + `lib/transcriptViewMode.ts`.

---

## 5. Documentation produced

| File | What it is |
|---|---|
| `docs/superpowers/specs/2026-11-12-files-view-redesign-design.md` | Design doc, Rev 2.2 |
| `docs/superpowers/specs/2026-11-12-files-view-redesign-gate-round1.md` | Design-gate findings (5 reviewers × 3 rounds) |
| `docs/plans/2026-11-12-files-view-redesign-plan.md` | Implementation plan, v13 |
| `docs/plans/2026-11-12-files-view-redesign-request.md` | Requirements R1–R6 in the operator's words |

---

## 6. If you open a PR

- Target `files/explorer` (this branch's base), **not** `main`. The operator's
  plan is to fold this into the existing `files/explorer` PR.
- Mention in the body: the mock-strategy reasoning (why `global.fetch`),
  the documented probe-miss 3-call case, and the `paths` batch's 50 KB
  degradation — all non-obvious and easy for a reviewer to "simplify" wrongly.
- Push with `BIN_EXEC git`, not `SHELL_EXEC` — only `BIN_EXEC` gets vault
  credential injection.
