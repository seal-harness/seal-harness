# Turn failure visibility — Requirements

**Status**: approved 2026-11-27 (operator accepted all four flagged defaults).
**Branch**: `fix/turn-failure-visibility`
**Scope**: Every surface a user can drive a turn from: web UI, CLI/TUI, and
the chat channels (Signal, Telegram).

**Frozen**: 2026-11-27. Changes from here are scope-change requests requiring
human sign-off, not review fixes.

> **What this document is.** The operator's review surface: the complete
> user-facing behaviour, and nothing else. It is the baseline every later
> design and plan is measured against. If it is not visible to a person
> watching their turn, it does not belong here.
>
> **Review cost**: ~2 minutes.

### Decisions taken at approval (all defaults, accepted by the operator)

1. **Durable failure entries live in the conversation transcript** — a
   whitelisted harness entry — so they scroll back naturally and reach chat
   channels via the existing reply fan-out. Consequence accepted: the model
   sees its own prior turn failures in context on later turns.
2. **Headline plain language, cause line raw.** e.g. headline
   `Turn failed — invalid UTF-8 in tool output`, cause
   `UnicodeException in readBounded`, plus a reference id. Mapping is
   best-effort with a generic fallback for unmapped exceptions.
   
   **AMENDED 2026-11-27 during design review — pending operator sign-off,
   see Amendments.** "Raw" is narrowed to a **closed vocabulary**: the cause
   line renders a fixed string per failure class (`UnicodeException`,
   `resource exhausted (No space left on device)`, `provider returned HTTP
   <status>`, or the exception TYPE NAME), never `show e`. Reason: the
   existing redaction rules are opcode-provenance based and say nothing about
   arbitrary exception text, and no secret-*value* scrubber exists in the
   codebase — so a free-text cause cannot satisfy constraint 1, and would be
   written into `conversation.jsonl` and sent to Telegram/Signal. Full raw
   detail remains in `seal.log`, reachable by the reference id. This
   preserves decision 2's stated intent ("tell a disk-full from a provider
   outage from a code bug") while making secret leaks structurally
   impossible.
3. **Every failed turn sends one message to its chat channel.** Consequence
   accepted: an outage during retries could produce several messages.
4. **Background turns and child workers surface failures on their own
   session**, not the parent's transcript. Consequence accepted: a parent is
   not told its child crashed.

---

## Behaviour

When a turn does not complete — an exception anywhere in the turn body, a dead
or stuck transcript writer, a provider failure, a crash inside a forked
worker — the user is told **that the turn failed and why**, on the surface
they started it from, and the explanation remains readable afterwards.

Today none of that happens on the web surface. A failing turn leaves the tab
looking like a normal completed turn: the status goes `thinking` → `idle`, no
reply appears, and no error is shown. The operator's only signal is "nothing
happened". This document fixes that.

## What the user sees

**In the web UI**, the failure appears in the transcript itself, as its own
entry, visually distinct from assistant text and from a tool result:

```
⚠ Turn failed — invalid UTF-8 in tool output

The turn stopped before completing. The tool call above did not return a result.
Cause: UnicodeException in readBounded
Reference: 1a2b3c4d
```

- The **headline** is plain language describing what went wrong, not a Haskell
  type name.
- The **cause line** names the underlying error (e.g. `UnicodeException`,
  `resource exhausted (No space left on device)`), so the operator can tell a
  disk-full from a provider outage from a code bug.
- The **reference** is the same short id already used by the log correlation,
  so an operator can find the full detail in `seal.log`.

**The failure entry persists.** Reloading the page, or switching away and back,
still shows it. It is part of the session's history — not a toast that
disappears.

**A live signal fires immediately** — the operator does not have to reload to
learn the turn died. If the tab is not focused, the tab strip indicates the
session has a problem.

