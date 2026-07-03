# Dynamic Retrieval + Line-Oriented Text Abstraction + Paged FILE_READ — Design

> **Phase 3, milestone M-a.** The first slice of the ISA build-out. Establishes
> the *Dynamic Retrieval* page-sizing pattern and a reusable line-oriented
> text-file abstraction, and retrofits `FILE_READ` onto them. The Tools (Meta)
> discovery opcodes (`TOOL_LIST` / `TOOL_SEARCH` / `TOOL_DESCRIBE`) and the
> tool-exposure gating that gives them teeth are the **next** milestone (M-b) —
> see "Deferred / next milestone" below.

**Status:** APPROVED (brainstorming, 2026-07-03). Revised after design-review
gate round 1 (see "Review-gate revision log" at the end).

**Goal:** ship the pieces of Phase 3's "self-describing ISA + Dynamic Retrieval"
work that have immediate, gating-independent value: a generic page sizer, a
reusable line-oriented text abstraction that later agent-def / skills / generic
file CRUD will all sit on, and a `FILE_READ` that returns bounded line windows
instead of whole files.

**Non-goal (this milestone):** any change to how opcodes are exposed to the
model. Every opcode remains a native provider tool offered every turn
(`registryToolDefs`), exactly as today. Discovery opcodes and exposure gating
are M-b.

---

## Background & context

The agent loop (`Seal.Agent.Loop`) offers the model the full opcode set as
native tools each turn via `registryToolDefs (aeRegistry env)`. The ISA is
"data" (`Seal.ISA.Opcode`): an `Opcode` carries `opName`, `opTrust`, `opDesc`,
`opInSchema`, `opOutSchema`, a pure `opAuthorize`, and an effectful `opRun ::
BackendExec -> Value -> App OpResult`. `FILE_READ` (`Seal.ISA.Ops.File`) is the
lone Untrusted seed opcode: it resolves a `SafePath`, then **reads at most
`maxReadBytes = 65536` (64 KiB)** via `BS.hGet` and returns the decoded text as
a single `TrpText` part — routed through `dispatch`, which does `recordAndAck`
**before** `opRun` (ACK-before-execute). All its IO is funnelled through the
`BackendExec` seam (`runLocal backend`) and guarded by `try @IOError`. Its own
comment states: *"Phase-3 Dynamic-Retrieval will implement proper paging."* That
64 KiB bound is a memory-safety property this milestone must **preserve**, not
drop.

Two roadmap deliverables motivate this milestone:

1. **Dynamic Retrieval pattern** — a shared "stat first, then adapt" page sizer,
   `page_size = clamp(floor, round(A·√total), ceiling)`, tunable at
   config / session / call layers, reused everywhere a retrieval opcode returns
   bounded content.
2. A retrofit of `FILE_READ` onto that pattern so large files return a bounded
   window rather than dumping the whole file into the context.

During design the user added a structural requirement: the line-oriented
file-access logic must be a **reusable abstraction**, not baked into `FILE_READ`,
because it will be reused in at least three places — agent-definition CRUD,
skills CRUD, and generic file operations (all Phase 5). The abstraction's
essential nature is *tool calls / opcodes for working with line-oriented text
files*; binary files would want a different abstraction and are out of scope.

---

## Architecture

Two new modules plus a retrofit of one existing opcode. No changes to
`Seal.ISA.Opcode`, `Registry`, `Dispatch`, or `Seal.Agent.Loop`.

| Module | Kind | Purpose |
|---|---|---|
| `Seal.Core.Paging` | new, pure | The Dynamic Retrieval sizer + a generic `paginate`. File-agnostic and placed at a neutral leaf namespace, so it is reused by future list-returning opcodes (memory rows, session lists, the M-b discovery ops) without those consumers depending on `Seal.ISA.*` or `Seal.Text.*`. |
| `Seal.Text.LineFile` | new, pure core + one IO fn | The reusable line-oriented text-file abstraction: a `LineWindow` built on `Seal.Core.Paging`, a pure `windowLines`, a **bounded** `readLineWindow` taking an opaque `SafePath`, and a `renderWindow`. The seam agent-def / skills / generic file CRUD reuse later. |
| `Seal.ISA.Ops.File` | modify | Retrofit `FILE_READ` to resolve its `SafePath` (unchanged), then delegate to `LineFile` through the `BackendExec` seam, exposing optional `offset` / `limit`. |

