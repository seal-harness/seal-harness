# `/last` — Implementation Plan (rev 3)

**Design**: `docs/superpowers/specs/2026-11-26-chat-last-message-design.md` (rev 5)
**Requirements**: `docs/superpowers/requirements/2026-11-26-chat-last-message-requirements.md`
**Branch**: `channels/last-message-requirements`
**Execution**: 3 core work units (WU-A, WU-B, WU-C) + 2 optional (WU-D, WU-E)

## Why rev 3 is much smaller

Plan Review Gate round 2 returned FAIL with two findings I verified against
source, and both were right — including one where rev 2 would have shipped a
**regression**.

### The big simplification: no transcript seam

`sendLastReply` already fetches the transcript **unbounded** on every `/b`
(`Loop.hs:1845`: `eEntries <- httpGetTranscript mgr apiBase sid`). So `/last`
reusing `httpGetTranscript` adds **no new cost class** over the status quo.

Deleting the seam removes, in one stroke:

- `cccGetTranscript` (the only new `ChatChannelConfig` field) and its two-site edit
- `httpGetTranscriptLimited`, `transcriptUrl`, the `HttpClientSpec` additions
- `entryFetchLimit` and the entire design §3.2 `ReadLastN` halving analysis
- the "limit is never 0 / ≥ 20" invariant

And it makes the pass/fail join **strictly more correct**: with the full
transcript in hand, a `tool_result` in a trailing conversation entry is always
in the window, so `LtsUnfinished` becomes a rare robustness case rather than
the ordinary path for a turn that ended on a tool call.

### The regression rev 2 would have shipped

Rev 2 (and design E6) proposed replacing `formatAsk` with the `/b` footer on
the **watch** path. That is wrong, verified:

- `notifyWatchCompletion` calls `registerWatchedAsk pendingAsks sid q`
  (`Loop.hs:1042`) **before** `ccSend` (`:1044`).
- `answerPendingBgAsk` explicitly includes those asks
  (`watched = [ … | ask <- filter paWatched asks ]`, `Loop.hs:1969-1976`).

So on the watch path a plain reply **does** answer, and `formatAsk`'s "Reply
with a number or type your own answer" is **correct** there. Swapping in
`/b` would tell the user to type a longer command that resolves to the same
thing — a behaviour change to a working, shipped surface, on no DoD.

**Dropped.** The watch path keeps `formatAsk` verbatim.

### Other rev-2 defects fixed

