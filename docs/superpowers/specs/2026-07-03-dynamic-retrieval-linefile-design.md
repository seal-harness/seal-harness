# Dynamic Retrieval + Line-Oriented Text Abstraction + Paged FILE_READ — Design

> **Phase 3, milestone M-a.** The first slice of the ISA build-out. Establishes
> the *Dynamic Retrieval* page-sizing pattern and a reusable line-oriented
> text-file abstraction, and retrofits `FILE_READ` onto them. The Tools (Meta)
> discovery opcodes (`TOOL_LIST` / `TOOL_SEARCH` / `TOOL_DESCRIBE`) and the
> tool-exposure gating that gives them teeth are the **next** milestone (M-b) —
> see "Deferred / next milestone" below.

**Status:** APPROVED (brainstorming, 2026-07-03).

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
lone Untrusted seed opcode: it resolves a `SafePath` and returns the **entire**
file as a single `TrpText` part, routed through `dispatch`, which does
`recordAndAck` **before** `opRun` (ACK-before-execute).

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

Two new pure-ish modules plus a retrofit of one existing opcode. No changes to
`Seal.ISA.Opcode`, `Registry`, `Dispatch`, or `Seal.Agent.Loop`.

| Module | Kind | Purpose |
|---|---|---|
| `Seal.ISA.Paging` | new, pure | The Dynamic Retrieval sizer + a generic `paginate`. File-agnostic, so it is reused by future list-returning opcodes (memory rows, session lists, the M-b discovery ops), not just files. |
| `Seal.Text.LineFile` | new, pure core + one IO fn | The reusable line-oriented text-file abstraction: a `LineWindow` built on `Paging`, a pure `windowLines`, a thin `readLineWindow`, and a `renderWindow`. The seam agent-def / skills / generic file CRUD reuse later. |
| `Seal.ISA.Ops.File` | modify | Retrofit `FILE_READ` to resolve its `SafePath` (unchanged) and then delegate to `LineFile`, exposing optional `offset` / `limit`. |

**Why split `Paging` from `LineFile`.** The count→page-size math is not
file-specific — the M-b discovery ops page over *opcodes*, and future Audited
opcodes page over memory rows and session lists. Keeping the sizer
file-agnostic is what makes it reusable; `LineFile` layers the line-oriented
text semantics on top.

**Namespaces.** `Seal.ISA.Paging` sits with the ISA machinery it primarily
serves. `Seal.Text.LineFile` introduces a new `Seal.Text.*` namespace for pure
text utilities (the roadmap namespace list has `Seal.Tools`, but this is a pure
text util with no tool/effect character, so `Seal.Text` reads truer). Both are
easy to rename before code lands if preferred.

---

## Component 1 — `Seal.ISA.Paging` (pure)

```haskell
data PageParams = PageParams
  { ppFloor   :: Int      -- minimum page size
  , ppCeiling :: Int      -- maximum page size
  , ppCoeff   :: Double   -- A in round(A·√total)
  }

data Page a = Page
  { pgItems   :: [a]
  , pgOffset  :: Int      -- offset this page starts at (clamped to [0, total])
  , pgTotal   :: Int      -- total item count
  , pgHasMore :: Bool     -- pgOffset + length pgItems < pgTotal
  }

-- clamp(ppFloor, round(ppCoeff · sqrt total), ppCeiling)
pageSize :: PageParams -> Int -> Int

-- paginate params offset mLimit items:
--   size   = maybe (pageSize params total) (clamp 1 ppCeiling) mLimit
--   window = take size (drop offset' items)   where offset' = clamp 0 total offset
paginate :: PageParams -> Int -> Maybe Int -> [a] -> Page a

defaultPageParams :: PageParams   -- PageParams 10 200 4.0
```

**Tuning layers.** *Call layer* is live: `mLimit` (an explicit per-call limit)
overrides the computed size and is itself clamped to `[1, ppCeiling]` so a caller
cannot request an unbounded window. *Config / session layers* are **deferred**:
`PageParams` is a plain record, so threading a `[retrieval]` config section (and
later a per-session override) in is purely additive; this milestone uses
`defaultPageParams` everywhere.

**Properties (QuickCheck):**
- `pageSize` result is always within `[ppFloor, ppCeiling]` (given `floor ≤ ceiling`).
- `pageSize` is monotonic non-decreasing in `total`.
- `paginate`: `pgOffset + length pgItems ≤ pgTotal`; `pgHasMore ⇔ pgOffset + length pgItems < pgTotal`; `pgItems` is a contiguous slice of `items`.
- Explicit `mLimit` wins over the computed size and is clamped to `[1, ppCeiling]`.

---

## Component 2 — `Seal.Text.LineFile` (pure core + thin IO)

```haskell
data LineWindow = LineWindow
  { lwLines   :: [Text]   -- the windowed lines, in file order
  , lwStart   :: Int      -- 0-based index of first returned line
  , lwEnd      :: Int     -- 0-based index just past the last returned line (== lwStart + length lwLines)
  , lwTotal   :: Int      -- total line count in the file
  , lwHasMore :: Bool     -- lwEnd < lwTotal
  }

-- Pure: window over lines already split. Built directly on Paging.paginate.
windowLines :: PageParams -> Int -> Maybe Int -> [Text] -> LineWindow

-- Thin IO: read an ALREADY-RESOLVED path, split into lines, window it.
-- SafePath confinement is the caller's responsibility, so non-opcode callers
-- (future CRUD) reuse this without the ISA.
readLineWindow :: PageParams -> Int -> Maybe Int -> FilePath -> IO LineWindow

-- Content + a machine-actionable footer telling the model how to page forward.
renderWindow :: LineWindow -> Text
```