**Why split `Paging` from `LineFile`.** The count→page-size math is not
file-specific — the M-b discovery ops page over *opcodes*, and future Audited
opcodes page over memory rows and session lists. Keeping the sizer file-agnostic
is what makes it reusable; `LineFile` layers the line-oriented text semantics on
top.

**Namespaces (resolved after gate feedback).** The pager goes to
**`Seal.Core.Paging`**, not `Seal.ISA.Paging`: it is claimed file- and
ISA-agnostic and is imported by `Seal.Text.LineFile` (itself reusable outside the
ISA), so homing it under `Seal.ISA.*` would make every non-ISA `LineFile`
consumer transitively depend on the ISA — the dependency arrow would read
backwards. `Seal.Core` is the existing leaf namespace for shared vocabulary, so
the arrow becomes `Seal.Text → Seal.Core` (clean) and `Seal.ISA.Ops.File →
{Seal.Core.Paging, Seal.Text.LineFile}` (clean). `Seal.Text.*` is a **new**
namespace for pure text utilities; the roadmap's namespace list is illustrative
("matching the README architecture"), and a dedicated `Seal.Text` reads truer for
this than shoehorning a text util into `Seal.Tools` (which is earmarked for
tool/opcode *execution*, e.g. `Seal.Tools.Exec.*` in Phase 4). *If the maintainer
prefers `Seal.Tools.LineFile`, it is a mechanical rename.*

---

## Component 1 — `Seal.Core.Paging` (pure)

```haskell
data PageParams = PageParams
  { ppFloor   :: Int      -- minimum page size (invariant: 1 <= ppFloor <= ppCeiling)
  , ppCeiling :: Int      -- maximum page size
  , ppCoeff   :: Double   -- A in round(A·√total)  (invariant: ppCoeff >= 0)
  }

data Page a = Page
  { pgItems   :: [a]
  , pgOffset  :: Int      -- offset this page starts at (clamped to [0, total])
  , pgTotal   :: Int      -- total item count (= length of the input list)
  , pgHasMore :: Bool     -- pgOffset + length pgItems < pgTotal
  }

-- clamp ppFloor..ppCeiling of round(ppCoeff * sqrt (fromIntegral total))
pageSize :: PageParams -> Int -> Int

-- The single source of truth for "how many items to return", shared by
-- paginate (list path) and readLineWindow (streaming path) so they cannot drift:
--   windowSize params total mLimit = maybe (pageSize params total) (clamp 1 ppCeiling) mLimit
windowSize :: PageParams -> Int -> Maybe Int -> Int

-- paginate params offset mLimit items, where total = length items:
--   offset' = clamp 0 total offset
--   size    = windowSize params total mLimit
--   window  = take size (drop offset' items)
paginate :: PageParams -> Int -> Maybe Int -> [a] -> Page a

defaultPageParams :: PageParams   -- PageParams { ppFloor = 10, ppCeiling = 200, ppCoeff = 4.0 }
```

`clamp lo hi x = max lo (min hi x)` — value last, matching `Data.Ord.clamp (lo,hi) x`.

**Tuning layers.** *Call layer* is live: `mLimit` (an explicit per-call limit)
overrides the computed size and is itself clamped to `[1, ppCeiling]` so a caller
cannot request an unbounded window — an explicit limit may reach `ppCeiling` but
never exceed it. *Config / session layers* are **deferred**: `PageParams` is a
plain record, so threading a `[retrieval]` config section (and later a
per-session override) in is purely additive; this milestone uses
`defaultPageParams` everywhere.

