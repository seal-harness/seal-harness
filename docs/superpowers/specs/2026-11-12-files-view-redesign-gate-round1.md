## Verdict summary

| Reviewer | Verdict |
|---|---|
| Security Design | NEEDS_REVISION — 2 blockers, 2 suggestions |
| Architect | NEEDS_REVISION — 3 blockers, 3 suggestions |
| CTO | NEEDS_REVISION — 8 blockers, 4 suggestions |
| Product Manager | NEEDS_REVISION — 4 blockers, 4 suggestions |
| Designer | NEEDS_REVISION — 3 blockers, 2 suggestions (§2 audit PASSED) |

**Gate result: NEEDS_REVISION.** Rev 2 required before the Plan Review Gate.

## Consolidated blockers

### Security (verified independently by orchestrator)

**S1 — Sensitive-directory warning unreachable on the content-read path.**
`checkBlocked` runs only on the listing arm (`FileExplorer.hs:234, :422`).
`FileContent` has no `warning` field; `fileContentJson` emits
`path/content/truncated/linesRead/isBinary` only. `blockedNames` =
`.env .ssh .gnupg .netrc .seal` (`Path.hs:52-53`), matched per path component.
So `GET /api/files/content?path=~/.env` — parent `$HOME` is *not* blocked —
produces zero warning end-to-end. §5.2/UC-3 make bookmarked content reads
routine, so this now bites. Spec §4.1 named exactly this class as the
catastrophe.
*Fix*: extend `checkBlocked` to the read arm and add `warning` to
`FileContent`, OR state plainly in §6 that the banner is unreachable for
`.env`-class paths.

**S2 — Three inaccurate security controls, not one.**
- (a) §4.1 non-loopback 403 never implemented: `Serve.hs:512` is
  `fromMaybe True (gcFileExplorerEnabled gwCfg)` with no loopback check, yet
  four error strings claim "gateway is not loopback" (`API.hs:2332, 2359,
  2380, 2411`).
- (b) §4.4 audit logging absent: `API.hs:72` says "audit logging deferred",
  while `API.hs:2355` still asserts "Audit-logs the access."
- (c) §4.2 Origin validation stale comment.
§6's standard is "stated rather than claimed away" — must list all three.

### Architect (verified independently by orchestrator)

**A1 — Cache placement contradiction.** §5.5 says the Map is "held in the
view"; §8 says `useApi.ts`. `useFileListing` is per-instance `useState`
(`useApi.ts:1755-1779`, verified), so a Map inside it is per-hook-instance:
the rail (`P`) and main pane (`T`) never share it and §5.3's two-call budget
silently becomes three. Must pick one location and specify in-flight dedup,
else simultaneous mounts double-fetch `P` and the §7.1 invocation-count test
fails in practice.

**A2 — No fallback when `T`'s basename is absent from `listing(P)`.** It can
be absent: listing truncates at `listingEntryLimit = 10000`
(`FileExplorer.hs:128, 259`); `parseRemoteListing` silently drops lines whose
name contains `|` (`FileExplorer.hs:583-585`, documented limitation,
verified); `P` may 403/404. Specify a content-call fallback or a "cannot
resolve" pane.

**A3 — §5.7 under-specified, and §5.3 depends on it.**
(a) `SF|` carries no size/mtime — must `stat -L` to keep `F|name|size|mtime`,
else symlinked files regress to `—`.
(b) Broken symlink: `-L` true, `-d` false → `SF|`, click → 404; state it or
add a tag.
(c) §5.3's premise (basename `isDir` decides the pane) holds only *after*
§5.7 lands — say so. Also `feIsSymlink`'s comment "not followed in listing"
(`FileExplorer.hs:81`) needs updating.

### CTO (verified independently by orchestrator)

**C1-C7 — Coverage lost in the test rewrite.** §7.1 has 18 entries against 24
existing tests. Unpreserved:
- C1 sort order (dirs first) — the *only* test pinning `sortEntries`, which
  §5.7 changes.
- C2 XSS escaping (`<script>` renders as text, no `<script>` element) — the
  only security-relevant frontend test; §7.1 never mentions it.
- C3 loading spinner (`files-loading`).
- C4 both download `X-Truncated` header warnings (distinct from the
  server-side `listing.truncated` / `content.truncated` flags — different
  mechanisms).
- C5 Back/parent navigation (`content-back`) — §7.1 offers only the
  outside-rail-root breadcrumb case, a different exit.
- C6 breadcrumb *rendering* + subdir-click nav + breadcrumb-to-parent: §5.2
  makes the breadcrumb the sole guaranteed navigation path, so these need
  explicit entries.
- C7 `downloadFile` non-`<a href>` contract (a real past bug).