**In the CLI/TUI** the failure is printed inline in the conversation, in the
same place and manner as it is today (`turn failed: …`), but carrying the same
improved cause + reference detail as the web entry rather than the generic
`internal error (plain) [ref: x]`.

**In the chat channels** (Signal, Telegram) the failure is sent as a message to
the conversation that started the turn, so a user driving a turn from their
phone learns it failed without opening a browser.

## Constraints

These are invariants a user would notice being violated. They are not
negotiable as part of this change.

1. **Failures never leak secrets.** No secret values, vault contents, or
   credentials appear in a failure entry, on any surface. The existing
   redaction rules apply to failure entries exactly as they apply to tool
   results.
2. **A failure record never causes a second failure.** If the mechanism that
   records the failure is itself unavailable (the transcript writer being dead
   is precisely the case that motivated this change), the user still gets the
   live signal, and the failure is still recorded somewhere an operator can
   find it. Recording a failure must not depend on the thing that just broke.
3. **The tab never stays stuck.** After a failed turn the session returns to a
   not-busy state, as it does today. The failure is reported, not left
   pending.
4. **A failed turn does not corrupt the session.** The session remains usable:
   the user's next message starts a fresh turn normally, with no leftover half
   state.
5. **One failure, one report.** A single failed turn produces exactly one
   failure entry — not one per retry, per nested worker, or per cleanup path.

## Out of scope

Stated explicitly so they are not re-litigated during design review. Each is a
real gap; none is *this* problem.

- **Making the transcript writer resumable after a write error.** PR #355
  already made it fail fast instead of hanging. Continuing after a partial
  write risks a desynced transcript; that trade-off is unchanged here.
- **Repairing already-damaged sessions.** Sessions that already died (e.g.
  `20261127-133020-166`, which ends on a tool call with no result) are not
  repaired. This change prevents recurrence.
- **Retry / resume / continue-after-failure.** Surfacing a failure is not the
  same as recovering from one. No automatic retry.
- **Provider-level error categorization.** Provider errors that the provider
  layer already reports cleanly keep their existing presentation.
- **A general error dashboard or log viewer.** The reference id points at
  `seal.log`; building an in-UI log viewer is a separate feature.
- **The disk-full condition itself.** `~/.seal` was at 96% during the incident
  that motivated this. Monitoring disk headroom is not this change.

## Done when

1. A turn that throws an exception on the web surface shows a failure entry in
   the transcript, and that entry is still present after a page reload.
2. The failure entry names the underlying cause — verified by triggering a
   genuine `UnicodeException` (the original bug) and seeing `UnicodeException`
   (or an unambiguous plain-language equivalent) rather than a bare
   `internal error`.
3. A live signal reaches a focused client when a turn fails, without a reload.
4. A turn that fails while the transcript writer is dead still delivers the
   live signal to the user (constraint 2), and the failure is still findable
   in the session log.
5. The CLI prints a failed turn with the same cause + reference detail as the
   web entry.
6. A turn failing in a chat-channel session (Signal or Telegram) sends one
   failure message to that conversation.
7. One failed turn yields exactly one failure entry (constraint 5), asserted by
   a test that drives a failure through the real path.
8. The existing `withExceptionLogging` tests, transcript-writer tests, and the
   full `make check` gate stay green.
9. `make check` passes; a regression test exists that fails against the
   pre-change code (the "no entry appears on failure" assertion is exactly the
   bug).

## Notes for the design phase

Facts the design should not have to rediscover. These are **not** requirements.

- `withExceptionLogging` (`src/Seal/Logging/Exceptions.hs`) already catches
  synchronous exceptions, logs full detail, and returns a sanitized
  `Either Text`. It rethrows `AsyncException` after logging, deliberately.
- The web path drops the result: `startPlainTurn` (`Gateway/Send.hs:693`) forks
  the turn and passes the `Left` to `sdTurnComplete`, which is a **no-op for
  every non-cron session** (`Command/Serve.hs:383`).
