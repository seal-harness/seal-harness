# `/last` chat command — learnings

Branch `channels/last-message-requirements`. Task: a `/last [tab] [n]` command
for Signal and Telegram that shows another tab's last message **without
changing the focused tab**.

Delivered: 4 commits, `make check` green at 5009 examples / 0 failures /
"No hints", no regressions across the 5006 pre-existing tests.

## The finding that mattered most: reusing a renderer shipped a misroute

`formatAsk` (`Bubble.hs`) renders a pending question plus a hardcoded footer:
`Reply with a number or type your own answer.`

That footer is **only true when a plain reply actually reaches the question**.
On the `/last` path it does not: a plain reply goes to `answerPendingBgAsk`,
which considers only this conversation's `/bg` sessions and asks the *watch*
path registered with `paWatched` (`Loop.hs` `registerWatchedAsk`, called only
on a watch-mode idle transition). With watch off, a non-focused tab's question
is never registered, so the reply falls through to `sendPlain` → the **focused**
tab, and if that session has its own pending ask the gateway answers *that*
one (`Send.hs`, oldest-pending).

The user's `1`, meant for tab `b`, silently answers a different question on
tab `a`. Reusing `formatAsk` would have shipped that exact instruction.

**Fix**: split it.

```haskell
formatAsk q os = formatQuestionBody q os <> liveAskHint os
```

`/last` uses `formatQuestionBody` only (question + numbered options, no hint)
and appends its own `/b <n>` footer. `formatAsk`'s output is byte-identical, so
the live ask is untouched — and that byte-identity is itself a test, not a
comment.

**Generalisation**: when a renderer's trailing hint encodes a *routing
assumption*, it is not presentation — it is behaviour. Reusing the renderer
reuses the assumption. Split the hint from the body.

## The counter-intuitive one: the watch path is different, and reusing /last's footer there is a regression

The design's own change table said to replace `formatAsk` with `/b`'s footer on
`notifyWatchCompletion` too, on the grounds that its hint is "misleading".

It is not. `notifyWatchCompletion` calls `registerWatchedAsk pendingAsks sid q`
**before** `ccSend`, and `answerPendingBgAsk` explicitly includes
`filter paWatched asks`. So on the watch path a plain reply **does** answer, and
`formatAsk`'s hint is correct there.

Two paths, same question text, opposite answer routing. The difference is one
line (`registerWatchedAsk`) buried 1000 lines away.

**Rule**: before changing a user-facing string that tells the user what to do,
verify the *routing* it describes at that specific call site. Two call sites
that render the same content can have different correct instructions.

## `sessionLookup` needs `SessionMap` — a "no mutable state" signature that cannot work

The design gave `handleLast` a signature with no `SessionMap`, so that "this is
a read" was enforced by the type (no `sessionInsert`, no `ensureWsConn`, no
`registerWatchedAsk`).

But bare `/last` must default to the focused tab, and
`sessionLookup :: SessionMap -> ConversationKey -> IO (Maybe SessionId)`. The
signature and the feature were mutually unsatisfiable, and only the plan review
caught it — two reviewers independently.

**Fix**: the caller (`handleInboundWithSource`, which already holds `sessions`)
resolves the focused session and passes `Maybe SessionId`. The real guarantee is
unchanged: `handleLast` receives no **handle it could write through**.

**Rule**: a "purity by signature" argument is only sound if every operation the
function needs is reachable without the thing you removed. Enumerate the
operations first, then remove.

## `ReadLastN` splits its budget — and the halving broke the join

`readTranscriptEntriesTimed` reserves **up to half** a `ReadLastN n` budget for
trailing conversation lines:

```haskell
trailingBudget = min n (min trailingCount (n `div` 2))
reconBudget    = n - trailingBudget
```

So asking for 40 entries does not give 40 reconstructed entries. Worse: a turn
that *ended* on a tool call puts its `tool_result` in a **trailing** conversation
entry (no `EntryRecord` yet), so the pass/fail join must read both halves.

The plan review pushed back hard enough that the right answer became obvious:
**don't add a limit at all.** `sendLastReply` already fetched the transcript
unbounded on every `/b`, so `/last` reusing `httpGetTranscript` adds no new cost
class — and with the full transcript the join is always correct, so a
`tool_use` with no result becomes a rare robustness case rather than the
ordinary path.

**Rule**: before adding a windowing parameter, check what the existing call
already pays. "Bounded" is only an improvement if the bound does not break a
join you depend on.

## `-Wall -Werror` RED mechanics

A brand-new module cannot both compile and fail its tests. The workable shape:

- `_`-patterned stubs returning a concrete wrong value of the right type
  (`renderLast _ = ""`). Avoids `-Wunused-matches` (no named binder),
  `-Wpartial-fields` (no record selected), and hlint's `Use const`.
- Never `undefined`/`error` (banned by AGENTS.md) and never a record literal
  with a missing field (`-Wpartial-fields`).
- **The one unavoidable RED is a new constructor**: adding `ChatLast` to
  `ChatRoute` makes `handleInboundWithSource`'s `case route body of`
  incomplete, so the dispatch arm must land in the same commit as the
  constructor.

## `Show` removal has a concrete test-side cost

