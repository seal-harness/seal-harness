# Implementation Plan: ASK_HUMAN Stock Answers (Slice 2 — Generic Chat)

**Issue**: https://github.com/seal-harness/seal-harness/issues/91
**Design**: `docs/superpowers/specs/2026-08-10-ask-human-stock-answers-design.md` (rev 2, §4.6)
**Branch**: `feat/ask-human-stock-answers` (continue on Slice 1's branch — Slice 1 PR #92 is still open; `main` lacks the types this plan depends on). Rebase onto `main` after PR #92 merges.
**Tooling**: cabal + Nix (`make`); tests = hspec + QuickCheck; lint = hlint; gate = `cabal build all` + `cabal test` + `hlint src/ test/`.
**User directive**: proceed without stopping at user gates.

This plan covers **Slice 2 (Generic chat — Signal, CLI TUI)** only. Slice 3 (Telegram) gets its own plan.

## Plan-gate iteration history

- **Iteration 1**: Feasibility FAIL (branch strategy), Completeness FAIL (CLI TUI uncovered + end-to-end test missing), Scope FAIL (branch strategy + end-to-end test missing). All 3 blockers traced to the codebase:
  1. **Branch strategy** — the plan said "branch off main" but PR #92 is unmerged and `main` lacks `QuestionOption`/`AskPrompt`/`askHumanWithOptions`/`paOptions`. **Fix (rev 2)**: continue on `feat/ask-human-stock-answers` (Slice 1's branch).
  2. **CLI TUI uncovered** — the design's §4.6 claim "CLI TUI gets it for free (it uses `mkHandleCaps`)" is wrong. The CLI TUI foreground REPL has its own `ccPrompt` (Cli.hs:316, haskeline `getInputLine`, ignores `_opts`) + its own answer path (Cli.hs:716, `deliverNextAnswerAny`, no resolution). The `/bg` path (Cli.hs:623) uses `askHuman` not `askHumanWithOptions`. **Fix (rev 2)**: W2 adds the CLI foreground `ccPrompt` + `/bg` `ccPrompt` (numbered-list rendering + `askHumanWithOptions`); W3 adds `deliverNextAnswerResolvedAny` (session-agnostic variant) + switches Cli.hs:716.
  3. **End-to-end test missing** — the design §6 channel-loop test (inbound `2`/`99`/` 2 ` through the loop) was unassigned. **Fix (rev 2)**: W3 adds end-to-end LoopSpec/RunSpec tests.
  4. **Minor** — W2 file scope should note the `askHumanWithOptions` import-list update in Loop.hs + Signal.Run.hs. **Fix (rev 2)**: noted in W2 file scope.

## Work units

### W1 — `deliverNextAnswerResolved` (folds numeric resolution into the STM transaction)

**DoD:**
- New function `deliverNextAnswerResolved :: AskReplyStore -> SessionId -> Text -> IO (Text, Bool)` in `Seal.Handles.AskReply`.
  - Finds the oldest pending ask for the session (FIFO by `paCreatedAt`, same as `deliverNextAnswer`).
  - If the body (after `T.strip`) is a 1-based decimal `Int` index into that ask's `paOptions` (i.e. `n ∈ [1..length opts]`), substitute the nth option's `qoLabel` as the delivered text.
  - Otherwise (out-of-range number, non-numeric text, or ask has no options), deliver the body as-is ("Other").
  - `T.strip` applied before parsing; `02` → 2 is accepted (decimal `Int` parse).
  - Returns `(deliveredText, accepted)` where `deliveredText` is the resolved label or the body as-is, and `accepted` is `True` if the answer was delivered (same `tryPutTMVar` logic as `deliverNextAnswer`).
  - The numeric resolution + the delivery happen in the **same STM transaction** (gate: Architect #4, Security #2 — eliminates the TOCTOU race + the double-read of the original `resolveStockIndex` design).
- Exported from `Seal.Handles.AskReply` module header.
- The existing `deliverNextAnswer` is kept unchanged (Slice 2 doesn't break the existing callers; the loop call sites switch to `deliverNextAnswerResolved` in W3).
- QuickCheck property: for `n ∈ [1..length opts]`, `deliverNextAnswerResolved` with body `T.pack (show n)` returns `(qoLabel opts[n-1], True)`; for any other input (out of range, non-numeric, empty options), the delivered text equals the body unchanged (`deliveredText == body`), and `accepted` depends on whether a pending ask exists. Use `ioProperty` (see `Seal.Security.PathSpec:84` for the pattern — the test forks an `askHumanWithOptions` thread, `threadDelay`s, then calls `deliverNextAnswerResolved`).

**File scope:**
- `src/Seal/Handles/AskReply.hs` — `deliverNextAnswerResolved`; export.
- `test/Seal/Handles/AskReplySpec.hs` — `describe "deliverNextAnswerResolved"`: numeric-index → label, out-of-range → as-is, non-numeric → as-is, no-options → as-is, QuickCheck property.

**Test first (red):** write the `deliverNextAnswerResolved` tests in `AskReplySpec` before implementing. Watch them fail to compile. Implement. Watch pass. Commit.

---

### W2 — Numbered-list rendering in `ccPrompt` (Loop + Signal)

**DoD:**
- `Seal.Channels.Loop.mkHandleCaps` `ccPrompt` closure: when `apOptions` is non-empty, the `notify` callback sends a numbered list to the peer via `chSend h`:
  ```
  <question>

  1) main — the default branch
  2) develop — ...

  Reply with a number or type your own answer.
  ```
  When `apOptions` is empty, the `notify` sends just the question text (today's behavior).
- `Seal.Channels.Signal.Run` `handleCaps` `ccPrompt` closure: same numbered-list rendering.
- The numbered-list format: question, blank line, one line per option (`N) label — description` — omit the ` — description` if empty), blank line, `Reply with a number or type your own answer.`.
- `AskPrompt` destructured to get `apQuestion` + `apOptions` in the closure.
- `askHumanWithOptions` called (registers `paOptions` in the store so the numeric resolution in W1 works).
- Tests: `LoopSpec` or `RunSpec` assert the `chSend` captured the numbered list format. (The existing tests use `FakeCaps` which captures `ccSend` output — verify the captured text includes the numbered list.)

**File scope:**
- `src/Seal/Channels/Loop.hs` — `mkHandleCaps.ccPrompt` closure (numbered-list rendering + `askHumanWithOptions`); add `askHumanWithOptions` to the `Seal.Handles.AskReply` import list (line ~100).
- `src/Seal/Channels/Signal/Run.hs` — `handleCaps.ccPrompt` closure (same); add `askHumanWithOptions` to the `Seal.Handles.AskReply` import list (line ~54).
- `src/Seal/Channel/Cli.hs` — **(gate-plan correction: the design's §4.6 claim "CLI TUI gets it for free (it uses mkHandleCaps)" is wrong):**
  - **Foreground `ccPrompt` (line 316):** render the numbered list as the haskeline prompt string (`getInputLine` accepts a multi-line prompt). When `apOptions` is non-empty, build the prompt as `question + numbered list + "Reply with a number or type your own answer."`; when empty, just the question text (today's behavior). Call `askHumanWithOptions` (registers `paOptions` so the foreground `deliverNextAnswerResolvedAny` in W3 can resolve). The foreground REPL's `ccPrompt` is synchronous (haskeline blocks on input), so the `notify` callback is the prompt rendering itself.
  - **`/bg` `ccPrompt` (line 623):** switch `askHuman` → `askHumanWithOptions`; in the `notify` callback, send the numbered list via `ccSend caps` (the `/bg` session's sends go to the foreground's stdout). Destructure `AskPrompt` to get `apOptions`.
- `test/Seal/Channels/LoopSpec.hs` — extend an existing test or add one asserting the numbered list is sent when options are present.
- `test/Seal/Channels/Signal/RunSpec.hs` — same.
- `test/Seal/Channel/CliSpec.hs` — assert the foreground `ccPrompt` builds the numbered-list prompt when options are present.

**Test first (red):** write the LoopSpec/RunSpec test asserting the numbered list is sent. Watch it fail (the current `notify` sends just the question text). Implement. Watch pass. Commit.

---

### W3 — Loop call sites switch to `deliverNextAnswerResolved` + `deliverNextAnswerResolvedAny` (CLI) + end-to-end tests

**DoD:**
- `Seal.Channels.Loop` (line 379): `deliverNextAnswer askReply sid body` → `(_, delivered) <- deliverNextAnswerResolved askReply sid body`. The `delivered` boolean drives the existing `if delivered then loop h reg bgConvSid else ...` (semantics preserved).
- `Seal.Channels.Signal.Run` (line 141): same switch.
- **`deliverNextAnswerResolvedAny`** (new, session-agnostic variant of `deliverNextAnswerResolved`, in `Seal.Handles.AskReply`): the CLI TUI's foreground REPL uses `deliverNextAnswerAny` (Cli.hs:716) which is session-agnostic (one input stream serves the active session + any `/bg` background sessions). The new `deliverNextAnswerResolvedAny :: AskReplyStore -> Text -> IO (Text, Bool)` is the resolved variant: finds the oldest pending ask across ALL sessions (FIFO by `paCreatedAt`), resolves a numeric body to the indexed label (same `T.strip` + `n ∈ [1..length opts]` logic as `deliverNextAnswerResolved`), delivers, returns `(deliveredText, accepted)`. Exported from `Seal.Handles.AskReply`.
- `Seal.Channel.Cli` (line 716): `deliverNextAnswerAny askReply (T.pack line)` → `(_, delivered) <- deliverNextAnswerResolvedAny askReply (T.pack line)`.
- Import `deliverNextAnswerResolved` in `Loop.hs` + `Signal.Run.hs`; import `deliverNextAnswerResolvedAny` in `Cli.hs`.
- **End-to-end tests (gate-plan correction: the design §6 channel-loop test was unassigned):**
  - `LoopSpec` or `RunSpec`: drive `ccPrompt (AskPrompt q [opt1, opt2])` → capture the `chSend` numbered list → inject an inbound body `"2"` through the loop → assert the `askHumanWithOptions` thread unblocks with `opt2`'s label.
  - Same test with `"99"` → assert the thread unblocks with `"99"` (as-is, no resolution).
  - Same test with `" 2 "` (whitespace) → assert the thread unblocks with `opt2`'s label (`T.strip` applied).
- The existing `deliverNextAnswer` + `deliverNextAnswerAny` tests in `AskReplySpec` stay green (the functions are unchanged).
- The existing loop tests (`LoopSpec`, `RunSpec`, `CliSpec`) stay green for non-options cases (the behavior is unchanged when `paOptions == []`).

**File scope:**
- `src/Seal/Handles/AskReply.hs` — `deliverNextAnswerResolvedAny` (session-agnostic variant; export).
- `src/Seal/Channels/Loop.hs` — line 379 switch; import `deliverNextAnswerResolved`.
- `src/Seal/Channels/Signal/Run.hs` — line 141 switch; import `deliverNextAnswerResolved`.
- `src/Seal/Channel/Cli.hs` — line 716 switch to `deliverNextAnswerResolvedAny`; import `deliverNextAnswerResolvedAny`.
- `test/Seal/Channels/LoopSpec.hs` or `test/Seal/Channels/Signal/RunSpec.hs` — end-to-end resolution tests (`2`/`99`/` 2 `).

**Test first:** the existing loop tests stay green for non-options cases. The new end-to-end tests exercise the integrated `ccPrompt` → `deliverNextAnswerResolved` flow. Write the end-to-end tests first (red — the resolution doesn't work yet because `deliverNextAnswer` doesn't resolve). Implement the switches. Watch pass. Commit.

---

### W4 — Gate check

**DoD:**
- `cabal build all` green (`-Werror` clean).
- `cabal test` green (including the new `deliverNextAnswerResolved` tests).
- `hlint src/ test/` → No hints (my files).
- Self-review: re-read the design's AC7 — "The generic chat channel (Signal, CLI TUI) renders a numbered list of options; a numeric inbound reply (after `T.strip`, `n ∈ [1..length opts]`) resolves to the indexed label via `deliverNextAnswerResolved` (single STM transaction, no TOCTOU race); a non-numeric or out-of-range reply is delivered as-is ('Other')." Verify each clause is met.

**File scope:** none (verification only).

---

## Dependencies (graph)

```
Slice 1 types (QuestionOption, AskPrompt, askHumanWithOptions, paOptions) — prerequisite (on feat/ask-human-stock-answers branch)

W1 (deliverNextAnswerResolved + deliverNextAnswerResolvedAny) ─┬─> W3 (loop + CLI call sites switch + end-to-end tests)
                                                                └─> W2 (numbered-list rendering needs askHumanWithOptions to register paOptions)

W2 (numbered-list rendering in Loop + Signal + Cli) ─> W3 (the loops must render the list AND resolve the reply)
all ─> W4 (gate check)
```

**Critical path:** W1 → W2 → W3 → W4. W1 and W2 can be partially parallelized (W1 is the store; W2 is the rendering), but both must be done before W3.

## Risks

- **`deliverNextAnswerResolved`/`deliverNextAnswerResolvedAny` STM complexity** — the numeric resolution must happen inside the same STM transaction as the `tryPutTMVar` delivery. The `T.strip` + `Int` parse are pure (fine inside STM). The `tryPutTMVar` + `writeTVar` are STM (fine). The resolution reads `paOptions` from the `PendingAsk` (already in the map — no extra read needed).
- **CLI TUI foreground `ccPrompt`** — the haskeline `getInputLine` accepts a multi-line prompt string, so the numbered list can be the prompt itself. But the human's reply (e.g. `2`) goes through `deliverNextAnswerResolvedAny` (Cli.hs:716), NOT back through `ccPrompt`. The `ccPrompt` closure is synchronous (haskeline blocks), so the `askHumanWithOptions` thread blocks until the answer is delivered. The numbered list is the prompt; the human types `2`; the `loop` (Cli.hs:716) calls `deliverNextAnswerResolvedAny` which resolves `2` → the 2nd label → delivers to the waiting `askHumanWithOptions` thread → `ccPrompt` returns the label. This flow is correct but subtle — the `ccPrompt` closure doesn't see the reply; the loop does.
- **Numbered-list format** — the format is a rendering concern. A mismatch between the format and the numeric resolution (e.g. 0-indexed vs 1-indexed) would be a bug. The format is 1-indexed (`1) ... 2) ...`) and the resolution is 1-indexed (`n ∈ [1..length opts]`) — consistent.
- **`deliverNextAnswer`/`deliverNextAnswerAny` backward compat** — the existing functions are kept (not removed). Slice 2 adds the resolved variants + switches the loop/CLI call sites. The existing tests stay green.
- **Slice 1 dependency** — the plan continues on `feat/ask-human-stock-answers` (Slice 1's branch). If PR #92 merges to main first, rebase. If PR #92 receives review feedback that changes Slice 1's types, this plan may need adjustment.