**C8 — Mock strategy cannot observe the budget or cache.** The spec does
`vi.mock('../../hooks/useApi')` — a full module replacement (verified,
`FilesView.test.tsx:8-15`), so the hooks are stubs and no cache logic runs.
Under that mock, "issues exactly two requests" and "reuses the cached parent
listing" are unobservable. §7 must specify fetch-level mocks
(`fetchFileListing`/`fetchFileContent`) plus real hooks, and fake timers for
the TTL window.

### CTO suggestions

- TDD readiness: NO. §7.1 is an end-state title list with no mock shape, no
  RED-GREEN-REFACTOR sequence, no per-unit ordering. Since the mock
  architecture must change (C8), RED cannot be written from Rev 1.
- §8 vs §5 mismatch: §5.1 mandates a Markdown Rendered/Raw toggle reusing
  `MarkdownView` + `lib/transcriptViewMode.ts`; neither file is in §8 and no
  toggle test exists. Conversely §8 lists `FileTree.test.tsx` as new while
  §7.1/§7.2 contain zero FileTree cases.
- Decomposable into ~4 units (backend symlink fix → tree → view rewrite →
  cache), but no boundaries/dependency order stated.
- §9 risk row 1 is self-referentially unfulfilled (says "enumerate every
  assertion," while §7.1 is missing C1-C7).
- §9 misstates the mechanism: `parseRemoteListing` returns `[FileEntry]` via
  `mapMaybe` (`FileExplorer.hs:584`), not `Maybe`. Conclusion unchanged.

## Confirmed accurate (survived adversarial review)

- §5.4 SSH-mux claim: **CONFIRMED**. `muxArgs "m"` applied unconditionally
  (`Remote.hs:99, 159-161`); both FileExplorer remote paths ride it
  (`FileExplorer.hs:427, 462, 499`); `RemoteSpec.hs:225-249` asserts the three
  options, both pools and disjointness. Minor: ControlPath is an absolute
  path, not `~`-form (`Remote.hs:160, 164-176`) — cosmetic.
- §5.3 parent-first probe error mapping: **CONFIRMED**
  (`API.hs:2405-2406`; `FileExplorer.hs:239-243, 429-431`). Arithmetic right.
- §5.7 `SD|`/`SF|` backward compatibility: **SOUND** — `mapMaybe` drops
  unknown tags.
- §2 token audit: **CONFIRMED** by designer and independently by orchestrator
  (all four claimed-undefined tokens grep to 0; all three claimed-real tokens
  exist with cited values).

## Open questions to resolve in Rev 2

1. Is `content-back` retained, or replaced by breadcrumb-only exit? (C5)
2. Are download `X-Truncated` warnings kept in the new `⋯` menu flow? (C4)
3. May the rewrite mock `fetchFileListing`/`fetchFileContent` instead of the
   hooks? (C8 — required, must be explicit)
4. Does the Markdown toggle ship in v1, or defer out of §5.1?
5. Does "explicit refresh" clear the whole cache map or just the focused key?
   (A1 — nested-stale × TTL interaction unspecified)
6. Should `SF|` sort as a file but be badged with the dir glyph? (§5.1 implies
   badge-only)

## Addendum — CTO second independent review

A second CTO reviewer independently reproduced the same verdict and all the
same substantive findings (B1-B5 above), which is strong evidence they are
real rather than reviewer noise. Additional specifics worth carrying into
Rev 2:

**Refines C8 (mock layer).** §7.1 #8/#9 ("issues exactly two requests") are
really *hook-invocation* counts — §7.1 never states the counting assertion
(e.g. `useFileListing.mock.calls` distinct paths). And the cache test cannot
live in `FilesView.test.tsx` at all: its mock replaces `useFileListing`
wholesale, so a mocked hook always returns data and "1 call instead of 2" is
unobservable through that seam. A `useApi`/cache test file is in neither §7
nor §8.

**Refines C4 (truncation overload).** Distinguish **data truncation**
(`listing.truncated` / `content.truncated`) from **download** `X-Truncated`
toasts. The existing testids `download-truncated-warning` vs
`download-truncation-warning` are already inconsistent — normalize them.

**Additional unpreserved coverage**: subdir-click navigation is only implied
by "renders a directory's detail listing," which asserts rendering, not the
`pushState` path. Breadcrumb *rendering* (segments + testids) is asserted
nowhere.

**B4 (new behavior with no test)**: Markdown Rendered/Raw toggle (§5.1),
refresh-button cache clear (§5.5), `⋯` menu "Copy path" (§10 Q2 if adopted).

**Suggested §7.0**: a table mapping each of the 24 existing `it`s → its
destination test name. Adopting this kills C1-C7 permanently and makes the
mapping auditable in the doc rather than in review prose.

**Suggested work-unit sequence**: (1) backend `SD|`/`SF|` + `FileExplorerSpec`;
(2) `useApi` cache + hook tests; (3) `FileTree` + tests; (4)
`FilesView` rewrite with the full preserved matrix; (5) style/token pass.
Sequenced 1→2→3→4, with (5) last.

**New risk to add (§9)**: `listing` reports `isDir:false` while `content`
returns `400 path is a directory` — the symlink window before §5.7 lands.
Needs the 400 state to stay user-legible; §7.1 #17 covers 400 for listing only.
# Files View Redesign — Design Review Gate Round 1

**Date**: 2026-11-12
**Design doc**: `docs/superpowers/specs/2026-11-12-files-view-redesign-design.md` (Rev 1)
**Branch**: `files/explorer2`

## Product Manager — NEEDS_REVISION

Verified: PM blocker 1 is a real self-contradiction in the design doc.

**P1 — UC-4 overclaims what §5.1 delivers.** UC-4 promises clicking siblings
"without losing the listing" (`design.md`, §4 UC-4), but §5.1 states:
"Selecting a **file** swaps the right pane to a viewer" (line 125-126). The
rail survives; the sibling *listing* does not. As written, a use case is not
delivered by the design.
*Fix*: reword UC-4 to the actual benefit ("switch files without a page
reload; the parent listing is cached, so returning costs 0 calls", §5.5), OR
keep the listing visible beside the viewer.

**P2 — Ungoaled, untested feature in §5.1.** The Markdown Rendered/Raw toggle
appears in no §3 Goal, no §4 UC, and no §7.1 test. Textbook feature creep.
*Fix*: promote to a Goal with a UC + test, or defer to v2.

**P3 — No user-outcome success criteria.** §3/§5.4 give an engineering budget
(two SSH ops) and §7.1 a regression test — good mechanisms, but nothing
measures UC-1's actual claim ("verify a file without opening a terminal").
*Fix*: add 1-2 measurable outcomes + how/when evaluated.

**P4 — UC-5 not delivered by this work.** Download already exists and is only
relocated into the `⋯` menu (§5.1). Should be labelled a retained capability,
not a redesign use case — it inflates the UC count and hides that v1's real
value is UC-1..UC-3.

### PM suggestions

- §5.7 symlink fix **is justified in-scope**: verified independently
  (`localEntry` sets `isDir = False`; `remoteListCmd` emits bare `S|name`;
  `sortEntries`' comment claims the opposite). Keep it, but note it is the
  only backend change and would make a clean standalone PR if the tree slips.
- Reframe honestly: §2 (token/emoji/layout drift) is the primary
  justification; §4 UCs are secondary gains. That framing survives scrutiny.
- Missing scenario: discoverability of UC-1 — how does Zoe get from a finished
  turn to `/files?path=…`? §5 has no affordance.
- UC use cases clear: 3 of 5 (UC-1, UC-2, UC-3). No user research cited; §2
  evidence is a code audit only.

### PM questions

1. Does UC-4's "compare" require side-by-side, or is cached back-and-forth
   acceptable?
2. Is remote mode (Sam/UC-3/UC-5) actually in use, or hypothetical?

## Product Manager — second independent review (NEEDS_REVISION)

A second PM reviewer reproduced the same UC-4 and feature-creep findings
(strong corroboration) and added two blockers worth carrying into Rev 2.

**P5 — §3 carries no success criteria.** The only measurable goal is §5.4's
two-SSH-operation budget — a *technical* budget, not a user outcome. Nothing
states what improves for UC-1..UC-5: no baseline, no failure signal, no
evaluation point. §7's tests are contract tests; they prove the design works,
not that it helped. *Fix*: a §3.1 with per-UC outcomes, e.g. UC-1 "verify an
agent-modified file without leaving the browser — zero terminal round-trips";
UC-4 "≤1 fetch per sibling switch" (§5.5 already implies this).

**P6 — UC-3's "share with a colleague" is undeliverable as designed.**
§6 states passkey mode returns 401 without an enrolled session, so a colleague
opening `/files?path=…` gets nothing. Verified: UC-3 (§4) says "he can share
or revisit it ... with a colleague", while §6 establishes the session
requirement. *Fix*: narrow UC-3 to *revisit/reload my own bookmarks*, or state
the enrollment precondition explicitly.

**P7 — Three features have no use case.** The §5.1 Markdown Rendered/Raw
toggle, §10 Q2 "Copy path", and the §5.5 refresh button. No UC-1..UC-5
requires any of them; the toggle also drags `MarkdownView` +
`lib/transcriptViewMode.ts` into scope without appearing in §8.

### PM suggestions (second review)

- **§5.7 is in-scope, not creep** — a symlinked directory cannot be a tree
  node, so UC-2 fails on any real repo. Justified. But it buys that with a
  Haskell + remote-protocol change; if backend slips, a frontend-only interim
  (treat symlink as navigable, fall back on the 400) preserves UC-1/UC-2.
- **Accessibility gap**: §5.1's hover-only `⋯` menu removes the touch and
  keyboard path to UC-5. Keep a download control in the viewer header and
  make the menu focus-reachable. (Note: `.session-archive` already has a
  `:focus-visible` rule, so the pattern supports this — but §5.1 does not
  say the new menu inherits it.)
- Ask whether anyone besides the operator ever loads `/files`. If not, UC-3
  is single-user bookmarking and Sam's "share" framing should be dropped.
- Is there recorded evidence for §1's "feels like leaving the app", or is it
  inference? (Orchestrator note: it is inference from a code/visual audit —
  the doc should say so.)

## Gate status after all five reviews

| Reviewer | Verdict |
|---|---|
| Security Design | NEEDS_REVISION (S1, S2) |
| Architect | NEEDS_REVISION (A1, A2, A3) |
| CTO | NEEDS_REVISION (C1-C8 + addendum) |
| Product Manager | NEEDS_REVISION (P1-P7) |
| Designer | see below |

**Consolidated theme**: the design's *engineering* claims largely survived
adversarial review (SSH mux, probe arithmetic, symlink protocol
compatibility, token audit all CONFIRMED). What failed is (a) the doc's
honesty about security controls it claims but which were never implemented,
(b) cache placement and test-mock architecture, (c) use cases that promise
more than the design delivers, and (d) a test plan that silently drops 8 of
24 existing tests including the only XSS assertion.

## Designer — NEEDS_REVISION (§2 PASSES)

**§2 token audit — VERIFIED CORRECT by an independent reviewer.** Confirms
all four claimed-undefined tokens absent (`--accent`, `--border-subtle`,
`--text-warning`, `--text-danger`) and all three claimed-real tokens present
with the cited values. Also confirms the sibling-view idiom claim (`width:
280` in exactly 7 non-Files views; ChannelsView header shape; 21 SVG icons;
FilesView the sole emoji file). The doc's central evidence stands.

**D1 — `⋯` menu is under-specified with no primitive to reuse.**
`.session-archive` (`App.css:816`, verified) is an 18×18 icon button that
reveals on hover — it is *not* a menu. Zero `role="menu"`/`aria-haspopup`
and no popover CSS exist in the codebase. Because Download becomes reachable
*only* through this menu, UC-5 depends on undefined behavior: dismissal
(outside-click/Escape), focus return, edge positioning/flip, `aria-expanded`.
*Fix*: specify the primitive, or keep an explicit download control in the
viewer header.

**D2 — Rail error surface undefined.** A 403/404 on `listing(P)` or on a
tree-node expand has no home; the main-pane `ErrorState` (`FilesView.tsx:172`)
is the wrong place for a rail failure. Decide inline-rail vs banner, and
which pane owns retry.

**D3 — Three edge cases absent from §5/§7.1**: long filenames in a 280px
rail; deep-path breadcrumb overflow; scroll-into-view when ancestors are
auto-expanded on cold load.

### Designer questions

1. Rendered/Raw storage: §5.1 says reuse `transcriptViewMode`, but
   `seal.transcriptViewMode` is the transcript's *global* preference — sharing
   couples file viewing to transcript rendering. Separate key? Which
   extensions count as markdown? Where does the toggle sit?
2. Does the rail persist expanded state (open Q1) *and* survive a cold
   bookmark load?

### Designer suggestions — one correct, one INCORRECT

- **CORRECT (adopt)**: §2.1's "rest of the app uses `--accent-secondary` for
  links" is inaccurate as an absolute. `var(--accent)` with **no fallback**
  also appears at `HarnessControls.tsx:124,130` and `ReposView.tsx:578`
  (verified). The drift is wider than FilesView. Rev 2 must scope it or record
  it as a follow-up.
- **INCORRECT (reject)**: the claim that `--needs-input` appears on "72 lines,
  not 63". Verified count is **63** (`grep -rn "var(--needs-input)"
  --include=*.tsx . | wc -l`), matching the design doc. Orchestrator
  re-verified; the doc is right and the reviewer miscounted.
- Adopt: §7.1 omits two live assertions — empty-directory state
  (`FilesView.tsx:295`, verified) and `download-truncated-warning`.
- Adopt: specify tree a11y (`role="tree"`/`treeitem`, `aria-expanded`, arrow
  keys).