| # | Defect | Fix |
|---|---|---|
| R1 | WU-1's stub passed `SessionMap`; WU-3's DoD forbade it — and `sessionLookup` needs it (`Types.hs:111`), so **neither order compiled** | WU-A owns `handleLast`'s **final signature** (`Maybe SessionId`) *and* the stub body; WU-C owns only the body |
| R2 | P3 claimed "two pure chunk tests"; none existed in any WU | Added to **WU-B**, parameterised by the real limits |
| R3 | `lastHelp`/`isLastHelpArg` had no owning WU | **WU-A** |
| R4 | No DoD pinned any error string | **WU-A** (`renderLastError`) + requirement literals reconciled below |
| R5 | `/<tab>` focus state had no DoD | **WU-C** |
| R6 | Design §8.2 still mandated 3 tests for the deleted cooldown | Design §8.2 rows removed |
| R7 | Design §8.1 still had 2 truncation rows that §5.6.2 deleted | Design §8.1 rows removed |
| R8 | Goldens were prose, not literals | §"Golden strings" below pins every byte |
| R9 | Property 1b (WU-D's effect) was sequenced before WU-D | Moved to WU-D |
| R10 | WU-0's test called non-exported `cbToFrontend` | Routes through exported `convLineToFrontend` |
| R11 | `nameOf` export had no test/owner | `TabRenderSpec.hs` added to WU-B scope |
| R12 | `/last b 2 for more` (formula) contradicted the requirements' `/last b 5 for more` (example) | Hint is **`/last <c> 5 for more.`**, a fixed literal — see §"Hint" |

---

## 1. Work units

### WU-A — route, args, help, error text, `handleLast` signature

**Scope (exclusive)**
- `src-chat-channels/Seal/Channels/Chat/Route.hs`
- `src-chat-channels/Seal/Channels/Chat/LastRender.hs` (**create** — args/error half)
- `src-chat-channels/Seal/Channels/Chat/Loop.hs` — dispatch arm **and** `handleLast`'s signature + stub body
- `test/Seal/Channels/Chat/RouteSpec.hs`
- `test/Seal/Channels/Chat/LastRenderSpec.hs` (**create**)
- `seal-harness.cabal` (exposed-modules + other-modules) — **WU-A owns**
- `test/Main.hs` (import block **and** spec list) — **WU-A owns**

**TDD**
1. RED `RouteSpec`: `/last`→`ChatLast ""`; `/last b`→`ChatLast "b"`;
   `/last b 3`→`ChatLast "b 3"`; `/last b 2 junk`→`ChatLast "b 2 junk"`;
   **`/l`→`ChatFocus 21`** (non-collision); `/lasty`→`ChatSlash "lasty"`.
2. GREEN `route`: one arm between `bg` and `otherwise`
   (`T.toCaseFold (T.takeWhile (/= ' ') rest) == "last"`).
3. RED `LastRenderSpec`: the 12 `parseLastArgs` rows (design §2.2), all 7
   `renderLastError` constructors, `lastHelp` content, `isLastHelpArg`.
4. GREEN those.
5. **Compile-wall step** — `handleLast`'s final signature, written once:
   ```haskell
   handleLast
     :: ChatChannel c
     => ChatChannelConfig -> c -> Maybe SessionId
     -> ConversationKey -> Text -> IO ()
   handleLast _cfg chan _mSid _key _args = ccSend chan ""   -- stub
   ```
   and the dispatch arm:
   ```haskell
   Right (ChatLast args) -> do
     mSid <- sessionLookup sessions key
     handleLast cfg chan mSid key args
   ```
   `handleLast`'s **signature is final here**; WU-C replaces only the body.

**DoD**
- [ ] 5 route cases + the `/l` non-collision test pass
- [ ] 12 `parseLastArgs` rows pass, incl. `"bb"`→`LENoSuchTab "bb"`, `"B"`→tab b
- [ ] all 7 `renderLastError` constructors rendered and asserted
- [ ] `lastHelp` documents `[tab] [n]`, the 1–5 clamp, "first arg is always the tab", **"never changes the focused tab"**, **"answer with `/b <n>`"**
- [ ] `/last -h` and `/last --help` render `lastHelp`; `/last b -h` does **not** (matches `/watch on -h`, `Loop.hs:920-924`)
- [ ] `/last` is **not** in the gateway `CommandSpec` registry
- [ ] `LastRender` registered in cabal exposed-modules **and** both `test/Main.hs` lists
- [ ] `handleLast`'s signature takes `Maybe SessionId`; no `SessionMap`, no `wsConns`, no `PendingAsks`
- [ ] `make check` green

**Error-string reconciliation (R4).** The requirements give 4 literals; design
§5.7 adds next-step hints. The requirements are the baseline, so the four
requirement strings are **exact**, and hints are appended only where the
requirements themselves show one:

| Case | Rendered (exact) |
|---|---|
| no such tab | `last failed: no such tab z — /tab list` |
| tab has no session | `last failed: tab b has no session (harness tab)` |
| no current tab | `last failed: no current tab` |
| transcript unreadable | `last failed: couldn't read tab b's transcript — try again in a moment` |
| bad count (not in requirements) | `last failed: "<t>" isn't a number — use /last <tab> 1-5` |
| lists fetch failed | `last failed: couldn't read the tab list — try again in a moment` |
| questions fetch failed | `last failed: couldn't read tab b's question — try again in a moment` |

`<t>` goes through `singleLine` (§5.7): newlines flattened, 16 chars + `…`.

---

### WU-B — extraction, resolution, rendering, `formatAsk` split, chunk tests

**Scope (exclusive)**
- `src-chat-channels/Seal/Channels/Chat/LastRender.hs` (render half)
- `src-chat-channels/Seal/Channels/Chat/Bubble.hs` (`formatQuestionBody`/`liveAskHint` split)
- `src-chat-channels/Seal/Channels/Chat/TabRender.hs` (export `nameOf`)
- `test/Seal/Channels/Chat/LastRenderSpec.hs`
- `test/Seal/Channels/Chat/BubbleSpec.hs`
- `test/Seal/Channels/Chat/TabRenderSpec.hs` (R11)

**No new seams.** Fetches use the existing `cccGetLists` / `httpGetTranscript` /
`cccGetQuestions`.

**TDD**
1. RED `BubbleSpec`: the **real** regression guard — `formatAsk q []` and
   `formatAsk q [2 options]` produce byte-identical output to today. Pin the
   literals (`Reply with your answer.` / `Reply with a number or type your own answer.`),
   not a tautological `f == g <> h`.
2. GREEN: split into `formatQuestionBody` + `liveAskHint`; move
   `formatOption` into `formatQuestionBody`; export both.
   **Verify the 4 call sites** still behave: `Loop.hs:1044` (watch — keeps
   `formatAsk`), `:1643`/`:1649` (`handleAsk`), and
   `formatQuestionWithOptions = formatAsk` (`:2156`, used by `Cli.hs:167,214`,
   pinned `LoopSpec:1563-1571`).
3. RED `TabRenderSpec`: `nameOf`'s title cascade (exported now).
4. RED `LastRenderSpec`: `extractEntry` (thinking dropped, unknown `type`
   dropped, request-direction contributes no text, `"\n\n"` join),
   `safeOpLabel`, the `tool_use_id → is_error` join (3 states),
   `isLegacyPayload`, `quoteBody`, `normalizeNewlines`, `singleLine`,
   `viewTag`, `renderedTools`.
5. GREEN those.
6. RED: the **golden strings** (§"Golden strings" below), byte-exact.
7. RED: **chunk attribution** (R2), parameterised by both real limits:
   - `chunkMessage ChunkUtf16Units 3900` (Telegram, `Telegram.hs:225`)
   - `chunkMessage ChunkUtf8Bytes 2048` (Signal, `Signal.hs:452`)
   Assert for each: `T.concat chunks ≡ rendered`, and each item's `b: `
   prefix shares a chunk with that item's first characters.
8. GREEN `renderLast` + `resolveLast`.

**DoD**
- [ ] `formatAsk` byte-identical to today at all 4 call sites (real literal assertions)
- [ ] `formatQuestionBody` never emits `Reply with`
- [ ] `quoteBody`: blank line → bare `>` (**no trailing space**); non-blank → `> `; U+2028/`\r`/U+0085/U+2029 normalised **before** prefixing
- [ ] `singleLine`: newlines flattened, 16 chars + `…`
- [ ] 3-row tool table renders 3 distinct strings
- [ ] `LastWorking Nothing` → `no tools have completed yet`
- [ ] `resolveLast` never yields `LastWorking (Just (… LtsUnfinished))`
- [ ] `renderLast (LastMessages h [])` ≡ `LastEmpty` bytes
- [ ] golden strings byte-exact, **U+2014** everywhere a dash appears
- [ ] chunk attribution: both limits, both assertions each
- [ ] `TabHeading`/`LastView`/`AssistantItem`/`ToolOutcome`/`PendingQuestion` have **no `Show`**; tests assert via `renderLast`/`viewTag`/`renderedTools`

---

### WU-C — loop wiring: `handleLast` body, focus, watch, `/b` branch

**Scope (exclusive)**
- `src-chat-channels/Seal/Channels/Chat/Loop.hs` (everything except WU-A's arm + signature)
- `test/Seal/Channels/Chat/LoopSpec.hs`

**TDD**
1. RED `LoopSpec`: DoD 1 (`/last`, `/last b`, `/last b 3`), DoD 2, DoD 4,
   DoD 5, the 7 error paths, the disclosure trace, the one `/b` branch, the
   watch tool-line, **the `/<tab>` focus block (R5)**.
2. GREEN `handleLast`'s body: `isLastHelpArg` → `parseLastArgs` →
   `cccGetLists` → resolve tab from `ljTabs` → `httpGetTranscript` +
   `cccGetQuestions` → `resolveLast` → `renderLast` → `ccSend`.
3. GREEN `handleFocus` (§6.2: render `LastMessages`/`LastWorking`/`LastQuestion`;
   suppress `LastEmpty` + fetch failure), `sendWatchNotification` (body only —
   **keep `formatAsk` on `notifyWatchCompletion`**), and the one `handleInject`
   branch.
4. Delete `sendLastReply` (one caller `Loop.hs:570`, not exported). Update its
   two haddocks (`:531-534`, `:574-578`).

**DoD**
- [ ] `/last`, `/last b`, `/last b 3` return the right tab's content
- [ ] channel claim met by construction (`ccSend` only; both adapters chunk via
      `Bubble.chunkMessage`) — **and** verified by WU-B's two chunk tests
- [ ] no-text turn shows opcode + pass/fail (DoD 2)
- [ ] DoD 4: `sessionLookup` unchanged after `/last`; a fresh map still
      `Nothing`; `getRecorders seams == []`
- [ ] DoD 5: question / working / empty render distinctly; none silent
- [ ] **`/<tab>` focus ends with the rendered block** (R5); `LastEmpty` and
      fetch failure suppressed
- [ ] watch: no text + a tool ⇒ the tool line; no text + no tool ⇒ the
      fallback line; **with text ⇒ byte-identical to today**, and the 12
      existing `finished thinking` assertions stay green **unchanged**
- [ ] watch question path **keeps `formatAsk`** (verified: the ask is
      registered at `Loop.hs:1042`, so plain replies answer it)
- [ ] `/b` with an answer-shaped payload + empty `assistant` response ⇒ the
      "no question waiting" line, not silence
- [ ] `dbg`/trace: tab char + view + a boolean only; never item text, question
      text, or title
- [ ] `sendLastReply` deleted; no dangling imports
- [ ] `make check` green

---

### WU-D — OPTIONAL hardening: `cbToFrontend` fallback (not a dependency)

**Why optional.** The fallback is **unreachable for well-formed data**:
`ContentBlock` has exactly four constructors (`Class.hs:68-73`) and all four
are handled (`Transcript.hs:612-633`). So design §4.1's rule is sound *today*
by an argument from the four constructors — not because of this change.

**Scope**: `src/Seal/Gateway/Transcript.hs`, extend
`test/Seal/Gateway/TranscriptSpec.hs` (**exists**, 50 KB, `cabal:505`,
`test/Main.hs:38` — extend, do not create).

**Change**: fallback's `"type"` `"text"` → `"unrecognized"`.

**R10**: `cbToFrontend` is **not exported** (`Transcript.hs:11-31`). Test via
the exported `convLineToFrontend`, asserting a non-`Cb*` tag's sentinel does
not appear as a `type:"text"` block.

**Blast radius, stated.** `cbToFrontend` feeds the HTTP seed, the WS broadcast,
and `convLineToFrontend`. The frontend has **no `unrecognized` handler** —
unknown `type`s are dropped (`ChatArea.tsx:1877`, `:1889`, `:1899`) — so today
such a block renders as **raw JSON prose** in the web transcript, and after
this change it **silently disappears**. Both are wrong; disappearing is safer
(raw JSON of a malformed block may contain tool input). This is a **behaviour
change to a surface the requirements declare out of scope**, so it needs
operator sign-off (§5).

**R9**: the E1 QuickCheck property (design §8.1(1b)) belongs **here**, not in
WU-B.

**DoD**
- [ ] a non-`Cb*` tag does not yield `type:"text"` (via `convLineToFrontend`)
- [ ] a sentinel in that block does not appear in the encoded output
- [ ] the four known tags byte-identical to before
- [ ] the E1 QuickCheck property passes
- [ ] `make check` green

---

### WU-E — OPTIONAL: Telegram menu entry

**No requirement basis** — discoverability only (design §2.3). Design itself
concedes Signal gets nothing, so this *widens* an accepted asymmetry. Include
only if the operator wants Telegram parity.

**Scope**: `TelegramCommands.hs`, `TelegramCommandsSpec.hs`.

**Change**: append `BotCommand "last" "Show a tab's last message"` after
`watch` → `[help, bg, watch, last]`.

**DoD**
- [ ] all 6 pinned assertions updated (`:36-41`, `:43-52`, `:57`, `:64`, `:69-71`, `:108-111`)
- [ ] 100-cap test still green (`:84-85`, unaffected)
- [ ] module haddock (`:96-97`) updated
- [ ] `make check` green

---

## 2. Golden strings (R8 — pinned, not prose)

Every literal below is normative. `—` is **U+2014**.

Heading: `📔 Tab <c> (<title>) — `, or `📔 Tab <c> — ` when the title is empty.

| View | Heading suffix | Body |
|---|---|---|
| `LastMessages h [x]` | `last message:` | `\n\n` + `x` |
| `LastMessages h [x,y]` | `last 2 messages:` | `\n\n` + `b: x` + `\n\n` + `b: y` |
| `LastMessages h []` | *(renders as `LastEmpty`)* | — |
| `LastWorking h (Just t)` | `still working:` | `\n\nlast completed: ` + toolLine t |
| `LastWorking h Nothing` | `still working:` | `\n\nno tools have completed yet` |
| `LastQuestion h q` | `waiting on your answer:` | `\n\n` + quoteBody (formatQuestionBody …) + `\n\n` + footer |
| `LastEmpty h` | `no messages yet.` | *(no body)* |

`toolLine`: `LtsOk` → `💻 SHELL_EXEC`; `LtsFailed` → `💻 SHELL_EXEC (failed)`;
`LtsUnfinished` → `💻 SHELL_EXEC (no result)`; `lsaName Nothing` →
`⚡ (unknown opcode)`.

`LriToolOnly o` inside `LastMessages` → `toolLine o <> " — no reply text."`

**Footer (normative literals).**
- options present: `Answer with /b 1 or /b <your answer>.`
- no options: `Answer with /b <your answer>.`
(`<b>` is the actual tab char.)

**Hint (R12 — fixed literal, resolving the formula/example conflict).**
Appended as `<> " " <> hint` after the whole block, iff the block contains
**no `LriText`** and `length items >= lriCount` (window saturated, so more may
exist):

- `k < 5` → `"/last " <> tabChar <> " 5 for more."`
- `k == 5` → `"/b to switch to that tab."`

The requirements' example shows `/last b 5 for more.`; rev 2's
`min 5 (2*k)` formula produced `/last b 2` for `k=1`, contradicting it. The
fixed literal matches the requirements and still saturates (a second `/last b 5`
is not re-offered because `length items == lriCount == 5` fails the `k < 5`
branch). **`lriItems` is the resolved, rendered list** — `length items` in the
rule above means `length` of the list `LastMessages` carries.

---

## 3. Dependency graph

```
WU-A ──> WU-B ──> WU-C ──> final review
WU-D (optional, parallel, needs sign-off)
WU-E (optional, parallel, needs sign-off)
```

WU-A must land first: it owns the cabal/`test/Main.hs` merge hotspots and
`handleLast`'s final signature. WU-C must not start from a stale `Loop.hs`.

---

## 4. Quality gates per work unit (blocking)

Run by the **orchestrator**, never trusted from the implementing agent:

```bash
make check      # build + test + lint (-Werror clean, hlint: No hints)
make test       # the .coverage-thresholds.json enforcement command
git diff --name-only   # verify file scope
```

Then a **fresh** adversarial reviewer per work unit, each DoD item with
`file:line` evidence. On FAIL: fix → re-validate → **new** reviewer (max 3,
then escalate).

## 5. Final comprehensive review

- [ ] `git diff main..HEAD` reviewed whole
- [ ] `make check` green
- [ ] WU-A's stub body fully replaced by WU-C (no `ccSend chan ""` left)
- [ ] No leftover TODO/FIXME
- [ ] File scope respected across all WUs
- [ ] All 5 requirements "Done when" items demonstrably met
- [ ] The 12 pre-existing `finished thinking` assertions unchanged and green
- [ ] `formatAsk` output unchanged at all 4 call sites

---

## 6. Operator sign-off — RESOLVED 2026-11-26

**All four items are signed.** The decisions are recorded in the requirements
doc's new **Amendments** section (A1–A5), which the operator approved:

| Item | Decision | Recorded as |
|---|---|---|
| Constraint 2 vs question text | **Show the question** (operator chose option A). Scope: a *currently pending* question only; the prompt's own argv leak is fixed separately | A1 |
| "number or plain text" answer path | Replaced by `/N <answer>`; `/last` never changes focus | A2 |
| WU-D's web-transcript change | Approved despite the web frontend being out of scope | A4 |
| `/last <c> 5 for more` hint | Fixed literal, matching the requirements' example | A3 |

WU-B and WU-C are unblocked. **WU-D and WU-E remain optional** and are not
required by any DoD.

### Original blocker text (superseded, kept for the record)

The Plan Review Gate found that rev 2 tried to amend an approved requirements
doc inside a plan. That is not the plan's to do. One consolidated decision is
needed on four items:

**(i) Constraint 2.** Behaviour says "`/last` shows the question and its
options"; constraint 2 says "never tool inputs, never secrets". The
confirmation-gate prompt is `"Allow " <> opName <> " " <> A.encode input <> "?
[y/N] "` (`Agent/Loop.hs:741-743`) — it **is** tool input, and can carry a
credential in argv. Options: amend constraint 2 in writing, or render no
question body at all (collapse `LastQuestion` to a "waiting on your answer —
`/b` to switch" line, which is honest and loses DoD 5's detail but violates
nothing).

> Note: rev 2's proposed middle path ("option-less ⇒ footer only") **does not
> work**: `API.hs:3264-3266` omits the `options` key when empty, so a gate ask
> and an open-ended `ASK_HUMAN` are byte-indistinguishable on the wire. That
> middle path would drop open-ended questions too.

**(ii) The "number or plain text" answer sentence.** Requirements say a user
answers a question "with a number or plain text". That is **false** for a
non-focused tab (`SeAsk` is focus-filtered, `Loop.hs:880`; `answerPendingBgAsk`
only sees bg sessions + `paWatched` asks, `:1969-1976`), and the operator's
decision replaces it with `/N <answer>`. The requirements' wording should be
corrected.

**(iii) WU-D's web-transcript behaviour change.** An unknown-tag block
currently renders as raw JSON prose in the web UI; after WU-D it disappears.
Out-of-scope surface, behaviour change.

**(iv) The `/last b 5 for more` literal.** Fixed per §2 above, matching the
requirements' example. Confirm.

Until these are recorded **in the requirements doc, by the operator**, WU-B and
WU-C do not start. WU-D and WU-E likewise.

---

## 7. Follow-ups (filed, not fixed here)

1. `buildConfirmationPrompt` (`Agent/Loop.hs:741-743`) embeds tool input —
   possibly a credential in argv — into the question text;
   `handleToolCallActivity` uses `formatToolLine mempty` so `SECRET_MANAGE`
   input is not redacted on the live chat tool line. One fix repairs both.
2. `/send` starts a turn before the channel can react, so an expired `/b <n>`
   still writes a literal message into the target tab (design §6.4 makes it
   visible). Also carries `✓ b: <label>` attribution and the full
   `isAnswerShaped` matrix trimmed from WU-C.
3. The disclosure trace goes to `dbg` (stderr, not persisted). Audit-log
   routing is separate.
4. `allow_from` is parsed but never enforced (pre-existing; requirements
   out-of-scope). `/last` sharpens its consequences (design §10.3).
5. Command rate limiting (pre-existing, requirements out-of-scope). **No
   cooldown or cache in this plan** — `/last` calls `cccGetLists` exactly as
   `handleTabList` does (`Loop.hs:2261`).
6. The tab **title** in the heading may be a user snippet (`lthTitle`), so it
   is not assistant-authored either; the requirements' own example shows one,
   but the §6(i) amendment should name it.