Dropping `Show` from content-bearing types is a real leak guard (a future
`dbg (show view)` becomes a compile error). But hspec's `shouldBe` needs `Show`
for its failure message, so:

`resolveLast inp \`shouldBe\` LastWorking h Nothing` — **does not compile**.

Plan for it: export small pure projections (`viewTag :: LastView -> Text`,
`renderedTools :: LastView -> [Text]`) and assert through those, or through the
rendered `Text`. Otherwise the first test you write forces you to re-add `Show`
and silently delete the guard.

## Haskell literal escape gotcha, in a test

`quoteBody "a\r\nb\x2028c"` did not mean what it looked like. `\x2028c` is a
**single** character — Haskell hex escapes are greedy and `c` is a hex digit.

Use `\&` to terminate the escape: `"b\x2028\&c"`.

The test failed with `but got: > a\n> b𠊌` — which is how it was caught.

## The `cbToFrontend` fallback defeats a type-based allowlist

`cbToFrontend`'s catch-all rewrites any unrecognised block tag to

```haskell
object ["type" .= ("text" :: Text), "text" .= <raw block JSON>]
```

That satisfies the natural extraction rule *verbatim* (`type == "text"` **and** a
string `text` field), so an allowlist written against `type` cannot exclude it —
the fallback has already forged the type. For a tool-use-shaped block the raw
JSON contains `input`.

Currently unreachable (`ContentBlock` has exactly four constructors, all
handled), so it is latent. Two fixes, both one line: give the fallback a
distinct `type` (`"unrecognized"`), or extract from the on-disk `tag` instead of
the rewritten shape.

**Rule**: an allowlist is only sound if the field it keys on cannot be
manufactured by a fallback upstream.

## Process: seven subagent timeouts

Seven review agents (Architect ×3, CTO ×2, PM, code-review) hit the 1200s
timeout across the design and plan gates. The foreground `AGENT_MANAGE` calls
with 5 parallel reviewers succeeded; background ones and large verification
prompts timed out.

Practical consequence: verification-focused prompts with 10 numbered checks and
"read the whole repo" framing blow the budget. Prompts that say "be sparing:
targeted greps, not broad reads" and cap at ~6 checks completed more often.

When a reviewer does time out, the orchestrator ran the checks itself — and
that is how the constraint-2 leak test got written (see below).

## A test that failed correctly, and the invariant it became

The ad-hoc verification script for constraint 2 (no tool input, result, system
prompt, or thinking block may render) became a permanent test instead of a
throwaway. It failed on first run — because the *test* asserted `SHELL_EXEC`
appears, but a response with text renders the text, not the tool line. The
rendered output was clean.

Two lessons:

1. Assert invariants as tests, not scripts. The test is what a future edit to
   `extractEntry` has to survive.
2. When a leak test fails, check whether the leak is real or the assertion is
   wrong — the failure output (`predicate failed on: "📔 Tab b (t) — last
   message:\n\nok"`) showed no sentinel at all.

## Scope discipline: what the gate removed, and what it should have

Three additions were deleted after review pushback, all correctly:

- A `LastCooldowns` TVar + a 2-second `ListsCache` for `/api/lists` — the
  requirements list command rate limiting as **out of scope**, and
  `handleTabList` already calls `cccGetLists` per invocation with no cache. The
  plan was implementing a limiter while filing rate limiting as a follow-up.
- A four-branch `/b` matrix plus `isAnswerShaped` — retained only the single
  branch the operator's decision requires (answer-shaped payload + empty
  `assistant` response ⇒ "no question has been asked"). The rest fixed nothing;
  the actual defect (a literal `"1"` written into the target tab) lives in
  `/send` and is a separate change.
- A `cccGetTranscript` seam with a count cap (see above).

Two optional work units were also **not** done: the `cbToFrontend` fallback
change (touches the web frontend, which the requirements exclude) and the
Telegram menu entry (no DoD).

## The requirements doc contradicted itself, and only the operator could fix it

Behaviour said "`/last` shows the question and its options"; constraint 2 said
"never tool inputs, never secrets". The confirmation-gate prompt **is** tool
input:

```haskell
buildConfirmationPrompt (OpName n) inp =
  "Allow " <> n <> " " <> T.pack (BLC.unpack (A.encode inp)) <> "? [y/N] "
```

It can carry a credential in a `SHELL_EXEC` argv.

A plan cannot amend an approved requirements doc — the doc is *the baseline the
plan is measured against*. The correct move was to ask the operator, and the
amendment was recorded in the requirements doc's own `## Amendments` section
rather than in the plan.

Also worth knowing: the "compromise" of rendering only option-less question
bodies **does not work**. `API.hs` omits the `options` key entirely when empty,
so a confirmation-gate ask and an open-ended `ASK_HUMAN` are byte-identical on
the wire. That path would silently drop real questions too.

## Rebutting a reviewer: `/b` already read another tab

A security reviewer claimed `/last` converts a pre-existing write-only
cross-conversation gap into a read oracle. Verified wrong: `handleFocus` already
calls `sendLastReply`, which already fetches and sends another tab's last
assistant reply. `/last` added no new assistant-text capability.

It **did** add one for **question text** — `handleFocus` never called
`/questions`. Accepting the rebuttal wholesale would have hidden a real new
exposure. The honest answer was "narrowed to assistant text; genuinely new for
questions".