- The CLI path already reports failures (`Channel/Cli.hs:117`,
  `handlePlain` → `ccSend "turn failed: …"`).
- `sanitizeException` passes `TranscriptError` text through verbatim and
  collapses everything else to `internal error (<where>) [ref: <id>]`. The
  real cause (invalid UTF-8) was one layer *below* the `TranscriptError`, so it
  needs to be carried up, not just un-sanitized.
- `BrokerEvent` (`src-gateway-types/Seal/Gateway/Types/Stream.hs:38`) has no
  error variant. The `activity` envelope carries free-form JSON keyed by
  `kind` (`harness-status`, `reply-delivered`), so a new activity `kind` needs
  no new constructor but does need frontend handling. Prefer the smaller of
  the two unless a new event type is clearly warranted.
- Harness entries (`EKHarness`) are **dropped** before reaching the frontend
  unless whitelisted in `userSurfacingOps` (`Gateway/Transcript.hs:681`). A
  durable failure entry must either be whitelisted there or use a kind/route
  that is not filtered.
- `EntryKind` (`Transcript/Entries.hs:44`) has `EKRequest | EKResponse |
  EKHarness | EKCompaction`. Reusing `EKHarness` with a tag is likely cheaper
  than a new constructor (which touches the reconstruction path).
- The transcript writer daemon is per-turn (`withIndexedTranscript`), so "the
  writer is dead" is scoped to the bracket. A dead writer means the durable
  write will *also* fail — hence constraint 2's fallback (the session log
  survives; `appendSessionLog` is a separate `withFile`).
- Bare `forkIO` sites that can swallow an exception entirely:
  `Gateway/Send.hs:693`, `Channel/Cli.hs:260`, `Agent/Runtime/Delegation.hs:606,786,802`,
  `Agent/Runtime/Registry.hs:139`, `Handles/AskReply.hs:412`, and the transcript
  daemons. The RTS default handler sends these to stderr only.
- PR #355 (merged) fixed the underlying UTF-8 decode and the shutdown hang;
  this change is what should have told the operator about it.

## Amendments

### A1 — 2026-11-27: decision 2 narrowed to a closed cause vocabulary

**Status: awaiting operator sign-off.** Raised by the security review during
the design gate.

Decision 2 originally promised a **raw** cause line
(`UnicodeException in readBounded`). The design gate established that this is
jointly unsatisfiable with constraint 1 for arbitrary `show e`, because the
existing redaction machinery (`redactMessages`, `Handles/Transcript.hs:736-766`)
is **opcode-provenance based**, and no secret-*value* scrubber exists anywhere
in `src/`. Shipping raw cause text would have written exception bodies into
`conversation.jsonl` (read by the model) and fanned them out to Telegram/Signal
(irreversible third-party egress), violating constraint 1.

Narrowed to: a fixed string per failure class (see the design's §3.4 table),
never `show e`. Requirement 2's "the reference lets the operator find the full
detail" is preserved — the full text goes to `seal.log` under the same id.

**A middle option the Designer raised, which I recommend (pending your call).**
Constraint 1 forbids "secret values, vault contents, or credentials". A
**function name** like `readBounded` is none of those. So
`Cause: UnicodeException in readBounded` — a type name plus a location drawn
from a *closed set of known throw sites* — satisfies constraint 1 **and**
decision 2 verbatim, recovering ` in readBounded` without any free text. The
cost is a small closed table of `(exception type, site) -> string` in
`classify`, plus one more wire value per cause. The fallback for an unknown site
is the type name alone.

The design currently specifies type-name-only because that is the smallest
change certainly safe. The middle option is strictly better copy for the same
security posture, so I would take it if you agree — it makes decision 2
literally true rather than "intent preserved".

**What the operator loses:** a raw Haskell exception dump in the UI.
**What the operator keeps:** the ability to distinguish a disk-full from a
provider outage from a code bug, which was decision 2's stated purpose.