`renderWindow` example output:

```
…the windowed lines…
[lines 1–72 of 320; 248 more — read with offset=72 for the next window]
```

(Numbers illustrative: `defaultPageParams` gives `round(4·√320)=72` for a
320-line file. The footer displays 1-based line numbers for humans; the `offset`
param is 0-based, so `offset=72` is the line shown as "73". When `lwHasMore` is
`False` the footer states the full range with no "more".)

**Line semantics.** Lines are split on `\n`. A missing final newline still counts
the last line. A single very long line is returned whole — line-oriented text is
the contract; byte-capping pathological lines and binary handling are a separate,
future abstraction (explicitly out of scope). Empty file → `lwTotal = 0`, empty
window.

**Properties (QuickCheck) + one IO test:**
- `lwLines` is a contiguous slice of the input lines, order preserved.
- `lwStart`/`lwEnd`/`lwTotal` consistent; `lwEnd = lwStart + length lwLines`.
- `lwHasMore ⇔ lwEnd < lwTotal`.
- **Reassembly:** paging from offset 0 with successive `lwEnd` values, concatenated, reconstructs the original line list exactly.
- `offset ≥ total` → empty window, `lwHasMore = False`.
- One temp-file test exercises `readLineWindow` end to end.

---

## Component 3 — `FILE_READ` retrofit (`Seal.ISA.Ops.File`)

**Schema.** Add two optional integer properties to the existing input schema:
`offset` (default `0`) and `limit` (default: pager-computed). `path` stays
required. `opOutSchema` documents the windowed-text-plus-footer shape.

**Behavior.** Unchanged front half: authorize, resolve the `SafePath` against the
workspace root, keep the existing `IOError`→error-result guard. New back half:
instead of reading the whole file, call
`readLineWindow defaultPageParams offset mLimit resolvedPath` and return
`renderWindow` as a single `TrpText` part.

**Preserved invariants (must not regress):**
- Trust stays **Untrusted** → `dispatch` still does `recordAndAck` before `opRun`
  (ACK-before-execute).
- `SafePath` still rejects traversal / absolute-escape / out-of-workspace paths.
- `orRecorded` stays the secret-free invocation shape (path + offset/limit);
  content is not added to the transcript beyond today's behavior.

**Behavioral change (intended):** reading a large file now returns a bounded
first window with a "more available / next offset" footer rather than the entire
file. The existing `FILE_READ` tests that assert full-file content are updated to
assert the windowed content + footer; the SafePath-rejection and ACK tests are
untouched.

---

## Error handling

Standard `Either Text` / non-fatal `OpResult` with `orIsError = True`. No new
error ADT. Specifically:
- A path that fails `SafePath` → the existing denial path (unchanged).
- An `IOError` during read → the existing error-result guard (unchanged).
- `offset`/`limit` out of range are **not** errors: `offset` is clamped to
  `[0, total]`, `limit` to `[1, ceiling]`; an offset past the end yields a
  well-formed empty window whose footer says so.

---

## Testing summary

| Unit | Coverage |
|---|---|
| `Seal.ISA.Paging` | QuickCheck: size bounds, monotonicity, slice/`hasMore`/offset invariants, explicit-limit override + clamp. |
| `Seal.Text.LineFile` | QuickCheck: slice/order/consistency, reassembly, offset-past-end; one temp-file IO test for `readLineWindow`. |
| `Seal.ISA.Ops.File` | First-window read + footer; offset paging to the tail; `limit` override; offset-past-end; empty file; **SafePath rejection unchanged; ACK-before-execute unchanged.** |

All under the Nix dev shell: `cabal build all` `-Werror` clean, `cabal test`
green (incl. new properties), `hlint src/ test/` clean. New library modules
registered alphabetically in `seal-harness.cabal` `exposed-modules`; new test
specs in `other-modules` and wired into `test/Main.hs` (alphabetical). One commit
per task.

---

## Deferred / next milestone (M-b)

Consciously out of scope here, recorded so the sequencing is explicit:

- **Tools (Meta) discovery opcodes** — `TOOL_LIST` (read-only catalog),
  `TOOL_SEARCH` (find opcodes by intent), `TOOL_DESCRIBE` (full detail incl.
  trust + output schema). These page over the registry using
  `Seal.ISA.Paging` built here, so this milestone is their dependency.
- **Tool-exposure gating** — a configurable policy that, above a registry-size
  threshold, stops offering the full opcode set natively and instead gates
  *discovery* (not invocation): `TOOL_SEARCH`/`TOOL_DESCRIBE` **activate** an
  opcode by injecting its real `ToolDefinition` into the native tool list for the
  rest of the session, and the model then calls it **directly**. Default remains
  expose-all; gating is opt-in.
- **`TOOL_CALL` is dropped, not deferred.** Its only job was invoking a tool
  absent from the native list; the activation-feeds-native-list mechanism above
  makes it unnecessary — everything is always called directly.

## Deviations from the master roadmap (recorded)

- The roadmap's Phase 3 deliverable 1 names four meta opcodes including
  `TOOL_CALL`; this design **drops `TOOL_CALL`** in favor of gate-discovery /
  call-directly (rationale above).
- The roadmap pairs the Meta group and Dynamic Retrieval in one phase; this
  design **sequences them** — retrieval core first (this milestone), meta ops +
  gating next — because the meta ops depend on the pager and have no live
  consumer until gating exists.