**Properties (QuickCheck).** Arbitrary `PageParams` is generated under the
invariants (`1 <= ppFloor <= ppCeiling`, `ppCoeff >= 0`); `total = length items`:
- `pageSize` result is always within `[ppFloor, ppCeiling]`.
- `pageSize` is monotonic non-decreasing in `total` (both `sqrt` and `round` are
  monotone non-decreasing; test expectations near `x.5` account for Haskell
  banker's rounding, e.g. `round 2.5 == 2`).
- `paginate`: `pgOffset + length pgItems <= pgTotal`; `pgHasMore ⇔ pgOffset +
  length pgItems < pgTotal`; `pgItems` is exactly `take size (drop pgOffset items)`
  (a contiguous slice, order preserved).
- **Security invariant (dedicated case):** for *any* `offset` (incl. negative or
  huge) and *any* `mLimit` (incl. negative or huge), `length pgItems <=
  ppCeiling` and `pgOffset ∈ [0, total]`. Negative offsets, over-large offsets,
  and unbounded limits are all defused here.

---

## Component 2 — `Seal.Text.LineFile` (pure core + one bounded IO fn)

```haskell
data LineWindow = LineWindow
  { lwLines     :: [Text]  -- the windowed lines, in file order
  , lwStart     :: Int     -- 0-based index of first returned line (== the Page pgOffset)
  , lwEnd       :: Int     -- 0-based index just past the last returned line (lwStart + length lwLines)
  , lwTotal     :: Int     -- total line count (see truncation note)
  , lwHasMore   :: Bool    -- lwEnd < lwTotal, OR the scan was truncated at the byte ceiling
  , lwTruncated :: Bool    -- True if the file exceeded the scan byte ceiling (lwTotal is a lower bound)
  }

-- Pure: window over lines already split. Built directly on Seal.Core.Paging.
windowLines :: PageParams -> Int -> Maybe Int -> [Text] -> LineWindow

-- Bounded IO: read an opaque, already-confined SafePath and window it WITHOUT
-- materializing the whole file. SafePath (from Seal.Security.Path, not the ISA)
-- keeps workspace confinement type-enforced for every caller — opcode or future
-- CRUD — while still allowing reuse "without the ISA".
readLineWindow :: PageParams -> Int -> Maybe Int -> SafePath -> IO LineWindow

-- Content + a machine-actionable footer telling the model how to page forward.
renderWindow :: LineWindow -> Text
```

### Line semantics (pinned)

Lines are produced by **`Data.Text.lines`** (never `T.splitOn "\n"`). This is the
correctness-critical choice the red tests assert against. Worked examples:

| Input bytes | `T.lines` result | `lwTotal` |
|---|---|---|
| `"a\nb\nc\n"` | `["a","b","c"]` | 3 |
| `"a\nb\nc"` (no final newline) | `["a","b","c"]` | 3 |
| `""` (empty file) | `[]` | 0 |

`T.splitOn "\n"` is wrong here: it would yield `["a","b","c",""]` (4) for the
first row, inflating `lwTotal` and every footer count. Because `T.lines` collapses
the trailing-newline distinction, the reassembly property (below) is stated over
the **line list**, not byte-identity to the original file. A `\r` from a CRLF file
is returned **verbatim** on each line (line-oriented text contract; no
normalization).

### Bounded memory (the fix for the gate's #1 blocker)

`readLineWindow` MUST NOT hold the whole file in memory. Guarantee: peak memory is
`O(window size + O(1))`; the full file is never materialized as `[Text]`.
Recommended mechanism — two streaming passes over the file `Handle`:

1. **Count pass:** stream lines, counting `lwTotal`, holding O(1) memory. Enforce
   the scan byte ceiling `maxScanBytes` **at the byte/chunk level while
   accumulating a line** — never read a whole line and then check the ceiling, or
   a single newline-free file would blow the bound before the check runs. If the
   ceiling is hit before EOF, stop; set `lwTruncated = True` and let `lwTotal` be
   the count so far (a lower bound; it may be `0` for a newline-free file, handled
   by footer guard 1).
2. **Compute** `size` from `PageParams`/`mLimit` and `lwTotal` (via the shared
   `windowSize` helper — see Paging), then a **window pass:** stream again,
   `drop lwStart`, `take size` lines into the window (O(window) memory).

`lwHasMore = (lwEnd < lwTotal) || lwTruncated`. Peak memory is `O(window +
O(1))`; the whole file is never materialized — closing the 64 KiB-drop
regression. `maxScanBytes` is a **fixed compile-time constant ≥ the current
65536**, never model- or call-influenced, so the memory bound cannot be widened
at call time. Because both passes scan from the file start bounded by
`maxScanBytes`, paging is supported *within* the scanned region only; tail-paging
of a file larger than `maxScanBytes` is **not** a goal of this milestone —
`lwTruncated`/`lwHasMore` communicate the truncation honestly. The two passes read
the file twice, so a concurrent external mutation between passes could make
`lwTotal` (pass 1) disagree with the pass-2 window; the result stays bounded and
well-formed (best-effort snapshot semantics, same TOCTOU window class as today's
`mkSafePath`→`withFile`).

### `renderWindow` output (pinned for all states, with evaluation order)

Windowed lines are joined with `"\n"` (`T.intercalate "\n"`, preserving line
content), then a blank line, then exactly one footer line. Footers use **ASCII
hyphen-minus** and 1-based inclusive display line numbers (`lwStart+1 .. lwEnd`);
the `offset=` value in the footer is the **0-based** `lwEnd` (copy-paste ready).

The footer states **overlap** (an empty window at end-of-file satisfies both
"offset past end" and "final"; a newline-free file over the cap satisfies both
"empty" and "truncated"), so the footer is chosen by this **total, ordered**
guard — first match wins. Implement it in exactly this order; do NOT reproduce a
table in some other order:

1. `lwTotal == 0 && lwTruncated` → `[no line break within the scan limit; file may be a single long line or non-line-oriented]`
2. `lwTotal == 0` → `[empty file (0 lines)]`
3. `lwStart == lwEnd` (empty window on a non-empty file — offset at/past the counted end):
   - if `lwTruncated`: `[offset {lwStart} reached the scan limit ({lwTotal}+ lines counted so far); read with offset=0 to restart]`
   - else: `[offset {lwStart} is past end of file ({lwTotal} lines); read with offset=0 to start over]`
4. `lwTruncated` → `[lines {lwStart+1}-{lwEnd} of >={lwTotal} (file exceeds scan limit; more may exist) - read with offset={lwEnd} for the next window]`
5. `lwEnd < lwTotal` → `[lines {lwStart+1}-{lwEnd} of {lwTotal}; {lwTotal-lwEnd} more - read with offset={lwEnd} for the next window]`
6. otherwise (`lwEnd == lwTotal`, `lwStart < lwEnd`) → `[lines {lwStart+1}-{lwEnd} of {lwTotal} (end of file)]`

Guards 1–3 catch every empty/degenerate window, so the range-printing states
(4–6) fire only when `lwStart < lwEnd`. Therefore **no state can ever emit an
inverted range** like `321-320` — this is now enforced by the guard order, not
merely asserted, and is checked by a dedicated property (see Testing). (Numbers
illustrative: `defaultPageParams` gives `round(4·√320)=72` for a 320-line file,
so its first window footers as `[lines 1-72 of 320; 248 more - read with
offset=72 for the next window]`.)

### Properties (QuickCheck) + IO tests

- `windowLines`: `lwLines` is a contiguous slice of the input lines, order
  preserved; `lwEnd == lwStart + length lwLines`; `lwHasMore ⇔ lwEnd < lwTotal`
  (pure path, `lwTruncated=False`).
- **Reassembly:** paging from offset 0 with successive `lwEnd` values,
  concatenating `lwLines`, reconstructs the original **`T.lines` list** exactly.
- `offset >= total` → empty window, `lwHasMore = False`, offset-past-end footer.
- IO: temp-file tests for `readLineWindow` covering a small multi-line file
  (exact window + footer), a no-trailing-newline file (`lwTotal` correct), an
  empty file, and a file engineered to exceed `maxScanBytes`
  (`lwTruncated = True`, memory stays bounded).

---

## Component 3 — `FILE_READ` retrofit (`Seal.ISA.Ops.File`)

**Schema.** `path` stays required; add two optional integer properties `offset`
(default `0`) and `limit` (default: pager-computed). The single-required-string
`singleStringSchema` helper cannot express this, so add a small **local** schema
builder in `Ops/File.hs` (do not prematurely share it; `singleStringSchema` stays
for the other ops). The `offset` property's `description` states the 0-based
convention explicitly ("0-based line index; the line displayed as N is offset
N-1"). `opOutSchema` stays lightweight (the output is a single free-text part —
windowed content plus footer — not an exhaustively-schema'd object).

**Input parsing (the gate's #5 blocker).** `path`, `offset`, `limit` are parsed
leniently from the model-supplied JSON: missing → default; a non-integer,
malformed, or negative value → the default (`offset` 0, `limit` = computed), never
a throw. The clamps in `paginate` (`offset`→`[0,total]`, `limit`→`[1,ceiling]`)
are the second line of defense; parsing is the first. `opAuthorize` still requires
`path`.

**Behavior.** Unchanged front half: authorize, resolve the `SafePath` against the
workspace root via `runLocal backend (mkSafePath root rel)`, keep the existing
`Left PathError` denial branch. New back half, still funnelled through the seam
and `try @IOError` exactly as today:

```haskell
Right safe -> do
  eWin <- runLocal backend (try @IOError (readLineWindow defaultPageParams offset mLimit safe))
  let recorded = object ["path" .= rel, "offset" .= offset, "limit" .= mLimit]  -- uniform in both branches
  case eWin of
    Left ioErr -> pure (OpResult [TrpText (T.pack (show ioErr))] True recorded)
    Right win  -> pure (OpResult [TrpText (renderWindow win)] False recorded)
```

**Preserved invariants (must not regress):**
- Trust stays **Untrusted** → `dispatch` still does `recordAndAck` before `opRun`
  (ACK-before-execute).
- `SafePath` still rejects traversal / absolute-escape / blocked-name / symlink
  escapes, and now the seam type (`SafePath`) makes an unconfined read
  impossible to express, in `FILE_READ` and in every future reuse site.
- All IO funnelled through `BackendExec` (`runLocal backend`) so Phase 4's remote
  executor still slots in; `try @IOError` retained.
- **Memory stays bounded** (`maxScanBytes`), preserving today's protection.
- `orRecorded` stays the secret-free invocation shape — now `path` + `offset` +
  `limit`, all non-secret request metadata (matching the existing "path is
  secret-free metadata" comment). File content still flows only to `orParts`,
  never to `orRecorded`/transcript, and `renderWindow`'s footer text is derived
  from counts only — it never echoes file content into `orRecorded`.

**Behavioral change (intended):** reading a large file now returns a bounded first
window with a next-offset footer rather than a 64 KiB byte-truncated blob. The
existing `FILE_READ` tests that assert full/64 KiB content are updated to assert
the windowed content + footer; a new test asserts a large file returns bounded
content (`lwHasMore` true / bounded line count), **not** the whole file. The
SafePath-rejection and ACK tests are untouched.

---

## Error handling

Standard `Either Text` / non-fatal `OpResult` with `orIsError = True`. No new
error ADT.
- A path that fails `SafePath` → the existing denial branch (unchanged).
- An `IOError` during read → the existing `try @IOError` error-result branch.
- `offset`/`limit` out of range or malformed are **not** errors: they degrade to
  defaults (parse layer) and are clamped (`paginate` layer); an offset past the
  end yields a well-formed empty window whose footer says so.

---

## Testing summary

| Unit | Coverage |
|---|---|
| `Seal.Core.Paging` | QuickCheck under generated invariants: size bounds, monotonicity (banker's-rounding-aware), slice/`hasMore`/offset invariants, explicit-limit override + clamp, and the security case (any offset/limit ⇒ bounded window, offset ∈ [0,total]). |
| `Seal.Text.LineFile` | QuickCheck: slice/order/consistency, reassembly over the `T.lines` list, offset-past-end; `renderWindow` exact strings for all six ordered states with the guard order asserted; a **no-inverted-range property** (whenever a footer prints a numeric range, `lwStart+1 <= lwEnd`) that mechanically enforces the guarantee across all states; IO temp-file tests incl. no-trailing-newline, empty, over-`maxScanBytes` (assert `lwTruncated` **and** that the read stays bounded, not just the flag), and a **newline-free file exceeding `maxScanBytes`** (`lwTotal==0 && lwTruncated` → footer guard 1, memory still bounded). |
| `Seal.ISA.Ops.File` | Lenient offset/limit parsing (malformed→default, no throw); first-window read + footer; offset paging to the tail; `limit` override; **large file → bounded content, not full file**; empty file; **SafePath rejection unchanged; ACK-before-execute unchanged; IO through the seam.** |

All under the Nix dev shell: `cabal build all` `-Werror` clean (strict warning
set), `cabal test` green (incl. new properties), `hlint src/ test/` clean. New
library modules registered alphabetically in `seal-harness.cabal`
`exposed-modules`; new test specs in `other-modules` and wired into `test/Main.hs`
(alphabetical). One commit per task. Clean-room throughout.

**Interactive smoke (manual, not a gate):** the milestone is user-testable via the
**CLI channel** (`seal tui` with `ANTHROPIC_API_KEY`), where the agent loop offers
`FILE_READ` as a native tool — ask the model to read a large file and observe a
bounded window plus a correct next-offset footer, then a follow-up read at that
offset. (The web channel named in the master roadmap was never built; Phase 2
shipped the CLI slice, so CLI is the live channel here.)

---

## Deferred / next milestone (M-b)

Consciously out of scope here, recorded so the sequencing is explicit:

- **Tools (Meta) discovery opcodes** — `TOOL_LIST` (read-only catalog),
  `TOOL_SEARCH` (find opcodes by intent), `TOOL_DESCRIBE` (full detail incl.
  trust + output schema). These page over the registry using `Seal.Core.Paging`
  built here, so this milestone is their dependency.
- **Tool-exposure gating** — a configurable policy that, above a registry-size
  threshold, stops offering the full opcode set natively and instead gates
  *discovery* (not invocation): `TOOL_SEARCH`/`TOOL_DESCRIBE` **activate** an
  opcode by injecting its real `ToolDefinition` into the native tool list for the
  rest of the session, and the model then calls it **directly**. Default remains
  expose-all; gating is opt-in.
- **`TOOL_CALL` is dropped, not deferred.** Its only job was invoking a tool
  absent from the native list; the activation-feeds-native-list mechanism above
  makes it unnecessary — everything is always called directly.

## Deviations from the master roadmap (recorded, and mirrored into the roadmap)

- The roadmap's Phase 3 deliverable 1 names four meta opcodes including
  `TOOL_CALL`; this design **drops `TOOL_CALL`** in favor of gate-discovery /
  call-directly.
- The roadmap pairs the Meta group and Dynamic Retrieval in one phase; this
  design **sequences them** — retrieval core first (this milestone), meta ops +
  gating next — because the meta ops depend on the pager and have no live consumer
  until gating exists.

The master roadmap's Phase 3 section is updated in lockstep to record the M-a/M-b
re-slice and the `TOOL_CALL` drop, so the two documents do not diverge.

---

## Review-gate revision log

Design-review gate round 1: PM APPROVED; Architect / CTO / Security / Designer
NEEDS_REVISION. Consolidated blockers, all addressed above:

1. **Unbounded-memory regression** (Architect/CTO/Security) — the whole-file
   `[Text]` read dropped today's 64 KiB bound. Fixed: `readLineWindow` is
   `O(window)`-memory via streaming with a `maxScanBytes` ceiling +
   `lwTruncated`/`lwHasMore` reporting.
2. **Raw `FilePath` seam** (Architect/Security) — pushed SafePath confinement onto
   callers by convention. Fixed: `readLineWindow` takes opaque `SafePath`;
   confinement is type-enforced for all present and future callers, and non-ISA
   reuse is preserved (SafePath ∈ `Seal.Security.Path`).
3. **Split semantics** (Architect/CTO) — pinned `T.lines` with worked examples;
   reassembly restated over the line list; CRLF returned verbatim.
4. **`renderWindow` undefined for empty/degenerate windows** (Designer/CTO/
   Architect) — all five footer states pinned with exact strings; no inverted
   ranges.
5. **Model-input validation** (Security) — lenient offset/limit parsing (→default,
   never throw) plus the `paginate` clamps.

Folded-in suggestions: route `readLineWindow` through the `BackendExec` seam +
`try @IOError`; pager moved to the neutral leaf `Seal.Core.Paging` (layering);
`PageParams` invariants + constrained Arbitrary + banker's-rounding note;
`total = length items` pinned; local FILE_READ schema builder; `lwStart := Page
pgOffset` correspondence documented; large-file-bounded test (PM); roadmap updated
in lockstep (Architect/PM question). Open judgment call surfaced to the
maintainer: the new `Seal.Text` namespace vs `Seal.Tools`.

Design-review gate round 2: Architect / CTO / Security **APPROVED** (all round-1
blockers verified fixed). Designer **NEEDS_REVISION** with one precise blocker,
corroborated by CTO and Security: the footer states were pinned as exact strings
but their **evaluation precedence** was not, and two states overlap
(final/offset-past-end; empty/truncated), so a first-match implementation could
re-emit an inverted `321-320` range. Fixed: `renderWindow` now specifies a single
**total, ordered** guard (six cases, empty/degenerate windows caught by guards
1–3 before any range-printing state), plus a `no-inverted-range` property.
Round-2 refinements folded: `maxScanBytes` enforced at byte level and pinned as a
fixed compile-time constant ≥ 65536; the inaccurate "can page past the ceiling"
claim removed (tail-paging beyond the cap is explicitly out of scope); shared
`windowSize` helper so the list and streaming paths can't drift; uniform
`orRecorded` (`path`+`offset`+`limit`) in both FILE_READ branches; best-effort
two-pass snapshot semantics noted. Out of scope, tracked: per-loop FILE_READ rate
limiting (Security medium-risk).
